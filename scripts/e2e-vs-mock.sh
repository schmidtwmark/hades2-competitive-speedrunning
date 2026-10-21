#!/usr/bin/env bash
# One real game client (test PC, instance A, in-game bot) races a mock opponent
# through a server on this Mac, reached directly over the LAN. Collects every log into local/runs/<stamp>-<scenario>/ and prints
# RESULT: PASS or RESULT: FAIL.
#
#   scripts/e2e-vs-mock.sh [game_wins|game_dies] [rooms]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
SCEN="${1:-game_wins}"
ROOMS="${2:-2}"
TIMEOUT="${E2E_TIMEOUT:-600}"
GUID="schmidtwmark-RankedRace"
PORT=$((20000 + RANDOM % 20000))
RUN="$ROOT/local/runs/$(date +%Y%m%d-%H%M%S)-$SCEN$([ "${COMPETITIVE:-0}" = 1 ] && echo -competitive)"
mkdir -p "$RUN"
RHOME="$(ssh "$HOST" 'echo $HOME')"
TB="$RHOME/h2r-testbed"
DATA="$TB/rom-A/ReturnOfModding/plugins_data/$GUID"
WIN() { echo "Z:$1"; }
GAME_ARGS=(/Windowed=true /Fullscreen=false /X=1280 /Y=720 /DirectLoadShell=false /RequireFocusToUpdate=false)
# COMPETITIVE=1: boot to the title screen, take "Play Competitive Speedrun", verify the
# maxed profile, and prove no save file in the test prefix changed.
COMPETITIVE="${COMPETITIVE:-0}"
SAVES="$TB/pfx-A/pfx/drive_c/users/steamuser/Saved Games/Hades II"
if [ "$COMPETITIVE" = 1 ]; then
  GAME_ARGS=(/Windowed=true /Fullscreen=false /X=1280 /Y=720 /RequireFocusToUpdate=false)
fi

PIDS=()
cleanup() {
  ssh "$HOST" "$TB/instance.sh stop A" >/dev/null 2>&1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
}
trap cleanup EXIT
fail() { echo "RESULT: FAIL $*"; exit 1; }

case "$SCEN" in
  game_wins)
    MOCK_ARGS=(--outcome none)
    BOT="{\"outcome\":\"win\",\"expect\":\"win\",\"expect_reason\":\"completed_first\"}" ;;
  game_dies)
    MOCK_ARGS=(--outcome win --finish-after 400)
    BOT="{\"outcome\":\"die\",\"expect\":\"lose\",\"expect_reason\":\"survivor_finished\"}" ;;
  *) fail "unknown scenario $SCEN" ;;
esac

(cd "$ROOT/server" && npm run --silent build) || fail "server build"
# By default the game connects straight to a server on this Mac over the LAN.
# REMOTE_SERVER=host:port uses a deployed server instead (e.g. Railway).
if [ -n "${REMOTE_SERVER:-}" ]; then
  MAC_IP="${REMOTE_SERVER%:*}"
  PORT="${REMOTE_SERVER##*:}"
  MOCK_HOST="$MAC_IP"
  echo "using remote server $MAC_IP:$PORT" >"$RUN/server.log"
else
  MAC_IP="${MAC_IP:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"
  MOCK_HOST=127.0.0.1
  PORT=$PORT HOST=0.0.0.0 VOTE_SECONDS=3 COUNTDOWN_MS=3000 node "$ROOT/server/dist/src/index.js" >"$RUN/server.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
fi

"$ROOT/scripts/bazzite/push.sh" >/dev/null || fail "push"
COMPETITIVE=$COMPETITIVE BOT_EXTRA="${BOT_EXTRA:-}" python3 - "$BOT" "$PORT" "$ROOMS" "$(WIN "$TB/run/code")" "$MAC_IP" >"$RUN/bot.json" <<'EOF'
import json, sys
bot = json.loads(sys.argv[1])
bot.update(role="join", server_host=sys.argv[5], server_port=int(sys.argv[2]), name="GameBot",
           rooms=int(sys.argv[3]), code_file=sys.argv[4], weapon="WeaponDagger",
           keepsake="LowHealthCritKeepsake", timeout=540, quit_after=5)
