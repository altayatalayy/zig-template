//! The runtime data a template renders against: the shape a YAML/JSON loader
//! produces. Maps preserve insertion order and are looked up linearly, which is
//! what code-generation contexts (small, hand- or loader-built) want.

const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: []const Value,
    map: []const Entry,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn get(map: []const Entry, key: []const u8) ?Value {
        for (map) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |b| b,
            .int => |n| n != 0,
            .float => |f| f != 0,
            .string => |s| s.len != 0,
            .list => |l| l.len != 0,
            .map => |m| m.len != 0,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .null => b == .null,
            .bool => |x| b == .bool and x == b.bool,
            .int => |x| b == .int and x == b.int,
            .float => |x| b == .float and x == b.float,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
            .list, .map => false,
        };
    }
};

test "truthy by type" {
    const t = std.testing;
    try t.expect(!(Value{ .null = {} }).truthy());
    try t.expect((Value{ .bool = true }).truthy());
    try t.expect(!(Value{ .bool = false }).truthy());
    try t.expect((Value{ .int = 1 }).truthy());
    try t.expect(!(Value{ .int = 0 }).truthy());
    try t.expect((Value{ .float = 0.5 }).truthy());
    try t.expect(!(Value{ .float = 0 }).truthy());
    try t.expect((Value{ .string = "x" }).truthy());
    try t.expect(!(Value{ .string = "" }).truthy());
    try t.expect((Value{ .list = &.{.{ .int = 1 }} }).truthy());
    try t.expect(!(Value{ .list = &.{} }).truthy());
    try t.expect((Value{ .map = &.{.{ .key = "k", .value = .null }} }).truthy());
    try t.expect(!(Value{ .map = &.{} }).truthy());
}

test "eql compares scalars only" {
    const t = std.testing;
    try t.expect(Value.eql(.null, .null));
    try t.expect(Value.eql(.{ .bool = true }, .{ .bool = true }));
    try t.expect(!Value.eql(.{ .bool = true }, .{ .bool = false }));
    try t.expect(Value.eql(.{ .int = 1 }, .{ .int = 1 }));
    try t.expect(!Value.eql(.{ .int = 1 }, .{ .int = 2 }));
    try t.expect(Value.eql(.{ .float = 1.5 }, .{ .float = 1.5 }));
    try t.expect(Value.eql(.{ .string = "a" }, .{ .string = "a" }));
    try t.expect(!Value.eql(.{ .string = "a" }, .{ .string = "b" }));
    // Different types never compare equal.
    try t.expect(!Value.eql(.{ .int = 1 }, .{ .string = "1" }));
    // Lists and maps never compare equal, even to themselves.
    const list: Value = .{ .list = &.{.{ .int = 1 }} };
    try t.expect(!Value.eql(list, list));
}
