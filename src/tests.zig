//! Behavior tests for whitespace control, conditions, diagnostics, template
//! indentation, conversion and malformed templates.

const std = @import("std");
const root = @import("root.zig");

const Diagnostic = root.Diagnostic;
const Options = root.Options;
const Template = root.Template;
const Value = root.Value;
const testing = std.testing;

const empty: Value = .{ .map = &.{} };

fn expectRender(expected: []const u8, source: []const u8, ctx: Value) !void {
    try root.expectRenderWith(expected, source, .{}, ctx);
}

fn expectRenderFails(err: anyerror, source: []const u8, ctx: Value) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    const result = root.render(testing.allocator, &aw.writer, source, ctx, .{}, null);

    try testing.expectError(err, result);
}

fn flags(comptime a: bool, comptime b: bool, comptime c: bool) Value {
    return .{ .map = &.{
        .{ .key = "a", .value = .{ .bool = a } },
        .{ .key = "b", .value = .{ .bool = b } },
        .{ .key = "c", .value = .{ .bool = c } },
    } };
}

fn expectDiagnostic(
    expected: []const u8,
    err: anyerror,
    diag: Diagnostic,
) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    try diag.write(&aw.writer, err);

    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

fn expectParseDiagnostic(expected: []const u8, err: anyerror, source: []const u8) !void {
    var diag: Diagnostic = .{};
    const result = Template.parse(testing.allocator, source, .{ .filename = "t.tmpl" }, &diag);

    try testing.expectError(err, result);
    try expectDiagnostic(expected, err, diag);
}

fn expectRenderDiagnostic(
    expected: []const u8,
    err: anyerror,
    source: []const u8,
    ctx: Value,
) !void {
    var diag: Diagnostic = .{};
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    const result = root.render(
        testing.allocator,
        &aw.writer,
        source,
        ctx,
        .{ .filename = "t.tmpl" },
        &diag,
    );

    try testing.expectError(err, result);
    try expectDiagnostic(expected, err, diag);
}

// --- whitespace ---

const block_source = "a\n  {% if x %}\nb\n  {% endif %}\nc";
const x_true: Value = .{ .map = &.{.{ .key = "x", .value = .{ .bool = true } }} };

test "whitespace: both options off keep every character" {
    try root.expectRenderWith(
        "a\n  \nb\n  \nc",
        block_source,
        .{ .trim_blocks = false, .lstrip_blocks = false },
        x_true,
    );
}

test "whitespace: trim_blocks alone keeps indentation" {
    try root.expectRenderWith(
        "a\n  b\n  c",
        block_source,
        .{ .lstrip_blocks = false },
        x_true,
    );
}

test "whitespace: lstrip_blocks alone keeps newlines" {
    try root.expectRenderWith(
        "a\n\nb\n\nc",
        block_source,
        .{ .trim_blocks = false },
        x_true,
    );
}

test "whitespace: both options on" {
    try expectRender("a\nb\nc", block_source, x_true);
}

test "whitespace: minus modifiers strip all adjacent whitespace" {
    const source = "a  \n {%- if x -%}  \n b \n {%- endif -%} \n c";
    try expectRender("abc", source, x_true);
}

test "whitespace: minus modifiers on expressions" {
    const ctx: Value = .{ .map = &.{.{ .key = "x", .value = .{ .string = "X" } }} };
    try expectRender("aXb", "a {{- x -}} b", ctx);
}

test "whitespace: plus modifiers override the defaults" {
    try expectRender("a\n  b", "a\n  {%+ if x %}b{% endif %}\n", x_true);
    try expectRender("\nb", "{% if x +%}\nb{% endif %}\n", x_true);
}

test "whitespace: inline blocks keep surrounding text" {
    const source = "int x = {% if y %}1{% else %}2{% endif %};\n";
    const ctx: Value = .{ .map = &.{.{ .key = "y", .value = .{ .bool = false } }} };
    try expectRender("int x = 2;\n", source, ctx);
}

test "whitespace: blank lines around blocks are kept" {
    try expectRender("a\n\nb\n\nc", "a\n\n{% if x %}\nb\n{% endif %}\n\nc", x_true);
}

test "whitespace: comments follow the same rules" {
    try expectRender("a\nb", "a\n  {# note #}\nb", empty);
    try expectRender("ab", "a\n{#- note -#}\nb", empty);
}

// --- nested blocks and loops ---

