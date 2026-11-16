//! Splits a template into a stream of raw tokens: literal text and the inner
//! text of `{{ }}`, `{% %}` and `{# #}` tags. It also applies whitespace
//! control so the parser and renderer never have to think about it:
//!
//!   * `trim_blocks`:   the newline after a `%}` or `#}` is removed.
//!   * `lstrip_blocks`: spaces and tabs before a `{%` or `{#` are removed when
//!     they start a line.
//!   * `{%-`, `{{-`, `{#-`: remove all whitespace before the tag.
//!   * `-%}`, `-}}`, `-#}`: remove all whitespace after the tag.
//!   * `{%+`, `{#+`: keep the whitespace before the tag despite `lstrip_blocks`.
//!   * `+%}`, `+#}`: keep the newline after the tag despite `trim_blocks`.

const std = @import("std");

pub const ScanError = error{UnclosedTag};

pub const Options = struct {
    trim_blocks: bool = true,
    lstrip_blocks: bool = true,
};

/// A literal-text run or the trimmed inner text of an expression/block tag.
/// Comments produce no token; they are consumed silently. `offset` is the
/// position of `text` in the source.
pub const Token = struct {
    kind: enum { text, output, block },
    text: []const u8,
    offset: usize,
};

const TagKind = enum { output, block, comment };

const Open = struct { idx: usize, kind: TagKind };

const whitespace = " \t\r\n";

pub const Scanner = struct {
    source: []const u8,
    options: Options,
    pos: usize = 0,

    /// Where the tag that was last started opens; locates `UnclosedTag`.
    tag_start: usize = 0,

    /// Set by a closing `-`: the next text run loses its leading whitespace.
    strip_next: bool = false,

    pub fn next(self: *Scanner) ScanError!?Token {
        while (self.pos < self.source.len) {
            const found = findOpen(self.source, self.pos) orelse {
                const offset = self.pos;
                self.pos = self.source.len;
                return self.textToken(offset, self.source.len, null);
            };

            if (found.idx > self.pos) {
                const offset = self.pos;
                self.pos = found.idx;
                return self.textToken(offset, found.idx, found);
            }

            self.strip_next = false;
            self.tag_start = found.idx;

            const close = switch (found.kind) {
                .output => "}}",
                .block => "%}",
                .comment => "#}",
            };
            const open_modifier = openModifier(self.source, found);
            const start = found.idx + 2 + @intFromBool(open_modifier != null);
            const close_idx = std.mem.indexOfPos(u8, self.source, start, close) orelse
                return error.UnclosedTag;
            const close_modifier = closeModifier(self.source, start, close_idx, found.kind);
            const end = close_idx - @intFromBool(close_modifier != null);

            const raw = self.source[start..end];
            const inner = std.mem.trim(u8, raw, whitespace);
            const inner_offset = start + (raw.len - std.mem.trimStart(u8, raw, whitespace).len);
            self.pos = close_idx + 2;

            if (close_modifier == '-') {
                self.strip_next = true;
            } else if (close_modifier == null and found.kind != .output and
                self.options.trim_blocks)
            {
                self.trimLeadingNewline();
            }

            switch (found.kind) {
                .output => return .{ .kind = .output, .text = inner, .offset = inner_offset },
                .block => return .{ .kind = .block, .text = inner, .offset = inner_offset },
                .comment => {},
            }
        }
        return null;
    }

    /// Builds the text token for `source[offset..end]`, applying the whitespace
    /// control of the preceding tag (`strip_next`) and of the following one.
    fn textToken(self: *Scanner, offset: usize, end: usize, next_tag: ?Open) Token {
        var text = self.source[offset..end];

        if (self.strip_next) {
            self.strip_next = false;
            text = std.mem.trimStart(u8, text, whitespace);
        }
        if (next_tag) |tag| text = self.stripTrailing(text, offset, tag);

        return .{ .kind = .text, .text = text, .offset = offset };
    }

    fn stripTrailing(self: Scanner, text: []const u8, offset: usize, tag: Open) []const u8 {
        const modifier = openModifier(self.source, tag);
        if (modifier == '-') return std.mem.trimEnd(u8, text, whitespace);
        if (modifier == '+' or tag.kind == .output or !self.options.lstrip_blocks) return text;

        const at_line_start = offset == 0 or self.source[offset - 1] == '\n';
        return lstripTail(text, at_line_start);
    }

    fn trimLeadingNewline(self: *Scanner) void {
        if (self.pos >= self.source.len) return;
        if (self.source[self.pos] == '\n') {
            self.pos += 1;
        } else if (std.mem.startsWith(u8, self.source[self.pos..], "\r\n")) {
            self.pos += 2;
        }
    }
};

fn findOpen(source: []const u8, from: usize) ?Open {
    var i = from;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] != '{') continue;
        switch (source[i + 1]) {
            '{' => return .{ .idx = i, .kind = .output },
            '%' => return .{ .idx = i, .kind = .block },
            '#' => return .{ .idx = i, .kind = .comment },
            else => {},
        }
    }
    return null;
}

/// The `-` or `+` right after the opening delimiter. `+` only applies to
/// block and comment tags.
fn openModifier(source: []const u8, tag: Open) ?u8 {
    if (tag.idx + 2 >= source.len) return null;
    const c = source[tag.idx + 2];
    if (c == '-' or (c == '+' and tag.kind != .output)) return c;
    return null;
}

/// The `-` or `+` right before the closing delimiter at `close_idx`.
fn closeModifier(source: []const u8, start: usize, close_idx: usize, kind: TagKind) ?u8 {
    if (close_idx <= start) return null;
    const c = source[close_idx - 1];
    if (c == '-' or (c == '+' and kind != .output)) return c;
    return null;
}

/// `lstrip_blocks`: drop the run of spaces/tabs right before a block/comment
/// tag, but only when that run starts a line. `at_line_start` says whether the
/// character preceding `text` was a newline (or the source start); it decides
/// the case where the blank run fills the whole text segment.
fn lstripTail(text: []const u8, at_line_start: bool) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
    if (end == text.len) return text;
    if (end == 0) return if (at_line_start) text[0..0] else text;
    return if (text[end - 1] == '\n') text[0..end] else text;
}

test lstripTail {
    const t = std.testing;
    // Indentation at the start of a line is stripped.
    try t.expectEqualStrings("x\n", lstripTail("x\n    ", true));
    // A whole-segment blank run is stripped only when it begins a line.
    try t.expectEqualStrings("", lstripTail("    ", true));
    try t.expectEqualStrings("    ", lstripTail("    ", false));
    // Trailing spaces that are not at a line start are left alone.
    try t.expectEqualStrings("a b ", lstripTail("a b ", false));
}
