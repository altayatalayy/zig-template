//! A small Jinja-subset template engine aimed at code generation.
//!
//! Tags:
//!   {{ path.to.value }}      output a value (string, int, float, bool)
//!   {{ name.upper() }}       output with a string method (upper / lower)
//!   {% if cond %}…{% elif cond %}…{% else %}…{% endif %}
//!   {% for x in items %}…{% else %}…{% endfor %}   (else runs when empty)
//!   {# comment #}            ignored
//!
//! Conditions test truthiness, equality (`a == b`, `a != b`) against another
//! path or a quoted string literal, and combine with `not`, `and`, `or` and
//! parentheses. Precedence, highest first: comparison, `not`, `and`, `or`.
//! `and` and `or` short-circuit: the right side is not evaluated (and its names
//! are not resolved) when the left side decides the result. Inside a loop,
//! `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last` and
//! `loop.length` are available.
//!
//! `{{ text.indent(4) }}` indents every line of a string after the first by
//! four spaces; see `indent` for the exact rules.
//!
//! Whitespace is controlled by `Options` and per-tag modifiers, see `scanner`.
//! By default the newline right after a `{% %}`/`{# #}` tag is removed, and
//! leading inline whitespace on a line up to such a tag is stripped. Output is
//! never escaped; it is written verbatim.
//!
//! Names resolve through the enclosing scopes (innermost first), so a loop body
//! sees both its loop variable and outer variables. A name that does not
//! resolve fails with `error.UnknownVariable`; values are never invented.
//!
//! Failures are plain error unions. Pass a `Diagnostic` to learn the file,
//! line, column and offending tag or name.
//!
//! The pipeline is split across modules: `scanner` (text → tokens), `parser`
//! (tokens → `ast`), and `renderer` (`ast` + `value` → output). A parsed
//! `Template` owns its AST in an arena but borrows the source text and the
//! filename; keep both alive for as long as the template is used.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const renderer = @import("renderer.zig");
const scanner = @import("scanner.zig");
const Report = @import("diagnostic.zig").Report;

pub const Value = @import("value.zig").Value;
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const ConvertError = @import("convert.zig").ConvertError;
pub const fromZig = @import("convert.zig").fromZig;
pub const indent = @import("indent.zig").indent;
pub const ParseError = parser.ParseError;
pub const RenderError = renderer.RenderError;

pub const Options = struct {
    /// Remove the newline after a block or comment tag.
    trim_blocks: bool = true,

    /// Remove indentation before a block or comment tag that starts a line.
    lstrip_blocks: bool = true,

    /// Reported in diagnostics.
    filename: []const u8 = "<template>",
};

pub const Template = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const ast.Node,
    source: []const u8,
    filename: []const u8,

    /// Parses `source`. On failure, `diag` (if given) describes the location.
    pub fn parse(
        alloc: std.mem.Allocator,
        source: []const u8,
        options: Options,
        diag: ?*Diagnostic,
    ) ParseError!Template {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        const report: Report = .{ .source = source, .filename = options.filename, .diag = diag };
        const nodes = try parser.Parser.parse(arena.allocator(), report, .{
            .trim_blocks = options.trim_blocks,
            .lstrip_blocks = options.lstrip_blocks,
        });

        return .{
            .arena = arena,
            .nodes = nodes,
            .source = source,
            .filename = options.filename,
        };
    }

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Renders into `w`. On failure, `diag` (if given) describes the location.
    pub fn render(
        self: Template,
        w: *std.Io.Writer,
        ctx: Value,
        diag: ?*Diagnostic,
    ) RenderError!void {
        const report: Report = .{ .source = self.source, .filename = self.filename, .diag = diag };
        return renderer.render(self.nodes, w, ctx, report);
    }
};

/// One-shot convenience: parse `source`, render it into `w`, free the parse.
pub fn render(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    source: []const u8,
    ctx: Value,
    options: Options,
    diag: ?*Diagnostic,
) (ParseError || RenderError)!void {
    var template = try Template.parse(alloc, source, options, diag);
    defer template.deinit();
    try template.render(w, ctx, diag);
}

// --- tests ---

const testing = std.testing;

pub fn expectRenderWith(
    expected: []const u8,
    source: []const u8,
    options: Options,
    ctx: Value,
) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try render(testing.allocator, &aw.writer, source, ctx, options, null);
    try testing.expectEqualStrings(expected, aw.writer.buffered());
}

