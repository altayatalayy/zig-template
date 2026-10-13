# zig-template

A small Jinja-subset template engine for Zig 0.17, aimed at code generation.
It renders a runtime `Value` tree (the shape a YAML/JSON loader produces), so
the same engine can emit Zig, C/C++, Rust, Go, Python, JS/TS — any text.

## Syntax

```jinja
{{ path.to.value }}      output a value (string, int, float, bool)
{{ name.upper() }}       string method: upper / lower
{% if cond %}…{% elif cond %}…{% else %}…{% endif %}
{% for x in items %}…{% else %}…{% endfor %}   (else runs when items is empty)
{# comment #}
```

- **Conditions** test truthiness, `==` / `!=` (against another path or a quoted
  string literal), and may be negated with `not`.
- **Loops** expose `loop.index` (1-based), `loop.index0`, `loop.first`,
  `loop.last`, `loop.length`. Bodies see both the loop variable and outer scope.
- **Whitespace** matches Jinja with `trim_blocks` + `lstrip_blocks` on: the
  newline after a `{% %}`/`{# #}` tag is removed, and line-leading whitespace up
  to such a tag is stripped. `{{ }}` tags are left untouched.
- A name that does not resolve fails with `error.UnknownVariable`; values are
  never invented. Output is written verbatim (no HTML escaping).

## Use

```zig
const template = @import("template");
const Value = template.Value;

const ctx: Value = .{ .map = &.{
    .{ .key = "title", .value = .{ .string = "demo" } },
    .{ .key = "items", .value = .{ .list = &.{
        .{ .map = &.{ .{ .key = "name", .value = .{ .string = "a" } } } },
    } } },
} };

// One-shot: parse, render, free.
try template.render(allocator, writer, "{{ title }}: {% for i in items %}{{ i.name }}{% endfor %}", ctx);

// Or parse once and render many times:
var tmpl = try template.Template.parse(allocator, source);
defer tmpl.deinit();
try tmpl.render(writer, ctx);
```

The context passed to `render` must be a `.map`. A parsed `Template` owns its AST
but borrows the source text, so keep the source alive while it is in use.
Parsing allocates the AST in an arena; **rendering allocates nothing** (loop
state lives on the stack), so a parsed template can be rendered repeatedly and
cheaply.

## Layout

The engine is one stage per file, in pipeline order:

| File | Role |
| --- | --- |
| `src/value.zig` | the runtime `Value` a template renders against |
| `src/scanner.zig` | source text → tokens (handles whitespace control) |
| `src/ast.zig` | the parsed node tree |
| `src/parser.zig` | tokens → AST |
| `src/renderer.zig` | AST + `Value` → output |
| `src/root.zig` | public API (`Template`, `render`) and behavior tests |

`examples/codegen.zig` reads a template from a file, renders it, and writes the
result to a file (`template-codegen <template-path> <output-path>`). Template
files use the `.tmpl` extension — a language-agnostic marker, since the engine
is a Jinja *subset* and the generated output can be any text (YAML, C++, …).

## Build

```sh
zig build test       # run the unit tests
zig build example    # render examples/codegen.tmpl -> zig-out/codegen.yaml
```
