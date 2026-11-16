//! Turns the scanner's token stream into the `ast.Node` tree. Everything is
//! allocated in `alloc` (a `Template`'s arena). Lists are grown with an
//! `ArrayList` and handed out as their `.items` slice: since the arena frees in
//! one shot, this avoids the shrink-and-copy `toOwnedSlice` would do.
//!
//! Condition grammar, from lowest to highest precedence:
//!
//!     or_expr  := and_expr ("or" and_expr)*
//!     and_expr := not_expr ("and" not_expr)*
//!     not_expr := "not" not_expr | primary
//!     primary  := "(" or_expr ")" | operand (("==" | "!=") operand)?

const std = @import("std");
const ast = @import("ast.zig");
const scanner = @import("scanner.zig");
const Report = @import("diagnostic.zig").Report;

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

const blank = " \t\r\n";

/// A piece of the source and its position there.
const Span = struct {
    text: []const u8,
    offset: usize,

    fn trimmed(self: Span) Span {
        const rest = std.mem.trimStart(u8, self.text, blank);
        return .{
            .text = std.mem.trimEnd(u8, rest, blank),
            .offset = self.offset + (self.text.len - rest.len),
        };
    }
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    scanner: scanner.Scanner,
    report: Report,

    const Stop = union(enum) { eof, endif, endfor, else_, elif: ast.Condition };
    const Body = struct { nodes: []const ast.Node, stop: Stop, stop_tag: Span };

    const ForHeader = struct { var_name: []const u8, iterable: ast.Path };
    const Block = union(enum) {
        if_: ast.Condition,
        elif_: ast.Condition,
        else_,
        endif,
        for_: ForHeader,
        endfor,
    };

    pub fn parse(
        alloc: std.mem.Allocator,
        report: Report,
        options: scanner.Options,
    ) ParseError![]const ast.Node {
        var parser: Parser = .{
            .alloc = alloc,
            .scanner = .{ .source = report.source, .options = options },
            .report = report,
        };
        const body = try parser.parseBody();
        if (body.stop != .eof) {
            return report.fail(body.stop_tag.offset, body.stop_tag.text, error.UnexpectedEndTag);
        }
        return body.nodes;
    }

    fn nextToken(self: *Parser) ParseError!?scanner.Token {
        return self.scanner.next() catch |err| {
            const start = self.scanner.tag_start;
            return self.report.fail(start, self.scanner.source[start..][0..2], err);
        };
    }

    fn parseBody(self: *Parser) ParseError!Body {
        var nodes: std.ArrayList(ast.Node) = .empty;
        var stop_tag: Span = .{ .text = "", .offset = self.scanner.source.len };

        while (try self.nextToken()) |token| {
            const span: Span = .{ .text = token.text, .offset = token.offset };

            switch (token.kind) {
                .text => {
                    if (token.text.len == 0) continue;
                    try nodes.append(self.alloc, .{ .text = token.text });
                },
                .output => {
                    const operand = try self.parseOperand(span, true);
                    try nodes.append(self.alloc, .{ .output = operand });
                },
                .block => {
                    const block = try self.parseBlock(span);
                    stop_tag = span;

                    switch (block) {
                        .if_ => |cond| {
                            const branch = try self.parseBranch(cond, span);
                            try nodes.append(self.alloc, .{ .branch = branch });
                        },
                        .for_ => |header| {
                            const loop = try self.parseLoop(header, span);
                            try nodes.append(self.alloc, .{ .loop = loop });
                        },
                        .elif_ => |cond| return .{
                            .nodes = nodes.items,
                            .stop = .{ .elif = cond },
                            .stop_tag = stop_tag,
                        },
                        .else_ => return .{
                            .nodes = nodes.items,
                            .stop = .else_,
                            .stop_tag = stop_tag,
                        },
                        .endif => return .{
                            .nodes = nodes.items,
                            .stop = .endif,
                            .stop_tag = stop_tag,
                        },
                        .endfor => return .{
                            .nodes = nodes.items,
                            .stop = .endfor,
                            .stop_tag = stop_tag,
                        },
                    }
                },
            }
        }
        return .{ .nodes = nodes.items, .stop = .eof, .stop_tag = stop_tag };
    }

    fn parseBranch(self: *Parser, first: ast.Condition, opener: Span) ParseError!ast.Node.Branch {
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
                    if (otherwise.stop != .endif) {
                        return self.report.fail(opener.offset, "if", error.MissingEndIf);
                    }
                    return .{ .arms = arms.items, .otherwise = otherwise.nodes };
                },
                .eof, .endfor => return self.report.fail(opener.offset, "if", error.MissingEndIf),
            }
        }
    }

    fn parseLoop(self: *Parser, header: ForHeader, opener: Span) ParseError!ast.Node.Loop {
        const body = try self.parseBody();
        var empty: []const ast.Node = &.{};

        switch (body.stop) {
            .endfor => {},
            .else_ => {
                const otherwise = try self.parseBody();
                if (otherwise.stop != .endfor) {
                    return self.report.fail(opener.offset, "for", error.MissingEndFor);
                }
                empty = otherwise.nodes;
            },
            .eof, .endif, .elif => {
                return self.report.fail(opener.offset, "for", error.MissingEndFor);
            },
        }

        return .{
            .var_name = header.var_name,
            .iterable = header.iterable,
            .body = body.nodes,
            .empty = empty,
        };
    }

    fn parseBlock(self: *Parser, tag: Span) ParseError!Block {
        const end = std.mem.indexOfAny(u8, tag.text, blank) orelse tag.text.len;
        const keyword = tag.text[0..end];
        const rest = (Span{ .text = tag.text[end..], .offset = tag.offset + end }).trimmed();

        const takes_expression = std.mem.eql(u8, keyword, "if") or
            std.mem.eql(u8, keyword, "elif") or
            std.mem.eql(u8, keyword, "for");
        if (takes_expression and rest.text.len == 0) {
            return self.report.fail(tag.offset, keyword, error.EmptyExpression);
        }

        if (std.mem.eql(u8, keyword, "if")) return .{ .if_ = try self.parseCondition(rest) };
        if (std.mem.eql(u8, keyword, "elif")) return .{ .elif_ = try self.parseCondition(rest) };
        if (std.mem.eql(u8, keyword, "for")) return .{ .for_ = try self.parseForHeader(rest) };

        if (rest.text.len == 0) {
            if (std.mem.eql(u8, keyword, "else")) return .else_;
            if (std.mem.eql(u8, keyword, "endif")) return .endif;
            if (std.mem.eql(u8, keyword, "endfor")) return .endfor;
        }
        return self.report.fail(tag.offset, tag.text, error.UnknownTag);
    }

    fn parseForHeader(self: *Parser, rest: Span) ParseError!ForHeader {
        const var_end = std.mem.indexOfAny(u8, rest.text, blank) orelse {
            return self.report.fail(rest.offset, rest.text, error.MalformedFor);
        };
        const var_name = rest.text[0..var_end];
        if (!isValidName(var_name)) {
            return self.report.fail(rest.offset, var_name, error.InvalidName);
        }

        const after = std.mem.trimStart(u8, rest.text[var_end..], blank);
        const keyword_end = std.mem.indexOfAny(u8, after, blank) orelse after.len;
        if (!std.mem.eql(u8, after[0..keyword_end], "in")) {
            return self.report.fail(rest.offset, rest.text, error.MalformedFor);
        }

        const iterable: Span = .{
            .text = after[keyword_end..],
            .offset = rest.offset + (rest.text.len - after.len) + keyword_end,
        };
        return switch (try self.parseOperand(iterable.trimmed(), false)) {
            .path => |path| .{ .var_name = var_name, .iterable = path },
            .string => self.report.fail(rest.offset, rest.text, error.MalformedFor),
        };
    }

    fn parseCondition(self: *Parser, span: Span) ParseError!ast.Condition {
        var conditions: ConditionParser = .{
            .parser = self,
            .span = span,
            .tokens = try self.lexCondition(span),
        };
        const cond = try conditions.parseOr();

        if (conditions.peek()) |extra| {
            return self.report.fail(extra.offset, extra.text, error.MalformedExpression);
        }
        return cond;
    }

    fn lexCondition(self: *Parser, span: Span) ParseError![]const ConditionToken {
        const s = span.text;
        var tokens: std.ArrayList(ConditionToken) = .empty;
        var i: usize = 0;

        while (i < s.len) {
            const start = i;
            var kind: ConditionToken.Kind = undefined;

            switch (s[i]) {
                ' ', '\t', '\r', '\n' => {
                    i += 1;
                    continue;
                },
                '(' => {
                    kind = .lparen;
                    i += 1;
                },
                ')' => {
                    kind = .rparen;
                    i += 1;
                },
                '"', '\'' => {
                    const close = std.mem.indexOfScalarPos(u8, s, i + 1, s[i]) orelse {
                        return self.report.fail(span.offset + i, s[i..], error.MalformedExpression);
                    };
                    kind = .string;
                    i = close + 1;
                },
                '=', '!' => {
                    if (i + 1 >= s.len or s[i + 1] != '=') {
                        const bad = s[i..][0..1];
                        return self.report.fail(span.offset + i, bad, error.MalformedExpression);
                    }
                    kind = if (s[i] == '=') .eq else .ne;
                    i += 2;
                },
                else => {
                    kind = .word;
                    while (i < s.len and !isWordEnd(s[i])) i += 1;

                    // `name.method(args)` is one word so that it can be rejected as a whole.
                    if (i < s.len and s[i] == '(' and !isKeyword(s[start..i])) {
                        const close = std.mem.indexOfScalarPos(u8, s, i, ')') orelse {
                            const offset = span.offset + start;
                            return self.report.fail(offset, s[start..], error.MalformedExpression);
                        };
                        i = close + 1;
                    }
                },
            }

            try tokens.append(self.alloc, .{
                .kind = kind,
                .text = s[start..i],
                .offset = span.offset + start,
            });
        }
        return tokens.items;
    }

    fn parseOperand(self: *Parser, span: Span, allow_method: bool) ParseError!ast.Operand {
        const s = span.trimmed();
        if (s.text.len == 0) return self.report.fail(s.offset, "", error.EmptyExpression);

        const quote = s.text[0];
        if (quote == '"' or quote == '\'') {
            if (s.text.len < 2 or s.text[s.text.len - 1] != quote) {
                return self.report.fail(s.offset, s.text, error.MalformedExpression);
            }
            return .{ .string = s.text[1 .. s.text.len - 1] };
        }
        return .{ .path = try self.parsePath(s, allow_method) };
    }

    fn parsePath(self: *Parser, span: Span, allow_method: bool) ParseError!ast.Path {
        var head = span.text;
        var method: ?ast.Method = null;

        if (std.mem.indexOfScalar(u8, span.text, '(')) |paren| {
            const dot = std.mem.lastIndexOfScalar(u8, span.text[0..paren], '.') orelse {
                return self.report.fail(span.offset, span.text, error.MalformedExpression);
            };
            if (span.text[span.text.len - 1] != ')') {
                return self.report.fail(span.offset, span.text, error.MalformedExpression);
            }
            if (!allow_method) {
                return self.report.fail(span.offset, span.text, error.MethodNotAllowed);
            }

            method = try self.parseMethod(.{
                .text = span.text[dot + 1 .. span.text.len],
                .offset = span.offset + dot + 1,
            });
            head = span.text[0..dot];
        }

        var segments: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, head, '.');
        while (parts.next()) |segment| {
            if (!isValidName(segment)) {
                return self.report.fail(span.offset, span.text, error.InvalidName);
            }
            try segments.append(self.alloc, segment);
        }
        return .{ .segments = segments.items, .method = method, .offset = span.offset };
    }

    /// Parses `name(args)`, the call part of a path.
    fn parseMethod(self: *Parser, call: Span) ParseError!ast.Method {
        const paren = std.mem.indexOfScalar(u8, call.text, '(').?;
        const name = call.text[0..paren];
        const args = std.mem.trim(u8, call.text[paren + 1 .. call.text.len - 1], blank);

        if (std.mem.eql(u8, name, "upper") or std.mem.eql(u8, name, "lower")) {
            if (args.len != 0) {
                return self.report.fail(call.offset, call.text, error.MalformedExpression);
            }
            return if (name[0] == 'u') .upper else .lower;
        }
        if (std.mem.eql(u8, name, "indent")) {
            const width = std.fmt.parseInt(usize, args, 10) catch {
                return self.report.fail(call.offset, call.text, error.MalformedExpression);
            };
            return .{ .indent = width };
        }
        return self.report.fail(call.offset, name, error.UnknownMethod);
    }
};