import os
if os.environ.get("COMPETITIVE") == "1":
    bot.update(press_competitive_after=3, expect_competitive=True, reset_to_hub=False)
# BOT_EXTRA='{"shadow_mirror":{"dx":160}}': extra bot.json fields for one-off checks.
if os.environ.get("BOT_EXTRA"):
    bot.update(json.loads(os.environ["BOT_EXTRA"]))
print(json.dumps(bot))
EOF
ssh "$HOST" "mkdir -p '$DATA' '$TB/run' && rm -f '$TB/run/code' '$DATA/bot-result.txt' '$DATA/trace.json' '$DATA/ranked.log' && cat > '$DATA/bot.json'" <"$RUN/bot.json" || fail "write bot.json"

node "$ROOT/server/dist/src/mock-client.js" --host "$MOCK_HOST" --port "$PORT" --name MockBot --create --code-file "$RUN/code" \
  --weapon WeaponDagger --keepsake LowHealthCritKeepsake "${MOCK_ARGS[@]}" --timeout "$TIMEOUT" >"$RUN/mock.log" 2>&1 &
MOCK=$!
PIDS+=($MOCK)
for _ in $(seq 50); do [ -s "$RUN/code" ] && break; sleep 0.2; done
[ -s "$RUN/code" ] || fail "mock never created a lobby"
ssh "$HOST" "cat > '$TB/run/code'" <"$RUN/code"
echo "lobby $(cat "$RUN/code") on port $PORT; launching game"

save_hashes() { ssh "$HOST" "cd '$SAVES' && sha256sum Profile* activeProfile 2>/dev/null"; }
save_hashes >"$RUN/saves-before.txt"
ssh "$HOST" "$TB/instance.sh stop A >/dev/null; $TB/instance.sh start A ${GAME_ARGS[*]}" || fail "launch"
start=$(date +%s)
while :; do
  if ssh "$HOST" "test -s '$DATA/bot-result.txt'"; then break; fi
  if ! ssh "$HOST" "$TB/instance.sh status A" | grep -q active; then echo "game exited before writing a result"; break; fi
  [ $(( $(date +%s) - start )) -gt "$TIMEOUT" ] && { echo "timeout after ${TIMEOUT}s"; break; }
  sleep 5
done
sleep 3
for f in bot-result.txt trace.json ranked.log; do scp -q "$HOST:$DATA/$f" "$RUN/$f" 2>/dev/null; done
scp -q "$HOST:$TB/rom-A/ReturnOfModding/LogOutput.log" "$RUN/LogOutput.log" 2>/dev/null
scp -q "$HOST:$TB/run/A.out" "$RUN/A.out" 2>/dev/null
wait "$MOCK" 2>/dev/null
ssh "$HOST" "$TB/instance.sh stop A" >/dev/null 2>&1
save_hashes >"$RUN/saves-after.txt"
SAVES_OK=1
if [ "$COMPETITIVE" = 1 ] && ! cmp -s "$RUN/saves-before.txt" "$RUN/saves-after.txt"; then
  SAVES_OK=0; echo "save files changed during competitive mode:"; diff "$RUN/saves-before.txt" "$RUN/saves-after.txt"
fi
echo "--- game bot ($RUN)"
cat "$RUN/bot-result.txt" 2>/dev/null || echo "(no bot-result.txt)"
echo "--- mock: $(grep '^RESULT:' "$RUN/mock.log" | cut -c1-240)"
[ "$COMPETITIVE" = 1 ] && echo "--- save files unchanged: $([ $SAVES_OK = 1 ] && echo yes || echo NO) ($(wc -l <"$RUN/saves-before.txt" | tr -d ' ') files)"
if grep -q '^RESULT: PASS' "$RUN/bot-result.txt" 2>/dev/null && [ $SAVES_OK = 1 ]; then
  echo "RESULT: PASS ($SCEN)"
else
  echo "--- ranked.log tail"; tail -25 "$RUN/ranked.log" 2>/dev/null
  fail "$SCEN"
fi
