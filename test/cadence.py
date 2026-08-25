#!/usr/bin/env python3
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("cadence", Path(__file__).parents[1] / "tools/cadence.py")
cadence = importlib.util.module_from_spec(spec); spec.loader.exec_module(cadence)

period = 1 / 120
pts = [i * period for i in range(2400)]
hashes = [f"frame-{i}" for i in range(2400)]
result = cadence.metrics(pts, hashes)
assert result["packets"] == 2400
assert 119 <= result["visible_fps"] <= 121
assert result["missed_deadlines"] == 0
assert result["consecutive_duplicates"] == 0
assert result["p99_ms"] < 8.5

# A late sample records a missed slot; subsequent samples retain the 60 Hz
# phase rather than forming a short catch-up interval.
late_pts = [0, period, 3 * period, 4 * period]
late = cadence.metrics(late_pts, ["a", "b", "c", "d"])
assert late["missed_deadlines"] == 1
assert late["worst_ms"] > 16

duplicate = cadence.metrics([0, period, 2 * period], ["a", "a", "b"])
assert duplicate["consecutive_duplicates"] == 1
print("cadence fixtures: monotonic 120 Hz, missed slots, duplicates: PASS")
