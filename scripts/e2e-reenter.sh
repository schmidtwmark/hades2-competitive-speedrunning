#!/usr/bin/env bash
# Competitive mode twice in one session: enter from the title screen, quit to
# the title screen through the pause menu (virtual gamepad), enter again. The
# Crossroads must be visible both times (a quit leaves the screen faded to
# black), and an Arcana card the bot changed on the first visit must still be
# changed on the second (the remembered loadout). Screenshots: local/runs/<stamp>-reenter/. Prints RESULT: PASS|FAIL.
# The bot also shows a countdown "3" in the Crossroads, cycling font sizes
# (PREVIEW_SIZES: sizes or Font:size, default "128"), for font screenshots:
# first-visit-<n>.png. RES="/X=3840 /Y=2160" for a 4K window.
#   scripts/e2e-reenter.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
GUID="schmidtwmark-RankedRace"
RUN="$ROOT/local/runs/$(date +%Y%m%d-%H%M%S)-reenter"
mkdir -p "$RUN"
RHOME="$(ssh "$HOST" 'echo $HOME')"
TB="$RHOME/h2r-testbed"
DATA="$TB/rom-A/ReturnOfModding/plugins_data/$GUID"
FIFO="$TB/run/pad.fifo"
# The bot's Arcana change lands in the remembered loadout: put it back afterwards.
cleanup() {
  ssh "$HOST" "$TB/instance.sh stop A; systemctl --user stop h2r-pad; cd '$DATA' && if [ -f loadout.json.reenter ]; then mv -f loadout.json.reenter loadout.json; else rm -f loadout.json; fi" >/dev/null 2>&1
}
trap cleanup EXIT
fail() { echo "RESULT: FAIL $*"; exit 1; }
pad() { echo "pad: $*"; ssh "$HOST" "python3 $TB/pad.py send $FIFO $*"; }
count() { ssh "$HOST" "grep -c '$1' '$DATA/ranked.log' 2>/dev/null || true"; }
wait_count() { # pattern n timeout
  local t0; t0=$(date +%s)
  until [ "$(count "$1")" -ge "$2" ]; do
    [ $(( $(date +%s) - t0 )) -gt "$3" ] && fail "never saw '$1' x$2"
    sleep 2
  done
}
shot() { "$ROOT/scripts/bazzite/capture.sh" "$RUN/$1.png" 1 >/dev/null || fail "screenshot $1"; }
brightness() { python3 -c "from PIL import Image; im=Image.open('$RUN/$1.png').convert('L'); print(int(sum(im.getdata())/(im.width*im.height)))"; }

"$ROOT/scripts/bazzite/push.sh" >/dev/null || fail "push"
SIZES="${PREVIEW_SIZES:-128}"
cat >"$RUN/bot.json" <<JSON
{"role":"idle","name":"PadPlayer","server_host":"127.0.0.1","server_port":9,
 "press_competitive_after":3,"press_competitive_again":true,"expect_competitive":true,"reset_to_hub":false,
 "show_ui":false,"timeout":600,"change_arcana":true,"preview_count":"3","preview_sizes":[$(printf '"%s",' $SIZES | sed 's/,$//')]}
JSON
ssh "$HOST" "mkdir -p '$DATA' '$TB/run' && rm -f '$DATA/bot-result.txt' '$DATA/ranked.log' && cat > '$DATA/bot.json' && { [ ! -f '$DATA/loadout.json' ] || cp '$DATA/loadout.json' '$DATA/loadout.json.reenter'; }" <"$RUN/bot.json" || fail "bot.json"
ssh "$HOST" "systemctl --user stop h2r-pad 2>/dev/null; rm -f $FIFO; systemd-run --user --unit=h2r-pad --collect --quiet \
  -p StandardOutput=append:$TB/run/pad.out -p StandardError=append:$TB/run/pad.out python3 $TB/pad.py serve $FIFO" || fail "pad"
sleep 2
ssh "$HOST" "$TB/instance.sh stop A >/dev/null; $TB/instance.sh start A /Windowed=true /Fullscreen=false ${RES:-/X=1920 /Y=1080} /RequireFocusToUpdate=false" || fail "launch"

wait_count 'competitive: in the hub' 1 240
sleep 6
# One screenshot per previewed font/size, 2 s after the bot switched to it
# (the game writes its log with Windows line ends).
k=$(wc -w <<<"$SIZES")
seen=" "
want=1
while [ "$(wc -w <<<"$seen")" -lt "$k" ]; do
  wait_count 'countdown preview' $want 30
  want=$(( $(count 'countdown preview') + 1 ))
  sleep 2
  pick=$(ssh "$HOST" "grep 'countdown preview' '$DATA/ranked.log' | tail -1" | tr -d '\r' | awk '{print $NF}' | tr ':' '-')
  case "$seen" in *" $pick "*) continue ;; esac
  seen="$seen$pick "
  shot "first-visit-$pick"
done
FIRST=$(brightness "first-visit-$pick")
echo "first visit: brightness $FIRST"

# Pause, Quit (the last item; extra presses stay on it), OK on "Quit without saving?".
pad up wait:1 start wait:2 down down down down down wait:1 a wait:2 a
wait_count 'competitive profile built' 2 120
sleep 8
shot second-visit
SECOND=$(brightness second-visit)
echo "second visit: brightness $SECOND"
scp -q "$HOST:$DATA/ranked.log" "$RUN/ranked.log" 2>/dev/null
grep -E "competitive:|fading|entering" "$RUN/ranked.log" | sed 's/^[0-9.]* //'
ARCANA=$(grep -o 'saved_arcana=[0-9]*' "$RUN/ranked.log" | cut -d= -f2 | tr '\n' ' ')
echo "equipped Arcana at each build: $ARCANA"
set -- $ARCANA
[ $# -ge 2 ] && [ $(( $1 - $2 )) -eq 1 -o $(( $2 - $1 )) -eq 1 ] || fail "the Arcana change didn't carry over ($ARCANA)"
[ "$FIRST" -gt 10 ] || fail "first visit is dark ($FIRST)"
[ "$SECOND" -gt 10 ] && echo "RESULT: PASS (the Crossroads shows after quitting and re-entering)" || fail "second visit is black ($SECOND)"
