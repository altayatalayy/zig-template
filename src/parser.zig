//! Turns the scanner's token stream into the `ast.Node` tree. Everything is
//! allocated in `alloc` (a `Template`'s arena). Lists are grown with an
//! `ArrayList` and handed out as their `.items` slice: since the arena frees in
//! one shot, this avoids the shrink-and-copy `toOwnedSlice` would do.

const std = @import("std");
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");

pub const ParseError = error{
    UnclosedTag,
    EmptyExpression,
    InvalidName,
    UnknownTag,
    UnknownMethod,
    MethodNotAllowed,
    MalformedFor,
    MalformedExpression,
    UnexpectedEndTag,
    MissingEndIf,
    MissingEndFor,
    OutOfMemory,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    scanner: scanner.Scanner,

    const Stop = union(enum) { eof, endif, endfor, else_, elif: ast.Condition };
    const Body = struct { nodes: []const ast.Node, stop: Stop };

    const ForHeader = struct { var_name: []const u8, iterable: ast.Path };
    const Block = union(enum) {
        if_: ast.Condition,
        elif_: ast.Condition,
        else_,
        endif,
        for_: ForHeader,
        endfor,
    };

    pub fn parse(alloc: std.mem.Allocator, source: []const u8) ParseError![]const ast.Node {
        var parser: Parser = .{ .alloc = alloc, .scanner = .{ .source = source } };
        const body = try parser.parseBody();
        if (body.stop != .eof) return error.UnexpectedEndTag;
        return body.nodes;
    }

    fn parseBody(self: *Parser) ParseError!Body {
        var nodes: std.ArrayList(ast.Node) = .empty;
        while (try self.scanner.next()) |token| switch (token) {
            .text => |text| if (text.len > 0) try nodes.append(self.alloc, .{ .text = text }),
            .output => |inner| try nodes.append(self.alloc, .{ .output = try self.parseOperand(inner, true) }),
            .block => |inner| switch (try self.parseBlock(inner)) {
                .if_ => |cond| try nodes.append(self.alloc, .{ .branch = try self.parseBranch(cond) }),
                .for_ => |header| try nodes.append(self.alloc, .{ .loop = try self.parseLoop(header) }),
                .elif_ => |cond| return .{ .nodes = nodes.items, .stop = .{ .elif = cond } },
                .else_ => return .{ .nodes = nodes.items, .stop = .else_ },
                .endif => return .{ .nodes = nodes.items, .stop = .endif },
                .endfor => return .{ .nodes = nodes.items, .stop = .endfor },
            },
        };
        return .{ .nodes = nodes.items, .stop = .eof };
    }

    fn parseBranch(self: *Parser, first: ast.Condition) ParseError!ast.Node.Branch {
        var arms: std.ArrayList(ast.Node.Arm) = .empty;
        var cond = first;
        while (true) {
            const body = try self.parseBody();
            try arms.append(self.alloc, .{ .cond = cond, .body = body.nodes });
            switch (body.stop) {
                .elif => |next_cond| cond = next_cond,
                .endif => return .{ .arms = arms.items, .otherwise = &.{} },
                .else_ => {
                    const otherwise = try self.parseBody();
                    if (otherwise.stop != .endif) return error.MissingEndIf;
                    return .{ .arms = arms.items, .otherwise = otherwise.nodes };
                },
                .eof, .endfor => return error.MissingEndIf,
            }
        }
    }

    fn parseLoop(self: *Parser, header: ForHeader) ParseError!ast.Node.Loop {
        const body = try self.parseBody();
        switch (body.stop) {
            .endfor => return .{ .var_name = header.var_name, .iterable = header.iterable, .body = body.nodes, .empty = &.{} },
            .else_ => {
                const empty = try self.parseBody();
                if (empty.stop != .endfor) return error.MissingEndFor;
                return .{ .var_name = header.var_name, .iterable = header.iterable, .body = body.nodes, .empty = empty.nodes };
            },
            .eof, .endif, .elif => return error.MissingEndFor,
        }
    }

    fn parseBlock(self: *Parser, inner: []const u8) ParseError!Block {
        const end = std.mem.indexOfAny(u8, inner, " \t") orelse inner.len;
        const keyword = inner[0..end];
        const rest = std.mem.trim(u8, inner[end..], " \t");

        if (std.mem.eql(u8, keyword, "if")) return .{ .if_ = try self.parseCondition(rest) };
        if (std.mem.eql(u8, keyword, "elif")) return .{ .elif_ = try self.parseCondition(rest) };
        if (std.mem.eql(u8, keyword, "for")) return .{ .for_ = try self.parseForHeader(rest) };
        if (rest.len != 0) return error.UnknownTag;
        if (std.mem.eql(u8, keyword, "else")) return .else_;
        if (std.mem.eql(u8, keyword, "endif")) return .endif;
        if (std.mem.eql(u8, keyword, "endfor")) return .endfor;
        return error.UnknownTag;
    }

    fn parseForHeader(self: *Parser, rest: []const u8) ParseError!ForHeader {
        const var_end = std.mem.indexOfAny(u8, rest, " \t") orelse return error.MalformedFor;
        const var_name = rest[0..var_end];
        try validateName(var_name);
        const after = std.mem.trimStart(u8, rest[var_end..], " \t");
        if (!std.mem.startsWith(u8, after, "in") or after.len < 3 or (after[2] != ' ' and after[2] != '\t'))
            return error.MalformedFor;
        const operand = try self.parseOperand(std.mem.trim(u8, after[2..], " \t"), false);
        return switch (operand) {
            .path => |path| .{ .var_name = var_name, .iterable = path },
            .string => error.MalformedFor,
        };
    }

    fn parseCondition(self: *Parser, source: []const u8) ParseError!ast.Condition {
        var s = std.mem.trim(u8, source, " \t");
        if (s.len == 0) return error.EmptyExpression;

        var negate = false;
        if (std.mem.startsWith(u8, s, "not") and s.len > 3 and (s[3] == ' ' or s[3] == '\t')) {
            negate = true;
            s = std.mem.trimStart(u8, s[3..], " \t");
        }

        if (findComparison(s)) |cmp| {
            const lhs = try self.parseOperand(std.mem.trim(u8, s[0..cmp.idx], " \t"), false);
            const rhs = try self.parseOperand(std.mem.trim(u8, s[cmp.idx + 2 ..], " \t"), false);
            return .{ .negate = negate, .kind = .{ .compare = .{ .lhs = lhs, .op = cmp.op, .rhs = rhs } } };
        }
        return .{ .negate = negate, .kind = .{ .truthy = try self.parseOperand(s, false) } };
    }

    fn parseOperand(self: *Parser, source: []const u8, allow_method: bool) ParseError!ast.Operand {
        const s = std.mem.trim(u8, source, " \t");
        if (s.len == 0) return error.EmptyExpression;
        if (s[0] == '"' or s[0] == '\'') {
            if (s.len < 2 or s[s.len - 1] != s[0]) return error.MalformedExpression;
            return .{ .string = s[1 .. s.len - 1] };
        }
        return .{ .path = try self.parsePath(s, allow_method) };
    }

    fn parsePath(self: *Parser, source: []const u8, allow_method: bool) ParseError!ast.Path {
        var segments: std.ArrayList([]const u8) = .empty;
        var method: ?ast.Method = null;
        var rest = source;
        while (true) {
            const dot = std.mem.indexOfScalar(u8, rest, '.');
            const segment = if (dot) |d| rest[0..d] else rest;

            if (std.mem.indexOfScalar(u8, segment, '(')) |paren| {
                if (dot != null or !std.mem.endsWith(u8, segment, "()") or segment.len != paren + 2)
                    return error.MalformedExpression;
                if (segments.items.len == 0) return error.MalformedExpression;
                if (!allow_method) return error.MethodNotAllowed;
                method = methodFromName(segment[0..paren]) orelse return error.UnknownMethod;
                break;
            }

            try validateName(segment);
            try segments.append(self.alloc, segment);
            if (dot) |d| {
                if (d + 1 >= rest.len) return error.InvalidName;
                rest = rest[d + 1 ..];
            } else break;
        }
        return .{ .segments = segments.items, .method = method };
    }
};

