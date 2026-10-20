#!/usr/bin/env python3
"""Diff two bot room traces (same race seed): rooms, per-room seeds, encounters,
rewards and boon choices. Prints a table and DETERMINISM: SAME / DIFFERENT."""
import json
import sys

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:  # missing trace = nothing to compare
        print(f"cannot read {path}: {e}")
        sys.exit(0)

a, b = load(sys.argv[1]), load(sys.argv[2])
print(f"seed A={a.get('seed')} B={b.get('seed')}")
ra = a.get("details", {}).get("rooms", [])
rb = b.get("details", {}).get("rooms", [])
same = a.get("seed") == b.get("seed")
fields = ["name", "seed", "encounter", "reward"]
for i in range(max(len(ra), len(rb))):
    x = ra[i] if i < len(ra) else {}
    y = rb[i] if i < len(rb) else {}
    diffs = [f for f in fields if x.get(f) != y.get(f)]
    if diffs:
        same = False
    mark = "same" if not diffs else "DIFF " + ",".join(diffs)
    print(f"room {i+1}: A={x.get('name')}/{x.get('encounter')}/{x.get('reward')} "
          f"B={y.get('name')}/{y.get('encounter')}/{y.get('reward')}  [{mark}]")
ca = a.get("details", {}).get("choices", [])
cb = b.get("details", {}).get("choices", [])
print(f"boon choices A={ca} B={cb} [{'same' if ca == cb else 'DIFF'}]")
if ca != cb:
    same = False
print("DETERMINISM: " + ("SAME" if same else "DIFFERENT"))
