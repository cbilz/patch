const std = @import("std");
const Patch = @This();

contents: union(enum) {
    file: std.Build.LazyPath,
    bytes: []const u8,
},
strip_dirs: StripDirs = .{ .count = 0 },

pub const StripDirs = union(enum) {
    /// A fixed number of leading components that will be stripped from paths in the patch.
    count: usize,
    /// Paths in the patch will be reduced to their last components, also known as basenames.
    all,
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
