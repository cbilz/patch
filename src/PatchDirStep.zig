const std = @import("std");
const Build = std.Build;
const assert = std.debug.assert;
const DirPatcher = @import("DirPatcher.zig");
const Patch = @import("Patch.zig");

step: Build.Step,
generated_directory: Build.GeneratedFile,
source: Build.LazyPath,
patches: []const Patch,
max_bytes_per_patch: usize,
max_count_source_files: usize,

pub const base_id: Build.Step.Id = .custom;
const PatchDirStep = @This();

pub const Options = struct {
    source: Build.LazyPath,
    patches: []const Patch,
    max_bytes_per_patch: usize = 2 * 1024 * 1024,
    max_count_source_files: usize = 2 * 1024,
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
        target.* = source.dupe(owner);
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
        .max_bytes_per_patch = options.max_bytes_per_patch,
        .max_count_source_files = options.max_count_source_files,
    };

    patch_dir_step.source.addStepDependencies(&patch_dir_step.step);
    for (patch_dir_step.patches) |patch| patch.file.addStepDependencies(&patch_dir_step.step);

    return patch_dir_step;
}

pub fn getOutput(patch_dir_step: *PatchDirStep) Build.LazyPath {
    return .{ .generated = .{ .file = &patch_dir_step.output_file } };
}

fn make(step: *Build.Step, options: Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const arena = b.allocator;
    const patch_dir_step: *PatchDirStep = @fieldParentPtr("step", step);

    const src_cache_path = patch_dir_step.source.getPath3(b, step);
    const src_dir = src_cache_path.openDir(".", .{ .iterate = true }) catch |err| {
        return step.fail(
            "unable to open source directory '{}': {s}",
            .{ src_cache_path, @errorName(err) },
        );
    };
    defer src_dir.close();

    const man, const files =
        try setWatchInputsAndCreateManifest(patch_dir_step, src_cache_path, src_dir);
    defer man.deinit();

    const hit = try step.cacheHit(&man);
    const out_sub_path = b.pathJoin(&.{ "o", &man.final() });
    const out_path = try b.cache_root.join(arena, &.{out_sub_path});

    if (hit) {
        patch_dir_step.generated_directory.path = out_path;
        return;
    }

    // TODO: Who is supposed to take care of file cleanup in case a build step fails?

    var out_dir = b.cache_root.handle.makeOpenPath(out_sub_path, .{}) catch |err| {
        return step.fail(
            "unable to make path '{}{s}': {s}",
            .{ b.cache_root, out_sub_path, @errorName(err) },
        );
    };
    defer out_dir.close();

    var patcher = DirPatcher.init(arena, files, src_dir, out_dir);
    const patch_list = std.ArrayList(u8).init(arena);

    for (patch_dir_step.patches) |patch| {
        switch (patch.contents) {
            .file => |lazy_path| {
                const cache_path = lazy_path.getPath3(b, step);

                const file = try cache_path.root_dir.handle.openFile(
                    cache_path.sub_path,
                    .{},
                ) catch |err| return step.fail(
                    "unable to open patch file '{}': {s}",
                    .{ cache_path, @errorName(err) },
                );
                defer file.close();

                patch_list.clearRetainingCapacity();
                file.reader().readAllArrayList(
                    &patch_list,
                    patch_dir_step.max_bytes_per_patch,
                ) catch |err| switch (err) {
                    error.StreamTooLong => return step.fail(
                        "size of patch file '{}' exceeds specified limit of {d} bytes",
                        .{ cache_path, patch_dir_step.max_bytes_per_patch },
                    ),
                    else => return step.fail(
                        "unable to read patch file '{}': {s}",
                        .{ cache_path, @errorName(err) },
                    ),
                };

                patcher.apply(patch_list.items, patch.strip_dirs) catch |err| {
                    return step.fail(
                        "unable to apply patch file '{}': {s}\n{s}",
                        .{ cache_path, @errorName(err), patcher.getDiagnostic() },
                    );
                };
            },
            .bytes => |bytes| {
                if (bytes.len > patch_dir_step.max_bytes_per_patch) {
                    return step.fail(
                        "size of patch file exceeds specified limit of {d} bytes",
                        .{patch_dir_step.max_bytes_per_patch},
                    );
                }
                patcher.apply(bytes, patch.strip_dirs) catch |err| {
                    return step.fail(
                        "unable to apply patch: {s}\n{s}",
                        .{ @errorName(err), patcher.getDiagnostic() },
                    );
                };
            },
        }
    }

    patcher.final() catch |err| {
        return step.fail(
            "unable to finish patching directory: {s}\n{s}",
            .{ @errorName(err), patcher.getDiagnostic() },
        );
    };

    patch_dir_step.generated_directory.path = out_path;
    try step.writeManifest(&man);
}

fn setWatchInputsAndCreateManifest(
    patch_dir_step: *PatchDirStep,
    src_cache_path: Build.Cache.Path,
    src_dir: std.fs.Dir,
) !struct { Build.Cache.Manifest, []const []const u8 } {
    const step = patch_dir_step.step;
    const b = step.owner;
    const arena = b.allocator;

    step.clearWatchInputs();
    var man = b.graph.cache.obtain();

    // Refresh this with new random bytes when the implementation of PatchDirStep is modified in a
    // non-backwards-compatible way.
    man.hash.add(@as(u32, 0x990db558));

    var files = std.ArrayListUnmanaged([]const u8){};

    {
        const need_derived_inputs = try step.addDirectoryWatchInput(patch_dir_step.source);
        var it = try src_dir.walk(arena);
        defer it.deinit();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (need_derived_inputs) {
                        const cache_path = try src_cache_path.join(arena, entry.path);
                        try step.addDirectoryWatchInputFromPath(cache_path);
                    }
                },
                .file => {
                    if (files.items.len >= patch_dir_step.max_count_source_files) {
                        return step.fail(
                            "number of files in source directory exceeds specified limit of {d}",
                            .{patch_dir_step.max_count_source_files},
                        );
                    }
                    try files.append(arena, b.dupe(entry.path));
                },
                else => continue,
            }
        }
    }

    // Add files to manifest after sorting, which avoids unnecessary rebuilds in case the directory
    // is subsequently traversed in a different order.
    {
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
        std.mem.sortUnstable([]const u8, files.items, Context{}, Context.lessThan);
        for (files.items) |sub_path| {
            const cache_path = try src_cache_path.join(arena, sub_path);
            _ = try man.addFilePath(cache_path, null);
        }
    }

    for (patch_dir_step.patches) |patch| {
        const cache_path = patch.file.getPath3(b, step);
        _ = try man.addFilePath(cache_path, null);
        switch (patch.strip_dirs) {
            .count => |c| {
                man.hash.add(@as(u8, 0));
                man.hash.add(@as(usize, c));
            },
            .all => {
                man.hash.add(@as(u8, 1));
                man.hash.add(@as(usize, 0));
            },
        }
        try step.addWatchInput(patch.file);
    }

    return .{ man, files.items };
}
