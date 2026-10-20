#!/usr/bin/env bash
# Two simulated game clients (real main.lua + bot on a toy game) race through a
# real server. Proves wiring and bot flow off-game. Prints RESULT: PASS or FAIL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="${LUA52_HOME:-$ROOT/local/tools/lua52}"
LUA="$L/bin/lua"
export LUA_PATH="$L/share/lua/5.2/?.lua;$L/share/lua/5.2/?/init.lua;;"
export LUA_CPATH="$L/lib/lua/5.2/?.so;;"
[ -x "$LUA" ] || { echo "RESULT: FAIL missing $LUA"; exit 1; }

(cd "$ROOT/server" && npm run --silent build)
WORK="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true; [ -z "${KEEP:-}" ] && rm -rf "$WORK"; }
trap cleanup EXIT
PORT=$PORT HOST=127.0.0.1 VOTE_SECONDS=2 COUNTDOWN_MS=500 node "$ROOT/server/dist/src/index.js" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done

rc=0
(cd "$ROOT/mod" && "$LUA" test/sim_race.lua "$PORT" "$WORK" "${PROGRESS_B:-0}") || rc=$?
if [ $rc -ne 0 ]; then
  echo "--- server log"; tail -30 "$WORK/server.log"
  for n in Host Guest; do echo "--- $n ranked.log"; tail -40 "$WORK/$n/data/ranked.log" 2>/dev/null || true; done
fi
exit $rc