test "nested loops with inline branches" {
    const source =
        "{% for r in rows %}\n" ++
        "{{ r.name }}:{% for c in r.cols %}{% if loop.first %} {% else %}, {% endif %}" ++
        "{{ c }}{% endfor +%}\n" ++
        "{% endfor %}";
    const ctx: Value = .{ .map = &.{.{ .key = "rows", .value = .{ .list = &.{
        .{ .map = &.{
            .{ .key = "name", .value = .{ .string = "a" } },
            .{ .key = "cols", .value = .{ .list = &.{ .{ .int = 1 }, .{ .int = 2 } } } },
        } },
        .{ .map = &.{
            .{ .key = "name", .value = .{ .string = "b" } },
            .{ .key = "cols", .value = .{ .list = &.{} } },
        } },
    } } }} };

    try expectRender("a: 1, 2\nb:\n", source, ctx);
}

// --- conditions ---

fn expectCondition(
    expected: []const u8,
    comptime cond: []const u8,
    ctx: Value,
) !void {
    try expectRender(expected, "{% if " ++ cond ++ " %}T{% else %}F{% endif %}", ctx);
}

test "conditions: and binds tighter than or" {
    try expectCondition("T", "a or b and c", flags(true, false, false));
    try expectCondition("F", "a and b or c", flags(true, false, false));
    try expectCondition("T", "a and b or c", flags(true, false, true));
}

test "conditions: not binds tighter than and" {
    try expectCondition("F", "not a and b", flags(true, false, false));
    try expectCondition("T", "not a and b", flags(false, true, false));
    try expectCondition("T", "not not a", flags(true, false, false));
}

test "conditions: parentheses group" {
    try expectCondition("F", "(a or b) and c", flags(true, false, false));
    try expectCondition("T", "(a or b) and c", flags(false, true, true));
    try expectCondition("T", "not (a and b)", flags(true, false, false));
    try expectCondition("T", "((a))", flags(true, false, false));
}

test "conditions: not applies to a whole comparison" {
    const ctx: Value = .{ .map = &.{.{ .key = "x", .value = .{ .string = "a" } }} };
    try expectCondition("F", "not x == 'a'", ctx);
    try expectCondition("T", "x == 'a' and not x != 'a'", ctx);
}

test "conditions: and and or short-circuit" {
    try expectCondition("F", "a and missing", flags(false, false, false));
    try expectCondition("T", "a or missing", flags(true, false, false));
    try expectCondition("F", "a and b and missing", flags(true, false, false));
}

test "conditions: the evaluated side still fails on unknown names" {
    try expectRenderFails(
        error.UnknownVariable,
        "{% if a and missing %}x{% endif %}",
        flags(true, false, false),
    );
    try expectRenderFails(
        error.UnknownVariable,
        "{% if a or missing %}x{% endif %}",
        flags(false, false, false),
    );
}

test "conditions: elif chains and multi-line conditions" {
    const source = "{% if a and b %}1{% elif a\n or c %}2{% else %}3{% endif %}";
    try expectRender("1", source, flags(true, true, false));
    try expectRender("2", source, flags(true, false, false));
    try expectRender("2", source, flags(false, false, true));
    try expectRender("3", source, flags(false, true, false));
}

// --- diagnostics ---

test "diagnostics: parse locations and subjects" {
    try expectParseDiagnostic(
        "t.tmpl:2:3: error.UnclosedTag: '{{'",
        error.UnclosedTag,
        "line1\n  {{ name",
    );
    try expectParseDiagnostic(
        "t.tmpl:2:4: error.UnknownTag: 'while x'",
        error.UnknownTag,
        "a\n{% while x %}",
    );
    try expectParseDiagnostic(
        "t.tmpl:2:4: error.MissingEndIf: 'if'",
        error.MissingEndIf,
        "x\n{% if a %}\ny",
    );
    try expectParseDiagnostic(
        "t.tmpl:1:4: error.UnexpectedEndTag: 'endif'",
        error.UnexpectedEndTag,
        "{% endif %}",
    );
    try expectParseDiagnostic(
        "t.tmpl:1:4: error.InvalidName: 'a..b'",
        error.InvalidName,
        "{{ a..b }}",
    );
    try expectParseDiagnostic(
        "t.tmpl:1:6: error.UnknownMethod: 'capitalize'",
        error.UnknownMethod,
        "{{ n.capitalize() }}",
    );
    try expectParseDiagnostic(
        "t.tmpl:1:9: error.MalformedExpression: '(a'",
        error.MalformedExpression,
        "{% if (a %}x{% endif %}",
    );
}

