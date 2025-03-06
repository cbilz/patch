# Zig package for applying patches to files

Work in progress. Feedback is welcome!

## Goal

This project will provide a Zig package for applying diffs in Git and unified
formats to directory trees or individual files. It will be free of system
dependencies by default while allowing integration with Git or GNU patch when
needed.

## Motivation

One use case for this package will be to enable building C and C++ projects from
pristine tarballs while applying patches for the host system, bug fixes, or
other reasons. This approach is more transparent to dependents compared to
building from a forked version of the upstream source.

## Rationale

The package will expose **outputs as artifacts** (via `b.addNamedLazyPath(...)`)
and accept **inputs as options** (via `b.option(LazyPath, ...)`), following [the
intended
approach](https://github.com/ziglang/zig/pull/18778#issuecomment-1925660119).

Internally, the package will use **`std.Build.Step.Run`** instead of custom build
steps in preparation for the [separation of the build runner from the configure
process](https://github.com/ziglang/zig/issues/20981).

By default, the package will use its **own `patch` implementation** to help
dependents reduce their system dependencies. Every system dependency removed
makes it easier to onboard new contributors.

However, there will also be options (via `b.systemIntegrationOption(...)`) to
[**use the system packages**](https://github.com/ziglang/zig/pull/18778) Git or
GNU patch when appropriate, such as when packaging or when build times or
compatibility are of concern.

## Next steps

1. Complete implementation and review resource management:
    - Ensure a small number of file descriptors are open at any time.
    - Delete temporary directories on exit.
    - Clean up output directories in case of errors.
2. Create a test build step.
3. Add additional test cases to check the following behaviors:
    - Correct handling of quote wrapped paths.
    - Correct handling of patches with junk text between a hunk and the next
      header.
    - Rejection of invalid paths (both wrapped and unwrapped).
    - Rejection of empty patches.
    - Rejection of patches without any headers.
    - Rejection of invalid headers.
    - Rejection of invalid hunks.
    - Rejection of multiple changes to the same file within a single Git patch.
4. Fix bugs.
5. Implement the remaining characteristics described in the
   [Rationale](#Rationale).
6. Update this README.
7. Tag a release.

## Requirements

Uses Zig 0.14.0-dev.3462+edabcf619.
