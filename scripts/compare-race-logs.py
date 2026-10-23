#!/usr/bin/env python3
"""Line up racers' choice logs (mod/src/racelog.lua, or the race server's copies
fetched by scripts/race-report.sh) by depth and show where their runs offered
different things. With more than two logs, each is compared with the first.

  scripts/compare-race-logs.py A.jsonl B.jsonl [C.jsonl ...]

Per depth: the room and its encounter, the encounters the game rolled for
each door's room, the doors offered (room + reward), boon offers (same source
only), and store stock. What each racer picked is shown but never counts as a
difference. Per pair it ends with "SEEDING: SAME" or "SEEDING: DIFFERENT (...)",
then "FAIRNESS: ...": offers can only be expected to match while both racers
have made the same choices (doors, boons, buys), so a difference before their
choices first split is the one that means an unfair race.
"""
import json
import sys
from collections import defaultdict


def load(path):
    by_depth = defaultdict(lambda: defaultdict(list))
    start = {}
    loadout = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            e = json.loads(line)
            if e.get("ev") == "start":
                start = e
                continue
            if e.get("ev") == "loadout":
                loadout = e
                continue
            by_depth[e.get("depth", 0)][e["ev"]].append(e)
    start["loadout"] = loadout
    return start, by_depth


def loadout_line(lo):
    if not lo:
        return "(not logged)"
    return f"aspect={lo.get('aspect')} keepsake={lo.get('keepsake')} familiar={lo.get('familiar')} arcana={','.join(lo.get('arcana') or []) or '-'}"


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


def compare(path_a, path_b):
    """Print one pair's per-depth comparison; return False if it looks unfair."""
    sa, a = load(path_a)
    sb, b = load(path_b)
    na, nb = sa.get("name", "A"), sb.get("name", "B")
    print(f"A = {na} ({path_a})\nB = {nb} ({path_b})")
    print(f"race {sa.get('race_id')} vs {sb.get('race_id')}  seed A={sa.get('seed')} B={sb.get('seed')}")
    if sa.get("seed") != sb.get("seed"):
        print("WARNING: different race seeds; these logs are from different races")
    print(f"loadout A: {loadout_line(sa['loadout'])}\nloadout B: {loadout_line(sb['loadout'])}")
    # Offers can differ by what each racer brought (hammers by aspect, ...).
    def kit(lo):
        return lo and {k: lo.get(k) for k in ("aspect", "arcana", "familiar", "keepsake")}
    same_loadout = kit(sa["loadout"]) == kit(sb["loadout"]) or not (sa["loadout"] and sb["loadout"])
    if not same_loadout:
        print("  (their loadouts differ: some offers may differ because of them)")
    diffs = []
    unfair = []
    split_at = None  # first depth where their choices differed
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
                if split_at is None:
                    unfair.append((depth, label))

        check("room", room_line(ea), room_line(eb))
        check("door rooms' encounters", door_encounters(ea) or None, door_encounters(eb) or None, partial_ok=True)
        check("doors", doors(ea), doors(eb), partial_ok=True)
        ba, bb = boons(ea), boons(eb)
        for src in sorted(set(ba) & set(bb)):
            check(f"boon offer {src}", ba[src], bb[src])
        sa_, sb_ = stores(ea), stores(eb)
        if sa_ or sb_:
            check("store", sa_, sb_)
        pa, pb = picks(ea), picks(eb)
        lines.append(f"  picks A: {', '.join(pa) or '-'}")
        lines.append(f"  picks B: {', '.join(pb) or '-'}")
        if split_at is None and pa != pb:
            split_at = depth
            lines.append("  (their choices split here: later offers may differ)")
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
    shared = f"depths 1-{split_at}" if split_at else f"all {last} depths"
    if unfair:
        where = ", ".join(f"{label} at depth {d}" for d, label in unfair)
        if not same_loadout and all(label.startswith("boon offer") for _, label in unfair):
            print(f"FAIRNESS: LOADOUTS DIFFER ({where}: boon offers can depend on aspect and Arcana)")
            return True
        print(f"FAIRNESS: CHECK ({where}, while both had made the same choices)")
        return False
    print(f"FAIRNESS: OK (same offers while their choices matched: {shared})")
    return True


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    logs = sys.argv[1:]
    fair = True
    for other in logs[1:]:
        if len(logs) > 2:
            print(f"===== {logs[0]} vs {other}")
        fair = compare(logs[0], other) and fair
    if len(logs) > 2:
        print("RACE FAIRNESS: " + ("OK" if fair else "CHECK"))


if __name__ == "__main__":
    main()
