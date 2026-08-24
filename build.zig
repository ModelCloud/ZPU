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
    icd.root_module.link_libc = true;
    icd.root_module.linkSystemLibrary("xcb", .{});
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
    const benchmark_cli_tests = b.addSystemCommand(&.{"bash"});
    benchmark_cli_tests.addFileArg(b.path("test/benchmark_cli.sh"));
    benchmark_cli_tests.addArtifactArg(benchmark);
    benchmark_cli_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&benchmark_cli_tests.step);
    const benchmark_history_tests = b.addSystemCommand(&.{"test/benchmark_history.sh"});
    benchmark_history_tests.addArtifactArg(benchmark);
    benchmark_history_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&benchmark_history_tests.step);
    const cpu_fanout_tests = b.addSystemCommand(&.{"test/cpu_fanout.sh"});
    cpu_fanout_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&cpu_fanout_tests.step);
    const limited_cpus_topology_tests = b.addSystemCommand(&.{"test/limited_cpus_topology.sh"});
    limited_cpus_topology_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&limited_cpus_topology_tests.step);

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
    const collect_cli_coverage = b.addSystemCommand(&.{"bash"});
    collect_cli_coverage.addFileArg(b.path("test/benchmark_cli.sh"));
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

    const xcb_present_test = b.addExecutable(.{
        .name = "zpu-xcb-present",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    xcb_present_test.root_module.addCSourceFile(.{ .file = b.path("test/xcb_present.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    xcb_present_test.root_module.link_libc = true;
    xcb_present_test.root_module.linkSystemLibrary("vulkan", .{});
    xcb_present_test.root_module.linkSystemLibrary("xcb", .{});
    const run_xcb_present = b.addSystemCommand(&.{ "xvfb-run", "-a", "-s", "-screen 0 640x480x24 -nolisten tcp" });
    run_xcb_present.addArtifactArg(xcb_present_test);
    run_xcb_present.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_xcb_present.step.dependOn(&require_limited.step);
    run_xcb_present.step.dependOn(b.getInstallStep());
    const xcb_present_step = b.step("xcb-present", "Require swapchain pixels to reach an XCB window under Xvfb");
    xcb_present_step.dependOn(&run_xcb_present.step);

    const run_vkcube_visual = b.addSystemCommand(&.{ "xvfb-run", "-a", "-s", "-screen 0 640x480x24 -nolisten tcp", "test/vkcube_visual.sh" });
    run_vkcube_visual.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_vkcube_visual.step.dependOn(&require_limited.step);
    run_vkcube_visual.step.dependOn(b.getInstallStep());
    const vkcube_visual_step = b.step("vkcube-visual", "Require non-clear vkcube pixels captured from the XCB window");
    vkcube_visual_step.dependOn(&run_vkcube_visual.step);

    const run_desktop_session = b.addSystemCommand(&.{ "xvfb-run", "-a", "-s", "-screen 0 640x480x24 -nolisten tcp", "test/desktop_session.sh" });
    run_desktop_session.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_desktop_session.step.dependOn(&require_limited.step);
    run_desktop_session.step.dependOn(b.getInstallStep());
    const desktop_session_step = b.step("desktop-session", "Require visually verified vkcube inside a minimal X11 desktop session");
    desktop_session_step.dependOn(&run_desktop_session.step);

    const desktop_probe = b.addExecutable(.{
        .name = "zpu-desktop-readiness",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    desktop_probe.root_module.addCSourceFile(.{ .file = b.path("test/desktop_readiness.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    desktop_probe.root_module.link_libc = true;
    desktop_probe.root_module.linkSystemLibrary("vulkan", .{});

    const run_desktop_probe = b.addRunArtifact(desktop_probe);
    run_desktop_probe.step.dependOn(&require_limited.step);
    run_desktop_probe.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_desktop_probe.step.dependOn(b.getInstallStep());
    const desktop_probe_step = b.step("desktop-probe", "Report Vulkan window-system and rendering readiness without requiring success");
    desktop_probe_step.dependOn(&run_desktop_probe.step);

    const require_desktop_ready = b.addRunArtifact(desktop_probe);
    require_desktop_ready.addArg("--require-ready");
    require_desktop_ready.step.dependOn(&require_limited.step);
    require_desktop_ready.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    require_desktop_ready.step.dependOn(b.getInstallStep());
    const desktop_ready_step = b.step("desktop-ready", "Require enough Vulkan WSI and rendering support to start a window test");
    desktop_ready_step.dependOn(&require_desktop_ready.step);

    const vkcube_probe = b.addSystemCommand(&.{"test/vkcube_compat.sh"});
    vkcube_probe.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    vkcube_probe.step.dependOn(&require_limited.step);
    vkcube_probe.step.dependOn(b.getInstallStep());
    const vkcube_probe_step = b.step("vkcube-probe", "Run two XCB vkcube frames under Xvfb and report the current blocker");
    vkcube_probe_step.dependOn(&vkcube_probe.step);

    const require_vkcube_ready = b.addSystemCommand(&.{"test/vkcube_compat.sh"});
    require_vkcube_ready.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    require_vkcube_ready.addArg("--require-ready");
    require_vkcube_ready.step.dependOn(&require_limited.step);
    require_vkcube_ready.step.dependOn(b.getInstallStep());
    const vkcube_ready_step = b.step("vkcube-ready", "Require two presented XCB vkcube frames under Xvfb");
    vkcube_ready_step.dependOn(&require_vkcube_ready.step);
}
