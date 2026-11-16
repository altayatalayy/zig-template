# zig-template

A small Jinja-subset template engine for Zig 0.17, aimed at code generation.
It renders a runtime `Value` tree, so the same engine can emit Zig, C/C++,
Rust, Go, Python, JS/TS — any text.

## Syntax

```jinja
{{ path.to.value }}      output a value (string, int, float, bool)
{{ name.upper() }}       string method: upper / lower
{{ body.indent(4) }}     indent every line after the first by 4 spaces
{% if cond %}…{% elif cond %}…{% else %}…{% endif %}
{% for x in items %}…{% else %}…{% endfor %}   (else runs when items is empty)
{# comment #}
```

### Conditions

- Operands are paths or quoted strings; a lone operand tests truthiness.
- `==` and `!=` compare two operands.
- `not`, `and`, `or` and parentheses combine conditions.
- Precedence, highest first: comparison, `not`, `and`, `or`.
- `and` and `or` short-circuit: a name on the skipped side is never resolved.

### Loops

- `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last` and
  `loop.length` are available inside a loop.
- Bodies see both the loop variable and the outer scope.

### Whitespace

Options `trim_blocks` and `lstrip_blocks` are on by default:

- `trim_blocks` removes the newline after a `%}` or `#}`.
- `lstrip_blocks` removes spaces and tabs before a `{%` or `{#` that starts a line.
- `{{ }}` tags are never trimmed by these options.

Per-tag modifiers override the options:

| Modifier | Effect |
| --- | --- |
| `{%-` `{{-` `{#-` | remove all whitespace before the tag |
| `-%}` `-}}` `-#}` | remove all whitespace after the tag |
| `{%+` `{#+` | keep the whitespace before the tag |
| `+%}` `+#}` | keep the newline after the tag |

### Indentation

`indent` (Zig) and `.indent(n)` (template) use the same rules:

- Every non-blank line gets `n` spaces.
- The template method leaves the first line alone, since it continues an
  already indented line; the Zig function takes a `first_line` flag.
- Blank lines (empty or whitespace only) are written unchanged.
- A trailing newline is kept and is not followed by indentation.
- Empty input writes nothing.

### Names and errors

- A name that does not resolve fails with `error.UnknownVariable`; values are
  never invented.
- Output is written verbatim (no escaping).
- Errors are plain error unions (`ParseError`, `RenderError`). Pass a
  `Diagnostic` to get `file:line:column`, the error and the offending tag or name:

```zig
var diag: template.Diagnostic = .{};
const options: template.Options = .{ .filename = "api.tmpl" };
var tmpl = template.Template.parse(alloc, source, options, &diag) catch |err| {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try diag.write(&w, err);
    std.log.err("{s}", .{w.buffered()}); // api.tmpl:3:4: error.UnknownTag: 'while x'
    return err;
};
```

## Use

```zig
const template = @import("template");

// Zig data -> Value. Lists and maps are allocated in `arena`; strings borrow.
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();
const ctx = try template.fromZig(arena.allocator(), .{
    .title = "demo",
    .items = @as([]const Item, &items),
});

// One-shot: parse, render, free.
try template.render(gpa, writer, "{{ title }}", ctx, .{}, null);

// Or parse once and render many times:
var tmpl = try template.Template.parse(gpa, source, .{}, null);
defer tmpl.deinit();
try tmpl.render(writer, ctx, null);
```

- `Options` sets `trim_blocks`, `lstrip_blocks` and `filename`.
- The context passed to `render` must be a `.map`.
- A parsed `Template` owns its AST but borrows the source text and filename;
  keep them alive while it is in use.
- Parsing allocates the AST in an arena; rendering allocates nothing, so a parsed
  template can be rendered repeatedly and cheaply.

### Converting Zig data

`fromZig(alloc, data)` converts:

| Zig | Value |
| --- | --- |
| `bool` | `.bool` |
| integers | `.int` (`i64`); out of range fails with `error.IntegerOutOfRange` |
| `f16`..`f64` | `.float` |
| `[]const u8`, `*const [N]u8` | `.string` (borrowed, not copied) |
| other slices, arrays, array pointers | `.list` |
| structs | `.map` in field order |
| `?T` | `.null` or the converted `T` |
| `*T` | the converted `T` |
| `Value` | unchanged |

Any other type (enums, unions, tuples, `[N]u8`, wide floats, …) is a compile
error. List and map storage belongs to `alloc`, so pass an arena; strings borrow
from `data`, which must outlive the result.

## Layout

The engine is one stage per file, in pipeline order:

| File | Role |
| --- | --- |
| `src/value.zig` | the runtime `Value` a template renders against |
| `src/convert.zig` | Zig data → `Value` |
| `src/scanner.zig` | source text → tokens (handles whitespace control) |
| `src/ast.zig` | the parsed node tree |
| `src/parser.zig` | tokens → AST (including condition grammar) |
| `src/renderer.zig` | AST + `Value` → output |
| `src/indent.zig` | multiline indentation |
| `src/diagnostic.zig` | source locations for failures |
| `src/root.zig` | public API (`Template`, `render`, `Options`) |
| `src/tests.zig`, `src/codegen_tests.zig` | behavior tests, CMake/C++ cases |

`examples/codegen.zig` reads a template from a file, renders it, and writes the
result to a file (`template-codegen <template-path> <output-path>`).

## Development

The Nix flake pins Zig 0.17.1 and provides the development shell.

```sh
direnv allow         # once, to load the flake via .envrc
zig build test       # run all tests
zig fmt --check build.zig src examples
zig build example    # render examples/codegen.tmpl -> zig-out/codegen.yaml
nix flake check      # formatting and tests with the pinned compiler
```
