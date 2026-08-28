// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default shipped artifacts to the x86-64 baseline CPU model so LLVM can
    // never emit AVX2/AVX-512 (or any VEX-encoded) instruction into them.
    // `-Dcpu` remains an explicit opt into a higher artifact tier. The
    // eight-lane kernels live in a separate x86_64_v3 library; building with
    // `-Dv3-kernels=false` produces fully kernel-free baseline artifacts for
    // the ISA disassembly evidence gates.
    const v3_kernels_enabled = b.option(bool, "v3-kernels", "Link the separately compiled x86-64-v3 eight-lane kernel objects") orelse true;
    const enable_xcb = b.option(bool, "xcb", "Build the xcb-dependent artifacts (ICD, demo)") orelse true;
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    if (b.option([]const u8, "search-prefix", "Extra library search prefix for cross builds (e.g. /usr/lib/aarch64-linux-gnu)")) |prefix| {
        b.addSearchPrefix(prefix);
    }

    const v3_tier_applicable = target.result.cpu.arch == .x86_64;
    const v3_available = v3_kernels_enabled and v3_tier_applicable;

    const build_config = b.addOptions();
    build_config.addOption(bool, "v3_kernels", v3_available);
    const build_config_module = build_config.createModule();

    // Kernel-free twin configuration: identical sources and flags except the
    // eight-lane boundary is compiled out. ReleaseFast copies of every
    // shipped artifact are gated with zero-VEX expectations in `isa-gate`,
    // keeping the strongest evidence inside the normal test contract.
    const clean_config = b.addOptions();
    clean_config.addOption(bool, "v3_kernels", false);
    const clean_config_module = clean_config.createModule();
    const release_fast = .ReleaseFast;

    const v3_kernels_main: ?*std.Build.Step.Compile =
        if (v3_available) addV3Kernels(b, target, "zpu-x86-64-v3-kernels") else null;
    const v3_kernels_host: ?*std.Build.Step.Compile =
        if (v3_available) addV3Kernels(b, b.graph.host, "zpu-host-x86-64-v3-kernels") else null;

    const require_limited = b.addSystemCommand(&.{"tools/require-limited.sh"});
    const smolvm_guest_test = b.addSystemCommand(&.{"test/smolvm_guest.sh"});
    smolvm_guest_test.step.dependOn(&require_limited.step);
    const smolvm_guest_step = b.step("smolvm-guest-test", "Test fail-closed SmolVM guest isolation and launch commands");
    smolvm_guest_step.dependOn(&smolvm_guest_test.step);
    const smolvm_dry_run = b.addSystemCommand(&.{"test/smolvm_dry_run.sh"});
    smolvm_dry_run.step.dependOn(&require_limited.step);
    const smolvm_untrusted_environment = [_][]const u8{
        "VK_DRIVER_FILES",              "VK_ICD_FILENAMES",                  "VK_ADD_DRIVER_FILES",             "VK_LAYER_PATH",               "VK_ADD_LAYER_PATH",
        "VK_IMPLICIT_LAYER_PATH",       "VK_ADD_IMPLICIT_LAYER_PATH",        "VK_INSTANCE_LAYERS",              "VK_LOADER_LAYERS_ENABLE",     "VK_LOADER_LAYERS_DISABLE",
        "VK_LOADER_LAYERS_ALLOW",       "VK_LOADER_DRIVERS_SELECT",          "VK_LOADER_DRIVERS_DISABLE",       "LD_PRELOAD",                  "LD_LIBRARY_PATH",
        "LD_AUDIT",                     "ZPU_REFRESH_HZ",                    "ZPU_SMOLVM_MACHINE",              "ZPU_SMOLVM_IMAGE",            "ZPU_SMOLVM_CPUS",
        "ZPU_SMOLVM_MEMORY",            "ZPU_SMOLVM_ALLOW_TRUSTED_X11",      "ZPU_SMOLVM_TESTING",              "ZPU_SMOLVM_TEST_SOCKET_ROOT", "DISPLAY",
        "XAUTHORITY",                   "XDG_RUNTIME_DIR",                   "SMOLVM_FIXTURE_LOG",              "SMOLVM_FIXTURE_OMIT",         "SMOLVM_FIXTURE_NETWORK",
        "SMOLVM_FIXTURE_STATE",         "SMOLVM_FIXTURE_JSON_MODE",          "SMOLVM_FIXTURE_FAIL_PACMAN",      "SMOLVM_FIXTURE_PACMAN_SLEEP", "SMOLVM_XAUTH_NLIST_FAIL",
        "SMOLVM_XAUTH_GENERATE_FAIL",   "SMOLVM_XAUTH_DUPLICATE_EQUIVALENT", "SMOLVM_FIXTURE_PACMAN_READY",     "SMOLVM_XAUTH_EQUAL_KEY",      "SMOLVM_XAUTH_MULTIPLE_NEW",
        "SMOLVM_XAUTH_READY",           "SMOLVM_XAUTH_SLEEP",                "SMOLVM_FIXTURE_CAPTURE_AUTH_DIR", "SMOLVM_TAR_LONG_LIST",        "SMOLVM_FIXTURE_FAIL_STOP_ONCE_FILE",
        "SMOLVM_FIXTURE_CLEANUP_READY",
    };
    for (smolvm_untrusted_environment) |name| {
        smolvm_guest_test.removeEnvironmentVariable(name);
        smolvm_dry_run.removeEnvironmentVariable(name);
    }
    const smolvm_dry_run_step = b.step("smolvm-dry-run", "Print the complete guest lifecycle without changing host or VM state");
    smolvm_dry_run_step.dependOn(&smolvm_dry_run.step);
    const validate_api_inventory = b.addSystemCommand(&.{ "python3", "tools/api_inventory.py" });
    validate_api_inventory.step.dependOn(&require_limited.step);
    const validate_command_matrix = b.addSystemCommand(&.{ "python3", "tools/vulkan_command_matrix.py" });
    validate_command_matrix.step.dependOn(&require_limited.step);
    const validate_vulkan_abi_status = b.addSystemCommand(&.{ "python3", "tools/vulkan_abi_status.py" });
    validate_vulkan_abi_status.step.dependOn(&require_limited.step);
    const test_api_inventory = b.addSystemCommand(&.{"test/api_inventory.sh"});
    test_api_inventory.step.dependOn(&require_limited.step);
    const api_inventory_step = b.step("api-inventory", "Validate the pinned Vulkan target inventory and failure fixtures");
    api_inventory_step.dependOn(&validate_api_inventory.step);
    api_inventory_step.dependOn(&validate_command_matrix.step);
    api_inventory_step.dependOn(&validate_vulkan_abi_status.step);
    api_inventory_step.dependOn(&test_api_inventory.step);
    const zpu = b.addModule("zpu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zpu.link_libc = true;
    if (enable_xcb) zpu.linkSystemLibrary("xcb", .{});
    zpu.addImport("zpu_config", build_config_module);
    if (v3_kernels_main) |k| zpu.linkLibrary(k);
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
    if (enable_xcb) icd.root_module.linkSystemLibrary("xcb", .{});
    if (enable_xcb) b.installArtifact(icd);
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
    if (enable_xcb) b.installArtifact(demo);

    // Kernel-free ReleaseFast twins used by the isa-gate as the strongest
    // normal-contract evidence: identical sources, boundary compiled out.
    const zpu_clean = b.addModule("zpu-clean", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = release_fast,
    });
    zpu_clean.link_libc = true;
    if (enable_xcb) zpu_clean.linkSystemLibrary("xcb", .{});
    zpu_clean.addImport("zpu_config", clean_config_module);
    const icd_clean = b.addLibrary(.{
        .name = "vulkan_zpu_clean",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan/driver.zig"),
            .target = target,
            .optimize = release_fast,
        }),
    });
    icd_clean.root_module.link_libc = true;
    if (enable_xcb) icd_clean.root_module.linkSystemLibrary("xcb", .{});
    const demo_clean = b.addExecutable(.{
        .name = "zpu-demo-clean",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo/main.zig"),
            .target = target,
            .optimize = release_fast,
            .imports = &.{.{ .name = "zpu", .module = zpu_clean }},
        }),
    });

    const benchmark = b.addExecutable(.{
        .name = "zpu-benchmark",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = target, .optimize = optimize }),
    });
    benchmark.root_module.addImport("zpu_config", build_config_module);
    if (v3_kernels_main) |k| benchmark.root_module.linkLibrary(k);
    b.installArtifact(benchmark);
    const benchmark_clean = b.addExecutable(.{
        .name = "zpu-benchmark-clean",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = target, .optimize = release_fast }),
    });
    benchmark_clean.root_module.addImport("zpu_config", clean_config_module);
    const run_benchmark = b.addRunArtifact(benchmark);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run deterministic 2D benchmark and optional baseline guard");
    benchmark_step.dependOn(&run_benchmark.step);
    run_benchmark.step.dependOn(&require_limited.step);

    const benchmark_3d = b.addExecutable(.{
        .name = "zpu-benchmark-3d",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_3d.zig"), .target = target, .optimize = optimize }),
    });
    benchmark_3d.root_module.link_libc = true;
    b.installArtifact(benchmark_3d);
    const run_benchmark_3d = b.addRunArtifact(benchmark_3d);
    if (b.args) |args| run_benchmark_3d.addArgs(args);
    run_benchmark_3d.step.dependOn(&require_limited.step);
    const benchmark_3d_step = b.step("benchmark-3d", "Run the deterministic vkcube-specific CPU 3D benchmark");
    benchmark_3d_step.dependOn(&run_benchmark_3d.step);

    const run_target_800x600 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_800x600.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_800x600.addArgs(&.{ "800", "600", "240", "241" });
    run_target_800x600.step.dependOn(&require_limited.step);
    run_target_800x600.step.dependOn(b.getInstallStep());
    const target_800x600_step = b.step("target-800x600", "Require vkcube 800x600 presented-frame p99 at 240 FPS or better");
    target_800x600_step.dependOn(&run_target_800x600.step);

    const run_target_4k_30 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_4k_30.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_4k_30.addArgs(&.{ "3840", "2160", "30", "31" });
    run_target_4k_30.step.dependOn(&require_limited.step);
    run_target_4k_30.step.dependOn(b.getInstallStep());
    const target_4k_30_step = b.step("target-4k-30", "Require vkcube 3840x2160 presented-frame p99 at 30 FPS or better");
    target_4k_30_step.dependOn(&run_target_4k_30.step);

    const run_target_4k_60 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_4k_60.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_4k_60.addArgs(&.{ "3840", "2160", "60", "63" });
    run_target_4k_60.step.dependOn(&require_limited.step);
    run_target_4k_60.step.dependOn(b.getInstallStep());
    const target_4k_60_step = b.step("target-4k-60", "Require vkcube 3840x2160 presented-frame p99 at 60 FPS or better");
    target_4k_60_step.dependOn(&run_target_4k_60.step);
    const benchmark_ir = b.addExecutable(.{ .name = "zpu-render-ir-exec-benchmark", .root_module = b.createModule(.{ .root_source_file = b.path("src/render_ir_exec_benchmark.zig"), .target = target, .optimize = optimize }) });
    benchmark_ir.root_module.link_libc = true;
    const run_benchmark_ir = b.addRunArtifact(benchmark_ir);
    run_benchmark_ir.step.dependOn(&require_limited.step);
    const benchmark_ir_step = b.step("benchmark-render-ir", "Benchmark synthetic scalar render IR setup and warm execution");
    benchmark_ir_step.dependOn(&run_benchmark_ir.step);

    const run_target_4k_120 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_4k_120.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_4k_120.addArgs(&.{ "3840", "2160", "120", "122" });
    run_target_4k_120.step.dependOn(&require_limited.step);
    run_target_4k_120.step.dependOn(b.getInstallStep());
    const target_4k_120_step = b.step("target-4k-120", "Require vkcube 3840x2160 presented-frame p99 at 120 FPS or better");
    target_4k_120_step.dependOn(&run_target_4k_120.step);

    const run_target_4k_240 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_4k_240.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_4k_240.addArgs(&.{ "3840", "2160", "240", "255" });
    run_target_4k_240.step.dependOn(&require_limited.step);
    run_target_4k_240.step.dependOn(b.getInstallStep());
    const target_4k_240_step = b.step("target-4k-240", "Require vkcube 3840x2160 presented-frame p99 at 240 FPS or better");
    target_4k_240_step.dependOn(&run_target_4k_240.step);

    const run_target_8k_60 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_8k_60.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_8k_60.addArgs(&.{ "7680", "4320", "60", "63" });
    run_target_8k_60.step.dependOn(&require_limited.step);
    run_target_8k_60.step.dependOn(b.getInstallStep());
    const target_8k_60_step = b.step("target-8k-60", "Require vkcube 7680x4320 presented-frame p99 at 60 FPS or better");
    target_8k_60_step.dependOn(&run_target_8k_60.step);

    const run_target_8k_120 = b.addSystemCommand(&.{ "python3", "test/vkcube_benchmark.py" });
    run_target_8k_120.addArg(b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_target_8k_120.addArgs(&.{ "7680", "4320", "120", "122" });
    run_target_8k_120.step.dependOn(&require_limited.step);
    run_target_8k_120.step.dependOn(b.getInstallStep());
    const target_8k_120_step = b.step("target-8k-120", "Require vkcube 7680x4320 presented-frame p99 at 120 FPS or better");
    target_8k_120_step.dependOn(&run_target_8k_120.step);

    const tests = b.addTest(.{ .root_module = zpu });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&require_limited.step);
    const test_step = b.step("test", "Run deterministic unit tests");
    const metal_abi_status = b.addSystemCommand(&.{ "python3", "tools/metal_abi_status.py" });
    metal_abi_status.step.dependOn(&require_limited.step);
    const metal_abi_tests = b.addSystemCommand(&.{ "test/metal_abi.sh" });
    metal_abi_tests.step.dependOn(&require_limited.step);
    const metal_abi_step = b.step("metal-abi", "Validate the native Metal ABI and report SDK coverage");
    metal_abi_step.dependOn(&metal_abi_status.step);
    metal_abi_step.dependOn(&metal_abi_tests.step);
    test_step.dependOn(metal_abi_step);
    // Cross-compiling: prove the test graph builds for the target without
    // attempting to execute foreign binaries locally.
    const cross_compiling = target.result.cpu.arch != b.graph.host.result.cpu.arch or
        target.result.os.tag != b.graph.host.result.os.tag;
    if (cross_compiling) {
        tests.step.dependOn(&require_limited.step);
        test_step.dependOn(&tests.step);
    } else {
        test_step.dependOn(&run_tests.step);
    }

    const benchmark_ir_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/render_ir_exec_benchmark.zig"), .target = b.graph.host, .optimize = .Debug }) });
    benchmark_ir_tests.root_module.link_libc = true;
    const run_benchmark_ir_tests = b.addRunArtifact(benchmark_ir_tests);
    run_benchmark_ir_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&run_benchmark_ir_tests.step);
    const cadence_tests = b.addSystemCommand(&.{ "python3", "test/cadence.py" });
    cadence_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&cadence_tests.step);
    const benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = b.graph.host, .optimize = .Debug }),
    });
    benchmark_tests.root_module.addImport("zpu_config", build_config_module);
    if (v3_kernels_host) |k| benchmark_tests.root_module.linkLibrary(k);
    const run_benchmark_tests = b.addRunArtifact(benchmark_tests);
    run_benchmark_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&run_benchmark_tests.step);
    const benchmark_3d_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_3d.zig"), .target = b.graph.host, .optimize = .Debug }),
    });
    benchmark_3d_tests.root_module.link_libc = true;
    const run_benchmark_3d_tests = b.addRunArtifact(benchmark_3d_tests);
    run_benchmark_3d_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&run_benchmark_3d_tests.step);
    const benchmark_cli_tests = b.addSystemCommand(&.{"bash"});
    benchmark_cli_tests.addFileArg(b.path("test/benchmark_cli.sh"));
    benchmark_cli_tests.addArtifactArg(benchmark);
    benchmark_cli_tests.step.dependOn(&require_limited.step);
    const benchmark_history_tests = b.addSystemCommand(&.{"test/benchmark_history.sh"});
    benchmark_history_tests.addArtifactArg(benchmark);
    benchmark_history_tests.step.dependOn(&require_limited.step);
    const evidence_tests = b.addSystemCommand(&.{"test/evidence.sh"});
    evidence_tests.addArtifactArg(benchmark);
    evidence_tests.addArtifactArg(benchmark_3d);
    evidence_tests.step.dependOn(&require_limited.step);
    if (!cross_compiling) {
        // These integrations execute the built artifacts locally and are
        // meaningless for foreign targets; the compile-only coverage above
        // already proves the graph builds.
        test_step.dependOn(&benchmark_cli_tests.step);
        test_step.dependOn(&benchmark_history_tests.step);
        test_step.dependOn(&evidence_tests.step);
    }
    const cpu_fanout_tests = b.addSystemCommand(&.{"test/cpu_fanout.sh"});
    cpu_fanout_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&cpu_fanout_tests.step);
    const limited_cpus_topology_tests = b.addSystemCommand(&.{"test/limited_cpus_topology.sh"});
    limited_cpus_topology_tests.step.dependOn(&require_limited.step);
    test_step.dependOn(&limited_cpus_topology_tests.step);
    test_step.dependOn(&test_api_inventory.step);

    const shader_module_client = b.addExecutable(.{
        .name = "zpu-vulkan-shader-module",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    shader_module_client.root_module.addCSourceFile(.{ .file = b.path("test/vulkan_shader_module.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    shader_module_client.root_module.link_libc = true;
    shader_module_client.root_module.linkSystemLibrary("vulkan", .{});
    const run_shader_module = b.addRunArtifact(shader_module_client);
    run_shader_module.step.dependOn(&require_limited.step);
    run_shader_module.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_shader_module.setEnvironmentVariable("VK_ICD_FILENAMES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_shader_module.step.dependOn(b.getInstallStep());
    if (cross_compiling) {
        // Foreign targets have no local Vulkan loader to link against (the
        // system libvulkan's glibc symbol versions typically exceed Zig's
        // bundled cross sysroot), and executing the client locally is
        // impossible anyway. The ISA-relevant proof is the rest of the graph.
    } else {
        test_step.dependOn(&run_shader_module.step);
    }

    const reference_module = b.createModule(.{ .root_source_file = b.path("test/spirv_frontend_reference.zig"), .target = b.graph.host, .optimize = .Debug });
    reference_module.addImport("frontend", b.createModule(.{ .root_source_file = b.path("src/vulkan/spirv_frontend.zig"), .target = b.graph.host, .optimize = .Debug }));
    const spirv_reference_tests = b.addTest(.{ .root_module = reference_module });
    const run_spirv_reference = b.addRunArtifact(spirv_reference_tests);
    run_spirv_reference.step.dependOn(&require_limited.step);
    test_step.dependOn(&run_spirv_reference.step);

    const fuzz_module = b.createModule(.{ .root_source_file = b.path("test/spirv_frontend_fuzz.zig"), .target = b.graph.host, .optimize = .Debug });
    fuzz_module.addImport("frontend", b.createModule(.{ .root_source_file = b.path("src/vulkan/spirv_frontend.zig"), .target = b.graph.host, .optimize = .Debug }));
    const spirv_fuzz_tests = b.addTest(.{ .root_module = fuzz_module });
    const run_spirv_fuzz = b.addRunArtifact(spirv_fuzz_tests);
    run_spirv_fuzz.step.dependOn(&require_limited.step);
    test_step.dependOn(&run_spirv_fuzz.step);

    const behavior_module = b.createModule(.{
        .root_source_file = b.path("src/vulkan/driver.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    behavior_module.link_libc = true;
    behavior_module.linkSystemLibrary("xcb", .{});
    const behavior_tests = b.addTest(.{
        .root_module = behavior_module,
    });
    // Zig 0.16's server-mode test runner can terminate this large direct
    // driver test binary before the parent sends its first protocol frame.
    // Execute the compiled test artifact directly so the behavior gate uses
    // the same exit-code path as the limited-CPU standalone test command.
    const run_behavior = b.addSystemCommand(&.{ "sh", "-c", "exec \"$1\"", "zpu-behavior" });
    run_behavior.addArtifactArg(behavior_tests);
    run_behavior.step.dependOn(&require_limited.step);
    const behavior_step = b.step("behavior", "Require every instrumented ICD behavioral requirement");
    behavior_step.dependOn(&run_behavior.step);

    const coverage_module = b.createModule(.{
        .root_source_file = b.path("src/vulkan/driver.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    coverage_module.link_libc = true;
    coverage_module.linkSystemLibrary("xcb", .{});
    const coverage_tests = b.addTest(.{
        .name = "zpu-icd-coverage-tests",
        .root_module = coverage_module,
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

    const spirv_coverage_tests = b.addTest(.{
        .name = "zpu-spirv-coverage-tests",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/vulkan/spirv.zig"), .target = b.graph.host, .optimize = .Debug }),
        .use_llvm = true,
    });
    const spirv_path = b.pathFromRoot("src/vulkan/spirv.zig");
    const collect_spirv_coverage = b.addSystemCommand(&.{ "kcov", "--clean", b.fmt("--include-path={s}", .{spirv_path}) });
    collect_spirv_coverage.step.dependOn(&require_limited.step);
    const spirv_coverage_output = collect_spirv_coverage.addOutputDirectoryArg("spirv-coverage");
    collect_spirv_coverage.addArtifactArg(spirv_coverage_tests);
    const verify_spirv_coverage = b.addRunArtifact(coverage_verifier);
    verify_spirv_coverage.addDirectoryArg(spirv_coverage_output);
    verify_spirv_coverage.addArg("/src/vulkan/spirv.zig");
    coverage_step.dependOn(&verify_spirv_coverage.step);

    inline for (.{
        .{ "spirv-decode", "src/vulkan/spirv_decode.zig" },
        .{ "spirv-frontend", "src/vulkan/spirv_frontend.zig" },
        .{ "render-ir", "src/vulkan/render_ir.zig" },
        .{ "render-ir-exec", "src/vulkan/render_ir_exec.zig" },
    }) |source| {
        const source_tests = b.addTest(.{
            .name = "zpu-" ++ source[0] ++ "-coverage-tests",
            .root_module = b.createModule(.{ .root_source_file = b.path(source[1]), .target = b.graph.host, .optimize = .Debug }),
            .use_llvm = true,
        });
        const source_path = b.pathFromRoot(source[1]);
        const collect_source = b.addSystemCommand(&.{ "kcov", "--clean", b.fmt("--include-path={s}", .{source_path}) });
        collect_source.step.dependOn(&require_limited.step);
        const source_output = collect_source.addOutputDirectoryArg(source[0] ++ "-coverage");
        collect_source.addArtifactArg(source_tests);
        const verify_source = b.addRunArtifact(coverage_verifier);
        verify_source.addDirectoryArg(source_output);
        verify_source.addArg("/" ++ source[1]);
        coverage_step.dependOn(&verify_source.step);
    }

    const benchmark_coverage_tests = b.addTest(.{
        .name = "zpu-benchmark-coverage-tests",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_main.zig"), .target = b.graph.host, .optimize = .Debug }),
        .use_llvm = true,
    });
    benchmark_coverage_tests.root_module.addImport("zpu_config", build_config_module);
    if (v3_kernels_host) |k| benchmark_coverage_tests.root_module.linkLibrary(k);
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
    benchmark_coverage_exe.root_module.addImport("zpu_config", build_config_module);
    if (v3_kernels_host) |k| benchmark_coverage_exe.root_module.linkLibrary(k);
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

    const benchmark_3d_coverage_tests = b.addTest(.{
        .name = "zpu-benchmark-3d-coverage-tests",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark_3d.zig"), .target = b.graph.host, .optimize = .Debug }),
        .use_llvm = true,
    });
    benchmark_3d_coverage_tests.root_module.link_libc = true;
    const benchmark_3d_path = b.pathFromRoot("src/benchmark_3d.zig");
    const collect_benchmark_3d_coverage = b.addSystemCommand(&.{ "kcov", "--clean", b.fmt("--include-path={s}", .{benchmark_3d_path}) });
    collect_benchmark_3d_coverage.step.dependOn(&require_limited.step);
    const benchmark_3d_coverage_output = collect_benchmark_3d_coverage.addOutputDirectoryArg("benchmark-3d-coverage");
    collect_benchmark_3d_coverage.addArtifactArg(benchmark_3d_coverage_tests);
    const verify_benchmark_3d_coverage = b.addRunArtifact(coverage_verifier);
    verify_benchmark_3d_coverage.addDirectoryArg(benchmark_3d_coverage_output);
    verify_benchmark_3d_coverage.addArg("/src/benchmark_3d.zig");
    coverage_step.dependOn(&verify_benchmark_3d_coverage.step);

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
    run_transfer.setEnvironmentVariable("VK_ICD_FILENAMES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_transfer.step.dependOn(b.getInstallStep());
    const transfer_step = b.step("transfer", "Run exact 240x240 transfers through the system Vulkan loader");
    transfer_step.dependOn(&run_transfer.step);

    const headless_present_client = b.addExecutable(.{
        .name = "zpu-headless-present",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    headless_present_client.root_module.addCSourceFile(.{ .file = b.path("test/headless_present.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    headless_present_client.root_module.link_libc = true;
    headless_present_client.root_module.linkSystemLibrary("vulkan", .{});
    const run_headless_present = b.addRunArtifact(headless_present_client);
    run_headless_present.step.dependOn(&require_limited.step);
    run_headless_present.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_headless_present.setEnvironmentVariable("VK_ICD_FILENAMES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_headless_present.step.dependOn(b.getInstallStep());
    const headless_present_step = b.step("headless-present", "Run VK_EXT_headless_surface through the system Vulkan loader");
    headless_present_step.dependOn(&run_headless_present.step);

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
    run_xcb_present.setEnvironmentVariable("VK_ICD_FILENAMES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
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
    run_desktop_probe.setEnvironmentVariable("VK_ICD_FILENAMES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    run_desktop_probe.step.dependOn(b.getInstallStep());
    const desktop_probe_step = b.step("desktop-probe", "Report Vulkan window-system and rendering readiness without requiring success");
    desktop_probe_step.dependOn(&run_desktop_probe.step);

    const require_desktop_ready = b.addRunArtifact(desktop_probe);
    require_desktop_ready.addArg("--require-ready");
    require_desktop_ready.step.dependOn(&require_limited.step);
    require_desktop_ready.setEnvironmentVariable("VK_DRIVER_FILES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
    require_desktop_ready.setEnvironmentVariable("VK_ICD_FILENAMES", b.getInstallPath(.prefix, "share/vulkan/icd.d/zpu_icd.x86_64.json"));
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

    const pr_readiness_command = b.addSystemCommand(&.{"tools/pr_readiness.sh"});
    pr_readiness_command.step.dependOn(&require_limited.step);
    const pr_readiness_step = b.step("pr-readiness", "Validate fresh complete benchmark, screenshot, and video evidence");
    pr_readiness_step.dependOn(&pr_readiness_command.step);

    const isa_gate = b.addSystemCommand(&.{ "bash", "tools/isa_disasm_gate.sh", "check" });
    if (target.result.cpu.arch == .x86_64) {
        const baseline_pinned = target.result.cpu.model == &std.Target.x86.cpu.x86_64;
        var gated_files: usize = 0;
        // Linkage consistency: the ICD never links kernels, whatever the tier.
        isa_gate.addArg("--no-kernel-symbols");
        if (enable_xcb) {
            isa_gate.addArtifactArg(icd);
            isa_gate.addArtifactArg(icd_clean);
            gated_files += 2;
        }
        if (baseline_pinned) {
            // Default tier: strongest contract. ReleaseFast kernel-free twins
            // and the default-tree artifacts must contain zero VEX inside
            // project functions; demo/benchmark additionally carry genuinely
            // vectorized kernel exports when the v3 tier applies.
            if (enable_xcb) {
                isa_gate.addArg("--clean");
                isa_gate.addArtifactArg(icd_clean);
                isa_gate.addArtifactArg(demo_clean);
                gated_files += 2;
            }
            isa_gate.addArg("--clean");
            isa_gate.addArtifactArg(benchmark_clean);
            gated_files += 1;
            if (v3_available) {
                isa_gate.addArg("--kernelized");
                gated_files += 1;
                isa_gate.addArtifactArg(demo);
                isa_gate.addArtifactArg(benchmark);
                if (v3_kernels_main) |k| {
                    isa_gate.addArtifactArg(k);
                    gated_files += 1;
                }
            } else {
                isa_gate.addArg("--no-kernel-symbols");
                gated_files += 1;
                isa_gate.addArtifactArg(demo);
                isa_gate.addArtifactArg(benchmark);
                gated_files += 1;
            }
        } else if (v3_available) {
            // Explicit -Dcpu opt-in: portable-tier VEX is the user's choice,
            // but the eight-lane exports must be linked and vectorized.
            isa_gate.addArg("--kernels-linked");
            gated_files += 1;
            isa_gate.addArtifactArg(demo);
            isa_gate.addArtifactArg(benchmark);
            if (v3_kernels_main) |k| {
                isa_gate.addArtifactArg(k);
                gated_files += 1;
            }
        }
        if (gated_files == 0) {
            // No artifacts to scan: run the gate's first-class skip path so
            // the step still exercises the tool deterministically and exits 0.
            const skip_reason = b.fmt("no scannable artifacts for cpu={s} -Dxcb={} -Dv3-kernels={}", .{ @tagName(target.result.cpu.arch), enable_xcb, v3_kernels_enabled });
            isa_gate.argv.clearRetainingCapacity();
            isa_gate.addArg(b.pathFromRoot("tools/isa_disasm_gate.sh"));
            isa_gate.addArg("skip");
            isa_gate.addArg(skip_reason);
        }
    } else {
        isa_gate.argv.clearRetainingCapacity();
        isa_gate.addArg(b.pathFromRoot("tools/isa_disasm_gate.sh"));
        isa_gate.addArg("skip");
        isa_gate.addArg(b.fmt("ISA tier evidence is x86-specific; target arch is {s}", .{@tagName(target.result.cpu.arch)}));
    }
    isa_gate.step.dependOn(&require_limited.step);

    const isa_selftest = b.addSystemCommand(&.{ "bash", "tools/isa_gate_selftest.sh" });
    isa_selftest.step.dependOn(&require_limited.step);

    const isa_wiring_regression = b.addSystemCommand(&.{ "bash", "tools/isa_gate_wiring_regression.sh" });
    isa_wiring_regression.step.dependOn(&require_limited.step);

    const isa_gate_step = b.step("isa-gate", "Require baseline artifacts free of VEX instructions with a vectorized kernel positive control");
    isa_gate_step.dependOn(&isa_gate.step);
    isa_gate_step.dependOn(&isa_selftest.step);
    isa_gate_step.dependOn(&isa_wiring_regression.step);
    test_step.dependOn(&isa_gate.step);
    if (v3_kernels_main) |k| {
        const kernel_guard_regression = b.addSystemCommand(&.{ "bash", "tools/kernel_guard_regression.sh" });
        kernel_guard_regression.addArtifactArg(k);
        kernel_guard_regression.step.dependOn(&require_limited.step);
        isa_gate_step.dependOn(&kernel_guard_regression.step);
        test_step.dependOn(&kernel_guard_regression.step);
    }
    test_step.dependOn(&isa_selftest.step);
    test_step.dependOn(&isa_wiring_regression.step);
    const isa_cross = b.addSystemCommand(&.{ "bash", "tools/isa_cross_target_gate.sh" });
    isa_cross.step.dependOn(&require_limited.step);
    const isa_cross_step = b.step("isa-cross", "Collect cross-target codegen evidence for the pinned ISA tiers");
    isa_cross_step.dependOn(&isa_cross.step);

    // Deterministic install path for the kernel archive (used by
    // tools/isa_cross_target_gate.sh); hard-fails when the tier is absent.
    const install_v3_step = b.step("install-v3-archive", "Install the x86-64-v3 eight-lane kernel archive");
    if (v3_kernels_main) |k| {
        const install_archive = b.addInstallArtifact(k, .{
            .dest_dir = .{ .override = .{ .custom = "isa" } },
            .dest_sub_path = "libzpu-x86-64-v3-kernels.a",
        });
        install_v3_step.dependOn(&install_archive.step);
    } else {
        const unavailable = b.addFail("install-v3-archive requires the x86-64-v3 tier (x86_64 target and -Dv3-kernels=true)");
        install_v3_step.dependOn(&unavailable.step);
    }
}

/// Builds the eight-lane kernel objects as their own static library compiled
/// with an explicit x86_64_v3 CPU model on the consumer's OS/ABI, or returns
/// null when the tier does not apply to that target's architecture. Baseline
/// artifact codegen never sees this source, so AVX2 instructions can only
/// exist inside these linked-in kernel objects.
///
/// The kernels are always ReleaseFast: they are hot loops, and Debug-mode
/// safety plumbing would otherwise drag std.debug machinery into the v3 tier.
fn addV3Kernels(b: *std.Build, resolved: std.Build.ResolvedTarget, name: []const u8) ?*std.Build.Step.Compile {
    if (resolved.result.cpu.arch != .x86_64) return null;
    var query = resolved.query;
    query.cpu_arch = .x86_64;
    query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
    query.cpu_features_add = .empty;
    query.cpu_features_sub = .empty;
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/x86_64_v3_kernels.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = .ReleaseFast,
        }),
    });
}