fn expectRender(expected: []const u8, source: []const u8, ctx: Value) !void {
    try expectRenderWith(expected, source, .{}, ctx);
}

fn expectRenderError(err: anyerror, source: []const u8, ctx: Value) !void {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(err, render(testing.allocator, &aw.writer, source, ctx, .{}, null));
}

fn expectParseError(err: ParseError, source: []const u8) !void {
    try testing.expectError(err, Template.parse(testing.allocator, source, .{}, null));
}

test "plain text passes through" {
    try expectRender("hello world", "hello world", .{ .map = &.{} });
}

test "empty template renders nothing" {
    try expectRender("", "", .{ .map = &.{} });
}

test "values output by type" {
    try expectRender(
        "name=zig n=42 pi=3.5 on=true",
        "name={{ name }} n={{ n }} pi={{ pi }} on={{ on }}",
        .{ .map = &.{
            .{ .key = "name", .value = .{ .string = "zig" } },
            .{ .key = "n", .value = .{ .int = 42 } },
            .{ .key = "pi", .value = .{ .float = 3.5 } },
            .{ .key = "on", .value = .{ .bool = true } },
        } },
    );
}

test "dotted access walks maps" {
    try expectRender(
        "User.id",
        "{{ obj.type }}.{{ obj.field.name }}",
        .{ .map = &.{.{ .key = "obj", .value = .{ .map = &.{
            .{ .key = "type", .value = .{ .string = "User" } },
            .{ .key = "field", .value = .{ .map = &.{
                .{ .key = "name", .value = .{ .string = "id" } },
            } } },
        } } }} },
    );
}

test "string methods upper and lower" {
    try expectRender("ABC_HPP / abc", "{{ n.upper() }}_HPP / {{ n.lower() }}", .{ .map = &.{
        .{ .key = "n", .value = .{ .string = "Abc" } },
    } });
}

test "unknown variable fails early" {
    try expectRenderError(error.UnknownVariable, "{{ missing }}", .{ .map = &.{
        .{ .key = "present", .value = .{ .string = "x" } },
    } });
}

test "dotted access on non-map fails" {
    try expectRenderError(error.NotAMap, "{{ a.b }}", .{ .map = &.{
        .{ .key = "a", .value = .{ .string = "scalar" } },
    } });
}

test "if elif else chooses one arm" {
    const source = "{% if a %}A{% elif b %}B{% else %}C{% endif %}";
    try expectRender("A", source, .{ .map = &.{
        .{ .key = "a", .value = .{ .bool = true } },
        .{ .key = "b", .value = .{ .bool = true } },
    } });
    try expectRender("B", source, .{ .map = &.{
        .{ .key = "a", .value = .{ .bool = false } },
        .{ .key = "b", .value = .{ .bool = true } },
    } });
    try expectRender("C", source, .{ .map = &.{
        .{ .key = "a", .value = .{ .bool = false } },
        .{ .key = "b", .value = .{ .bool = false } },
    } });
}

test "elif chain walks multiple arms" {
    const source = "{% if a %}A{% elif b %}B{% elif c %}C{% else %}D{% endif %}";
    const ctx: Value = .{ .map = &.{
        .{ .key = "a", .value = .{ .bool = false } },
        .{ .key = "b", .value = .{ .bool = false } },
        .{ .key = "c", .value = .{ .bool = true } },
    } };
    try expectRender("C", source, ctx);
}

test "conditions: equality, inequality and not" {
    const ctx: Value = .{ .map = &.{.{ .key = "role", .value = .{ .string = "admin" } }} };
    try expectRender("yes", "{% if role == \"admin\" %}yes{% else %}no{% endif %}", ctx);
    try expectRender("no", "{% if role != \"admin\" %}yes{% else %}no{% endif %}", ctx);
    try expectRender("yes", "{% if not role == \"guest\" %}yes{% endif %}", ctx);
}

test "equality compares two paths" {
    const source = "{% if a == b %}same{% else %}diff{% endif %}";
    try expectRender("same", source, .{ .map = &.{
        .{ .key = "a", .value = .{ .string = "x" } },
        .{ .key = "b", .value = .{ .string = "x" } },
    } });
    try expectRender("diff", source, .{ .map = &.{
        .{ .key = "a", .value = .{ .int = 1 } },
        .{ .key = "b", .value = .{ .int = 2 } },
    } });
}

