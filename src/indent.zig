//! Indents multiline text, for embedding generated fragments at a nesting level.

const std = @import("std");

/// Writes `text` with every non-blank line prefixed by `width` spaces.
///
///   * The first line is indented only when `first_line` is set; clear it when
///     the fragment continues a line that is already indented.
///   * Blank lines (empty or only spaces, tabs and `\r`) are written unchanged
///     so no trailing whitespace is created.
///   * A trailing newline is kept and is not followed by an indented empty line.
///   * Empty input writes nothing.
pub fn indent(
    w: *std.Io.Writer,
    text: []const u8,
    width: usize,
    first_line: bool,
) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var is_first = true;

    while (lines.next()) |line| : (is_first = false) {
        if (!is_first) try w.writeByte('\n');
        if ((first_line or !is_first) and !isBlank(line)) try w.splatByteAll(' ', width);
        try w.writeAll(line);
    }
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn expectIndent(
    expected: []const u8,
    text: []const u8,
    width: usize,
    first_line: bool,
) !void {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try indent(&aw.writer, text, width, first_line);

    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "indents every line including the first" {
    try expectIndent("  a\n  b", "a\nb", 2, true);
}

test "first line is left alone when requested" {
    try expectIndent("a\n  b", "a\nb", 2, false);
}

test "blank lines stay unindented and keep their content" {
    try expectIndent("  a\n\n \t\n  b", "a\n\n \t\nb", 2, true);
}

test "trailing newline is kept without a trailing indent" {
    try expectIndent("  a\n", "a\n", 2, true);
    try expectIndent("  a\n\n", "a\n\n", 2, true);
}

test "empty input and zero width" {
    try expectIndent("", "", 4, true);
    try expectIndent("\n", "\n", 4, true);
    try expectIndent("a\nb", "a\nb", 0, true);
}

test "existing indentation is preserved" {
    try expectIndent("      a\n        b", "  a\n    b", 4, true);
}
