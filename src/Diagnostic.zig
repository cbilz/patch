const std = @import("std");
const Allocator = std.mem.Allocator;

contents: std.ArrayListUnmanaged(u8),
failed: bool,

const Diagnostic = @This();

const empty = Diagnostic{ .contents = .empty, .failed = false };

pub fn deinit(d: *Diagnostic, allocator: Allocator) void {
    d.contents.deinit(allocator);
    d.failed = undefined;
}

pub fn get(d: Diagnostic) []const u8 {
    return if (d.failed) "(This diagnostic message could not be formatted.)" else d.contents.items;
}

pub fn clear(d: *Diagnostic) void {
    d.contents.clearRetainingCapacity();
    d.failed = false;
}

pub fn print(d: *Diagnostic, allocator: Allocator, comptime fmt: []const u8, args: anytype) void {
    if (!d.failed) {
        std.fmt.format(d.contents.writer(allocator), fmt, args) catch {
            d.contents.clearRetainingCapacity();
            d.failed = true;
        };
    }
}

// Adapted from `std.testing.printLine`.
pub fn appendLineWithVisibleNewline(d: *Diagnostic, allocator: Allocator, line: []const u8) void {
    std.debug.assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    if (line.len != 0) {
        switch (line[line.len - 1]) {
            ' ', '\t' => {
                return d.print(allocator, "{s}⏎\n", .{line}); // Return symbol
            },
            else => {},
        }
    }
    d.print(allocator, "{s}\n", .{line});
}
