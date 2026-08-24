#!/usr/bin/env python3
"""Summarize ZPU's preallocated one-core monotonic presentation trace."""
import argparse, json, math, statistics, struct
from pathlib import Path

FIELDS = ("frame", "render_complete_ns", "deadline_ns", "wake_ns",
          "wake_error_ns", "present_start_ns", "upload_end_ns",
          "copy_start_ns", "copy_end_ns", "flush_end_ns", "frame_end_ns")
RECORD = struct.Struct("<QQQQqQQQQQQ")

def percentile(values, fraction):
    ordered = sorted(values); rank = fraction * (len(ordered) - 1)
    lo = math.floor(rank); hi = math.ceil(rank)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (rank - lo)

def distribution(values):
    mean = statistics.fmean(values)
    return {"mean_ms": mean / 1e6, "p50_ms": percentile(values,.5)/1e6,
            "p95_ms": percentile(values,.95)/1e6, "p99_ms": percentile(values,.99)/1e6,
            "p999_ms": percentile(values,.999)/1e6, "max_ms": max(values)/1e6,
            "cv": statistics.pstdev(values)/mean if mean else 0}

def main():
    p=argparse.ArgumentParser(); p.add_argument("trace"); p.add_argument("--output")
    args=p.parse_args(); data=Path(args.trace).read_bytes()
    if not data or len(data)%RECORD.size: raise SystemExit("invalid presentation trace")
    rows=[dict(zip(FIELDS, RECORD.unpack_from(data,i))) for i in range(0,len(data),RECORD.size)]
    intervals=[b["flush_end_ns"]-a["flush_end_ns"] for a,b in zip(rows,rows[1:])]
    stages={"producer": [b["render_complete_ns"]-a["frame_end_ns"] for a,b in zip(rows,rows[1:])],
            "wake_error": [max(0,r["wake_error_ns"]) for r in rows],
            "upload": [r["upload_end_ns"]-r["present_start_ns"] for r in rows],
            "phase_wait": [r["copy_start_ns"]-r["upload_end_ns"] for r in rows],
            "copy": [r["copy_end_ns"]-r["copy_start_ns"] for r in rows],
            "flush": [r["flush_end_ns"]-r["copy_end_ns"] for r in rows],
            "present": [r["flush_end_ns"]-r["present_start_ns"] for r in rows],
            "frame": [r["frame_end_ns"]-r["render_complete_ns"] for r in rows]}
    worst=max(range(len(intervals)),key=intervals.__getitem__)
    result={"schema_version":1,"records":len(rows),"record_bytes":RECORD.size,
            "present_intervals":distribution(intervals),
            "stages":{k:distribution(v) for k,v in stages.items()},
            "late_slot":{"interval_index":worst,"interval_ms":intervals[worst]/1e6,
                         "before":rows[worst],"after":rows[worst+1]}}
    text=json.dumps(result,indent=2,sort_keys=True)+"\n"
    if args.output: Path(args.output).write_text(text)
    print(text,end="")
if __name__=="__main__": main()
