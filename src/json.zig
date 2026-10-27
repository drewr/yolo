//! JSON over std.json.Value: the Haskell's `at`/`jstr`/list/num helpers, so
//! the datum binary's JSON is read the same way.

const std = @import("std");

pub const Value = std.json.Value;

/// Parse `text` into `allocator` (usually an arena); `null` on bad JSON, like
/// `A.decodeStrict` returning Nothing.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ?Value {
    const parsed = std.json.parseFromSliceLeaky(Value, allocator, text, .{}) catch return null;
    return parsed;
}

/// The value at a path of object keys (`at` in the Haskell: Null when missing,
/// or when the path runs into something that isn't an object).
pub fn at(path: []const []const u8, v: Value) Value {
    if (path.len == 0) return v;
    return switch (v) {
        .object => |o| {
            const next = o.get(path[0]) orelse return .null;
            return at(path[1..], next);
        },
        else => .null,
    };
}

/// A string at a path, "" when missing (`jstr`).
pub fn str(path: []const []const u8, v: Value) []const u8 {
    return switch (at(path, v)) {
        .string => |s| s,
        else => "",
    };
}

/// An array at a path, empty when missing (`list`).
pub fn list(path: []const []const u8, v: Value) []const Value {
    return switch (at(path, v)) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// A number at a path, rendered as an integer ("0" when missing; `num`).
pub fn num(allocator: std.mem.Allocator, path: []const []const u8, v: Value) ![]const u8 {
    return switch (at(path, v)) {
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(@round(f)))}),
        .number_string => |s| std.fmt.allocPrint(allocator, "{d}", .{std.fmt.parseInt(i64, s, 10) catch 0}),
        else => "0",
    };
}

/// The object at a path, if it is one.
pub fn object(path: []const []const u8, v: Value) ?std.json.ObjectMap {
    return switch (at(path, v)) {
        .object => |o| o,
        else => null,
    };
}
