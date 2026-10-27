# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A competitive speedrun race mod for Hades 2 — two to five players race the same seed/weapon/keepsake with a live rival HUD (it started as 1v1; plan.md still says so). See [plan.md](plan.md) for the original architecture and milestone roadmap (M0–M5), and [NOTES.md](NOTES.md) for what has actually been verified in the game, with sources — where they disagree, NOTES.md wins.

## Repository layout
- `mod/src/` — Lua mod loaded by Hell2Modding (H2M). No build step; raw Lua files. `main.lua` wires `client.lua` (protocol), `net.lua` (LuaSocket transport), `game.lua` (game hooks), `competitive.lua` + `profile.lua` (title-screen mode, maxed in-memory profile), the native UI (`board.lua` Race Board, `hud.lua` rival plate, `shadow.lua` shadow Melinoë, `banner.lua` countdown/result), `ui.lua` (ImGui debug window, F8) and `bot.lua` (in-game test bot, inactive unless `bot.json` exists).
- `mod/test/` — offline Lua tests, plus `h2m_sim.lua`, a fake H2M + toy game that loads the real `main.lua`.
- `server/` — Node.js + TypeScript TCP server (lobby relay, vote resolution, win/loss arbitration) and `mock-client.ts`, a scriptable opponent.
- `scripts/` — test gates and test-PC tooling (`scripts/bazzite/`).
- `local/` — git-ignored: game script dump, pinned packages, Lua 5.2 toolchain, test run logs.

## Common commands
- Server: `cd server && npm run build` then `npm start` (`PORT`, `HOST`, `VOTE_SECONDS`, ... env vars). Tests: `npm test`.
- Public server: Railway project `hades2-ranked-race` at `hopper.proxy.rlwy.net:16303` (TCP proxy), status page on its web domain (`STATUS_PORT` 8080). Redeploy: `scripts/railway-deploy.sh` (prints both addresses).
- Everything: `scripts/suite.sh` (offline gates) or `scripts/suite.sh --game` (adds real-game gates on the test PC). Every gate prints `RESULT: PASS|FAIL`.
- Mod: no build. `scripts/bazzite/push.sh` copies `mod/src/` and pinned dependencies into the test PC's instance roots.
- Player install (no mod manager): `install/install.sh` / `install/install.ps1` with the pins in `install/packages.txt`; see INSTALL.md. Keep the pins in step with `local/thunderstore` and the launch option `--rom_enabled true` documented.
- Thunderstore: `scripts/thunderstore-package.sh` (build + check the upload zip); publish with the manual GitHub Action "Thunderstore release" (dry run by default).
- After a race on the public server: `scripts/race-report.sh` (list) / `scripts/race-report.sh 1` (what each racer was offered, fairness verdict).
- Screenshots of a real race: `scripts/screenshot-tour.sh [host:port|local]` (frames in `local/runs/tour/`). Controller-only test: `scripts/e2e-pad.sh`.

## Test machine
- The Linux PC `bazzite` (`ssh bazzite.local`, Steam Game Mode, Proton 11). The Mac has no Hades II and H2M doesn't run on macOS.
- Tests use `~/h2r-testbed` there: reflink copies of the install and Proton prefix per instance, launched as systemd user units by `scripts/bazzite/instance.sh` with `/DirectLoadShell=false /RequireFocusToUpdate=false`. Never write to the owner's real install, prefix, saves or r2modman profile.
- Game scripts for the tested build are in `local/game-scripts/` (copied from the install); grep them instead of guessing function names.

## Architecture essentials
- **Two components, one protocol.** Each Hades 2 client holds one persistent connection to the server. All coordination (lobby state, votes, seed, progress, results) flows through newline-delimited JSON messages — `server/src/protocol.ts` is the authoritative list.
- **Server is the single source of truth** for lobby code generation, vote resolution, the RNG seed, race start time, and win/loss/draw determination. Clients only render and report.
- **Mod entry point is `mod/src/main.lua`.** Player-facing UI is native Hades UI built with the game's own screen functions (see NOTES.md "Native UI") and must work with a controller alone; the ImGui window (F8) is a debug tool. Object ids the mod keeps must live in `MapState` (map loads reuse ids).
- **Game-state hooks use ModUtil** (`modutil.mod.Path.Wrap`) against game globals read through `rom.game` (plugin envs only copy lowercase globals). Hooked functions live in Hades II's `RunLogic.lua`, `RoomLogic.lua`, `DeathLoopLogic.lua`, `RandomLogic.lua`, `KeepsakeLogic.lua`, `RewardLogic.lua` (not the Hades 1 `RunManager.lua`/`RoomManager.lua`).

## Hard constraints
- **Lua networking must be non-blocking.** LuaSocket comes from `require("socket")` (not `rom.socket`). Always `settimeout(0)` and poll inside the ImGui render callback. Synchronous I/O will freeze the game thread.
- **Lua 5.2.** Keep mod code 5.1–5.5 compatible (`goto` is a keyword; no integer division operator). Check with `local/tools/lua52/bin/luac -p`.
- **MVP transport is raw TCP + newline-delimited JSON**, not a real WebSocket handshake (despite the "WebSocket" framing in plan.md). The server speaks the same framing.
- **Defensive hooks.** Game patches rename Lua functions; check existence before wrapping so the mod degrades instead of crashing on update.
- **Seed determinism is verified only so far.** Rooms, encounters and offers matched for 8-10 depths with deliberately different choices (rank picks + per-depth reseeds, see NOTES.md "Same offers"); full runs and Ephyra's hub rooms past the first are untested. Debug drift with the per-race choice logs (`scripts/fetch-race-logs.sh`).
