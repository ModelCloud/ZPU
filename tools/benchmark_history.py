#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

"""Append validated benchmark JSON to the repository's append-only history."""
import argparse
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

OPS = ["clear", "pixel_write", "clipped_rectangle", "vulkan_host_memory_fill", "vulkan_host_memory_copy", "source_over_blend", "sprite_draw", "frame"]
RASTER = ["clear", "pixel_write", "clipped_rectangle", "source_over_blend", "sprite_draw", "frame"]
ORACLES = {
    "clear": "89fcf336d86c4f25", "pixel_write": "3d0737332ec9e1cc",
    "clipped_rectangle": "2cf726772c9ab549", "vulkan_host_memory_fill": "50dbc316a6090325",
    "vulkan_host_memory_copy": "4e61ac2d0cc0777b", "source_over_blend": "d5f99fe5b4e7eef8",
    "sprite_draw": "e73fc1dc4f99be0c", "frame": "2e480a89ab6181ef",
}
LEGACY_ORACLES = ["89fcf336d86c4f25", "3d0737332ec9e1cc", "b5cb439ce748a598", "50dbc316a6090325", "4e61ac2d0cc0777b", "d5f99fe5b4e7eef8", "3717a00e187d9381", "2e480a89ab6181ef"]

def fail(message):
    raise SystemExit(f"history refusal: {message}")

def git(*args):
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()

def cpu_list(text):
    out = []
    for part in text.replace(" ", "").split(","):
        if not part:
            fail("malformed affinity list")
        if "-" in part:
            a, b = part.split("-", 1)
            try: a, b = int(a), int(b)
            except ValueError: fail("malformed affinity list")
            if b < a: fail("malformed affinity list")
            out.extend(range(a, b + 1))
        else:
            try: out.append(int(part))
            except ValueError: fail("malformed affinity list")
    if len(set(out)) != len(out) or not out or len(out) > 8:
        fail("affinity is not <=8 unique CPUs")
    return out

def trusted_fingerprint(fp):
    if fp.get("limited_gate") != "physical-core-v1": fail("missing limited-core gate marker")
    cpus = cpu_list(fp.get("selected_cpus", ""))
    if int(fp.get("max_threads", 0)) != len(cpus): fail("thread cap is not derived from selected affinity")
    try:
        actual = sorted(os.sched_getaffinity(0))
    except AttributeError:
        fail("Linux affinity unavailable")
    if actual != sorted(cpus): fail("fingerprint affinity is not trusted process affinity")
    model = ""
    for line in Path("/proc/cpuinfo").read_text().splitlines():
        if line.startswith("model name") or line.startswith("Hardware"):
            model = line.split(":", 1)[1].strip(); break
    if not model or fp.get("cpu_model") != model: fail("CPU model fingerprint is not trusted")
    topo = []
    for cpu in cpus:
        base = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
        try:
            package = (base / "physical_package_id").read_text().strip()
            core = (base / "core_id").read_text().strip()
        except OSError:
            fail("topology fingerprint unavailable")
        topo.append(f"{package}:{core}@{cpu}")
    if fp.get("topology") != ";".join(topo): fail("topology fingerprint is not trusted")

def validate_report(report):
    if report.get("schema_version") != 4 or report.get("workload_id") != "zpu-2d-kernels-v4-240x240-seed-151521030":
        fail("schema/workload mismatch")
    if report.get("rate_tolerance_fraction") != 0.20 or report.get("latency_tolerance_fraction") != 1.50:
        fail("tolerance policy mismatch")
    if not re.fullmatch(r"[0-9a-f]{40}", report.get("source_commit", "")) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", report.get("utc", "")):
        fail("source commit/UTC binding missing")
    fp = report.get("fingerprint")
    if not isinstance(fp, dict): fail("missing fingerprint")
    trusted_fingerprint(fp)
    pipeline = report.get("pipeline", {})
    if not isinstance(pipeline, dict) or not all(isinstance(pipeline.get(k), int) and not isinstance(pipeline.get(k), bool) and pipeline[k] > 0 for k in ("iterations", "key_construction_ns", "cache_lookup_ns", "cache_hits", "cache_misses")):
        fail("invalid pipeline benchmark")
    if pipeline["cache_hits"] != pipeline["iterations"] or pipeline["cache_misses"] != 1:
        fail("cache lifecycle counters mismatch")
    if not isinstance(pipeline.get("cache_hit_rate"), (int, float)) or not math.isfinite(pipeline["cache_hit_rate"]) or not 0 < pipeline["cache_hit_rate"] < 1:
        fail("invalid cache hit rate")
    metrics = report.get("metrics")
    if not isinstance(metrics, list) or not metrics: fail("missing metrics")
    has_avx2 = any(m.get("backend") == "avx2" for m in metrics)
    expected = [(op, "scalar") for op in OPS]
    expected += [(op, "portable_vector") for op in RASTER]
    if has_avx2: expected += [(op, "avx2") for op in RASTER]
    expected += [(op, "runtime") for op in RASTER]
    seen = set()
    for i, (m, key) in enumerate(zip(metrics, expected)):
        if not isinstance(m, dict) or (m.get("name"), m.get("backend")) != key:
            fail("metric set/order mismatch")
        if key in seen: fail("duplicate metric key")
        seen.add(key)
        if m.get("checksum_hex") != ORACLES[key[0]] or int(m.get("checksum", -1)) != int(ORACLES[key[0]], 16):
            fail(f"oracle mismatch for {key[0]}/{key[1]}")
        for field in ("mpix_s", "bytes_s", "effective_gib_s", "draws_s", "fps"):
            value = m.get(field)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                fail(f"invalid {field}")
        if key[0] in ("sprite_draw", "frame") and m["mpix_s"] != 0: fail("inapplicable MPix metric is nonzero")
        if key[0] == "sprite_draw" and m["draws_s"] <= 0: fail("sprite draws/s is zero")
        if key[0] != "sprite_draw" and m["draws_s"] != 0: fail("inapplicable draws/s is nonzero")
        if key[0] == "frame" and m["fps"] <= 0: fail("frame FPS is zero")
        if key[0] != "frame" and m["fps"] != 0: fail("inapplicable FPS is nonzero")
        frame = m.get("frame", {})
        if not (frame.get("p50_ns", 0) > 0 <= frame.get("p95_ns", 0) <= frame.get("p99_ns", 0) <= frame.get("max_ns", 0)) or not isinstance(frame.get("cv"), (int, float)) or not math.isfinite(frame["cv"]) or frame["cv"] < 0:
            fail("invalid latency percentiles")
    if len(seen) != len(expected): fail("missing metrics")
    return expected