const ConditionToken = struct {
    kind: Kind,
    text: []const u8,
    offset: usize,

    const Kind = enum { word, string, lparen, rparen, eq, ne };
};

const ConditionParser = struct {
    parser: *Parser,
    span: Span,
    tokens: []const ConditionToken,
    pos: usize = 0,

    fn peek(self: ConditionParser) ?ConditionToken {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn acceptWord(self: *ConditionParser, word: []const u8) bool {
        const token = self.peek() orelse return false;
        if (token.kind != .word or !std.mem.eql(u8, token.text, word)) return false;
        self.pos += 1;
        return true;
    }

    fn box(self: ConditionParser, cond: ast.Condition) ParseError!*const ast.Condition {
        const ptr = try self.parser.alloc.create(ast.Condition);
        ptr.* = cond;
        return ptr;
    }

    fn parseOr(self: *ConditionParser) ParseError!ast.Condition {
        var cond = try self.parseAnd();
        while (self.acceptWord("or")) {
            const lhs = try self.box(cond);
            const rhs = try self.box(try self.parseAnd());
            cond = .{ .either = .{ lhs, rhs } };
        }
        return cond;
    }

    fn parseAnd(self: *ConditionParser) ParseError!ast.Condition {
        var cond = try self.parseNot();
        while (self.acceptWord("and")) {
            const lhs = try self.box(cond);
            const rhs = try self.box(try self.parseNot());
            cond = .{ .both = .{ lhs, rhs } };
        }
        return cond;
    }

    fn parseNot(self: *ConditionParser) ParseError!ast.Condition {
        if (self.acceptWord("not")) return .{ .not = try self.box(try self.parseNot()) };
        return self.parsePrimary();
    }

    fn parsePrimary(self: *ConditionParser) ParseError!ast.Condition {
        const first = self.peek() orelse return self.unexpectedEnd();

        if (first.kind == .lparen) {
            self.pos += 1;
            const inner = try self.parseOr();

            const close = self.peek() orelse return self.unexpectedEnd();
            if (close.kind != .rparen) {
                return self.parser.report.fail(close.offset, close.text, error.MalformedExpression);
            }
            self.pos += 1;
            return inner;
        }

        const lhs = try self.parseOperand();
        const op_token = self.peek() orelse return .{ .truthy = lhs };
        const op: ast.CmpOp = switch (op_token.kind) {
            .eq => .eq,
            .ne => .ne,
            else => return .{ .truthy = lhs },
        };
        self.pos += 1;

        return .{ .compare = .{ .lhs = lhs, .op = op, .rhs = try self.parseOperand() } };
    }

    fn parseOperand(self: *ConditionParser) ParseError!ast.Operand {
        const token = self.peek() orelse return self.unexpectedEnd();
        const report = self.parser.report;
        self.pos += 1;

        switch (token.kind) {
            .string => return .{ .string = token.text[1 .. token.text.len - 1] },
            .word => {
                if (isKeyword(token.text)) {
                    return report.fail(token.offset, token.text, error.MalformedExpression);
                }
                const span: Span = .{ .text = token.text, .offset = token.offset };
                return .{ .path = try self.parser.parsePath(span, false) };
            },
            else => return report.fail(token.offset, token.text, error.MalformedExpression),
        }
    }

    fn unexpectedEnd(self: ConditionParser) ParseError {
        const end = self.span.offset + self.span.text.len;
        return self.parser.report.fail(end, self.span.text, error.MalformedExpression);
    }
};

fn isKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "and") or
        std.mem.eql(u8, word, "or") or
        std.mem.eql(u8, word, "not");
}

fn isWordEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '(', ')', '=', '!', '"', '\'' => true,
        else => false,
    };
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}
