#!/usr/bin/env bash
# What a race offered each racer, from the race server's own records (Railway
# volume /data/races, written by server/src/race-log-store.ts): the setup and
# results, then every racer's choice log compared depth by depth with a
# fairness verdict (scripts/compare-race-logs.py).
#   scripts/race-report.sh            list the latest races
#   scripts/race-report.sh 1          report on the latest (2: the one before, ...)
#   scripts/race-report.sh <folder>   report on that race (a name from the list)
# Reports land in local/runs/server-races/<folder>/report.txt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE=race-server
DIR=/data/races
cd "$ROOT/server" # the linked Railway project
# railway ssh runs its command through a shell on the server: pass one string.
remote() { railway ssh --service "$SERVICE" -- "$1" | tr -d '\r'; }

list="$(remote "ls -1t $DIR 2>/dev/null | head -20")"
if [ -z "${1:-}" ]; then
  [ -n "$list" ] || { echo "no races recorded yet"; exit 0; }
  printf '%s\n' "$list" | nl -w2 -s'  '
  echo "report on one: scripts/race-report.sh <number|folder>"
  exit 0
fi
if [[ "$1" =~ ^[0-9]+$ ]]; then F="$(printf '%s\n' "$list" | sed -n "${1}p")"; else F="$1"; fi
[[ "$F" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "no such race: $1" >&2; exit 1; }
OUT="$ROOT/local/runs/server-races"
mkdir -p "$OUT"
remote "tar -cz -C $DIR $F | base64" | base64 -d | tar -xz -C "$OUT"
cd "$OUT/$F"
{
  python3 - <<'PY'
import json
r = json.load(open("race.json"))
print(f"race {r['race_id']} in lobby {r['lobby']}, {r['started_at']}")
print(f"seed {r['seed']}  route {r['route'] or '-'}  weapon {r['weapon']}  keepsake {r['keepsake']}")
print("racers: " + ", ".join(e["name"] + (" (bot)" if e.get("bot") else "") for e in r["entrants"]))
for e in r.get("results") or []:
    t = f"{e['time']:.1f}s" if isinstance(e.get("time"), (int, float)) else "-"
    print(f"  {e['place']}. {e['name']}: {e['outcome']} {t} depth {e.get('depth')}")
if not r.get("results"):
    print("  (no results: still running, or the server restarted)")
PY
  echo
  logs=( $(ls -1 *.jsonl 2>/dev/null | sort -n) )
  if [ ${#logs[@]} -ge 2 ]; then
    python3 "$ROOT/scripts/compare-race-logs.py" "${logs[@]}"
  else
    echo "only ${#logs[@]} racer log(s): nothing to compare"
  fi
} | tee report.txt
echo "(saved to $OUT/$F/report.txt)"
