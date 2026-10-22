#!/usr/bin/env bash
# Hell2Modding's overlay takes all game input while open; a controller player
# must still be able to close it. One competitive game instance on the test PC
# with the virtual gamepad (scripts/bazzite/pad.py): the bot opens the overlay
# in the Crossroads (bot.lua probe_overlay), the pad presses B, and the overlay
# must close. Logs: local/runs/<stamp>-overlay/. Prints RESULT: PASS|FAIL.
#   scripts/e2e-overlay-pad.sh            (PAD_KEYS="back" to press another button;
#                                          only B closes it: Back has no game control)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
GUID="schmidtwmark-RankedRace"
RUN="$ROOT/local/runs/$(date +%Y%m%d-%H%M%S)-overlay"
mkdir -p "$RUN"
RHOME="$(ssh "$HOST" 'echo $HOME')"
TB="$RHOME/h2r-testbed"
DATA="$TB/rom-A/ReturnOfModding/plugins_data/$GUID"
FIFO="$TB/run/pad.fifo"
cleanup() { ssh "$HOST" "$TB/instance.sh stop A; systemctl --user stop h2r-pad" >/dev/null 2>&1; }
trap cleanup EXIT
fail() { echo "RESULT: FAIL $*"; exit 1; }
pad() { echo "pad: $*"; ssh "$HOST" "python3 $TB/pad.py send $FIFO $*"; }

"$ROOT/scripts/bazzite/push.sh" >/dev/null || fail "push"
# No server needed: the client's connection goes nowhere (port 9 on the test PC).
cat >"$RUN/bot.json" <<JSON
{"role":"idle","probe_overlay":true,"name":"PadPlayer","server_host":"127.0.0.1","server_port":9,
 "press_competitive_after":3,"expect_competitive":true,"reset_to_hub":false,"show_ui":false,
 "timeout":300,"quit_after":3}
JSON
ssh "$HOST" "mkdir -p '$DATA' '$TB/run' && rm -f '$DATA/bot-result.txt' '$DATA/ranked.log' && cat > '$DATA/bot.json'" <"$RUN/bot.json" || fail "bot.json"
ssh "$HOST" "systemctl --user stop h2r-pad 2>/dev/null; rm -f $FIFO; systemd-run --user --unit=h2r-pad --collect --quiet \
  -p StandardOutput=append:$TB/run/pad.out -p StandardError=append:$TB/run/pad.out python3 $TB/pad.py serve $FIFO" || fail "pad"
sleep 2
ssh "$HOST" "test -p $FIFO" || fail "pad fifo missing"
ssh "$HOST" "$TB/instance.sh stop A >/dev/null; $TB/instance.sh start A /Windowed=true /Fullscreen=false /X=1280 /Y=720 /RequireFocusToUpdate=false" || fail "launch"

t0=$(date +%s)
until ssh "$HOST" "grep -q 'bot: overlay opened' '$DATA/ranked.log' 2>/dev/null"; do
  [ $(( $(date +%s) - t0 )) -gt 240 ] && fail "the bot never opened the overlay"
  sleep 2
done
sleep 2
for key in ${PAD_KEYS:-b}; do
  pad "$key"
  sleep 4
  ssh "$HOST" "grep -q 'overlay: closed by the controller' '$DATA/ranked.log'" && break
done
t0=$(date +%s)
until ssh "$HOST" "test -s '$DATA/bot-result.txt'"; do
  [ $(( $(date +%s) - t0 )) -gt 90 ] && break
  sleep 2
done
scp -q "$HOST:$DATA/ranked.log" "$RUN/ranked.log" 2>/dev/null
scp -q "$HOST:$DATA/bot-result.txt" "$RUN/bot-result.txt" 2>/dev/null
grep -E "overlay|competitive:" "$RUN/ranked.log" | sed 's/^[0-9.]* //'
cat "$RUN/bot-result.txt" 2>/dev/null || echo "(no bot-result.txt)"
grep -q '^RESULT: PASS' "$RUN/bot-result.txt" 2>/dev/null && grep -q 'overlay: closed by the controller' "$RUN/ranked.log" \
  && echo "RESULT: PASS (controller closes the overlay)" || fail "controller closes the overlay"
