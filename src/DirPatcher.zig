const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Diagnostic = @import("Diagnostic.zig");
const StripDirs = @import("Patch.zig").StripDirs;

const DirPatcher = @This();

allocator: Allocator,
files: std.StringArrayHashMapUnmanaged(Status),
src: std.fs.Dir,
out: std.fs.Dir,
tmp: std.fs.Dir,
diagnostic: Diagnostic,

const Status = struct {
    cur: ?Location,
    old: Location,
    const init = .{ .cur = .src, .old = undefined };
};
const Location = enum { src, out, tmp };

pub const Options = struct {
    src: std.fs.Dir,
    out: std.fs.Dir,
    tmp: std.fs.Dir,
};

pub fn create(allocator: Allocator, options: Options) DirPatcher {
    return .{
        .allocator = allocator,
        .files = std.StringArrayHashMapUnmanaged(Status).empty,
        .src = options.src,
        .out = options.out,
        .tmp = options.tmp,
        .diagnostic = .init(allocator),
    };
}

pub fn countSourceFiles(dir_patcher: DirPatcher) usize {
    return dir_patcher.files.count();
}

pub fn addSourceFile(dir_patcher: *DirPatcher, path: []const u8) !void {
    try dir_patcher.files.put(dir_patcher.allocator, try dir_patcher.allocator.dupe(path), .init);
}

pub fn apply(dir_patcher: *DirPatcher, patch: []const u8, strip_dirs: StripDirs) !void {
    for (dir_patcher.files.values()) |*status| status.old = status.cur.?;

    var fbs = std.io.fixedBufferStream(patch);
    var first_maybe: ?struct { header: Header, pos: usize } = null;

    while (fbs.pos < patch.len) {
        const pos_old = fbs.pos;
        if (try Header.parse(&fbs, &dir_patcher.diagnostic)) |header| {
            if (first_maybe) |first| blk: {
                const unified = if (header == .unified)
                    pos_old
                else if (first.header == .unified)
                    first.pos
                else
                    break :blk;

                const git = if (header != .unified)
                    pos_old
                else if (first.header != .unified)
                    first.pos
                else
                    break :blk;

                dir_patcher.diagnostic.clear();
                dir_patcher.diagnostic.print(
                    "Found Git header on line {d} and non-Git header on line {d}.\n",
                    .{
                        std.mem.count(u8, patch[0..git], "\n") + 1,
                        std.mem.count(u8, patch[0..unified], "\n") + 1,
                    },
                );
                return error.InvalidPatch;
            } else {
                first_maybe = .{ .header = header, .pos = pos_old };
            }
            try applyInner(dir_patcher, &fbs, strip_dirs, header);
        } else {
            fbs.pos = if (std.mem.indexOfPos(u8, patch, fbs.pos, '\n')) |newline|
                newline + 1
            else
                patch.len;
        }
    }

    if (first_maybe == null) {
        dir_patcher.diagnostic.clear();
        dir_patcher.diagnostic.append("Patch does not touch any files.\n", .{});
        return error.InvalidPatch;
    }

    // Clears old locations and removes deleted files from hash map.
    var i: usize = 0;
    while (i < dir_patcher.files.count()) {
        const status = &dir_patcher.files.values()[i];
        if (status.cur) |_| {
            status.old = undefined;
            i += 1;
        } else {
            dir_patcher.files.swapRemoveAt(i);
        }
    }
}

/// Moves output files in other directories to the output directory.
pub fn commit(dir_patcher: *DirPatcher) !void {
    var it = dir_patcher.files.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const status = entry.value_ptr;
        const file_dir = switch (status.cur.?) {
            .src => dir_patcher.src,
            .out => continue,
            .tmp => dir_patcher.tmp,
        };
        std.fs.Dir.updateFile(file_dir, path, dir_patcher.out, path, .{}) catch |err| {
            const dir_name = switch (status.cur.?) {
                .src => "source",
                .out => unreachable,
                .tmp => "temporary",
            };
            dir_patcher.diagnostic.clear();
            dir_patcher.diagnostic.print(
                "failed to copy file '{s}' from {s} directory to output directory",
                .{ path, dir_name },
            );
            return err;
        };
        status.cur = .out;
    }
}

