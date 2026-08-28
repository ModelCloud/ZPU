#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

import math
import os
import pathlib
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile

WARMUP_FRAMES = 120
SAMPLE_FRAMES = 1000


def percentile(values: list[int], percent: int) -> int:
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * percent / 100) - 1]


def main() -> int:
    if len(sys.argv) not in (5, 6):
        raise SystemExit(f"usage: {sys.argv[0]} <installed-icd-manifest> <width> <height> <target-hz> [pacing-hz]")
    manifest = pathlib.Path(sys.argv[1])
    try:
        width, height, target_fps = map(int, sys.argv[2:5])
        pacing_fps = int(sys.argv[5]) if len(sys.argv) == 6 else target_fps
    except ValueError as error:
        raise SystemExit(f"width, height, and target Hz must be integers: {error}")
    if not (1 <= width <= 8192 and 1 <= height <= 8192 and 1 <= target_fps <= pacing_fps <= 1000):
        raise SystemExit("width/height must be 1..8192 and target Hz must be 1..pacing Hz..1000")
    frame_budget_ns = 1_000_000_000 // target_fps
    if not manifest.is_file():
        raise SystemExit(f"ZPU ICD manifest not found: {manifest}")
    for program in ("taskset", "timeout", "Xvfb", "xvfb-run", "vkcube"):
        if shutil.which(program) is None:
            raise SystemExit(f"required program not found: {program}")

    allowed_cpus = sorted(os.sched_getaffinity(0))
    isolate_xvfb = len(allowed_cpus) >= 8
    client_cpus = allowed_cpus[:-1] if isolate_xvfb else allowed_cpus
    xvfb_cpu = allowed_cpus[-1] if isolate_xvfb else None
    requested_client_cpus = os.environ.get("ZPU_BENCH_CLIENT_CPUS")
    if requested_client_cpus:
        try:
            requested = [int(cpu) for cpu in requested_client_cpus.split(",")]
        except ValueError as error:
            raise SystemExit(f"ZPU_BENCH_CLIENT_CPUS must be a comma-separated CPU list: {error}")
        if not requested or len(set(requested)) != len(requested) or any(cpu not in client_cpus for cpu in requested):
            raise SystemExit("ZPU_BENCH_CLIENT_CPUS must be a unique, non-empty subset of the client affinity")
        client_cpus = requested

    presented_frames = WARMUP_FRAMES + SAMPLE_FRAMES + 1
    command = [
        "timeout", "180s", "xvfb-run", "-a", "-s",
        f"-screen 0 {width}x{height}x24 -nolisten tcp -fakescreenfps 240",
        "taskset", "-c", ",".join(map(str, client_cpus)),
        "vkcube", "--c", str(presented_frames),
        "--width", str(width), "--height", str(height), "--suppress_popups",
    ]
    with tempfile.TemporaryDirectory(prefix="zpu-vkcube-") as temporary_directory:
        metrics_path = pathlib.Path(temporary_directory) / "frame-metrics.bin"
        environment = os.environ.copy()
        environment["VK_DRIVER_FILES"] = str(manifest)
        environment["VK_ICD_FILENAMES"] = str(manifest)
        environment["ZPU_FRAME_METRICS"] = "1"
        environment["ZPU_FRAME_METRICS_COUNT"] = str(WARMUP_FRAMES + SAMPLE_FRAMES)
        environment["ZPU_FRAME_METRICS_PATH"] = str(metrics_path)
        environment["ZPU_REFRESH_HZ"] = str(pacing_fps)
        if xvfb_cpu is not None:
            wrapper = pathlib.Path(temporary_directory) / "Xvfb"
            wrapper.write_text(
                "#!/bin/sh\nexec "
                + shlex.quote(shutil.which("taskset"))
                + " -c "
                + str(xvfb_cpu)
                + " "
                + shlex.quote(shutil.which("Xvfb"))
                + " \"$@\"\n"
            )
            wrapper.chmod(0o700)
            environment["PATH"] = temporary_directory + os.pathsep + environment["PATH"]
        result = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=190)
        metric_bytes = metrics_path.read_bytes() if metrics_path.is_file() else b""
    if result.returncode != 0:
        sys.stdout.write(result.stdout[-8000:])
        raise SystemExit(f"vkcube benchmark failed with status {result.returncode}")

    if len(metric_bytes) % 8 != 0:
        raise SystemExit(f"frame timing file has invalid size {len(metric_bytes)}")
    timings = list(struct.unpack(f"={len(metric_bytes) // 8}Q", metric_bytes))
    if len(timings) != WARMUP_FRAMES + SAMPLE_FRAMES:
        raise SystemExit(f"expected {WARMUP_FRAMES + SAMPLE_FRAMES} frame timings, got {len(timings)}")
    samples = timings[WARMUP_FRAMES:]
    p50_ns = percentile(samples, 50)
    p95_ns = percentile(samples, 95)
    p99_ns = percentile(samples, 99)
    median_fps = 1_000_000_000 / p50_ns
    one_percent_low_fps = 1_000_000_000 / p99_ns
    print(f"ZPU vkcube {width}x{height} target={target_fps} pacing={pacing_fps} Hz: median={median_fps:.1f} FPS, "
          f"1%-low={one_percent_low_fps:.1f} FPS, "
          f"p50/p95/p99={p50_ns}/{p95_ns}/{p99_ns} ns, budget={frame_budget_ns} ns")
    if p99_ns > frame_budget_ns:
        raise SystemExit(f"vkcube {width}x{height} target={target_fps} pacing={pacing_fps} Hz p99 frame-time target missed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
