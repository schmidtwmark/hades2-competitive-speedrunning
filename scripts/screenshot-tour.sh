#!/usr/bin/env bash
# Capture the real competitive flow for docs/review: two test instances race
# through the given server with human-paced bots (6 s pause before each lobby
# action); both game windows are captured every ~3 s (game windows only, via
# scripts/bazzite/capture.sh). Frames land in local/runs/tour/<epoch>-w<n>.png.
#   scripts/screenshot-tour.sh [host:port | local]   (local: a server on this Mac)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-hopper.proxy.rlwy.net:16303}"
OUT="$ROOT/local/runs/tour"
mkdir -p "$OUT"
find "$OUT" -name '*.png' -delete

[ "$SERVER" = local ] && SERVER=""
REMOTE_SERVER="$SERVER" COMPETITIVE=1 DIVERGE=1 OVERLAY=1 BOARD=1 DWELL=${DWELL:-6} SHOW_UI=false RES="/X=1280 /Y=720" E2E_TIMEOUT=900 \
  "$ROOT/scripts/e2e-two-games.sh" 3 >"$OUT/e2e.txt" 2>&1 &
E2E=$!
sleep 8
while kill -0 "$E2E" 2>/dev/null; do
  t=$(date +%s)
  for i in 1 2; do
    "$ROOT/scripts/bazzite/capture.sh" "$OUT/$t-w$i.png" "$i" >/dev/null 2>&1 || rm -f "$OUT/$t-w$i.png"
  done
  sleep 2
done
wait "$E2E"
echo "frames: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ')"
grep -E '^RESULT|DETERMINISM' "$OUT/e2e.txt"
