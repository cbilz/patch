const std = @import("std");
const Patch = @This();

contents: union(enum) {
    file: std.Build.LazyPath,
    bytes: []const u8,
},
strip_dirs: StripDirs = .default,

pub const StripDirs = union(enum) {
    /// Strip one leading component from paths if the patch is in Git format and don't strip path
    /// components if the patch is in unified format.
    default,
    /// The number of leading components that will be stripped from paths in the patch.
    count: usize,
};

pub fn dupe(patch: Patch, b: *std.Build) Patch {
    return .{
        .contents = switch (patch.contents) {
            .file => |file| .{ .file = file.dupe(b) },
            .bytes => |bytes| .{ .bytes = b.dupe(bytes) },
        },
        .strip_dirs = patch.strip_dirs,
    };
}