test "truthiness of lists and strings" {
    try expectRender("full", "{% if xs %}full{% else %}empty{% endif %}", .{ .map = &.{
        .{ .key = "xs", .value = .{ .list = &.{.{ .int = 1 }} } },
    } });
    try expectRender("empty", "{% if xs %}full{% else %}empty{% endif %}", .{ .map = &.{
        .{ .key = "xs", .value = .{ .list = &.{} } },
    } });
    try expectRender("empty", "{% if s %}full{% else %}empty{% endif %}", .{ .map = &.{
        .{ .key = "s", .value = .{ .string = "" } },
    } });
}

test "for iterates with element scope and outer visibility" {
    try expectRender(
        "v1/a v1/b ",
        "{% for f in fields %}{{ ver }}/{{ f.name }} {% endfor %}",
        .{ .map = &.{
            .{ .key = "ver", .value = .{ .string = "v1" } },
            .{ .key = "fields", .value = .{ .list = &.{
                .{ .map = &.{.{ .key = "name", .value = .{ .string = "a" } }} },
                .{ .map = &.{.{ .key = "name", .value = .{ .string = "b" } }} },
            } } },
        } },
    );
}

test "for over scalars uses the loop variable directly" {
    try expectRender(
        "import a;import b;",
        "{% for m in imports %}import {{ m }};{% endfor %}",
        .{ .map = &.{.{ .key = "imports", .value = .{ .list = &.{
            .{ .string = "a" },
            .{ .string = "b" },
        } } }} },
    );
}

test "nested loops see both loop variables" {
    try expectRender(
        "a1a2b1b2",
        "{% for x in xs %}{% for y in ys %}{{ x }}{{ y }}{% endfor %}{% endfor %}",
        .{ .map = &.{
            .{ .key = "xs", .value = .{ .list = &.{ .{ .string = "a" }, .{ .string = "b" } } } },
            .{ .key = "ys", .value = .{ .list = &.{ .{ .int = 1 }, .{ .int = 2 } } } },
        } },
    );
}

test "for else renders when empty" {
    const source = "{% for x in xs %}{{ x }}{% else %}(none){% endfor %}";
    try expectRender("ab", source, .{ .map = &.{.{ .key = "xs", .value = .{ .list = &.{
        .{ .string = "a" }, .{ .string = "b" },
    } } }} });
    try expectRender("(none)", source, .{ .map = &.{.{ .key = "xs", .value = .{ .list = &.{} } }} });
}

test "loop metadata: index, index0, last and length" {
    try expectRender(
        "1/0:x 2/1:y 3/2:z len=3",
        "{% for i in xs %}{{ loop.index }}/{{ loop.index0 }}:{{ i }}{% if not loop.last %} {% else %} len={{ loop.length }}{% endif %}{% endfor %}",
        .{ .map = &.{.{ .key = "xs", .value = .{ .list = &.{
            .{ .string = "x" }, .{ .string = "y" }, .{ .string = "z" },
        } } }} },
    );
}

test "whitespace: trim_blocks and lstrip_blocks on nested if/for" {
    const source =
        "items:\n" ++
        "{% for x in xs %}\n" ++
        "  - name: {{ x.name }}\n" ++
        "{% if x.tags %}\n" ++
        "    tags:\n" ++
        "{% for t in x.tags %}\n" ++
        "      - {{ t }}\n" ++
        "{% endfor %}\n" ++
        "{% else %}\n" ++
        "    tags: []\n" ++
        "{% endif %}\n" ++
        "{% endfor %}";
    try expectRender(
        "items:\n  - name: a\n    tags:\n      - p\n      - q\n  - name: b\n    tags: []\n",
        source,
        .{ .map = &.{.{ .key = "xs", .value = .{ .list = &.{
            .{ .map = &.{
                .{ .key = "name", .value = .{ .string = "a" } },
                .{ .key = "tags", .value = .{ .list = &.{ .{ .string = "p" }, .{ .string = "q" } } } },
            } },
            .{ .map = &.{
                .{ .key = "name", .value = .{ .string = "b" } },
                .{ .key = "tags", .value = .{ .list = &.{} } },
            } },
        } } }} },
    );
}

test "whitespace: trim_blocks works with CRLF line endings" {
    const source = "a\r\n{% if on %}\r\n  b\r\n{% endif %}\r\nc";
    try expectRender("a\r\n  b\r\nc", source, .{ .map = &.{
        .{ .key = "on", .value = .{ .bool = true } },
    } });
}

