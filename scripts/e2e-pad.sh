#!/usr/bin/env bash
# Real controller input end to end: a virtual gamepad on the test PC
# (scripts/bazzite/pad.py, kernel uinput) drives the native Race Board in one
# competitive game instance, against a mock rival met through Find Match.
# Only pad presses move the lobby forward: the in-game bot is hands-off
# (role "pad") until the race starts, then plays the run as usual.
#
# Script: home -> A (Find Match, focused) ; weapon vote -> Right Right A
# (third weapon: proves D-pad navigation) ; keepsake vote -> Down A ;
# ready check -> A. Logs: local/runs/<stamp>-pad/. Prints RESULT: PASS|FAIL.
# PAD_SCENARIO=forfeit: after the rooms, Start -> Down Down A ("Race Menu"
# in the native pause menu) -> Up A (its Forfeit Race) -> Up A (the confirm
# prompt's Forfeit); the rival then finishes and wins.
#   scripts/e2e-pad.sh [rooms]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
ROOMS="${1:-2}"
TIMEOUT="${E2E_TIMEOUT:-600}"
GUID="schmidtwmark-RankedRace"
PORT=$((20000 + RANDOM % 20000))
RUN="$ROOT/local/runs/$(date +%Y%m%d-%H%M%S)-pad"
mkdir -p "$RUN"
RHOME="$(ssh "$HOST" 'echo $HOME')"
TB="$RHOME/h2r-testbed"
DATA="$TB/rom-A/ReturnOfModding/plugins_data/$GUID"
FIFO="$TB/run/pad.fifo"
MAC_IP="${MAC_IP:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"

PIDS=()
cleanup() {
  ssh "$HOST" "$TB/instance.sh stop A; systemctl --user stop h2r-pad" >/dev/null 2>&1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
}
trap cleanup EXIT
fail() { echo "RESULT: FAIL $*"; exit 1; }
pad() { echo "pad: $*"; ssh "$HOST" "python3 $TB/pad.py send $FIFO $*"; }
# Wait until the game logged that the board shows a page starting with $1.
wait_page() {
  local t0; t0=$(date +%s)
  until ssh "$HOST" "grep -q 'board: page $1' '$DATA/ranked.log' 2>/dev/null"; do
    [ $(( $(date +%s) - t0 )) -gt "${2:-120}" ] && fail "board never showed page $1"
    sleep 1
  done
  echo "board: $1"
  sleep 1.5 # let the screen's input loop settle, like a player reading it
}

(cd "$ROOT/server" && npm run --silent build) || fail "server build"
PORT=$PORT HOST=0.0.0.0 VOTE_SECONDS=20 COUNTDOWN_MS=3000 node "$ROOT/server/dist/src/index.js" >"$RUN/server.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
"$ROOT/scripts/bazzite/push.sh" >/dev/null || fail "push"

SCEN="${PAD_SCENARIO:-win}"
OUTCOME='"outcome":"win","clear_screen":true,"expect":"win","expect_reason":"completed_first"'
[ "$SCEN" = forfeit ] && OUTCOME='"outcome":"external","expect":"lose","expect_reason":"survivor_finished"'
cat >"$RUN/bot.json" <<JSON
{"role":"pad","name":"PadPlayer","server_host":"$MAC_IP","server_port":$PORT,"rooms":$ROOMS,
 $OUTCOME,"timeout":$((TIMEOUT - 60)),"quit_after":${QUIT_AFTER:-5},
 "press_competitive_after":3,"expect_competitive":true,"reset_to_hub":false,"expect_results_screen":true}
JSON
ssh "$HOST" "mkdir -p '$DATA' '$TB/run' && rm -f '$DATA/bot-result.txt' '$DATA/trace.json' '$DATA/ranked.log' && cat > '$DATA/bot.json'" <"$RUN/bot.json" || fail "bot.json"

# The pad exists before the game starts, like a controller that is plugged in.
ssh "$HOST" "systemctl --user stop h2r-pad 2>/dev/null; rm -f $FIFO; systemd-run --user --unit=h2r-pad --collect --quiet \
  -p StandardOutput=append:$TB/run/pad.out -p StandardError=append:$TB/run/pad.out python3 $TB/pad.py serve $FIFO" || fail "pad"
