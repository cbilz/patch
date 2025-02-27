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
    _ = dir_patcher;
    _ = patch;
    _ = strip_dirs;

    // TODO
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

/// Represents a valid (incomplete) Git patch header, with the following deliberate limitations,
/// some of which mirror the behavior of `git apply`: Does not capture (dis)similarity indices. Does
/// not capture blob hashes. Does not capture old modes, only new modes.
const GitHeader = struct {
    extended_action: ?enum { delete, create, copy, rename },
    path_from: ?[]const u8,
    path_to: ?[]const u8,
    new_mode: ?enum { normal, executable },

    const empty = @This(){
        .extended_action = null,
        .patch_from = null,
        .path_to = null,
        .new_mode = null,
    };
};