def markdown(report, source_commit, comparison, observed):
    fp = report["fingerprint"]
    lines = [
        f"### {source_commit}",
        "", "- Entry semantics: benchmarked source commit; the history append commit follows this source commit.",
        f"- UTC: {report.get('_history_utc', '')}",
        f"- Schema/workload: v{report['schema_version']} / `{report['workload_id']}`",
        f"- Zig/compiler: `{fp['compiler']}`; build mode: `{fp['build_mode']}`",
        f"- Trusted CPU: `{fp['cpu_model']}`; topology: `{fp['topology']}`; affinity: `{fp['selected_cpus']}`",
        f"- Threads: configured `{fp['max_threads']}`, observed `{observed}`",
        f"- Available backends: {', '.join(sorted({m['backend'] for m in report['metrics']}))}",
        f"- Pipeline: key construction `{report['pipeline']['key_construction_ns']} ns`; cache lookup `{report['pipeline']['cache_lookup_ns']} ns`; hits/misses `{report['pipeline']['cache_hits']}/{report['pipeline']['cache_misses']}`; hit rate `{report['pipeline']['cache_hit_rate']:.9g}`",
        f"- Baseline comparison: `{comparison}`",
        "", "| name | backend | MPix/s | bytes/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | max ns | CV | checksum_hex |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for m in report["metrics"]:
        p = m["frame"]
        lines.append(f"| {m['name']} | {m['backend']} | {m['mpix_s']:.9g} | {m['bytes_s']:.9g} | {m['effective_gib_s']:.9g} | {m['draws_s']:.9g} | {m['fps']:.9g} | {p['p50_ns']} | {p['p95_ns']} | {p['p99_ns']} | {p['max_ns']} | {p['cv']:.9g} | `{m['checksum_hex']}` |")
    return "\n".join(lines) + "\n"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("json_path", nargs="?")
    parser.add_argument("history_path", nargs="?")
    parser.add_argument("--commit")
    parser.add_argument("--comparison-result", default="not-run")
    parser.add_argument("--observed-threads", type=int)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--validate-history", action="store_true")
    args = parser.parse_args()
    if args.validate_history:
        if not args.history_path: fail("history path required")
        text = Path(args.history_path).read_text()
        commits = re.findall(r"^### ([0-9a-f]{40})$", text, re.MULTILINE)
        if len(commits) != len(set(commits)): fail("duplicate history commit")
        for commit in commits:
            try: git("cat-file", "-e", f"{commit}^{{commit}}")
            except subprocess.CalledProcessError: fail(f"history commit is not present: {commit}")
            block = text.split(f"### {commit}", 1)[1].split("\n### ", 1)[0]
            for required in ("Entry semantics:", "- UTC:", "Schema/workload:", "Zig/compiler:", "Trusted CPU:", "Threads:", "Available backends:", "Baseline comparison:", "| name | backend |"):
                if required not in block: fail(f"history entry {commit} is missing {required}")
            expected_oracles = LEGACY_ORACLES if "Schema/workload: v2 / `zpu-2d-v2-240x240-seed-151521030`" in block else ORACLES.values()
            for checksum_hex in expected_oracles:
                if f"`{checksum_hex}`" not in block: fail(f"history entry {commit} is missing checksum {checksum_hex}")
        return
    if not args.json_path or not args.history_path or not args.commit or args.observed_threads is None: fail("JSON, history, --commit, and --observed-threads are required")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit): fail("commit must be a full 40-character SHA")
    try: head = git("rev-parse", "HEAD")
    except subprocess.CalledProcessError: fail("not a git worktree")
    if head != args.commit: fail("commit does not match HEAD")
    if not args.validate_only:
        if git("status", "--porcelain"): fail("worktree is dirty")
    try: report = json.loads(Path(args.json_path).read_text())
    except (OSError, json.JSONDecodeError) as exc: fail(f"malformed JSON: {exc}")
    validate_report(report)
    if report.get("source_commit") != args.commit: fail("report source commit mismatch")
    if args.observed_threads < 1 or args.observed_threads > 8: fail("observed threads outside 1..8")
    history = Path(args.history_path)
    existing = history.read_text() if history.exists() else ""
    if re.search(rf"^### {re.escape(args.commit)}$", existing, re.MULTILINE): fail("duplicate commit entry")
    if args.validate_only:
        return
    from datetime import datetime, timezone
    report["_history_utc"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    with history.open("a", encoding="utf-8") as out:
        if existing and not existing.endswith("\n\n"): out.write("\n")
        out.write(markdown(report, args.commit, args.comparison_result, args.observed_threads))

if __name__ == "__main__":
    main()
