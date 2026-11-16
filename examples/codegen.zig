//! Reads a template from a file, renders it against Zig data converted with
//! `fromZig` (the shape a YAML loader would produce), and writes the result to
//! a file. Parse and render failures are logged with their source location.
//!
//!     template-codegen <template-path> <output-path>
//!
//! `zig build example` supplies `examples/codegen.tmpl` and an output path under
//! `zig-out/`.

const std = @import("std");
const template = @import("template");

const Service = struct {
    name: []const u8,
    image: []const u8,
    ports: []const u16,
};

const services = [_]Service{
    .{ .name = "web", .image = "nginx:1.27", .ports = &.{ 80, 443 } },
    .{ .name = "worker", .image = "redis:7", .ports = &.{} },
};

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

    var data_arena = std.heap.ArenaAllocator.init(gpa);
    defer data_arena.deinit();
    const ctx = try template.fromZig(data_arena.allocator(), .{
        .services = @as([]const Service, &services),
    });

    var diag: template.Diagnostic = .{};
    const options: template.Options = .{ .filename = template_path };
    var parsed = template.Template.parse(gpa, source, options, &diag) catch |err| {
        return logFailure(diag, err);
    };
    defer parsed.deinit();

    if (std.fs.path.dirname(output_path)) |dir| try cwd.createDirPath(io, dir);
    var out_file = try cwd.createFile(io, output_path, .{});
    defer out_file.close(io);

    var buf: [4096]u8 = undefined;
    var out = out_file.writer(io, &buf);
    parsed.render(&out.interface, ctx, &diag) catch |err| return logFailure(diag, err);
    try out.interface.flush();
}

fn logFailure(diag: template.Diagnostic, err: anyerror) anyerror {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    diag.write(&w, err) catch {};
    std.log.err("{s}", .{w.buffered()});
    return err;
}
