#!/usr/bin/env bash
# Full test suite. Offline gates always run; real-game gates (test PC) with --game.
# Each gate must print a RESULT line; a gate with no RESULT line counts as FAIL.
# Mutation twins must FAIL (their RESULT is inverted).
#   scripts/suite.sh            offline only (~1 min)
#   scripts/suite.sh --game     + real game on the test PC (~30 min, runs one game gate at a time)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/local/runs/suite-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG"
GAME=0
[ "${1:-}" = "--game" ] && GAME=1
declare -a NAMES RESULTS

gate() { # name expect(PASS|FAIL) command...
  local name=$1 expect=$2; shift 2
  local out="$LOG/$name.log"
  printf '%-34s ' "$name"
  "$@" >"$out" 2>&1
  local line
  line=$(grep -E '^RESULT: (PASS|FAIL)' "$out" | tail -1)
  local got=${line#RESULT: }; got=${got%% *}
  [ -z "$got" ] && got=NONE
  local verdict=FAIL
  [ "$got" = "$expect" ] && verdict=PASS
  NAMES+=("$name"); RESULTS+=("$verdict")
  echo "$verdict (gate printed ${got}, expected ${expect})"
}

server_tests() {
  (cd "$ROOT/server" && npm test) || { echo "RESULT: FAIL"; return; }
  echo "RESULT: PASS"
}
lua_tests() {
  (cd "$ROOT/mod" && "$ROOT/local/tools/lua52/bin/lua" test/run.lua) && echo "RESULT: PASS" || echo "RESULT: FAIL"
}

gate server-unit+tcp PASS server_tests
gate lua-unit-5.2 PASS lua_tests
gate protocol-lua-vs-node PASS "$ROOT/scripts/test-protocol.sh"
gate sim-two-clients PASS "$ROOT/scripts/test-sim.sh"
gate sim-twin-no-depth-seed FAIL env MUTATE=no_depth_seed "$ROOT/scripts/test-sim.sh"
if [ $GAME -eq 1 ]; then
  gate game-vs-mock-win PASS "$ROOT/scripts/e2e-vs-mock.sh" game_wins 2
  gate game-vs-mock-die PASS "$ROOT/scripts/e2e-vs-mock.sh" game_dies 2
  gate game-competitive-title-to-race PASS env COMPETITIVE=1 "$ROOT/scripts/e2e-vs-mock.sh" game_wins 2
  # Two real clients in competitive mode, B deliberately taking other doors and boons:
  # rooms, seeds, mirroring, encounters, enemy rosters and spawn order must still match.
  gate game-two-clients-diverging PASS env COMPETITIVE=1 DIVERGE=1 "$ROOT/scripts/e2e-two-games.sh" 5
  gate game-two-clients-same-rooms PASS bash -c "grep -q 'DETERMINISM: SAME' \"\$(ls -td '$ROOT'/local/runs/*-two | head -1)/compare.txt\" && echo 'RESULT: PASS' || echo 'RESULT: FAIL'"
  # Native Race Board: both clients type the same code on its keys, vote and ready
  # through it; the rival plate and shadow must render (bot overlay checks).
  gate game-two-clients-board-by-code PASS env COMPETITIVE=1 BOARD=1 CODE=1 OVERLAY=1 "$ROOT/scripts/e2e-two-games.sh" 3
  # Real controller input: a virtual gamepad drives the board (Find Match, D-pad
  # vote, Ready) against a mock rival.
  gate game-controller-race PASS "$ROOT/scripts/e2e-pad.sh" 2
  gate game-controller-closes-overlay PASS "$ROOT/scripts/e2e-overlay-pad.sh"
  gate game-quit-and-reenter PASS "$ROOT/scripts/e2e-reenter.sh"
  gate game-crossroads-setup PASS env COMPETITIVE=1 PROBE_PREP=1 "$ROOT/scripts/e2e-two-games.sh" 2
  # Mutation twin: per-depth seeding off, same divergent choices -> rooms must differ.
  # A real comparison must report DIFFERENT (FAIL is what the twin expects); no
  # comparison at all prints no RESULT, which the scorer counts as a failure.
  gate twin-no-depth-seed-must-differ FAIL env COMPETITIVE=1 DIVERGE=1 MUTATE=no_depth_seed bash -c "'$ROOT/scripts/e2e-two-games.sh' 5 >/dev/null 2>&1; c=\"\$(ls -td '$ROOT'/local/runs/*-two | head -1)/compare.txt\"; grep -q 'DETERMINISM: DIFFERENT' \"\$c\" && echo 'RESULT: FAIL'; grep -q 'DETERMINISM: SAME' \"\$c\" && echo 'RESULT: PASS'; true"
fi
pass=0; fail=0
for r in "${RESULTS[@]}"; do [ "$r" = PASS ] && pass=$((pass + 1)) || fail=$((fail + 1)); done
echo "suite: $pass passed, $fail failed (logs: $LOG)"
[ $fail -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