test "whitespace: trim_blocks collapses comma-separated items (matches Jinja)" {
    const source =
        "arr = {\n" ++
        "{% for c in cols %}\n" ++
        "    \"{{ c }}\"{% if not loop.last %},{% endif %}\n" ++
        "{% endfor %}}";
    try expectRender(
        "arr = {\n    \"a\",    \"b\",    \"c\"}",
        source,
        .{ .map = &.{.{ .key = "cols", .value = .{ .list = &.{
            .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
        } } }} },
    );
}

test "equality drives per-item branches" {
    const source =
        "users:\n" ++
        "{% for u in items %}\n" ++
        "  - {{ u.role }}: {{ u.name }}\n" ++
        "{% if u.role == \"admin\" %}\n" ++
        "    access: all\n" ++
        "{% else %}\n" ++
        "    access: read\n" ++
        "{% endif %}\n" ++
        "{% endfor %}";
    try expectRender(
        "users:\n  - admin: alice\n    access: all\n  - guest: bob\n    access: read\n",
        source,
        .{ .map = &.{.{ .key = "items", .value = .{ .list = &.{
            .{ .map = &.{
                .{ .key = "role", .value = .{ .string = "admin" } },
                .{ .key = "name", .value = .{ .string = "alice" } },
            } },
            .{ .map = &.{
                .{ .key = "role", .value = .{ .string = "guest" } },
                .{ .key = "name", .value = .{ .string = "bob" } },
            } },
        } } }} },
    );
}

test "comments are dropped" {
    try expectRender("ab", "a{# ignore #}b", .{ .map = &.{} });
}

test "string literals may use single quotes" {
    const ctx: Value = .{ .map = &.{.{ .key = "name", .value = .{ .string = "zig" } }} };
    try expectRender("yes", "{% if name == 'zig' %}yes{% else %}no{% endif %}", ctx);
    try expectRender("hi", "{{ 'hi' }}", .{ .map = &.{} });
}

test "null renders as nothing" {
    try expectRender("ab", "a{{ n }}b", .{ .map = &.{
        .{ .key = "n", .value = .null },
    } });
}

test "template parses once and renders repeatedly" {
    var template = try Template.parse(testing.allocator, "hi {{ name }}", .{}, null);
    defer template.deinit();

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const one: Value = .{ .map = &.{.{ .key = "name", .value = .{ .string = "one" } }} };
    const two: Value = .{ .map = &.{.{ .key = "name", .value = .{ .string = "two" } }} };
    try template.render(&aw.writer, one, null);
    try template.render(&aw.writer, two, null);
    try testing.expectEqualStrings("hi onehi two", aw.writer.buffered());
}

test "render errors are explicit" {
    try expectRenderError(error.NotIterable, "{% for x in n %}{{ x }}{% endfor %}", .{ .map = &.{
        .{ .key = "n", .value = .{ .int = 1 } },
    } });
    try expectRenderError(error.MethodOnNonString, "{{ n.upper() }}", .{ .map = &.{
        .{ .key = "n", .value = .{ .int = 1 } },
    } });
    try expectRenderError(error.NotPrintable, "{{ xs }}", .{ .map = &.{
        .{ .key = "xs", .value = .{ .list = &.{} } },
    } });
    try expectRenderError(error.ContextNotMap, "x", .{ .string = "not a map" });
}

test "parse errors are explicit" {
    try expectParseError(error.UnclosedTag, "a {{ name");
    try expectParseError(error.EmptyExpression, "{{ }}");
    try expectParseError(error.UnknownTag, "{% while x %}y{% endwhile %}");
    try expectParseError(error.UnknownMethod, "{{ name.capitalize() }}");
    try expectParseError(error.MethodNotAllowed, "{% if name.upper() %}x{% endif %}");
    try expectParseError(error.MalformedFor, "{% for x of xs %}y{% endfor %}");
    try expectParseError(error.MalformedFor, "{% for x in \"lit\" %}y{% endfor %}");
    try expectParseError(error.InvalidName, "{{ a..b }}");
    try expectParseError(error.MalformedExpression, "{{ \"oops }}");
    try expectParseError(error.MissingEndIf, "{% if a %}x");
    try expectParseError(error.MissingEndFor, "{% for x in xs %}{{ x }}");
    try expectParseError(error.UnexpectedEndTag, "x{% endif %}");
}

test {
    // Pull in the focused unit tests living next to each stage.
    _ = @import("scanner.zig");
    _ = @import("diagnostic.zig");
    _ = @import("indent.zig");
    _ = @import("convert.zig");
    _ = @import("value.zig");
    _ = @import("tests.zig");
    _ = @import("codegen_tests.zig");
}
