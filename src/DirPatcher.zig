const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const StripDirs = @import("Patch.zig").StripDirs;

const DirPatcher = @This();

allocator: std.mem.Allocator,
files: std.StringArrayHashMapUnmanaged(Status),
src: std.fs.Dir,
out: std.fs.Dir,
tmp: std.fs.Dir,
diagnostic: Diagnostic,

const Status = struct { cur: ?Location, old: Location };
const Location = enum { src, out, tmp };

pub const Options = struct {
    src_files: []const []const u8,
    src: std.fs.Dir,
    out: std.fs.Dir,
    tmp: std.fs.Dir,
};

pub fn create(allocator: std.mem.Allocator, options: Options) !DirPatcher {
    var files = std.StringArrayHashMapUnmanaged(Status).empty;
    try files.ensureUnusedCapacity(allocator, options.src_files.len);
    for (options.src_files) |path| {
        files.putAssumeCapacity(allocator, path, .{ .cur = .src, .old = undefined });
    }
    return .{
        .allocator = allocator,
        .files = files,
        .src = options.src,
        .out = options.out,
        .tmp = options.tmp,
        .diagnostic = .init(allocator),
    };
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
};
