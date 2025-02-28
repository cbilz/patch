const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

contents: std.ArrayList(u8),
failed: bool,

const Diagnostic = @This();

pub fn init(allocator: Allocator) Diagnostic {
    return .{ .contents = .init(allocator), .failed = false };
}

pub fn deinit(diagnostic: *Diagnostic) void {
    diagnostic.contents.deinit();
    diagnostic.* = undefined;
}

pub fn get(diagnostic: Diagnostic) []const u8 {
    return if (diagnostic.failed)
        "(This diagnostic message could not be formatted.)"
    else
        diagnostic.contents.items;
}

pub fn clear(diagnostic: *Diagnostic) void {
    diagnostic.contents.clearRetainingCapacity();
    diagnostic.failed = false;
}

pub fn print(diagnostic: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
    if (!diagnostic.failed) {
        std.fmt.format(diagnostic.contents.writer(), fmt, args) catch {
            diagnostic.contents.clearRetainingCapacity();
            diagnostic.failed = true;
        };
    }
}

const AppendOptions = struct {
    append_newline: bool = false,
    visible_newlines: bool = false,
    visible_end_of_text: bool = false,
};

pub fn append(
    diagnostic: *Diagnostic,
    bytes: []const u8,
    options: AppendOptions,
) void {
    // The implementation of this function was adapted from `std.testing.printWithVisibleNewlines`.
    var i: usize = 0;
    if (options.visible_newlines) {
        while (i < bytes.len) {
            const nl = if (std.mem.indexOfScalarPos(u8, bytes, i, '\n')) |index|
                index
            else if (options.append_newline)
                bytes.len
            else
                break;

            if (nl != i and (bytes[nl - 1] == ' ' or bytes[nl - 1] == '\t')) {
                diagnostic.print("{s}⏎\n", .{bytes[i..nl]}); // Return symbol
            } else {
                diagnostic.print("{s}\n", .{bytes[i..nl]});
            }

            i = @min(bytes.len, nl +| 1);
        }
    }
    diagnostic.print("{s}{s}", .{
        bytes[i..],
        if (options.visible_end_of_text) "␃\n" else "", // End of Text symbol (ETX)
    });
}

/// Appends a diagnostic message comparing the `actual` string to one or more
/// `expected_alternatives`. Asserts that `actual` differs from each of the alternatives.
fn appendExpectedAndActualLines(
    diagnostic: *Diagnostic,
    expected_alternatives: []const []const u8,
    actual: []const u8,
) void {
    // The implementation of this function was adapted from `std.testing.expectEqualStrings`.
    assert(expected_alternatives.len != 0);

    diagnostic.append("============ found this: =============\n", .{});
    diagnostic.append(actual, .{ .visible_newlines = true, .visible_end_of_text = true });

    for (expected_alternatives, 0..) |expected, i| {
        if (i == 0) {
            diagnostic.append("========= but expected this: =========\n", .{});
        } else {
            diagnostic.append("\n============== or this: ==============\n", .{});
        }

        diagnostic.append(expected, .{ .visible_newlines = true, .visible_end_of_text = true });

        {
            diagnostic.append("======================================\n", .{});
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

        diagnostic.print("First difference occurs on line {d}, column {d}.\n", .{ line, column });
    }
}
