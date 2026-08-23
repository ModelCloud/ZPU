const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const require_limited = b.addSystemCommand(&.{"tools/require-limited.sh"});
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

    const benchmark = b.addExecutable(.{
        .name = "zpu-benchmark",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(benchmark);
    const run_benchmark = b.addRunArtifact(benchmark);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run deterministic 2D benchmark and optional baseline guard");
    benchmark_step.dependOn(&run_benchmark.step);
    run_benchmark.step.dependOn(&require_limited.step);

    const tests = b.addTest(.{ .root_module = zpu });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&require_limited.step);
    const test_step = b.step("test", "Run deterministic unit tests");
    test_step.dependOn(&run_tests.step);
    const benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = b.graph.host, .optimize = .Debug }),
    });
    const run_benchmark_tests = b.addRunArtifact(benchmark_tests);
    run_benchmark_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&run_benchmark_tests.step);
    const benchmark_cli_tests = b.addSystemCommand(&.{"test/benchmark_cli.sh"});
    benchmark_cli_tests.addArtifactArg(benchmark);
    benchmark_cli_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&benchmark_cli_tests.step);
    const benchmark_history_tests = b.addSystemCommand(&.{"test/benchmark_history.sh"});
    benchmark_history_tests.addArtifactArg(benchmark);
    benchmark_history_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&benchmark_history_tests.step);

    const behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan/driver.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_behavior = b.addRunArtifact(behavior_tests);
    run_behavior.step.dependOn(&require_limited.step);
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
    collect_coverage.step.dependOn(&require_limited.step);
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
    const coverage_step = b.step("coverage", "Require 100% executed-line coverage for ICD and benchmark core");
    coverage_step.dependOn(&verify_coverage.step);

    const benchmark_coverage_tests = b.addTest(.{
        .name = "zpu-benchmark-coverage-tests",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = b.graph.host, .optimize = .Debug }),
        .use_llvm = true,
    });
    const benchmark_path = b.pathFromRoot("src/benchmark.zig");
    const collect_benchmark_coverage = b.addSystemCommand(&.{ "kcov", "--clean", b.fmt("--include-path={s}", .{benchmark_path}) });
    collect_benchmark_coverage.step.dependOn(&require_limited.step);
    const benchmark_coverage_output = collect_benchmark_coverage.addOutputDirectoryArg("benchmark-coverage");
    collect_benchmark_coverage.addArtifactArg(benchmark_coverage_tests);
    const verify_benchmark_coverage = b.addRunArtifact(coverage_verifier);
    verify_benchmark_coverage.addDirectoryArg(benchmark_coverage_output);
    verify_benchmark_coverage.addArg("/src/benchmark.zig");
    coverage_step.dependOn(&verify_benchmark_coverage.step);
    const benchmark_coverage_exe = b.addExecutable(.{
        .name = "zpu-benchmark-coverage",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = b.graph.host, .optimize = .Debug }),
        .use_llvm = true,
    });
    const collect_cli_coverage = b.addSystemCommand(&.{"test/benchmark_cli.sh"});
    collect_cli_coverage.step.dependOn(&require_limited.step);
    collect_cli_coverage.addArtifactArg(benchmark_coverage_exe);
    const cli_coverage_output = collect_cli_coverage.addOutputDirectoryArg("benchmark-cli-coverage-v8");
    collect_cli_coverage.addArg(b.pathFromRoot("src/benchmark_main.zig"));
    collect_cli_coverage.addArtifactArg(benchmark_coverage_tests);
    const verify_cli_coverage = b.addRunArtifact(coverage_verifier);
    verify_cli_coverage.addDirectoryArg(cli_coverage_output);
    verify_cli_coverage.addArg("/src/benchmark_main.zig");
    coverage_step.dependOn(&verify_cli_coverage.step);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(&require_limited.step);
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
    run_smoke.step.dependOn(&require_limited.step);
    run_smoke.addArtifactArg(icd);
    const smoke_step = b.step("smoke", "dlopen and exercise the private ICD ABI");
    smoke_step.dependOn(&run_smoke.step);

    const transfer_client = b.addExecutable(.{
        .name = "zpu-vulkan-transfer",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    transfer_client.root_module.addCSourceFile(.{ .file = b.path("test/vulkan_transfer.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    transfer_client.root_module.link_libc = true;
    transfer_client.root_module.linkSystemLibrary("vulkan", .{});
    const run_transfer = b.addRunArtifact(transfer_client);
    run_transfer.step.dependOn(&require_limited.step);
    run_transfer.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_transfer.step.dependOn(b.getInstallStep());
    const transfer_step = b.step("transfer", "Run exact 240x240 transfers through the system Vulkan loader");
    transfer_step.dependOn(&run_transfer.step);
}
