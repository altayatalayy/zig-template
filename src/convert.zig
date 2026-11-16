//! Converts ordinary Zig data into the `Value` tree a template renders against.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const ConvertError = error{
    OutOfMemory,

    /// An integer does not fit in `Value.int` (`i64`).
    IntegerOutOfRange,
};

/// Converts `data` to a `Value`.
///
///   * `bool` becomes `.bool`; integers become `.int`; floats up to `f64`
///     become `.float`. Integers outside the `i64` range fail with
///     `error.IntegerOutOfRange`; no number is converted to a string.
///   * `[]const u8` (and other `u8` slices and array pointers) become `.string`.
///   * Slices, array pointers and arrays of other types become `.list`.
///   * Structs become `.map` with one entry per field, in declaration order.
///   * Optionals become `.null` or the converted payload.
///   * Single-item pointers are followed. A `Value` is returned unchanged.
///
/// Any other type is a compile error. `[N]u8` arrays are rejected because a
/// string would have to borrow from the function's own copy; pass a slice.
///
/// Ownership: list and map storage is allocated with `alloc` and is not freed
/// individually, so `alloc` should be an arena that outlives the rendering.
/// Strings are not copied: they borrow from `data`, which must outlive the
/// result. On error the partial result is abandoned; releasing the arena
/// frees it.
pub fn fromZig(alloc: std.mem.Allocator, data: anytype) ConvertError!Value {
    const T = @TypeOf(data);
    if (T == Value) return data;

    switch (@typeInfo(T)) {
        .bool => return .{ .bool = data },
        .int, .comptime_int => {
            const n = std.math.cast(i64, data) orelse return error.IntegerOutOfRange;
            return .{ .int = n };
        },
        .float => |info| {
            if (info.bits > 64) @compileError("floats wider than f64 lose precision");
            return .{ .float = data };
        },
        .comptime_float => return .{ .float = data },
        .optional => return if (data) |payload| fromZig(alloc, payload) else .null,
        .pointer => |info| switch (info.size) {
            .slice => return fromSlice(alloc, info.child, data),
            .one => switch (@typeInfo(info.child)) {
                .array => |array| return fromSlice(alloc, array.child, data),
                else => return fromZig(alloc, data.*),
            },
            else => @compileError("unsupported pointer type: " ++ @typeName(T)),
        },
        .array => |info| {
            if (info.child == u8) @compileError("pass a slice instead of an array of u8");
            return fromSlice(alloc, info.child, &data);
        },
        .@"struct" => |info| {
            if (info.is_tuple) @compileError("tuples are not supported: " ++ @typeName(T));

            const entries = try alloc.alloc(Value.Entry, info.field_names.len);
            inline for (info.field_names, 0..) |name, i| {
                entries[i] = .{
                    .key = name,
                    .value = try fromZig(alloc, @field(data, name)),
                };
            }
            return .{ .map = entries };
        },
        else => @compileError("unsupported type: " ++ @typeName(T)),
    }
}

fn fromSlice(
    alloc: std.mem.Allocator,
    comptime Child: type,
    items: []const Child,
) ConvertError!Value {
    if (Child == u8) return .{ .string = items };

    const values = try alloc.alloc(Value, items.len);
    for (items, values) |item, *value| value.* = try fromZig(alloc, item);
    return .{ .list = values };
}

const testing = std.testing;

test "struct with strings, numbers, optionals and slices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Field = struct { name: []const u8, width: ?u8 };
    const fields = [_]Field{
        .{ .name = "id", .width = 4 },
        .{ .name = "tag", .width = null },
    };
    const value = try fromZig(arena.allocator(), .{
        .title = "demo",
        .count = @as(u32, 7),
        .ratio = @as(f32, 0.5),
        .on = true,
        .fields = @as([]const Field, &fields),
    });

    try testing.expectEqualStrings("demo", Value.get(value.map, "title").?.string);
    try testing.expectEqual(@as(i64, 7), Value.get(value.map, "count").?.int);
    try testing.expectEqual(@as(f64, 0.5), Value.get(value.map, "ratio").?.float);
    try testing.expect(Value.get(value.map, "on").?.bool);

    const list = Value.get(value.map, "fields").?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("id", Value.get(list[0].map, "name").?.string);
    try testing.expectEqual(@as(i64, 4), Value.get(list[0].map, "width").?.int);
    try testing.expectEqual(Value.null, Value.get(list[1].map, "width").?);
}

test "arrays, array pointers and single pointers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const numbers = [_]i32{ 1, -2 };
    const value = try fromZig(arena.allocator(), .{
        .by_value = numbers,
        .by_pointer = &numbers,
        .text = "literal",
        .nested = &.{ .flag = false },
    });

    try testing.expectEqual(@as(i64, -2), Value.get(value.map, "by_value").?.list[1].int);
    try testing.expectEqual(@as(usize, 2), Value.get(value.map, "by_pointer").?.list.len);
    try testing.expectEqualStrings("literal", Value.get(value.map, "text").?.string);

    const nested = Value.get(value.map, "nested").?;
    try testing.expect(!Value.get(nested.map, "flag").?.bool);
}

test "strings are borrowed, not copied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text: []const u8 = "borrowed";
    const value = try fromZig(arena.allocator(), text);

    try testing.expectEqual(text.ptr, value.string.ptr);
}

test "integers keep their meaning and range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const max: u64 = std.math.maxInt(i64);
    const min: i128 = std.math.minInt(i64);

    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), (try fromZig(alloc, max)).int);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), (try fromZig(alloc, min)).int);
    try testing.expectEqual(@as(i64, 42), (try fromZig(alloc, 42)).int);

    try testing.expectError(error.IntegerOutOfRange, fromZig(alloc, max + 1));
    try testing.expectError(error.IntegerOutOfRange, fromZig(alloc, min - 1));
    const huge: u128 = std.math.maxInt(u128);
    try testing.expectError(error.IntegerOutOfRange, fromZig(alloc, .{ .big = huge }));
}

test "allocation failure is reported" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    const items = [_]u8{ 1, 2, 3 };
    try testing.expectError(error.OutOfMemory, fromZig(failing.allocator(), .{ .items = &items }));
}

test "value passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const value = try fromZig(arena.allocator(), .{ .raw = Value{ .string = "x" } });

    try testing.expectEqualStrings("x", Value.get(value.map, "raw").?.string);
}
