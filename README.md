# Zig build step for applying patches to files

Work in progress.

## Goal

This project will provide a Zig build step for applying diffs in Git, unified
and context formats to directory trees or individual files.

## Motivation

I plan to use this build step to enable building C and C++ projects from
pristine tarballs while applying patches for the target system, bug fixes, or
other reasons. This approach is more transparent to dependents compared to
building from a forked version of the upstream source.
