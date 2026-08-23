const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zpu = b.addModule("zpu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const demo = b.addExecutable(.{
        .name = "zpu-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zpu", .module = zpu }},
        }),
    });
    b.installArtifact(demo);

    const tests = b.addTest(.{ .root_module = zpu });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run deterministic unit tests");
    test_step.dependOn(&run_tests.step);

    const run_demo = b.addRunArtifact(demo);
    run_demo.addArg("zpu-demo.ppm");
    const demo_step = b.step("demo", "Render deterministic desktop scene to zpu-demo.ppm");
    demo_step.dependOn(&run_demo.step);
}
