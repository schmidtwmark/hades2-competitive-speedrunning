#!/usr/bin/env python3
"""Compare two bot room traces from the same race seed.

Must match per depth: room name, room seed, mirroring, encounter and its enemy
roster (the "same room, same enemies" rule). Reported only: the rewards behind
each door and the boons picked, which may differ when the players chose
differently. Prints DETERMINISM: SAME / DIFFERENT.
"""
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


def rooms(t):
    d = t.get("details", {})
    return d.get("rooms", d) if isinstance(d, dict) else d


ra, rb = rooms(a), rooms(b)
same = a.get("seed") == b.get("seed")
strict = ["name", "seed", "flipped", "encounter", "enemies", "spawns"]
n = min(len(ra), len(rb))
for i in range(max(len(ra), len(rb))):
    x = ra[i] if i < len(ra) else {}
    y = rb[i] if i < len(rb) else {}
    if i >= n:
        print(f"room {i+1}: only one side reached it ({x.get('name') or y.get('name')})")
        continue
    diffs = [f for f in strict if x.get(f) != y.get(f)]
    if diffs:
        same = False
    mark = "same" if not diffs else "DIFF " + ",".join(diffs)
    print(f"room {i+1}: {x.get('name')} flip={x.get('flipped')} {x.get('encounter')} [{mark}]")
    if "enemies" in diffs:
        print(f"   A enemies: {x.get('enemies')}\n   B enemies: {y.get('enemies')}")
    da = [(d.get('room'), d.get('reward'), d.get('loot')) for d in x.get("doors") or []]
    db = [(d.get('room'), d.get('reward'), d.get('loot')) for d in y.get("doors") or []]
    if da or db:
        rooms_a = {r for r, _, _ in da}
        rooms_b = {r for r, _, _ in db}
        print(f"   doors A={da}\n   doors B={db}")
        if len(rooms_a) > 1 or len(rooms_b) > 1:
            print("   NOTE: doors at this depth lead to different rooms")
        if rooms_a and rooms_b and rooms_a != rooms_b:
            same = False
            print("   DIFF next room offered")
taken_diff = [i + 1 for i in range(n)
              if (ra[i].get("taken") or {}).get("id") != (rb[i].get("taken") or {}).get("id")
              and len(ra[i].get("doors") or []) > 1]
print(f"depths where the players took different doors: {taken_diff or 'none'}")
if "--expect-divergence" in sys.argv and not taken_diff:
    same = False
    print("   FAIL: players were supposed to choose differently but never did (hollow test)")
ca = (a.get("details") or {}).get("choices", []) if isinstance(a.get("details"), dict) else []
cb = (b.get("details") or {}).get("choices", []) if isinstance(b.get("details"), dict) else []
print(f"boon choices A={ca} B={cb} (allowed to differ)")
if n == 0:
    same = False
print("DETERMINISM: " + ("SAME" if same else "DIFFERENT"))
