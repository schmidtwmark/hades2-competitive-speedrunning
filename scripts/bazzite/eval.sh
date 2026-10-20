#!/usr/bin/env bash
# Run Lua inside the live game instance (test mode only) and print the result.
#   scripts/bazzite/eval.sh [A|B] 'return G.CurrentRun.CurrentRoom.Name'
# The code runs in a game coroutine with G = game globals, game = our Game object.
set -euo pipefail
X="${1:-A}"; CODE="${2:?lua code}"
HOST="${BAZZITE:-bazzite.local}"
D='h2r-testbed/rom-'"$X"'/ReturnOfModding/plugins_data/schmidtwmark-RankedRace'
ssh "$HOST" "rm -f $D/eval.out; cat > $D/eval.lua.tmp && mv $D/eval.lua.tmp $D/eval.lua" <<<"$CODE"
for _ in $(seq 60); do
  if ssh "$HOST" "grep -q -- '--END--' $D/eval.out 2>/dev/null"; then ssh "$HOST" "sed '\$d' $D/eval.out"; exit 0; fi
  sleep 0.5
done
echo "eval: no answer (is the instance running with bot.json?)"; exit 1
