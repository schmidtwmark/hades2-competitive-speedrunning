#!/usr/bin/env bash
# Two real game clients on the test PC (instances A and B, each with its own
# prefix/save copy and in-game bot) race each other through a server on this
# Mac over the LAN. B dies after the rooms; A clears once it sees B's death.
# Then the two room traces are diffed (same seed => same rooms?).
# Logs: local/runs/<stamp>-two/. Prints RESULT: PASS or RESULT: FAIL.
#   scripts/e2e-two-games.sh [rooms]      (MUTATE=no_seed runs the mutation twin: traces must differ)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
ROOMS="${1:-3}"
TIMEOUT="${E2E_TIMEOUT:-720}"
GUID="schmidtwmark-RankedRace"
PORT=$((20000 + RANDOM % 20000))
RUN="$ROOT/local/runs/$(date +%Y%m%d-%H%M%S)-two"
mkdir -p "$RUN"
RHOME="$(ssh "$HOST" 'echo $HOME')"
TB="$RHOME/h2r-testbed"
RES="${RES:-/X=960 /Y=540}"
GAME_ARGS="/Windowed=true /Fullscreen=false $RES /DirectLoadShell=false /RequireFocusToUpdate=false"
# COMPETITIVE=1: both clients enter via the title-screen entry (identical maxed profiles).
# DIVERGE=1: instance B takes the highest-id door and the last boon (A: lowest, first).
# QUEUE=1: both clients use Find Match instead of a private lobby code.
# BOARD=1: lobby actions go through the native Race Board (code typed on its keys).
# CODE=1: both clients enter the same random race code (no host).
# SCENARIO=clear_then_forfeit: A clears first through the game's run clear
#   screen; B is told mid-run, keeps going two more rooms, then forfeits.
if [ "${COMPETITIVE:-0}" = 1 ]; then
  GAME_ARGS="/Windowed=true /Fullscreen=false $RES /RequireFocusToUpdate=false"
fi
MAC_IP="${MAC_IP:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"
data() { echo "$TB/rom-$1/ReturnOfModding/plugins_data/$GUID"; }

PIDS=()
cleanup() {
  ssh "$HOST" "$TB/instance.sh stop A; $TB/instance.sh stop B" >/dev/null 2>&1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
}
trap cleanup EXIT
fail() { echo "RESULT: FAIL $*"; exit 1; }

# REMOTE_SERVER=host:port races through a deployed server (e.g. Railway) instead of this Mac.
if [ -n "${REMOTE_SERVER:-}" ]; then
  MAC_IP="${REMOTE_SERVER%:*}"; PORT="${REMOTE_SERVER##*:}"
else
  (cd "$ROOT/server" && npm run --silent build) || fail "server build"
  PORT=$PORT HOST=0.0.0.0 VOTE_SECONDS=4 COUNTDOWN_MS=3000 node "$ROOT/server/dist/src/index.js" >"$RUN/server.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
fi
"$ROOT/scripts/bazzite/push.sh" >/dev/null || fail "push"