const Comparison = struct { idx: usize, op: ast.CmpOp };

/// Finds the first top-level `==` or `!=`, ignoring any inside a quoted string.
fn findComparison(s: []const u8) ?Comparison {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (i + 1 < s.len and s[i + 1] == '=') {
            if (c == '=') return .{ .idx = i, .op = .eq };
            if (c == '!') return .{ .idx = i, .op = .ne };
        }
    }
    return null;
}

fn methodFromName(name: []const u8) ?ast.Method {
    if (std.mem.eql(u8, name, "upper")) return .upper;
    if (std.mem.eql(u8, name, "lower")) return .lower;
    return null;
}

fn validateName(name: []const u8) ParseError!void {
    if (name.len == 0) return error.InvalidName;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return error.InvalidName;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidName;
    }
}

test findComparison {
    const t = std.testing;
    try t.expectEqual(@as(?Comparison, .{ .idx = 2, .op = .eq }), findComparison("a == b"));
    try t.expectEqual(@as(?Comparison, .{ .idx = 2, .op = .ne }), findComparison("a != b"));
    try t.expectEqual(@as(?Comparison, null), findComparison("flag"));
    // A `==` inside a string literal is not a comparison operator.
    try t.expectEqual(@as(?Comparison, null), findComparison("\"a == b\""));
}
