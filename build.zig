const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("template", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "template-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/codegen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "template", .module = mod }},
        }),
    });
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    run_example.addFileArg(b.path("examples/codegen.tmpl"));
    run_example.addArg(b.getInstallPath(.prefix, "codegen.yaml"));
    b.step("example", "Run the codegen example").dependOn(&run_example.step);
}
