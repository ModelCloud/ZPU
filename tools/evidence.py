#!/usr/bin/env python3
"""Generate and validate ZPU PR evidence. Generated media and JSON stay ignored."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ORACLE_3D = "b63a7b2fb2f50601"
COUNTERS = {
    "triangles_submitted": 12, "triangles_rasterized": 12,
    "fragments_tested": 124360, "fragments_covered": 58608,
    "depth_tests_passed": 29304, "color_writes": 29304,
}

def fail(message): raise SystemExit(f"evidence refusal: {message}")
def load(path):
    try: return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc: fail(f"malformed JSON {path}: {exc}")
def finite(value, positive=False):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and (value > 0 if positive else value >= 0)
def sha256(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for chunk in iter(lambda:f.read(1024*1024),b""): h.update(chunk)
    return h.hexdigest()
def run(*args): return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def validate_3d(report):
    if report.get("schema_version") != 1 or report.get("workload_id") != "zpu-vkcube-cpu-3d-v1-320x240-cube12": fail("3D schema/workload mismatch")
    if report.get("renderer_scope") != "existing vkcube-specific cpu_cube renderer; not general SPIR-V": fail("3D scope mismatch")
    if report.get("resolution") != "320x240" or report.get("warmup_iterations") != 5 or report.get("sample_count") != 30: fail("3D resolution/sampling mismatch")
    m=report.get("metric",{})
    if m.get("name") != "vkcube_cpu_cube" or m.get("backend") != "vkcube-specific-cpu": fail("3D metric/backend mismatch")
    if m.get("checksum_hex") != ORACLE_3D or m.get("checksum") != int(ORACLE_3D,16): fail("3D checksum mismatch")
    if m.get("counters_per_frame") != COUNTERS: fail("3D exact counters mismatch")
    if not finite(m.get("fps"),True) or not finite(m.get("triangles_s"),True): fail("3D rates invalid")
    f=m.get("frame",{}); values=[f.get(k) for k in ("p50_ns","p95_ns","p99_ns")]
    if not all(finite(v,True) for v in values) or values != sorted(values): fail("3D percentiles invalid")
    if abs(m["triangles_s"] - m["fps"]*12) > max(1e-7, m["triangles_s"]*1e-12): fail("3D triangle rate inconsistent")

def validate_2d(report):
    import sys
    sys.path.insert(0,str(ROOT/"tools"))
    import benchmark_history
    benchmark_history.validate_report(report)
    if report.get("warmup_iterations") != 1 or report.get("sample_count") != 15: fail("2D full sampling required")

def metric_rows(two, three, raw2d, raw3d, commit, utc, cadence=None, raw_cadence=None):
    rows=[]
    notes2=f"full 1 warmup/15 samples; checksum-bound; UTC {utc}"
    for m in two["metrics"]:
        common=["2D",two["workload_id"],"240x240",f"{m['name']}/{m['backend']}"]
        measures=[("MPix/s",m["mpix_s"],"MPix/s"),("bytes/s",m["bytes_s"],"bytes/s"),("modeled GiB/s",m["effective_gib_s"],"GiB/s"),("draws/s",m["draws_s"],"draws/s"),("FPS",m["fps"],"FPS"),("p50",m["frame"]["p50_ns"],"ns"),("p95",m["frame"]["p95_ns"],"ns"),("p99",m["frame"]["p99_ns"],"ns"),("checksum",m["checksum_hex"],"FNV-1a-64")]
        for measure,value,unit in measures:
            if value != 0: rows.append(common+[measure,value,unit,m["fps"] if m["fps"] else "—","1 warmup + 15 full samples",commit,utc,raw2d,notes2])
    m=three["metric"]; common=["3D",three["workload_id"],three["resolution"],f"{m['name']}/{m['backend']}"]
    measures=[("FPS",m["fps"],"FPS"),("triangles/s",m["triangles_s"],"triangles/s"),("p50",m["frame"]["p50_ns"],"ns"),("p95",m["frame"]["p95_ns"],"ns"),("p99",m["frame"]["p99_ns"],"ns"),("checksum",m["checksum_hex"],"FNV-1a-64")]+[(k,v,"count/frame") for k,v in m["counters_per_frame"].items()]
    for measure,value,unit in measures: rows.append(common+[measure,value,unit,m["fps"],"5 warmups + 30 full samples",commit,utc,raw3d,"vkcube-specific cpu_cube; not general SPIR-V"])
    if cadence:
        common=["pacing","zpu-xvfb-lossless-60hz-v1","640x480","visible-cadence/synthetic-xvfb"]
        measures=[("visible FPS",cadence["visible_fps"],"FPS"),("p50",cadence["p50_ms"],"ms"),("p95",cadence["p95_ms"],"ms"),("p99",cadence["p99_ms"],"ms"),("worst",cadence["worst_ms"],"ms"),("interval CV",cadence["interval_cv"],"ratio"),("missed deadlines",cadence["missed_deadline_pct"],"percent"),("consecutive duplicates",cadence["consecutive_duplicate_pct"],"percent"),("packets",cadence["packets"],"packets"),("capture drops",cadence["capture_drops"],"frames")]
        notes=f"synthetic Xvfb, not physical scanout; {cadence['affinity']}; monotonic PTS={cadence['monotonic_pts']}"
        for measure,value,unit in measures: rows.append(common+[measure,value,unit,cadence["visible_fps"],"900 lossless FFV1 packets / 15 s",commit,cadence["utc"],raw_cadence,notes])
    return sorted(rows,key=lambda r:(r[0],r[1],r[3],r[4]))

def fmt(value): return f"{value:.9g}" if isinstance(value,float) else str(value)
def progress_text(two,three,raw2d,raw3d,commit,utc,evidence,cadence=None,raw_cadence=None):
    rows=metric_rows(two,three,raw2d,raw3d,commit,utc,cadence,raw_cadence)
    out=["# Progress benchmarks","",f"Benchmarked source commit: `{commit}`  ","Evidence relationship: `source commit or one later progress_benchmarks.md-only commit`  ",f"UTC: `{utc}`","", "| category | workload/schema | resolution | metric/backend | measure | value | unit | FPS | sampling | commit | UTC | raw artifact | notes |", "|---|---|---|---|---|---:|---|---:|---|---|---|---|---|"]
    for r in rows: out.append("| " + " | ".join(fmt(x) for x in r) + " |")
    return "\n".join(out)+"\n"

def git_binding(source):
    if not re.fullmatch(r"[0-9a-f]{40}",source): fail("source commit is not a full SHA")
    head=run("git","rev-parse","HEAD").strip()
    try: run("git","merge-base","--is-ancestor",source,head)
    except subprocess.CalledProcessError: fail("source commit is not an ancestor of HEAD")
    distance=int(run("git","rev-list","--count",f"{source}..{head}").strip())
    if distance > 1: fail("more than one later evidence commit")
    if distance == 1:
        changed=run("git","diff","--name-only",source,head).splitlines()
        if changed != ["progress_benchmarks.md"]: fail("later commit is not evidence-only Markdown")
    return head

def progress(args):
    two,three=load(args.two_d),load(args.three_d); validate_2d(two); validate_3d(three)
    if two.get("source_commit") not in (None,args.source_commit): fail("2D source commit mismatch")
    if three.get("source_commit") != args.source_commit: fail("3D source commit mismatch")
    if three.get("utc") != args.utc: fail("3D UTC mismatch")
    evidence=args.evidence_commit or ("fixture" if args.skip_git_binding else git_binding(args.source_commit))
    cadence=load(args.cadence) if args.cadence else None
    if cadence and (cadence.get("source_commit") != args.source_commit or cadence.get("evidence_kind") != "synthetic-xvfb-pacing" or cadence.get("physical_scanout") is not False): fail("cadence source/classification mismatch")
    expected=progress_text(two,three,args.two_d,args.three_d,args.source_commit,args.utc,evidence,cadence,args.cadence)
    path=Path(args.output)
    if args.write: path.write_text(expected)
    else:
        if not path.exists() or path.read_text()!=expected: fail("progress table incomplete, stale, duplicated, misordered, or unit/checksum-invalid")

def video(args):
    video=Path(args.video); meta=load(args.metadata)
    if not video.is_file() or video.stat().st_size == 0: fail("video missing/empty")
    if meta.get("sha256") != sha256(video) or meta.get("size_bytes") != video.stat().st_size: fail("video hash/size mismatch")
    if not re.fullmatch(r"[0-9a-f]{40}",meta.get("source_commit","")) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ",meta.get("utc","")): fail("video commit/UTC metadata invalid")
    probe=json.loads(run("ffprobe","-v","error","-count_frames","-show_entries","stream=codec_name,width,height,avg_frame_rate,nb_read_frames:format=duration","-of","json",str(video)))
    streams=probe.get("streams",[])
    if len(streams)!=1: fail("video must contain exactly one stream")
    s=streams[0]
    if s.get("codec_name") != "vp9" or (s.get("width"),s.get("height")) != (640,480): fail("video codec/resolution mismatch")
    duration=float(probe["format"]["duration"]); frames=int(s.get("nb_read_frames","0")); num,den=map(int,s["avg_frame_rate"].split("/")); fps=num/den
    if not 19.0 <= duration <= 21.5 or frames <= 0 or fps <= 0: fail("video duration/FPS/frame count invalid")
    subprocess.check_call(["ffmpeg","-v","error","-i",str(video),"-f","null","-"])
    md5=run("ffmpeg","-v","error","-i",str(video),"-vf","fps=2","-f","framemd5","-")
    hashes={line.rsplit(",",1)[-1].strip() for line in md5.splitlines() if line and not line.startswith("#")}
    if len(hashes)<3: fail("video is static")
    black=run("ffmpeg","-hide_banner","-i",str(video),"-vf","blackdetect=d=18:pix_th=0.10","-an","-f","null","-")
    if re.search(r"black_duration:(?:19|20|21)(?:\.\d+)?",black): fail("video is black")
    for shot in meta.get("screenshots",[]):
        p=Path(shot["path"])
        if not p.is_file() or p.stat().st_size == 0 or sha256(p)!=shot["sha256"]: fail("screenshot missing/stale/hash mismatch")
        if (shot.get("width"),shot.get("height")) != (640,480) or shot.get("source_commit") != meta["source_commit"] or shot.get("utc") != meta["utc"] or not shot.get("capture_command"): fail("screenshot dimensions/provenance missing")
    print(json.dumps({"duration":duration,"fps":fps,"frames":frames,"codec":"vp9","width":640,"height":480,"sha256":meta["sha256"],"size_bytes":meta["size_bytes"]},sort_keys=True))

def main():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="cmd",required=True)
    q=sub.add_parser("progress"); q.add_argument("--2d",dest="two_d",required=True); q.add_argument("--3d",dest="three_d",required=True); q.add_argument("--cadence"); q.add_argument("--output",required=True); q.add_argument("--source-commit",required=True); q.add_argument("--utc",required=True); q.add_argument("--evidence-commit"); q.add_argument("--write",action="store_true"); q.add_argument("--skip-git-binding",action="store_true")
    v=sub.add_parser("video"); v.add_argument("--video",required=True); v.add_argument("--metadata",required=True)
    args=p.parse_args(); progress(args) if args.cmd=="progress" else video(args)
if __name__=="__main__": main()
