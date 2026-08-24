#!/usr/bin/env python3
"""Validate truthful 120 Hz synthetic-Xvfb capture cadence."""
import argparse
import hashlib
import json
import math
import os
import statistics
import subprocess
from pathlib import Path

HZ = 120
DURATION_SECONDS = 20
EXPECTED_FRAMES = HZ * DURATION_SECONDS
PERIOD = 1.0 / HZ

def fail(message):
    raise SystemExit(f"cadence refusal: {message}")

def percentile(values, fraction):
    ordered = sorted(values)
    rank = fraction * (len(ordered) - 1)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (rank - lower)

def metrics(pts, hashes):
    if len(pts) != len(hashes) or len(pts) < 2:
        fail("PTS/hash sample counts differ or are too small")
    if any(b <= a for a, b in zip(pts, pts[1:])):
        fail("packet PTS are not strictly monotonic")
    intervals = [b - a for a, b in zip(pts, pts[1:])]
    mean = statistics.fmean(intervals)
    duplicates = sum(a == b for a, b in zip(hashes, hashes[1:]))
    missed = sum(max(0, round(value / PERIOD) - 1) for value in intervals)
    duration = pts[-1] - pts[0] + PERIOD
    visible = (len(hashes) - duplicates) / duration
    return {
        "packets": len(pts), "duration_s": duration, "visible_fps": visible, "mean_ms": mean * 1000,
        "p50_ms": percentile(intervals, .50) * 1000,
        "p95_ms": percentile(intervals, .95) * 1000,
        "p99_ms": percentile(intervals, .99) * 1000,
        "p999_ms": percentile(intervals, .999) * 1000,
        "worst_ms": max(intervals) * 1000,
        "interval_cv": statistics.pstdev(intervals) / mean,
        "missed_deadlines": missed,
        "missed_deadline_pct": 100 * missed / len(intervals),
        "consecutive_duplicates": duplicates,
        "consecutive_duplicate_pct": 100 * duplicates / len(intervals),
        "monotonic_pts": True, "capture_drops": max(0, EXPECTED_FRAMES - len(pts)),
    }

def command_output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def analyze(video):
    probe = json.loads(command_output("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(video)))
    pts = [float(frame["best_effort_timestamp_time"]) for frame in probe.get("frames", [])]
    md5 = command_output("ffmpeg", "-v", "error", "-i", str(video), "-fps_mode", "passthrough", "-f", "framemd5", "-")
    hashes = [line.rsplit(",", 1)[-1].strip() for line in md5.splitlines() if line and not line.startswith("#")]
    return metrics(pts, hashes)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", required=True)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--source-commit")
    parser.add_argument("--utc")
    parser.add_argument("--affinity")
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    video = Path(args.video)
    if not video.is_file() or video.stat().st_size == 0:
        fail("lossless capture missing or empty")
    metrics_data = analyze(video)
    if args.validate:
        saved = json.loads(Path(args.metadata).read_text())
        for key, value in metrics_data.items():
            if isinstance(value, float):
                if not math.isclose(saved.get(key, math.nan), value, rel_tol=0, abs_tol=1e-9): fail(f"stale cadence metric: {key}")
            elif saved.get(key) != value: fail(f"stale cadence metric: {key}")
        if saved.get("sha256") != hashlib.sha256(video.read_bytes()).hexdigest(): fail("capture hash mismatch")
        if saved.get("evidence_kind") != "synthetic-xvfb-pacing" or saved.get("physical_scanout") is not False: fail("Xvfb evidence classification missing")
        if not saved.get("affinity", "").startswith("cpu=") or len(saved.get("source_commit", "")) != 40: fail("affinity/commit binding missing")
        gates = {"packets": saved["packets"] == EXPECTED_FRAMES,
                 "visible_fps": 119.0 <= saved["visible_fps"] <= 121.0,
                 "mean_ms": abs(saved["mean_ms"] - 1000 / HZ) <= .05,
                 "p95_ms": saved["p95_ms"] <= 8.50, "p99_ms": saved["p99_ms"] <= 8.75,
                 "p999_ms": saved["p999_ms"] <= 9.0, "worst_ms": saved["worst_ms"] <= 10.0,
                 "interval_cv": saved["interval_cv"] <= .010, "missed_deadline_pct": saved["missed_deadline_pct"] <= 1,
                 "consecutive_duplicate_pct": saved["consecutive_duplicate_pct"] <= 1,
                 "capture_drops": saved["capture_drops"] == 0, "monotonic_pts": saved["monotonic_pts"] is True}
        print(json.dumps({"gates": gates, "metrics": metrics_data}, sort_keys=True))
        if not all(gates.values()): fail("one or more 120 Hz acceptance gates failed")
        return
    if not all((args.source_commit, args.utc, args.affinity)): fail("creation requires source commit, UTC, and affinity")
    result = dict(metrics_data)
    result.update({
        "schema_version": 1, "evidence_kind": "synthetic-xvfb-pacing",
        "physical_scanout": False, "source_commit": args.source_commit,
        "utc": args.utc, "affinity": args.affinity, "capture": str(video),
        "codec": "rawvideo", "resolution": "800x600", "nominal_hz": HZ,
        "size_bytes": video.stat().st_size,
        "sha256": hashlib.sha256(video.read_bytes()).hexdigest(),
    })
    Path(args.metadata).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(metrics_data, sort_keys=True))
    if result["packets"] != EXPECTED_FRAMES or result["capture_drops"] != 0:
        fail(f"capture must contain exactly {EXPECTED_FRAMES} lossless packets with zero drops")

if __name__ == "__main__":
    main()
