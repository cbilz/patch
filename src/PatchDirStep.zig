const std = @import("std");
const Build = std.Build;
const assert = std.debug.assert;
const Parser = @import("Parser.zig");

step: Build.Step,
generated_directory: Build.GeneratedFile,
source: Build.LazyPath,
patches: []const Patch,

pub const base_id: Build.Step.Id = .custom;
const PatchDirStep = @This();

pub const Patch = struct {
    file: Build.LazyPath,
    strip_dirs: StripDirs = .{ .count = 0 },
};

// Fix the values of the tags of StripDirs to prevent potential cache collisions.
const StripDirsTag = enum(u1) {
    count = 0,
    all = 1,
};

const StripDirs = union(StripDirsTag) {
    /// A fixed number of leading components that will be stripped from paths in the patch.
    count: usize,
    /// Paths in the patch will be reduced to their last components, also known as basenames.
    all,
};

pub const Options = struct {
    source: Build.LazyPath,
    patches: []const Patch,
    first_ret_addr: ?usize = null,
};

pub fn create(owner: *Build, options: Options) *PatchDirStep {
    const arena = owner.allocator;

    const name = switch (options.patches.len) {
        1 => owner.fmt(
            "applying patch '{s}' to directory '{s}'",
            .{ options.patches[0].file.getDisplayName(), options.source.getDisplayName() },
        ),
        else => owner.fmt(
            "applying {d} patches to directory '{s}'",
            .{ options.patches.len, options.source.getDisplayName() },
        ),
    };

    const patches = arena.alloc(Patch, options.patches.len) catch @panic("OOM");
    for (options.patches, patches) |source, *target| {
        target.* = .{
            .file = source.file.dupe(owner),
            .strip_dirs = options.strip_dirs,
        };
    }

    const patch_dir_step = arena.create(PatchDirStep) catch @panic("OOM");
    patch_dir_step.* = .{
        .step = Build.Step.init(.{
            .id = base_id,
            .name = name,
            .owner = owner,
            .makeFn = make,
            .first_ret_addr = options.first_ret_addr orelse @returnAddress(),
        }),
        .generated_directory = .{ .step = &patch_dir_step.step },
        .source = options.source.dupe(owner),
        .patches = patches,
    };

    patch_dir_step.source.addStepDependencies(&patch_dir_step.step);
    for (patch_dir_step.patches) |patch| patch.file.addStepDependencies(&patch_dir_step.step);

    return patch_dir_step;
}

pub fn getOutput(patch_dir_step: *PatchDirStep) Build.LazyPath {
    return .{ .generated = .{ .file = &patch_dir_step.output_file } };
}

fn make(step: *Build.Step, options: Build.Step.MakeOptions) !void {
    _ = step;
    _ = options;
}
