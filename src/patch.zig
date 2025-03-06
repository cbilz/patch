const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const Diagnostic = @import("Diagnostic.zig");
const DirPatcher = @import("DirPatcher.zig");
const StripDirs = @import("Patch.zig").StripDirs;

const Status = struct {
    cur: ?Location,
    old: Location,
    const init = .{ .cur = .src, .old = undefined };
};
const Location = enum { src, out, tmp };

const log = std.log.scoped(.patch);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    // Non-path arguments come first.

    const strip: StripDirs = blk: {
        const name = "strip";
        try expect("--" ++ name, try nextArg(&arg_it));
        const arg: []const u8 = try nextArg(&arg_it);
        if (std.mem.eql(u8, @tagName(StripDirs.default), arg)) {
            break :blk .default;
        }
        const count = try parseUnsignedArg(usize, arg, name);
        break :blk .{ .count = count };
    };

    const max_bytes_per_patch = blk: {
        const name = "max-bytes-per-patch";
        try expect("--" ++ name, try nextArg(&arg_it));
        break :blk try parseUnsignedArg(usize, try nextArg(&arg_it), name);
    };

    const max_src_files = blk: {
        const name = "max-src-files";
        try expect("--" ++ name, try nextArg(&arg_it));
        break :blk try parseUnsignedArg(usize, try nextArg(&arg_it), name);
    };

    const cwd = std.fs.cwd();

    var patcher = try createPatcher(allocator, cwd, &arg_it, max_src_files);

    try expect("--patch-dir", try nextArg(&arg_it));
    const patch_arg = try nextArg(&arg_it);
    const patch_dir = try openDir(cwd, patch_arg, .{ .iterate = true }, "patch");

    if (arg_it.next()) |arg| {
        log.err("excess argument: {s}", .{arg});
        return error.ExcessArgument;
    }

    try applyPatches(allocator, &patcher, patch_arg, patch_dir, .{
        .max_bytes_per_patch = max_bytes_per_patch,
        .strip = strip,
    });
}

fn createPatcher(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    arg_it: *std.process.ArgIterator,
    max_src_files: usize,
) DirPatcher {
    // Source, output and temp directories are intentionally left for the OS to close on exit.

    try expect("--src", try nextArg(arg_it));
    const src_arg = try nextArg(arg_it);
    const src = try openDir(cwd, src_arg, .{ .iterate = true }, "source");

    try expect("--out", try nextArg(arg_it));
    const out = try openDirEmpty(cwd, try nextArg(arg_it), .{ .iterate = true }, "output");

    try expect("--tmp", try nextArg(arg_it));
    const tmp = try openDirEmpty(cwd, try nextArg(arg_it), .{ .iterate = true }, "temporary");

    var result = DirPatcher.create(allocator, .{ .src = src, .out = out, .tmp = tmp });

    var it = try src.walk(allocator);
    defer it.deinit(); // We don't want to leak an unknown number of directory handles.
    while (true) {
        if (it.next()) |entry_maybe| {
            if (entry_maybe) |entry| {
                switch (entry.kind) {
                    .file => {
                        if (result.countSourceFiles() >= max_src_files) {
                            log.err(
                                "number of source files exceeds specified limit of {d}",
                                .{max_src_files},
                            );
                            return error.TooManyFiles;
                        }
                        try result.addSourceFile(entry.path);
                    },
                    else => continue,
                }
            } else break;
        } else |err| {
            log.err(
                "failed to walk source directory '{s}': {s}",
                .{ src_arg, @errorName(err) },
            );
            return err;
        }
    }

    return result;
}

const ApplyPatchesOptions = struct {
    max_bytes_per_patch: usize,
    strip: StripDirs,
};

fn applyPatches(
    allocator: std.mem.Allocator,
    patcher: *DirPatcher,
    patch_arg: []const u8,
    patch_dir: std.fs.Dir,
    options: ApplyPatchesOptions,
) !void {
    var patch = std.ArrayList(u8).init(allocator);
    for (try getSortedPatchPaths(allocator, patch_arg, patch_dir).items) |sub_path| {
        const file = try patch_dir.openFile(sub_path, .{}) catch |err| {
            log.err(
                "unable to open patch file '{s}{c}{s}': {s}",
                .{ patch_arg, std.fs.path.sep, sub_path, @errorName(err) },
            );
            return err;
        };
        defer file.close(); // Closing because there could be many patch files.

        patch.clearRetainingCapacity();
        file.reader().readAllArrayList(
            &patch,
            options.max_bytes_per_patch,
        ) catch |err| {
            switch (err) {
                error.StreamTooLong => log.err(
                    "size of patch file '{s}{c}{s}' exceeds specified limit of {d} bytes",
                    .{ patch_arg, std.fs.path.sep, sub_path, options.max_bytes_per_patch },
                ),
                else => log.err(
                    "unable to read patch file '{s}{c}{s}': {s}",
                    .{ patch_arg, std.fs.path.sep, sub_path, @errorName(err) },
                ),
            }
            return err;
        };

        patcher.apply(patch.items, options.strip) catch |err| {
            logWithDiagnostic(
                patcher.diagnostic,
                "unable to apply patch file '{s}{c}{s}': {s}",
                .{ patch_arg, std.fs.path.sep, sub_path, @errorName(err) },
            );
            return err;
        };
    }

    patcher.commit() catch |err| {
        logWithDiagnostic(
            patcher.diagnostic,
            "unable to finalize patched directory: {s}",
            .{@errorName(err)},
        );
        return err;
    };
}

