#!/usr/bin/env python3
"""Line up two racers' choice logs (mod/src/racelog.lua) by depth and show
where their runs offered different things.

  scripts/compare-race-logs.py A.jsonl B.jsonl

Per depth: the room and its encounter, the encounters the game rolled for
each door's room, the doors offered (room + reward), boon offers (same source
only), and store stock. What each racer picked is shown but never counts as a
difference. Ends with "SEEDING: SAME" or "SEEDING: DIFFERENT (...)".
"""
import json
import sys
from collections import defaultdict


def load(path):
    by_depth = defaultdict(lambda: defaultdict(list))
    start = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            e = json.loads(line)
            if e.get("ev") == "start":
                start = e
                continue
            by_depth[e.get("depth", 0)][e["ev"]].append(e)
    return start, by_depth


def room_line(evs):
    r = evs.get("room")
    if not r:
        return None
    r = r[0]
    return f"{r.get('name')} encounter={r.get('encounter')}"


def door_encounters(evs):
    # Encounters rolled for the rooms behind this depth's doors (main rolls only).
    return sorted({e.get("encounter") or "-" for e in evs.get("encounter", []) if e.get("for_door") and e.get("kind") == "main"})


def doors(evs):
    d = evs.get("doors")
    if not d:
        return None
    return sorted(f"{x.get('room')}:{x.get('reward')}" + (f"({x['loot']})" if x.get("loot") else "") for x in d[-1].get("doors", []))


def boons(evs):
    out = {}
    for e in evs.get("boon", []):
        out.setdefault(e.get("source"), []).append(
            sorted(f"{o['name']}/{o.get('rarity')}" for o in e.get("offered", [])))
    return out


def stores(evs):
    return [sorted(e.get("items", [])) for e in evs.get("store", [])]


def picks(evs):
    out = []
    for e in evs.get("take_door", []):
        out.append(f"door->{e.get('room')}:{e.get('reward')}")
    for e in evs.get("boon", []):
        out.append(f"boon {e.get('picked')}")
    for e in evs.get("buy", []):
        out.append(f"buy {e.get('item')}")
    for kind in ("died", "forfeit", "cleared"):
        if evs.get(kind):
            out.append(kind)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sa, a = load(sys.argv[1])
    sb, b = load(sys.argv[2])
    na, nb = sa.get("name", "A"), sb.get("name", "B")
    print(f"A = {na} ({sys.argv[1]})\nB = {nb} ({sys.argv[2]})")
    print(f"race {sa.get('race_id')} vs {sb.get('race_id')}  seed A={sa.get('seed')} B={sb.get('seed')}")
    if sa.get("seed") != sb.get("seed"):
        print("WARNING: different race seeds; these logs are from different races")
    diffs = []
    last = min(max(a or [0]), max(b or [0]))
    for depth in range(1, last + 1):
        ea, eb = a.get(depth, {}), b.get(depth, {})
        if not ea and not eb:
            continue
        lines = []

        def check(label, va, vb, partial_ok=False):
            if va is None or vb is None:
                if partial_ok:
                    return
                if va is None and vb is None:
                    return
            same = va == vb
            mark = "same" if same else "DIFF"
            if same:
                lines.append(f"  {label}: {mark}  {va}")
            else:
                lines.append(f"  {label}: {mark}\n     A {va}\n     B {vb}")
                diffs.append((depth, label))

        check("room", room_line(ea), room_line(eb))
        check("door rooms' encounters", door_encounters(ea) or None, door_encounters(eb) or None, partial_ok=True)
        check("doors", doors(ea), doors(eb), partial_ok=True)
        ba, bb = boons(ea), boons(eb)
        for src in sorted(set(ba) & set(bb)):
            check(f"boon offer {src}", ba[src], bb[src])
        sa_, sb_ = stores(ea), stores(eb)
        if sa_ or sb_:
            check("store", sa_, sb_)
        lines.append(f"  picks A: {', '.join(picks(ea)) or '-'}")
        lines.append(f"  picks B: {', '.join(picks(eb)) or '-'}")
        print(f"depth {depth}")
        print("\n".join(lines))
    if diffs:
        first = {}
        for depth, label in diffs:
            first.setdefault(label.split(" ")[0] if label.startswith("boon") else label, depth)
        summary = ", ".join(f"{k} from depth {v}" for k, v in first.items())
        print(f"SEEDING: DIFFERENT ({summary})")
    else:
        print(f"SEEDING: SAME through depth {last}")


if __name__ == "__main__":
    main()
