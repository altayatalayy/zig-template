//! Realistic CMake and C++ generation cases with exact expected output.

const std = @import("std");
const root = @import("root.zig");

const testing = std.testing;

fn expectGenerated(expected: []const u8, source: []const u8, data: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ctx = try root.fromZig(arena.allocator(), data);

    try root.expectRenderWith(expected, source, .{}, ctx);
}

test "CMakeLists.txt" {
    const source =
        \\cmake_minimum_required(VERSION 3.20)
        \\project({{ name }} LANGUAGES CXX)
        \\
        \\add_library({{ name }}
        \\{% for src in sources %}
        \\    {{ src }}
        \\{% endfor %}
        \\)
        \\{% if tests and enable_tests %}
        \\enable_testing()
        \\{% endif %}
        \\target_link_libraries({{ name }} PUBLIC
        \\{%- for l in libs %} {{ l }}{% endfor %})
        \\
    ;
    const Project = struct {
        name: []const u8,
        sources: []const []const u8,
        libs: []const []const u8,
        tests: bool,
        enable_tests: bool,
    };

    try expectGenerated(
        "cmake_minimum_required(VERSION 3.20)\n" ++
            "project(gen LANGUAGES CXX)\n" ++
            "\n" ++
            "add_library(gen\n" ++
            "    a.cpp\n" ++
            "    b.cpp\n" ++
            ")\n" ++
            "enable_testing()\n" ++
            "target_link_libraries(gen PUBLIC fmt spdlog)\n",
        source,
        Project{
            .name = "gen",
            .sources = &.{ "a.cpp", "b.cpp" },
            .libs = &.{ "fmt", "spdlog" },
            .tests = true,
            .enable_tests = true,
        },
    );
}

test "C++ enum header" {
    const source =
        \\#pragma once
        \\
        \\namespace {{ ns }} {
        \\
        \\{% for e in enums %}
        \\enum class {{ e.name }} {
        \\{% for v in e.values %}
        \\    {{ v.name }}{% if v.value %} = {{ v.value }}{% endif %},
        \\{% endfor %}
        \\};
        \\
        \\{% endfor %}
        \\}  // namespace {{ ns }}
        \\
    ;
    const Member = struct { name: []const u8, value: ?i32 };
    const Enum = struct { name: []const u8, values: []const Member };

    try expectGenerated(
        "#pragma once\n" ++
            "\n" ++
            "namespace gen {\n" ++
            "\n" ++
            "enum class Color {\n" ++
            "    Red = 1,\n" ++
            "    Green,\n" ++
            "    Blue = 4,\n" ++
            "};\n" ++
            "\n" ++
            "enum class Mode {\n" ++
            "    Fast,\n" ++
            "};\n" ++
            "\n" ++
            "}  // namespace gen\n",
        source,
        .{
            .ns = "gen",
            .enums = @as([]const Enum, &.{
                .{ .name = "Color", .values = &.{
                    .{ .name = "Red", .value = 1 },
                    .{ .name = "Green", .value = null },
                    .{ .name = "Blue", .value = 4 },
                } },
                .{ .name = "Mode", .values = &.{.{ .name = "Fast", .value = null }} },
            }),
        },
    );
}

test "C++ class with indented method bodies" {
    const source =
        \\struct {{ name }} {
        \\{% for m in methods %}
        \\{% if m.body and m.enabled %}
        \\    void {{ m.name }}() {
        \\        {{ m.body.indent(8) }}
        \\    }
        \\{% else %}
        \\    void {{ m.name }}() {}
        \\{% endif %}
        \\{% endfor %}
        \\};
        \\
    ;
    const Method = struct { name: []const u8, body: []const u8, enabled: bool };

    try expectGenerated(
        "struct S {\n" ++
            "    void run() {\n" ++
            "        int a = 1;\n" ++
            "        return;\n" ++
            "    }\n" ++
            "    void noop() {}\n" ++
            "};\n",
        source,
        .{
            .name = "S",
            .methods = @as([]const Method, &.{
                .{ .name = "run", .body = "int a = 1;\nreturn;", .enabled = true },
                .{ .name = "noop", .body = "", .enabled = true },
            }),
        },
    );
}
