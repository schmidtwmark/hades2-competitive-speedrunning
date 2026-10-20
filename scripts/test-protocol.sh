#!/usr/bin/env bash
# Cross-language protocol test: Lua 5.2 + LuaSocket client (the mod's code)
# vs the real Node server vs a Node mock bot. Prints RESULT: PASS or FAIL.
#
# Needs Lua 5.2 with LuaSocket. Defaults to the copy built in local/tools/lua52
# (see NOTES.md "Tooling"); override with LUA52_HOME.
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
cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

PORT=$PORT HOST=127.0.0.1 VOTE_SECONDS=3 COUNTDOWN_MS=1000 node "$ROOT/server/dist/src/index.js" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done

run_case() {
  local name=$1 lua_outcome=$2 bot_outcome=$3 lua_after=$4 bot_after=$5
  rm -f "$WORK/code"
  node "$ROOT/server/dist/src/mock-client.js" --port "$PORT" --name Bot --join-file "$WORK/code" \
    --outcome "$bot_outcome" --finish-after "$bot_after" --progress-every 0.5 --timeout 40 --quiet >"$WORK/bot-$name.log" 2>&1 &
  local bot=$!
  local lua_rc=0
  (cd "$ROOT/mod" && "$LUA" test/integration.lua "$PORT" "$WORK/code" "$lua_outcome" "$lua_after") >"$WORK/lua-$name.log" 2>&1 || lua_rc=$?
  local bot_rc=0
  wait "$bot" || bot_rc=$?
  local lua_res bot_res
  lua_res=$(grep '^RESULT:' "$WORK/lua-$name.log" || echo "RESULT: FAIL no result line")
  bot_res=$(grep '^RESULT:' "$WORK/bot-$name.log" || echo "RESULT: FAIL no result line")
  echo "case $name: lua -> $lua_res"
  echo "case $name: bot -> ${bot_res:0:200}"
  if [ $lua_rc -ne 0 ] || [ $bot_rc -ne 0 ] || [[ "$lua_res" != "RESULT: PASS"* ]]; then
    echo "--- lua log"; tail -20 "$WORK/lua-$name.log"; echo "--- server log"; tail -20 "$WORK/server.log"
    return 1
  fi
}

fail=0
run_case lua_wins win none 2 0 || fail=1
run_case bot_wins die win 1 3 || fail=1
if [ $fail -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
