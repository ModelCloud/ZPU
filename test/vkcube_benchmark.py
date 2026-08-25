#!/usr/bin/env python3
import math
import os
import pathlib
import re
import shutil
import subprocess
import sys

WIDTH = 800
HEIGHT = 600
WARMUP_FRAMES = 120
SAMPLE_FRAMES = 1000
TARGET_FPS = 240
FRAME_BUDGET_NS = 1_000_000_000 // TARGET_FPS


def percentile(values: list[int], percent: int) -> int:
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * percent / 100) - 1]


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <installed-icd-manifest>")
    manifest = pathlib.Path(sys.argv[1])
    if not manifest.is_file():
        raise SystemExit(f"ZPU ICD manifest not found: {manifest}")
    for program in ("timeout", "xvfb-run", "vkcube"):
        if shutil.which(program) is None:
            raise SystemExit(f"required program not found: {program}")

    presented_frames = WARMUP_FRAMES + SAMPLE_FRAMES + 1
    command = [
        "timeout", "180s", "xvfb-run", "-a", "-s",
        f"-screen 0 {WIDTH}x{HEIGHT}x24 -nolisten tcp",
        "vkcube", "--wsi", "xcb", "--c", str(presented_frames),
        "--width", str(WIDTH), "--height", str(HEIGHT), "--suppress_popups",
    ]
    environment = os.environ.copy()
    environment["VK_DRIVER_FILES"] = str(manifest)
    environment["ZPU_FRAME_METRICS"] = "1"
    environment["ZPU_REFRESH_HZ"] = str(TARGET_FPS)
    result = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=190)
    if result.returncode != 0:
        sys.stdout.write(result.stdout[-8000:])
        raise SystemExit(f"vkcube benchmark failed with status {result.returncode}")

    timings = [int(value) for value in re.findall(r"^zpu_vkcube_frame_ns=(\d+)$", result.stdout, re.MULTILINE)]
    if len(timings) != WARMUP_FRAMES + SAMPLE_FRAMES:
        raise SystemExit(f"expected {WARMUP_FRAMES + SAMPLE_FRAMES} frame timings, got {len(timings)}")
    samples = timings[WARMUP_FRAMES:]
    p50_ns = percentile(samples, 50)
    p95_ns = percentile(samples, 95)
    p99_ns = percentile(samples, 99)
    median_fps = 1_000_000_000 / p50_ns
    one_percent_low_fps = 1_000_000_000 / p99_ns
    print(f"ZPU vkcube {WIDTH}x{HEIGHT}: median={median_fps:.1f} FPS, "
          f"1%-low={one_percent_low_fps:.1f} FPS, "
          f"p50/p95/p99={p50_ns}/{p95_ns}/{p99_ns} ns, budget={FRAME_BUDGET_NS} ns")
    if p99_ns > FRAME_BUDGET_NS:
        raise SystemExit("vkcube 800x600 p99 frame-time target missed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