fn getSortedPatchPaths(
    allocator: std.mem.Allocator,
    patch_arg: []const u8,
    patch_dir: std.fs.Dir,
) []const []const u8 {
    var paths = std.ArrayListUnmanaged(u8).empty;
    var it = patch_dir.iterate();
    while (true) {
        if (it.next()) |entry_maybe| {
            if (entry_maybe) |entry| {
                switch (entry.kind) {
                    .file => {
                        try paths.append(allocator, try allocator.dupe(entry.name));
                    },
                    else => {
                        log.err(
                            "invalid entry '{s}' in patch directory '{s}': {s}",
                            .{ entry.name, patch_arg, @tagName(entry.kind) },
                        );
                        return error.InvalidDirEntry;
                    },
                }
            } else break;
        } else |err| {
            log.err(
                "failed to iterate patch directory '{s}': {s}",
                .{ patch_arg, @errorName(err) },
            );
            return err;
        }
    }
    const Context = struct {
        fn lessThan(self: @This(), lhs: []const u8, rhs: []const u8) bool {
            _ = self;
            const len = @min(lhs.len, rhs.len);
            for (lhs[0..len], rhs[0..len]) |x, y| {
                if (x < y) return true;
                if (x > y) return false;
            }
            return lhs.len < rhs.len;
        }
    };
    std.mem.sortUnstable([]const u8, paths.items, Context{}, Context.lessThan);
    return paths;
}

fn logWithDiagnostic(
    diagnostic: Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const slice = diagnostic.get();
    if (slice.len == 0) {
        log.err(fmt, args);
    } else {
        log.err(fmt ++ "\n{s}", args ++ .{slice});
    }
}

// Similar to `std.fmt.parseUnsigned`, but does not accept underscores and has better error
// reporting.
fn parseUnsignedArg(Int: type, bytes: []const u8, name: []const u8) !Int {
    var acc: Int = 0;
    if (std.mem.indexOfNone(u8, bytes, "0123456789")) |_| {
        log.err("unexpected byte in " ++ name ++ " argument.", .{});
        return error.InvalidArgument;
    }
    for (bytes) |c| {
        acc, const ov0 = @mulWithOverflow(acc, 10);
        acc, const ov1 = @addWithOverflow(acc, c - '0');
        if (ov0 != 0 or ov1 != 0) {
            log.err(name ++ " argument exceeds {d}.", .{std.math.maxInt(@TypeOf(Int))});
            return error.InvalidArgument;
        }
    }
    return acc;
}

fn nextArg(arg_it: *std.process.ArgIterator) ![]const u8 {
    return arg_it.next() orelse {
        log.err("too few arguments provided.", .{});
        return error.MissingArgument;
    };
}

fn expect(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) {
        log.err("expected argument '{s}', but found '{s}'", .{ expected, actual });
        return error.InvalidArgument;
    }
}

fn openDir(
    dir: std.fs.Dir,
    sub_path: []const u8,
    args: std.fs.Dir.OpenOptions,
    name: []const u8,
) !std.fs.Dir {
    return dir.openDir(sub_path, args) catch |err| {
        log.err("failed to open {s} directory '{s}': {s}", .{ name, sub_path, @errorName(err) });
        return err;
    };
}

fn openDirEmpty(
    dir: std.fs.Dir,
    sub_path: []const u8,
    args: std.fs.Dir.OpenOptions,
    name: []const u8,
) !std.fs.Dir {
    const args_copy: std.fs.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .iterate = true,
        .no_follow = args.no_follow,
    };
    const result = try openDir(dir, sub_path, args_copy, name);
    if (result.iterate().next()) |entry_maybe| {
        if (entry_maybe != null) {
            log.err("{s} directory '{s}' is not empty.", .{ name, sub_path });
            return error.NonEmptyDirectory;
        }
    } else |err| {
        log.err("failed to iterate {s} directory '{s}': {s}", .{ name, sub_path, @errorName(err) });
        return err;
    }
    return result;
}
