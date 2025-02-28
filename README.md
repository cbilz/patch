# Zig build step for applying patches to files

Work in progress.

## Goal

This project will provide a Zig build step for applying diffs in Git and unified
formats to directory trees or individual files.

## Motivation

I plan to use this build step to enable building C and C++ projects from
pristine tarballs while applying patches for the target system, bug fixes, or
other reasons. This approach is more transparent to dependents compared to
building from a forked version of the upstream source.

## Next steps

1. Complete implementation of `PatchDirStep` and `PatchFileStep`.
2. Review resource management:
    - Close file descriptors before `make` returns.
    - Delete any created temporary directories before `make` returns.
    - Decide whether the output directory should be deleted in case of an error.
    - Ensure that repeated calls to `make` do not result in memory leaks. I
      think this is required for incremental compilation to work correctly.
3. Create a build step that runs the test cases.
4. Add additional test cases to check the following behaviors:
    - correct handling of quote wrapped paths
    - correct handling of patches with junk text between a hunk and the next
      header
    - rejection of invalid paths (both wrapped and unwrapped)
    - rejection of empty patches
    - rejection of patches without any headers
    - rejection of invalid headers
    - rejection of invalid hunks
    - rejection of multiple changes to the same file within a single Git patch

## Requirements

Uses Zig 0.14.0-dev.3046+08d661fcf.
