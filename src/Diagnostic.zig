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

const AppendOptions = struct {
    visible_newlines: bool = false,
    visible_end_of_text: bool = false,
};

pub fn append(
    d: *Diagnostic,
    allocator: Allocator,
    bytes: []const u8,
    options: AppendOptions,
) void {
    // The implementation of this function was adapted from `std.testing.printWithVisibleNewlines`.
    var i: usize = 0;
    if (options.visible_newlines) {
        while (std.mem.indexOfScalarPos(u8, bytes, i, '\n')) |nl| : (i = nl + 1) {
            if (nl != i) {
                switch (bytes[nl - 1]) {
                    ' ', '\t' => {
                        d.print(allocator, "{s}⏎\n", .{bytes[i..nl]}); // Return symbol
                        continue;
                    },
                    else => {},
                }
            }
            d.print(allocator, "{s}\n", .{bytes[i..nl]});
        }
    }
    print("{s}{s}", .{
        bytes[i..],
        if (options.visible_end_of_text) "␃\n" else "", // End of Text symbol (ETX)
    });
}