/// Represents a valid (incomplete) patch header in Git or unified format, with the following
/// deliberate limitations, some of which mirror the behavior of `git apply`: Does not capture
/// (dis)similarity indices. Does not capture blob hashes. Does not capture old modes, only new
/// modes.
const Header = union(enum) {
    unified: Unified,
    edit: Edit,
    create: CreateDelete,
    delete: CreateDelete,
    copy: CopyMove,
    move: CopyMove,

    const Unified = struct { path: []const u8 };
    const Edit = struct { path: []const u8, mode: ?Mode };
    const CreateDelete = struct { path: []const u8, mode: Mode };
    const CopyMove = struct { from: []const u8, to: []const u8, mode: ?Mode };

    const Mode = enum { normal, executable };

    fn parse(fbs: *std.io.FixedBufferStream([]const u8), diagnostic: *Diagnostic) !?Header {
        _ = diagnostic;

        if (std.mem.startsWith(u8, fbs.buffer[fbs.pos..], "diff --git ")) {
            // TODO: Parse Git header
        } else if (std.mem.startsWith(u8, "--- ")) {
            // TODO: Parse unified header
        } else {
            return null;
        }
    }

    fn parsePath(
        allocator: Allocator,
        fbs: *std.io.FixedBufferStream([]const u8),
        diagnostic: *Diagnostic,
    ) ![]const u8 {
        if (fbs.pos >= fbs.buffer.len) {
            diagnostic.clear();
            diagnostic.append("Expected path");
        } else if (fbs.buffer[fbs.pos] == '"') {
            // Parse a C-escaped path wrapped in double quotes. The following C escape sequences are
            // not recognized as Git does not use them: \' \? \x... \u... \U...
            fbs.pos += 1;
            const list = std.ArrayListUnmanaged(u8).empty;
            var end = fbs.buffer.len;
            outer: while (fbs.pos < end) {
                switch (fbs.buffer[fbs.pos]) {
                    '"' => {
                        fbs.pos += 1;
                        return list.items;
                    },
                    '\\' => {
                        if (fbs.pos + 1 >= fbs.buffer.len) {
                            diagnostic.clear();
                            diagnostic.append("Unescaped backslash", .{});
                            break :outer;
                        }
                        switch (fbs.buffer[fbs.pos + 1]) {
                            '"' => try list.append(allocator, '"'), // double quote
                            '\\' => try list.append(allocator, '\\'), // backslash
                            'n' => try list.append(allocator, '\n'), // line feed
                            'r' => try list.append(allocator, '\r'), // carriage return
                            't' => try list.append(allocator, '\t'), // tab
                            'a' => try list.append(allocator, '\x07'), // bell
                            'b' => try list.append(allocator, '\x08'), // backspace
                            'v' => try list.append(allocator, '\x0b'), // vertical tab
                            'f' => try list.append(allocator, '\x0c'), // form feed
                            else => {
                                // Octal value between 0 and 255, at most 3 octal digits.
                                var byte: u8 = 0;
                                var n: usize = 0;
                                while (n < 3 and n < fbs.buffer.len - fbs.pos - 1) : (n += 1) {
                                    switch (fbs.buffer[fbs.pos + n + 1]) {
                                        '0'...'7' => |digit| {
                                            if (byte >= 32) {
                                                diagnostic.clear();
                                                diagnostic.append("Octal value exceeds 255", .{});
                                                break :outer;
                                            }
                                            byte *= 8;
                                            byte += @as(u3, @intCast(digit - '0'));
                                        },
                                        else => break,
                                    }
                                }
                                if (n == 0) {
                                    diagnostic.clear();
                                    diagnostic.append("Unrecognized escape sequence", .{});
                                    break :outer;
                                }
                                fbs.pos += n - 1; // Note the additional increment a bit below.
                                try list.append(allocator, byte);
                            },
                        }
                        fbs.pos += 2;
                    },
                    '\n' => end = fbs.pos,
                    else => |byte| {
                        if (byte >= 0x20 and byte != 0x7f) {
                            fbs.pos += 1;
                            try list.append(allocator, byte);
                        } else {
                            diagnostic.clear();
                            diagnostic.print("Unescaped control code \\{o}", .{byte});
                            break :outer;
                        }
                    },
                }
            } else {
                // Reached newline or end of buffer.
                diagnostic.clear();
                diagnostic.append("Expected closing double quote", .{});
            }
        } else {
            // Parse a plain path, neither quote wrapped nor escaped.
            var i: usize = fbs.pos;
            var end: usize = fbs.buffer.len;
            while (i < end) : (i += 1) {
                switch (fbs.buffer[i]) {
                    '\n' => end = i,
                    '"' => {
                        diagnostic.clear();
                        diagnostic.append("Unescaped double quote", .{});
                        break;
                    },
                    '\\' => {
                        diagnostic.clear();
                        diagnostic.append("Unescaped backslash", .{});
                        break;
                    },
                    0...0x1f, 0x7f => |byte| {
                        diagnostic.clear();
                        diagnostic.append("Unescaped control code \\{o}", .{byte});
                        break;
                    },
                    else => {},
                }
            } else return fbs.buffer[fbs.pos..end];
        }
        completeLineError(fbs, diagnostic);
        return error.ParsePath;
    }
};

fn completeLineError(
    fbs: std.io.FixedBufferStream([]const u8),
    diagnostic: *Diagnostic,
) void {
    if (!diagnostic.failed) {
        const d = diagnostic.get();
        assert(d.len != 0);
        assert(!std.ascii.isWhitespace(d[d.len - 1]));
    }

    const coords = coordinates(fbs);
    diagnostic.print(" on line {d}, column {d}:\n", .{ coords.line, coords.column });

    const end = std.mem.indexOfScalarPos(u8, fbs.buffer, fbs.pos, '\n') orelse fbs.buffer.len;
    diagnostic.append(fbs.buffer[fbs.pos..end], .{
        .append_newline = true,
        .visible_newlines = true,
    });

    for (1..coords.column) |_| diagnostic.append("-", .{});
    diagnostic.append("^\n", .{});
}

fn coordinates(fbs: std.io.FixedBufferStream([]const u8)) struct { line: usize, column: usize } {
    const column = if (std.mem.lastIndexOfScalar(u8, fbs.buffer[0..fbs.pos], '\n')) |newline|
        fbs.pos - newline
    else
        fbs.pos + 1;
    return .{
        .line = std.mem.count(u8, fbs.buffer[0 .. fbs.pos - (column - 1)], "\n") + 1,
        .column = column,
    };
}
