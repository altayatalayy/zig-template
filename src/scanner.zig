//! Splits a template into a stream of raw tokens: literal text and the inner
//! text of `{{ }}`, `{% %}` and `{# #}` tags. It also applies Jinja's
//! `trim_blocks` and `lstrip_blocks` whitespace control so the parser and
//! renderer never have to think about it.

const std = @import("std");

pub const ScanError = error{UnclosedTag};

/// A literal-text run or the trimmed inner text of an expression/block tag.
/// Comments produce no token; they are consumed silently.
pub const RawToken = union(enum) {
    text: []const u8,
    output: []const u8,
    block: []const u8,
};

const TagKind = enum { output, block, comment };

pub const Scanner = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn next(self: *Scanner) ScanError!?RawToken {
        while (self.pos < self.source.len) {
            const found = findOpen(self.source, self.pos) orelse {
                const text = self.source[self.pos..];
                self.pos = self.source.len;
                return .{ .text = text };
            };
            if (found.idx > self.pos) {
                var text = self.source[self.pos..found.idx];
                if (found.kind != .output) {
                    const at_line_start = self.pos == 0 or self.source[self.pos - 1] == '\n';
                    text = lstripTail(text, at_line_start);
                }
                self.pos = found.idx;
                return .{ .text = text };
            }

            const close = switch (found.kind) {
                .output => "}}",
                .block => "%}",
                .comment => "#}",
            };
            const start = self.pos + 2;
            const close_idx = std.mem.indexOfPos(u8, self.source, start, close) orelse
                return error.UnclosedTag;
            const inner = std.mem.trim(u8, self.source[start..close_idx], " \t\r\n");
            self.pos = close_idx + 2;

            switch (found.kind) {
                .output => return .{ .output = inner },
                .block => {
                    self.trimLeadingNewline();
                    return .{ .block = inner };
                },
                .comment => self.trimLeadingNewline(),
            }
        }
        return null;
    }

    /// `trim_blocks`: drop the single newline right after a block/comment tag.
    fn trimLeadingNewline(self: *Scanner) void {
        if (self.pos >= self.source.len) return;
        if (self.source[self.pos] == '\n') {
            self.pos += 1;
        } else if (std.mem.startsWith(u8, self.source[self.pos..], "\r\n")) {
            self.pos += 2;
        }
    }
};

fn findOpen(source: []const u8, from: usize) ?struct { idx: usize, kind: TagKind } {
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
