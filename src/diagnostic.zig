//! Source locations for parse and render failures. Errors stay plain error
//! unions; a caller that wants details passes a `Diagnostic` and reads it after
//! a failure.

const std = @import("std");

/// Describes the most recent failure. `filename` and `subject` borrow from the
/// `Options` and template source given to `Template.parse`; they are valid as
/// long as those are.
pub const Diagnostic = struct {
    filename: []const u8 = "",

    /// 1-based line and byte column of the offending token.
    line: usize = 0,
    column: usize = 0,

    /// The tag, variable or expression that caused the failure. May be empty.
    subject: []const u8 = "",

    /// Writes `file:line:column: error.Name: 'subject'`.
    pub fn write(self: Diagnostic, w: *std.Io.Writer, err: anyerror) std.Io.Writer.Error!void {
        try w.print("{s}:{d}:{d}: error.{s}", .{
            self.filename,
            self.line,
            self.column,
            @errorName(err),
        });
        if (self.subject.len != 0) try w.print(": '{s}'", .{self.subject});
    }
};

/// Records failures for one template. Fields are borrowed.
pub const Report = struct {
    source: []const u8,
    filename: []const u8,
    diag: ?*Diagnostic,

    /// Records the location of `offset` and returns `err` for the caller to propagate.
    pub fn fail(self: Report, offset: usize, subject: []const u8, err: anytype) @TypeOf(err) {
        const diag = self.diag orelse return err;
        const end = @min(offset, self.source.len);
        const before = self.source[0..end];
        const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;

        diag.* = .{
            .filename = self.filename,
            .line = std.mem.count(u8, before, "\n") + 1,
            .column = end - line_start + 1,
            .subject = subject,
        };
        return err;
    }
};

test "fail records line, column and subject" {
    var diag: Diagnostic = .{};
    const report: Report = .{ .source = "ab\ncd {{ x }}", .filename = "t.tmpl", .diag = &diag };

    const err = report.fail(8, "x", error.UnknownVariable);

    try std.testing.expectEqual(error.UnknownVariable, err);
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqual(@as(usize, 6), diag.column);
    try std.testing.expectEqualStrings("x", diag.subject);
}
