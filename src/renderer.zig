//! Walks the `ast.Node` tree and writes the result, resolving names against a
//! chain of scopes (innermost first). Rendering allocates nothing: loop state
//! lives in stack arrays that exist only while the loop body is rendered.

const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;

pub const RenderError = error{
    ContextNotMap,
    UnknownVariable,
    NotAMap,
    NotIterable,
    MethodOnNonString,
    NotPrintable,
    WriteFailed,
};

pub fn render(nodes: []const ast.Node, w: *std.Io.Writer, ctx: Value) RenderError!void {
    if (ctx != .map) return error.ContextNotMap;
    const root: Scope = .{ .vars = ctx.map, .parent = null };
    try renderNodes(nodes, w, &root);
}

const Scope = struct {
    vars: []const Value.Entry,
    parent: ?*const Scope,

    fn resolve(self: *const Scope, name: []const u8) ?Value {
        if (Value.get(self.vars, name)) |value| return value;
        if (self.parent) |parent| return parent.resolve(name);
        return null;
    }
};

fn renderNodes(nodes: []const ast.Node, w: *std.Io.Writer, scope: *const Scope) RenderError!void {
    for (nodes) |node| switch (node) {
        .text => |text| try w.writeAll(text),
        .output => |operand| try renderOutput(w, scope, operand),
        .branch => |branch| try renderBranch(w, scope, branch),
        .loop => |loop| try renderLoop(w, scope, loop),
    };
}

fn renderOutput(w: *std.Io.Writer, scope: *const Scope, operand: ast.Operand) RenderError!void {
    switch (operand) {
        .string => |literal| try w.writeAll(literal),
        .path => |path| {
            const value = try resolvePath(scope, path);
            const method = path.method orelse return writeValue(w, value);
            if (value != .string) return error.MethodOnNonString;
            for (value.string) |c| try w.writeByte(switch (method) {
                .upper => std.ascii.toUpper(c),
                .lower => std.ascii.toLower(c),
            });
        },
    }
}

fn renderBranch(w: *std.Io.Writer, scope: *const Scope, branch: ast.Node.Branch) RenderError!void {
    for (branch.arms) |arm| {
        if (try evalCondition(scope, arm.cond)) return renderNodes(arm.body, w, scope);
    }
    try renderNodes(branch.otherwise, w, scope);
}

fn renderLoop(w: *std.Io.Writer, scope: *const Scope, loop: ast.Node.Loop) RenderError!void {
    const value = try resolvePath(scope, loop.iterable);
    if (value != .list) return error.NotIterable;
    const items = value.list;
    if (items.len == 0) return renderNodes(loop.empty, w, scope);

    for (items, 0..) |item, i| {
        var meta = [_]Value.Entry{
            .{ .key = "index", .value = .{ .int = @intCast(i + 1) } },
            .{ .key = "index0", .value = .{ .int = @intCast(i) } },
            .{ .key = "first", .value = .{ .bool = i == 0 } },
            .{ .key = "last", .value = .{ .bool = i == items.len - 1 } },
            .{ .key = "length", .value = .{ .int = @intCast(items.len) } },
        };
        var vars = [_]Value.Entry{
            .{ .key = loop.var_name, .value = item },
            .{ .key = "loop", .value = .{ .map = &meta } },
        };
        const child: Scope = .{ .vars = &vars, .parent = scope };
        try renderNodes(loop.body, w, &child);
    }
}

fn evalCondition(scope: *const Scope, cond: ast.Condition) RenderError!bool {
    const result = switch (cond.kind) {
        .truthy => |operand| (try operandValue(scope, operand)).truthy(),
        .compare => |c| blk: {
            const equal = Value.eql(try operandValue(scope, c.lhs), try operandValue(scope, c.rhs));
            break :blk switch (c.op) {
                .eq => equal,
                .ne => !equal,
            };
        },
    };
    return result != cond.negate;
}

fn operandValue(scope: *const Scope, operand: ast.Operand) RenderError!Value {
    return switch (operand) {
        .string => |literal| .{ .string = literal },
        .path => |path| resolvePath(scope, path),
    };
}

fn resolvePath(scope: *const Scope, path: ast.Path) RenderError!Value {
    var value = scope.resolve(path.segments[0]) orelse return error.UnknownVariable;
    for (path.segments[1..]) |segment| {
        if (value != .map) return error.NotAMap;
        value = Value.get(value.map, segment) orelse return error.UnknownVariable;
    }
    return value;
}

fn writeValue(w: *std.Io.Writer, value: Value) RenderError!void {
    switch (value) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| try w.writeAll(s),
        .list, .map => return error.NotPrintable,
    }
}
