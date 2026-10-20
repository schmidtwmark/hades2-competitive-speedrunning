# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A competitive 1v1 speedrun mod for Hades 2 — two players race the same seed/weapon/keepsake with a live opponent HUD. See [plan.md](plan.md) for the original architecture and milestone roadmap (M0–M5), and [NOTES.md](NOTES.md) for what has actually been verified in the game, with sources — where they disagree, NOTES.md wins.

## Repository layout
- `mod/src/` — Lua mod loaded by Hell2Modding (H2M). No build step; raw Lua files. `main.lua` wires `client.lua` (protocol), `net.lua` (LuaSocket transport), `ui.lua` (ImGui), `game.lua` (game hooks) and `bot.lua` (in-game test bot, inactive unless `bot.json` exists).
- `mod/test/` — offline Lua tests, plus `h2m_sim.lua`, a fake H2M + toy game that loads the real `main.lua`.
- `server/` — Node.js + TypeScript TCP server (lobby relay, vote resolution, win/loss arbitration) and `mock-client.ts`, a scriptable opponent.
- `scripts/` — test gates and test-PC tooling (`scripts/bazzite/`).
- `local/` — git-ignored: game script dump, pinned packages, Lua 5.2 toolchain, test run logs.

## Common commands
- Server: `cd server && npm run build` then `npm start` (`PORT`, `HOST`, `VOTE_SECONDS`, ... env vars). Tests: `npm test`.
- Everything: `scripts/suite.sh` (offline gates) or `scripts/suite.sh --game` (adds real-game gates on the test PC). Every gate prints `RESULT: PASS|FAIL`.
- Mod: no build. `scripts/bazzite/push.sh` copies `mod/src/` and pinned dependencies into the test PC's instance roots.

## Test machine
- The Linux PC `bazzite` (`ssh bazzite.local`, Steam Game Mode, Proton 11). The Mac has no Hades II and H2M doesn't run on macOS.
- Tests use `~/h2r-testbed` there: reflink copies of the install and Proton prefix per instance, launched as systemd user units by `scripts/bazzite/instance.sh` with `/DirectLoadShell=false /RequireFocusToUpdate=false`. Never write to the owner's real install, prefix, saves or r2modman profile.
- Game scripts for the tested build are in `local/game-scripts/` (copied from the install); grep them instead of guessing function names.

## Architecture essentials
- **Two components, one protocol.** Each Hades 2 client holds one persistent connection to the server. All coordination (lobby state, votes, seed, progress, results) flows through newline-delimited JSON messages — `server/src/protocol.ts` is the authoritative list.
- **Server is the single source of truth** for lobby code generation, vote resolution, the RNG seed, race start time, and win/loss/draw determination. Clients only render and report.
- **Mod entry point is `mod/src/main.lua`.** UI is an ImGui overlay toggled by hotkey (F8) — *not* native menu injection. Native menu work is explicitly deferred past MVP.
- **Game-state hooks use ModUtil** (`modutil.mod.Path.Wrap`) against game globals read through `rom.game` (plugin envs only copy lowercase globals). Hooked functions live in Hades II's `RunLogic.lua`, `RoomLogic.lua`, `DeathLoopLogic.lua`, `RandomLogic.lua`, `KeepsakeLogic.lua`, `RewardLogic.lua` (not the Hades 1 `RunManager.lua`/`RoomManager.lua`).

## Hard constraints
- **Lua networking must be non-blocking.** LuaSocket comes from `require("socket")` (not `rom.socket`). Always `settimeout(0)` and poll inside the ImGui render callback. Synchronous I/O will freeze the game thread.
- **Lua 5.2.** Keep mod code 5.1–5.5 compatible (`goto` is a keyword; no integer division operator). Check with `local/tools/lua52/bin/luac -p`.
- **MVP transport is raw TCP + newline-delimited JSON**, not a real WebSocket handshake (despite the "WebSocket" framing in plan.md). The server speaks the same framing.
- **Defensive hooks.** Game patches rename Lua functions; check existence before wrapping so the mod degrades instead of crashing on update.
- **Seed determinism is verified only so far.** Two real clients with the same race seed matched for 7 rooms on slightly different saves; the mod re-seeds before `InitializeRewardStores` and `ChooseStartingRoom` because `StartNewRun` draws save-dependent randomness first. Saves with very different progress and full runs are untested.
