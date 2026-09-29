//! Reads a template from a file, renders it against a hand-built `Value` context
//! (the shape a YAML loader would produce), and writes the result to a file.
//!
//!     template-codegen <template-path> <output-path>
//!
//! `zig build example` supplies `examples/codegen.tmpl` and an output path under
//! `zig-out/`.

const std = @import("std");
const template = @import("template");
const Value = template.Value;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.skip(); // program name
    const template_path = args.next() orelse return error.MissingTemplatePath;
    const output_path = args.next() orelse return error.MissingOutputPath;

    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAlloc(io, template_path, gpa, .unlimited);
    defer gpa.free(source);

    const ctx: Value = .{ .map = &.{.{ .key = "services", .value = .{ .list = &.{
        .{ .map = &.{
            .{ .key = "name", .value = .{ .string = "web" } },
            .{ .key = "image", .value = .{ .string = "nginx:1.27" } },
            .{ .key = "ports", .value = .{ .list = &.{
                .{ .int = 80 },
                .{ .int = 443 },
            } } },
        } },
        .{ .map = &.{
            .{ .key = "name", .value = .{ .string = "worker" } },
            .{ .key = "image", .value = .{ .string = "redis:7" } },
            .{ .key = "ports", .value = .{ .list = &.{} } },
        } },
    } } }} };

    if (std.fs.path.dirname(output_path)) |dir| try cwd.createDirPath(io, dir);
    var out_file = try cwd.createFile(io, output_path, .{});
    defer out_file.close(io);

    var buf: [4096]u8 = undefined;
    var out = out_file.writer(io, &buf);
    try template.render(gpa, &out.interface, source, ctx);
    try out.interface.flush();
}