test "diagnostics: render locations and subjects" {
    const user: Value = .{ .map = &.{.{ .key = "user", .value = .{ .map = &.{} } }} };
    try expectRenderDiagnostic(
        "t.tmpl:2:6: error.UnknownVariable: 'name'",
        error.UnknownVariable,
        "ok\n  {{ user.name }}",
        user,
    );
    try expectRenderDiagnostic(
        "t.tmpl:1:13: error.UnknownVariable: 'missing'",
        error.UnknownVariable,
        "{% if a and missing %}x{% endif %}",
        flags(true, false, false),
    );

    const scalars: Value = .{ .map = &.{
        .{ .key = "a", .value = .{ .string = "s" } },
        .{ .key = "n", .value = .{ .int = 1 } },
    } };
    try expectRenderDiagnostic(
        "t.tmpl:1:4: error.NotAMap: 'b'",
        error.NotAMap,
        "{{ a.b }}",
        scalars,
    );
    try expectRenderDiagnostic(
        "t.tmpl:1:13: error.NotIterable: 'n'",
        error.NotIterable,
        "{% for x in n %}{% endfor %}",
        scalars,
    );
    try expectRenderDiagnostic(
        "t.tmpl:1:1: error.ContextNotMap",
        error.ContextNotMap,
        "x",
        .{ .string = "not a map" },
    );
}

test "diagnostics: a parsed template reports its own filename" {
    const options: Options = .{ .filename = "gen.tmpl" };
    var template = try Template.parse(testing.allocator, "{{ missing }}", options, null);
    defer template.deinit();

    var diag: Diagnostic = .{};
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();

    try testing.expectError(error.UnknownVariable, template.render(&aw.writer, empty, &diag));
    try testing.expectEqualStrings("gen.tmpl", diag.filename);
}

// --- indentation ---

test "indent method indents continuation lines only" {
    const source = "class A {\n    {{ body.indent(4) }}\n}\n";
    const ctx: Value = .{ .map = &.{.{
        .key = "body",
        .value = .{ .string = "int a;\nint b;\n\nint c;" },
    }} };

    try expectRender("class A {\n    int a;\n    int b;\n\n    int c;\n}\n", source, ctx);
}

test "indent method rejects non-strings" {
    const ctx: Value = .{ .map = &.{.{ .key = "n", .value = .{ .int = 1 } }} };

    try expectRenderFails(error.MethodOnNonString, "{{ n.indent(2) }}", ctx);
}

// --- conversion ---

test "converted Zig data renders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Item = struct { name: []const u8, size: ?u32 };
    const items = [_]Item{
        .{ .name = "a", .size = 8 },
        .{ .name = "b", .size = null },
    };
    const ctx = try root.fromZig(arena.allocator(), .{ .items = @as([]const Item, &items) });

    const source =
        "{% for i in items %}{{ i.name }}{% if i.size %}={{ i.size }}{% endif %};{% endfor %}";
    try expectRender("a=8;b;", source, ctx);
}

// --- malformed templates ---

test "malformed templates fail with explicit errors" {
    const cases = [_]struct { anyerror, []const u8 }{
        .{ error.MalformedExpression, "{% if (a %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if (a)) %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if () %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if a b %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if a and %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if a == %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if a = b %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if a ! b %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if and %}x{% endif %}" },
        .{ error.MalformedExpression, "{% if 'a %}x{% endif %}" },
        .{ error.MalformedExpression, "{{ n.indent(x) }}" },
        .{ error.MalformedExpression, "{{ n.indent() }}" },
        .{ error.MalformedExpression, "{{ n.upper(1) }}" },
        .{ error.MethodNotAllowed, "{% if n.indent(2) %}x{% endif %}" },
        .{ error.EmptyExpression, "{% if %}x{% endif %}" },
        .{ error.EmptyExpression, "{% for x in %}{% endfor %}" },
        .{ error.UnknownTag, "{% endif x %}" },
        .{ error.UnclosedTag, "{# open" },
        .{ error.UnexpectedEndTag, "{% else %}" },
        .{ error.UnexpectedEndTag, "{% elif a %}" },
        .{ error.MissingEndIf, "{% if a %}{% else %}{% else %}{% endif %}" },
        .{ error.MissingEndFor, "{% for x in xs %}{% endif %}" },
    };

    for (cases) |case| {
        const err, const source = case;
        try testing.expectError(err, Template.parse(testing.allocator, source, .{}, null));
    }
}
