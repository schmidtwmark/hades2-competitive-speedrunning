#!/usr/bin/env bash
# Copy the newest race choice log from each machine (the players' own
# installs, not the test bed) and compare them by depth.
#   scripts/fetch-race-logs.sh [host-a] [host-b]   (default: deck@steamdeck.local bazzite.local)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="${1:-deck@steamdeck.local}"
B="${2:-bazzite.local}"
OUT="$ROOT/local/runs/races/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
REMOTE='.local/share/Steam/steamapps/common/Hades II/Ship/ReturnOfModding/plugins_data/schmidtwmark-Hades_2_Competitive_Speedrunning/races'
fetch() { # host -> local path of its newest log
  local host=$1 name
  name=$(ssh "$host" "ls -t \"\$HOME/$REMOTE\"/*.jsonl 2>/dev/null | head -1")
  [ -n "$name" ] || { echo "no race logs on $host" >&2; exit 1; }
  scp -q "$host:$(printf '%q' "$name")" "$OUT/"
  echo "$OUT/$(basename "$name")"
}
LA=$(fetch "$A")
LB=$(fetch "$B")
python3 "$ROOT/scripts/compare-race-logs.py" "$LA" "$LB" | tee "$OUT/compare.txt"