COMP_JSON=""
[ "${COMPETITIVE:-0}" = 1 ] && COMP_JSON='"press_competitive_after":3,"expect_competitive":true,"reset_to_hub":false,'
RACE_CODE=$(LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 4)
MUT_JSON=""
[ -n "${MUTATE:-}" ] && MUT_JSON="\"$MUTATE\":true"
for X in A B; do
  PICK=""
  [ "${DIVERGE:-0}" = 1 ] && [ "$X" = B ] && PICK='"door_pick":"highest","boon_pick":"last",'
  if [ "$X" = A ]; then ROLE=host; EXTRA='"outcome":"win","clear_screen":true,"win_after_opponent_death":true,"expect":"win","expect_reason":"survivor_finished"'
  else ROLE=join; EXTRA='"outcome":"die","expect":"lose","expect_reason":"survivor_finished"'; fi
  if [ "${SCENARIO:-}" = clear_then_forfeit ]; then
    if [ "$X" = A ]; then EXTRA='"outcome":"win","clear_screen":true,"expect":"win","expect_reason":"completed_first"'
    else EXTRA='"outcome":"forfeit","rooms":'$((ROOMS + 2))',"expect":"lose","expect_reason":"completed_first"'; fi
  fi
  [ "${QUEUE:-0}" = 1 ] && ROLE=queue
  [ "${CODE:-0}" = 1 ] && ROLE=code
  cat >"$RUN/bot-$X.json" <<JSON
{"role":"$ROLE","name":"Bot$X","server_host":"$MAC_IP","server_port":$PORT,"rooms":$ROOMS,
 "code_file":"Z:$TB/run/code","weapon":"WeaponAxe","keepsake":"BossPreDamageKeepsake",
 "timeout":$((TIMEOUT - 60)),"quit_after":${QUIT_AFTER:-5},"show_ui":${SHOW_UI:-true},"dwell":${DWELL:-0},"expect_overlay":$([ "${OVERLAY:-0}" = 1 ] && echo true || echo false),"use_board":$([ "${BOARD:-0}" = 1 ] && echo true || echo false),"expect_results_screen":$([ "${BOARD:-0}" = 1 ] && echo true || echo false),"race_code":"$RACE_CODE","mutations":{$MUT_JSON},$COMP_JSON$PICK
 $EXTRA}
JSON
  D="$(data $X)"
  ssh "$HOST" "mkdir -p '$D' && rm -f '$D'/bot-result.txt '$D'/trace.json '$D'/ranked.log && cat > '$D/bot.json'" <"$RUN/bot-$X.json" || fail "bot.json $X"
done
ssh "$HOST" "rm -f '$TB/run/code'; $TB/instance.sh stop A >/dev/null; $TB/instance.sh stop B >/dev/null; $TB/instance.sh start A $GAME_ARGS && sleep 8 && $TB/instance.sh start B $GAME_ARGS" || fail "launch"

start=$(date +%s)
while :; do
  done_n=$(ssh "$HOST" "ls '$(data A)/bot-result.txt' '$(data B)/bot-result.txt' 2>/dev/null | wc -l")
  [ "$done_n" -ge 2 ] && break
  [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ] && { echo "timeout after ${TIMEOUT}s"; break; }
  sleep 5
done
sleep 3
# QUIT_AFTER: the games linger on their result screens (recordings); let them close themselves.
if [ -n "${QUIT_AFTER:-}" ]; then
  for _ in $(seq $(( QUIT_AFTER + 30 ))); do
    ssh "$HOST" "$TB/instance.sh status A; $TB/instance.sh status B" | grep -q ': active' || break
    sleep 1
  done
fi
for X in A B; do
  D="$(data $X)"
  for f in bot-result.txt trace.json ranked.log; do scp -q "$HOST:$D/$f" "$RUN/$X-$f" 2>/dev/null; done
  scp -q "$HOST:$TB/rom-$X/ReturnOfModding/LogOutput.log" "$RUN/$X-LogOutput.log" 2>/dev/null
done
ok=1
for X in A B; do
  echo "--- instance $X"
  cat "$RUN/$X-bot-result.txt" 2>/dev/null || { echo "(no result)"; tail -15 "$RUN/$X-ranked.log" 2>/dev/null; }
  grep -q '^RESULT: PASS' "$RUN/$X-bot-result.txt" 2>/dev/null || ok=0
done
for X in A B; do
  if grep -q "ui: \|frame error" "$RUN/$X-ranked.log" 2>/dev/null; then
    echo "instance $X logged UI/frame errors:"; grep "ui: \|frame error" "$RUN/$X-ranked.log" | head -5; ok=0
  fi
done
echo "--- trace comparison"
python3 "$ROOT/scripts/compare-traces.py" "$RUN/A-trace.json" "$RUN/B-trace.json" $([ "${DIVERGE:-0}" = 1 ] && echo --expect-divergence) | tee "$RUN/compare.txt"
[ $ok -eq 1 ] && echo "RESULT: PASS (two real clients)" || fail "two real clients"
