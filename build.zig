const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zpu = b.addModule("zpu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const icd = b.addLibrary(.{
        .name = "vulkan_zpu",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan/driver.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(icd);
    const install_manifest = b.addInstallFile(b.path("src/vulkan/zpu_icd.x86_64.json"), "share/vulkan/icd.d/zpu_icd.x86_64.json");
    b.getInstallStep().dependOn(&install_manifest.step);
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

    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan/driver.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_behavior = b.addRunArtifact(behavior_tests);
    const behavior_step = b.step("behavior", "Require every instrumented ICD behavioral requirement");
    behavior_step.dependOn(&run_behavior.step);

    const coverage_tests = b.addTest(.{
        .name = "zpu-icd-coverage-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan/driver.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    const driver_path = b.pathFromRoot("src/vulkan/driver.zig");
    const collect_coverage = b.addSystemCommand(&.{ "kcov", "--clean", b.fmt("--include-path={s}", .{driver_path}) });
    const coverage_output = collect_coverage.addOutputDirectoryArg("coverage");
    collect_coverage.addArtifactArg(coverage_tests);
    const coverage_verifier = b.addExecutable(.{
        .name = "zpu-coverage-gate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/coverage_gate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const verify_coverage = b.addRunArtifact(coverage_verifier);
    verify_coverage.addDirectoryArg(coverage_output);
    const coverage_step = b.step("coverage", "Require 100% executed-line coverage for the ICD implementation");
    coverage_step.dependOn(&verify_coverage.step);

    const run_demo = b.addRunArtifact(demo);
    run_demo.addArg("zpu-demo.ppm");
    const demo_step = b.step("demo", "Render deterministic desktop scene to zpu-demo.ppm");
    demo_step.dependOn(&run_demo.step);

    const smoke = b.addExecutable(.{
        .name = "zpu-icd-smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    smoke.root_module.addCSourceFile(.{ .file = b.path("test/icd_smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    smoke.root_module.link_libc = true;
    smoke.root_module.linkSystemLibrary("dl", .{});
    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.addArtifactArg(icd);
    const smoke_step = b.step("smoke", "dlopen and exercise the private ICD ABI");
    smoke_step.dependOn(&run_smoke.step);
}
