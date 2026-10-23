#!/usr/bin/env bash
# Practice from the Race Board, in one competitive game instance on the test PC
# against a server on this Mac: "race_bot" takes Practice -> Race a Bot (the
# server's house bot joins, readies and follows our votes), "solo" takes
# Practice -> Solo Run. The in-game bot presses the board's controls, votes,
# readies, clears the run and checks the result (and, against the house bot,
# that it reported its rooms and that the keepsake vote named the weapon pick).
#   scripts/e2e-practice.sh [race_bot|solo] [rooms]
# BOT_EXTRA='"update_peek":8' adds bot.json fields; server env vars (e.g.
# LATEST_MOD_VERSION=9.9.9) pass through to the local server.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
MODE="${1:-race_bot}"
ROOMS="${2:-2}"
TIMEOUT="${E2E_TIMEOUT:-600}"
GUID="schmidtwmark-RankedRace"
PORT=$((20000 + RANDOM % 20000))
RUN="$ROOT/local/runs/$(date +%Y%m%d-%H%M%S)-practice-$MODE"
mkdir -p "$RUN"
RHOME="$(ssh "$HOST" 'echo $HOME')"
TB="$RHOME/h2r-testbed"
DATA="$TB/rom-A/ReturnOfModding/plugins_data/$GUID"
MAC_IP="${MAC_IP:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"
PIDS=()
cleanup() {
  ssh "$HOST" "$TB/instance.sh stop A" >/dev/null 2>&1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
}
trap cleanup EXIT
fail() { echo "RESULT: FAIL $*"; exit 1; }
case "$MODE" in
  race_bot) EXTRA='"expect_rival":"Bot","expect_results":2' ;;
  solo) EXTRA='"expect_results":1' ;;
  *) fail "unknown mode $MODE" ;;
esac

(cd "$ROOT/server" && npm run --silent build) || fail "server build"
# The house bot reports a room every 5 s, so a short run sees its progress.
PORT=$PORT HOST=0.0.0.0 VOTE_SECONDS=12 COUNTDOWN_MS=3000 BOT_ROOM_SECONDS=5 ROUTES=underworld,surface \
  node "$ROOT/server/dist/src/index.js" >"$RUN/server.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
"$ROOT/scripts/bazzite/push.sh" >/dev/null || fail "push"
cat >"$RUN/bot.json" <<JSON
{"role":"$MODE","name":"PracticeBot","server_host":"$MAC_IP","server_port":$PORT,"rooms":$ROOMS,"use_board":true,
 "route":"underworld","weapon":"WeaponDagger","keepsake":"LowHealthCritKeepsake",
 "outcome":"win","clear_screen":true,"expect":"win","expect_reason":"completed_first",$EXTRA,"expect_results_screen":true,
 "timeout":$((TIMEOUT - 60)),"quit_after":5,"press_competitive_after":3,"expect_competitive":true,"reset_to_hub":false${BOT_EXTRA:+,$BOT_EXTRA}}
JSON
ssh "$HOST" "mkdir -p '$DATA' && rm -f '$DATA/bot-result.txt' '$DATA/trace.json' '$DATA/ranked.log' && cat > '$DATA/bot.json'" <"$RUN/bot.json" || fail "bot.json"
ssh "$HOST" "$TB/instance.sh stop A >/dev/null; $TB/instance.sh start A /Windowed=true /Fullscreen=false /X=1280 /Y=720 /RequireFocusToUpdate=false" || fail "launch"
start=$(date +%s)
while :; do
  ssh "$HOST" "test -s '$DATA/bot-result.txt'" && break
  ssh "$HOST" "$TB/instance.sh status A" | grep -q active || { echo "game exited before writing a result"; break; }
  [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ] && { echo "timeout after ${TIMEOUT}s"; break; }
  sleep 5
done
sleep 3
for f in bot-result.txt ranked.log; do scp -q "$HOST:$DATA/$f" "$RUN/$f" 2>/dev/null; done
scp -q "$HOST:$TB/rom-A/ReturnOfModding/LogOutput.log" "$RUN/LogOutput.log" 2>/dev/null
echo "--- game bot ($RUN)"
cat "$RUN/bot-result.txt" 2>/dev/null || echo "(no bot-result.txt)"
grep -c "Script error" "$RUN/LogOutput.log" 2>/dev/null | sed 's/^/script errors: /'
if grep -q '^RESULT: PASS' "$RUN/bot-result.txt" 2>/dev/null && ! grep -q "Script error" "$RUN/LogOutput.log" 2>/dev/null; then
  echo "RESULT: PASS (practice $MODE)"
else
  echo "--- ranked.log tail"; tail -25 "$RUN/ranked.log" 2>/dev/null
  fail "practice $MODE"
fi
