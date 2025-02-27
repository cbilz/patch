const std = @import("std");
const assert = std.debug.assert;
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

/// Appends a diagnostic message comparing the `actual` string to one or more
/// `expected_alternatives`. Asserts that `actual` differs from each of the alternatives.
fn appendExpectedAndActualLines(
    d: *Diagnostic,
    allocator: Allocator,
    expected_alternatives: []const []const u8,
    actual: []const u8,
) void {
    // The implementation of this function was adapted from `std.testing.expectEqualStrings`.
    assert(expected_alternatives.len != 0);

    d.append(allocator, "============ found this: =============\n", .{});
    d.append(allocator, actual, .{ .visible_newlines = true, .visible_end_of_text = true });

    for (expected_alternatives, 0..) |expected, i| {
        if (i == 0) {
            d.append(allocator, "========= but expected this: =========\n", .{});
        } else {
            d.append(allocator, "\n============== or this: ==============\n", .{});
        }

        d.append(allocator, expected, .{ .visible_newlines = true, .visible_end_of_text = true });

        {
            d.append(allocator, "======================================\n", .{});
        }

        const shortest = @min(expected.len, actual.len);
        var line: usize = 1;
        var column: usize = 1;
        for (expected[0..shortest], actual[0..shortest]) |expected_byte, actual_byte| {
            if (expected_byte != actual_byte) {
                break;
            } else if (actual_byte == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        } else assert(expected.len != actual.len);

        d.print("First difference occurs on line {d}, column {d}.\n", .{ line, column });
    }
}
