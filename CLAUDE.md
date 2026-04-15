# Hades 2 Ranked Speedrun Mod

See plan.md for full architecture, message protocol, and milestones.

## Structure
- mod/src/ — Lua mod for Hell2Modding (Hades 2 mod loader)
- server/ — Node.js + TypeScript WebSocket backend

## Mod (Lua)
- Uses ImGui for overlay UI, rom.socket (LuaSocket) for networking,
  ModUtil for game function hooking
- Entry point: mod/src/main.lua
- No build step — raw Lua files

## Server
- TypeScript, `ws` library for WebSocket
- Build: npm run build | Run: npm start
- Newline-delimited JSON protocol (see plan.md for message types)

## Key constraints
- Lua networking MUST use settimeout(0) — never block the game thread
- MVP uses ImGui overlay on hotkey (F8), not native menu injection
- Game script files (RunManager.lua etc.) need manual investigation
  on Steam Deck — we don't have them here