sleep 2
ssh "$HOST" "test -p $FIFO" || fail "pad fifo missing: $(ssh "$HOST" "tail -3 $TB/run/pad.out")"

node "$ROOT/server/dist/src/mock-client.js" --host 127.0.0.1 --port "$PORT" --name MockRival --queue --outcome none \
  --timeout "$TIMEOUT" >"$RUN/mock.log" 2>&1 &
MOCK=$!
PIDS+=($MOCK)

ssh "$HOST" "$TB/instance.sh stop A >/dev/null; $TB/instance.sh start A /Windowed=true /Fullscreen=false /X=1280 /Y=720 /RequireFocusToUpdate=false" || fail "launch"

wait_page home 240
# The test enters competitive through a hook, so the game is still in mouse
# mode and its first pad input only switches to controller mode. Spend it on
# D-pad Up (nothing above Find Match, so the focus stays there).
pad up
sleep 1.5
pad a
wait_page vote_weapon
pad right right a
wait_page vote_keepsake
pad down a
wait_page "ready:false"
pad a

if [ "$SCEN" = forfeit ]; then
  t0=$(date +%s)
  until ssh "$HOST" "grep -q 'bot: rooms done' '$DATA/ranked.log' 2>/dev/null"; do
    [ $(( $(date +%s) - t0 )) -gt 300 ] && fail "rooms never finished"
    sleep 2
  done
  sleep 2
  pad start            # native pause menu, cursor on Continue
  sleep 1.5
  pad down down a      # Options, then "Race Menu"
  wait_page "prompt:race" 30
  pad up a             # the race menu focuses Back; Forfeit Race is above it
  wait_page "prompt:forfeit" 30
  pad up a             # the prompt focuses Keep Racing; Forfeit is above it
fi

start=$(date +%s)
while :; do
  ssh "$HOST" "test -s '$DATA/bot-result.txt'" && break
  ssh "$HOST" "$TB/instance.sh status A" | grep -q active || { echo "game exited before writing a result"; break; }
  [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ] && { echo "timeout after ${TIMEOUT}s"; break; }
  sleep 5
done
sleep 3
# QUIT_AFTER: the game lingers on its result screens (recordings); let it close itself.
if [ -n "${QUIT_AFTER:-}" ]; then
  for _ in $(seq $(( QUIT_AFTER + 30 ))); do
    ssh "$HOST" "$TB/instance.sh status A" | grep -q ': active' || break
    sleep 1
  done
fi
for f in bot-result.txt trace.json ranked.log; do scp -q "$HOST:$DATA/$f" "$RUN/$f" 2>/dev/null; done
scp -q "$HOST:$TB/run/pad.out" "$RUN/pad.out" 2>/dev/null
wait "$MOCK" 2>/dev/null

echo "--- board and pause actions seen in game"
grep -E 'board: (find|vote|ready|page|forfeit|prompt)|pause menu|forfeiting|blocked native' "$RUN/ranked.log" | sed 's/^[0-9.]* //'
VOTE=$(grep -oE 'board: vote [A-Za-z]+' "$RUN/ranked.log" | head -1 | awk '{print $3}')
echo "--- game bot"
cat "$RUN/bot-result.txt" 2>/dev/null || echo "(no bot-result.txt)"
NAV_OK=0; [ "$VOTE" = WeaponTorch ] && NAV_OK=1
echo "--- D-pad navigation: weapon vote $VOTE (want WeaponTorch): $([ $NAV_OK = 1 ] && echo ok || echo WRONG)"
PAUSE_OK=1
if [ "$SCEN" = forfeit ]; then
  grep -q 'pause menu Undo Night -> race prompt' "$RUN/ranked.log" && grep -q 'game: forfeiting the race' "$RUN/ranked.log" || PAUSE_OK=0
  echo "--- forfeit through the native pause menu: $([ $PAUSE_OK = 1 ] && echo ok || echo MISSING)"
fi
if grep -q '^RESULT: PASS' "$RUN/bot-result.txt" 2>/dev/null && [ $NAV_OK = 1 ] && [ $PAUSE_OK = 1 ]; then
  echo "RESULT: PASS (controller-driven race)"
else
  echo "--- ranked.log tail"; tail -25 "$RUN/ranked.log" 2>/dev/null
  fail "controller-driven race"
fi
