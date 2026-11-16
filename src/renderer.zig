//! Walks the `ast.Node` tree and writes the result, resolving names against a
//! chain of scopes (innermost first). Rendering allocates nothing: loop state
//! lives in stack arrays that exist only while the loop body is rendered.

const std = @import("std");
const ast = @import("ast.zig");
const indent = @import("indent.zig").indent;
const Report = @import("diagnostic.zig").Report;
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

pub fn render(
    nodes: []const ast.Node,
    w: *std.Io.Writer,
    ctx: Value,
    report: Report,
) RenderError!void {
    if (ctx != .map) return report.fail(0, "", error.ContextNotMap);

    const renderer: Renderer = .{ .w = w, .report = report };
    const root: Scope = .{ .vars = ctx.map, .parent = null };
    try renderer.renderNodes(nodes, &root);
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

const Renderer = struct {
    w: *std.Io.Writer,
    report: Report,

    fn renderNodes(self: Renderer, nodes: []const ast.Node, scope: *const Scope) RenderError!void {
        for (nodes) |node| switch (node) {
            .text => |text| try self.w.writeAll(text),
            .output => |operand| try self.renderOutput(scope, operand),
            .branch => |branch| try self.renderBranch(scope, branch),
            .loop => |loop| try self.renderLoop(scope, loop),
        };
    }

    fn renderOutput(self: Renderer, scope: *const Scope, operand: ast.Operand) RenderError!void {
        const path = switch (operand) {
            .string => |literal| return self.w.writeAll(literal),
            .path => |path| path,
        };

        const value = try self.resolvePath(scope, path);
        const method = path.method orelse return self.writeValue(value, path);
        if (value != .string) return self.fail(path, error.MethodOnNonString);

        switch (method) {
            .upper => for (value.string) |c| try self.w.writeByte(std.ascii.toUpper(c)),
            .lower => for (value.string) |c| try self.w.writeByte(std.ascii.toLower(c)),
            .indent => |width| try indent(self.w, value.string, width, false),
        }
    }

    fn renderBranch(self: Renderer, scope: *const Scope, branch: ast.Node.Branch) RenderError!void {
        for (branch.arms) |arm| {
            if (try self.evalCondition(scope, arm.cond)) return self.renderNodes(arm.body, scope);
        }
        try self.renderNodes(branch.otherwise, scope);
    }

    fn renderLoop(self: Renderer, scope: *const Scope, loop: ast.Node.Loop) RenderError!void {
        const value = try self.resolvePath(scope, loop.iterable);
        if (value != .list) return self.fail(loop.iterable, error.NotIterable);

        const items = value.list;
        if (items.len == 0) return self.renderNodes(loop.empty, scope);

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
            try self.renderNodes(loop.body, &child);
        }
    }

    /// `and` and `or` evaluate their right side only when the left side does not
    /// decide the result, so an unresolvable name there is never looked up.
    fn evalCondition(self: Renderer, scope: *const Scope, cond: ast.Condition) RenderError!bool {
        switch (cond) {
            .truthy => |operand| return (try self.operandValue(scope, operand)).truthy(),
            .compare => |c| {
                const lhs = try self.operandValue(scope, c.lhs);
                const rhs = try self.operandValue(scope, c.rhs);
                return Value.eql(lhs, rhs) == (c.op == .eq);
            },
            .not => |inner| return !try self.evalCondition(scope, inner.*),
            .both => |pair| {
                if (!try self.evalCondition(scope, pair[0].*)) return false;
                return self.evalCondition(scope, pair[1].*);
            },
            .either => |pair| {
                if (try self.evalCondition(scope, pair[0].*)) return true;
                return self.evalCondition(scope, pair[1].*);
            },
        }
    }

    fn operandValue(self: Renderer, scope: *const Scope, operand: ast.Operand) RenderError!Value {
        return switch (operand) {
            .string => |literal| .{ .string = literal },
            .path => |path| self.resolvePath(scope, path),
        };
    }

    fn resolvePath(self: Renderer, scope: *const Scope, path: ast.Path) RenderError!Value {
        const first = path.segments[0];
        var value = scope.resolve(first) orelse {
            return self.report.fail(path.offset, first, error.UnknownVariable);
        };

        for (path.segments[1..]) |segment| {
            if (value != .map) return self.report.fail(path.offset, segment, error.NotAMap);
            value = Value.get(value.map, segment) orelse {
                return self.report.fail(path.offset, segment, error.UnknownVariable);
            };
        }
        return value;
    }

    fn writeValue(self: Renderer, value: Value, path: ast.Path) RenderError!void {
        switch (value) {
            .null => {},
            .bool => |b| try self.w.writeAll(if (b) "true" else "false"),
            .int => |n| try self.w.print("{d}", .{n}),
            .float => |f| try self.w.print("{d}", .{f}),
            .string => |s| try self.w.writeAll(s),
            .list, .map => return self.fail(path, error.NotPrintable),
        }
    }

    /// Fails with `err`, naming the last segment of `path` as the subject.
    fn fail(self: Renderer, path: ast.Path, err: anytype) @TypeOf(err) {
        return self.report.fail(path.offset, path.segments[path.segments.len - 1], err);
    }
};
