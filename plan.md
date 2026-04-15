# Hades 2 Ranked Speedrunning Mod — Technical Plan

## Project Overview

A competitive 1v1 speedrunning mod for Hades 2, inspired by Minecraft Ranked Speedrunning. Two players race through identical runs (same RNG seed, weapon, keepsake) and can monitor each other's progress in real time. The MVP covers lobby creation, voting, synchronized starts, live progress tracking, and win/loss detection.

---

## Architecture

The project has two major components:

1. **Client Mod** — A Hell2Modding (H2M) Lua plugin that runs inside Hades 2. Handles UI, game-state hooks, and server communication.
2. **Backend Server** — A lightweight WebSocket server that manages lobbies, relays state, and enforces race logic. Written in a language of your choice (Node.js/TypeScript recommended for fast iteration; Python or Go also work).

```
┌──────────────────────┐         WebSocket          ┌──────────────────────┐
│     Player A         │◄──────────────────────────► │    Backend Server    │
│  (Hades 2 + Mod)     │                             │  (Lobby + Relay)     │
└──────────────────────┘                             └──────────┬───────────┘
                                                                │
┌──────────────────────┐         WebSocket                      │
│     Player B         │◄───────────────────────────────────────┘
│  (Hades 2 + Mod)     │
└──────────────────────┘
```

---

## Technology Stack & Key APIs

### Client (Lua mod via Hell2Modding)

| Capability | H2M API | Notes |
|---|---|---|
| **Overlay UI** | `ImGui.*` | Full Dear ImGui bindings. Used for lobby screen, voting UI, opponent progress HUD. Renders on top of the game. |
| **Networking** | `rom.socket` | LuaSocket library. Supports TCP sockets. You'll need to implement a lightweight WebSocket handshake in Lua or use raw TCP with a simple framing protocol. Alternatively, use HTTP long-polling via LuaSocket's `http` module. |
| **Game function hooking** | ModUtil (dependency) | `ModUtil.WrapBaseFunction`, `ModUtil.Override`, etc. Intercept any game Lua function. |
| **Game state access** | Global Lua tables | `CurrentRun`, `GameState`, `CurrentHero` etc. are all accessible. Weapons, rooms, boons, health, and run progress are readable. |
| **Config** | `rom.config` | Persistent user settings (server URL, keybinds, etc.). |
| **Logging** | `rom.log` | Debug output. |
| **Custom textures** | `rom.game.LoadPackages` / `rom.gpk` | Load custom `.pkg` files for any custom icons or UI art. |

### Backend Server

| Component | Recommendation | Notes |
|---|---|---|
| **Runtime** | Node.js + TypeScript | Fast to prototype. `ws` library for WebSocket. |
| **Protocol** | WebSocket | Bidirectional, low-latency. Each client holds one persistent connection. |
| **Data format** | JSON messages | Simple, debuggable. Each message has a `type` field. |
| **Hosting** | Any VPS or cloud (Fly.io, Railway, a personal server) | Very lightweight — even a $5/mo VPS handles hundreds of concurrent lobbies. |
| **Database (future)** | SQLite or PostgreSQL | Only needed for ELO/matchmaking later. MVP is stateless (in-memory lobbies). |

---

## Mod Structure (Thunderstore Package)

Use the official [Hades2ModTemplate](https://github.com/SGG-Modding/Hades2ModTemplate).

```
YourName-HadesRanked/
├── manifest.json            # Thunderstore metadata
├── icon.png                 # 256x256 mod icon
├── README.md
├── CHANGELOG.md
├── thunderstore.toml        # Build config
├── src/
│   ├── main.lua             # Entry point — registers callbacks, loads modules
│   ├── network.lua          # WebSocket/TCP client, message send/receive
│   ├── lobby.lua            # Lobby state machine (create, join, vote, ready)
│   ├── race.lua             # Race lifecycle (start, track progress, end)
│   ├── ui_lobby.lua         # ImGui lobby/voting screens
│   ├── ui_hud.lua           # ImGui in-game opponent progress overlay
│   ├── seed.lua             # RNG seed injection and management
│   └── config.lua           # User-configurable settings
└── data/                    # Optional custom .pkg textures
```

### Dependencies (in manifest.json)
- `Hell2Modding-Hell2Modding`
- `SGG_Modding-ModUtil`
- `SGG_Modding-SJSON` (if you need to edit game data files)
- `SGG_Modding-ENVY` (environment variable management)

---

## Feature Breakdown & Implementation Details

### 1. Entry Point — "Ranked Race" Access

**Goal:** Player can access the ranked race mode from within the game.

**Approach — ImGui overlay (recommended for MVP):**
Rather than modifying the title screen (which requires deep hooks into Supergiant's menu system and custom texture packages), use a hotkey-triggered ImGui overlay. This is how most H2M mods expose their UI.

- Register a hotkey (e.g., `F8` or a configurable key) in `main.lua`.
- When pressed, toggle the lobby ImGui window.
- The window acts as the full "Ranked Race" interface: connect to server, create/join lobby, vote, see results.

```lua
-- main.lua (simplified)
local Lobby = require("lobby")
local UI = require("ui_lobby")

local show_lobby = false

gui.add_imgui(function()
    if ImGui.IsKeyPressed(ImGuiKey.F8) then
        show_lobby = not show_lobby
    end
    if show_lobby then
        UI.Draw(Lobby.state)
    end
end)
```

**Future enhancement:** Hook into the main menu Lua (`UIScripts`, `DeathLoopData`, `ScreenScripts`) to add a native-looking menu button. This requires reverse-engineering the game's screen creation functions via ModUtil, which is a significant effort best deferred past MVP.

---

### 2. Backend Server — Lobby System

**Lobby lifecycle:**

```
[WAITING]  →  player joins  →  [FULL]  →  voting complete  →  [STARTING]  →  countdown  →  [RACING]  →  result  →  [FINISHED]
```

**Message protocol (JSON over WebSocket):**

#### Client → Server
| Type | Payload | When |
|---|---|---|
| `create_lobby` | `{}` | Player creates a new lobby |
| `join_lobby` | `{ code: "ABCD" }` | Player joins with a code |
| `vote_weapon` | `{ weapon: "WeaponStaffSwing" }` | During weapon vote phase |
| `vote_keepsake` | `{ keepsake: "SilverWheelTrait" }` | During keepsake vote phase |
| `ready` | `{}` | Player confirms ready after votes resolve |
| `progress_update` | `{ room: "F_Boss01", depth: 12, hp: 150, time: 94.5, alive: true }` | Every ~2 seconds during race |
| `run_complete` | `{ time: 312.7, victory: true }` | Player finishes or dies |

#### Server → Client
| Type | Payload | When |
|---|---|---|
| `lobby_created` | `{ code: "ABCD" }` | After create |
| `lobby_joined` | `{ opponent: "PlayerName" }` | Other player joined |
| `vote_phase` | `{ phase: "weapon", options: [...], timer: 15 }` | Start of vote phase |
| `vote_result` | `{ phase: "weapon", selected: "WeaponStaffSwing" }` | After vote resolves |
| `race_start` | `{ seed: 123456789, weapon: "...", keepsake: "...", countdown: 3 }` | Initiate the run |
| `opponent_progress` | `{ room: "...", depth: 8, hp: 200, time: 61.2, alive: true }` | Relay of opponent's state |
| `race_result` | `{ winner: "PlayerA", reason: "completed_first" }` | Race over |
| `error` | `{ message: "Lobby not found" }` | Any error |

**Lobby code:** Generate a random 4-character alphanumeric code (e.g., `ABCD`). Store lobbies in an in-memory `Map<string, Lobby>`. Clean up lobbies after 30 minutes of inactivity.

**Seed generation:** The server generates a random integer seed when the race starts. Both clients receive the same seed. This is the single source of truth for RNG.

---

### 3. Voting System

**Weapon vote:**
- Server sends `vote_phase` with `phase: "weapon"` and the full list of available weapons (or the client knows the list and server just signals the phase).
- Each player selects a weapon. The server waits up to 15 seconds.
- If both vote for the same weapon, that weapon is used. If they vote for different weapons, the server randomly picks one of the two. If a player doesn't vote, a random weapon from the full pool is selected.
- Server broadcasts `vote_result`.

**Keepsake vote:**
- Same flow, `phase: "keepsake"`.
- Both players use the same keepsake for a fair race.

**ImGui voting UI:**
```lua
-- ui_lobby.lua (pseudocode)
function DrawVotePhase(phase, options)
    ImGui.Begin("Vote: " .. phase)
    for i, opt in ipairs(options) do
        if ImGui.Button(opt.display_name, 200, 40) then
            Network.send({ type = "vote_" .. phase, [phase] = opt.id })
            voted = true
        end
    end
    if voted then
        ImGui.Text("Waiting for opponent...")
    end
    ImGui.End()
end
```

---

### 4. Seed Injection & Synchronized Starts

**How Hades 2 RNG works:**
- Hades games use a seeded PRNG. The `CurrentRun` table contains the seed and RNG state.
- From the Hades 1 modding community (HadesRoutingModPack), we know the game exposes `RandomSeed` and RNG functions that can be hooked.
- In Hades 2, the run's random seed is set during run initialization.

**Approach:**
- Use ModUtil to hook into the run-start function (likely `StartNewRun` or equivalent — inspect the game scripts in `Content/Scripts/RunManager.lua` and `RoomManager.lua`).
- Before the run's RNG is initialized, override the seed value with the one received from the server.

```lua
-- seed.lua (pseudocode)
local forced_seed = nil

function SetForcedSeed(seed)
    forced_seed = seed
end

-- Hook into run initialization
ModUtil.WrapBaseFunction("StartNewRun", function(base, prevRun, args)
    if forced_seed then
        -- Override the random seed before the run begins
        args = args or {}
        args.Seed = forced_seed
        forced_seed = nil  -- only force once
    end
    return base(prevRun, args)
end, YourMod)
```

**Key investigation needed:** You'll need to inspect the game's Lua scripts to find the exact function and parameter name for seeding. The game scripts are located at `<Hades2>/Content/Scripts/`. Key files to examine:
- `RunManager.lua` — run initialization
- `RoomManager.lua` — room generation and progression
- `RandomData.lua` or similar — RNG configuration
- `HeroData.lua` — player/weapon setup

**Weapon and keepsake forcing:**
Similarly, hook into the weapon/keepsake selection logic to override the player's choices with the server-dictated ones. Look for functions like `EquipWeaponAndLoadAmmo`, `EquipKeepsake`, or the pre-run setup screen logic.

**Synchronized countdown:**
After both players send `ready`, the server sends `race_start` with a `start_at` UTC timestamp (or a countdown). Both clients display a 3-2-1 countdown overlay and then trigger the run start simultaneously.

---

### 5. In-Game Progress Tracking & Opponent HUD

**Tracking local progress:**
Hook into room-transition functions to detect when the player enters a new room. Read the room name, biome, depth, and player HP from the game's Lua state.

```lua
-- race.lua (pseudocode)
ModUtil.WrapBaseFunction("LeaveRoom", function(base, run, door)
    local result = base(run, door)

    -- Send progress to server
    Network.send({
        type = "progress_update",
        room = CurrentRun.CurrentRoom.Name,
        depth = CurrentRun.RunDepthCache,
        hp = CurrentRun.Hero.Health,
        time = GetTimeSinceRaceStart(),
        alive = true,
    })

    return result
end, YourMod)
```

**Detecting run completion:**
- Hook into the victory function (killing the final boss triggers a specific script — look for `EndBossPresentation` or `CompleteQuestObjective` in the Scripts).
- Hook into the death function (`HandleHeroDeath` or `KillHero`) to detect a player dying.

**Displaying opponent progress (ImGui HUD):**
Render a small, non-intrusive overlay during gameplay showing the opponent's status.

```lua
-- ui_hud.lua (pseudocode)
function DrawOpponentHUD(opponent)
    ImGui.SetNextWindowPos(10, 10, ImGuiCond.Always)
    ImGui.SetNextWindowSize(250, 100)
    ImGui.Begin("Opponent", nil,
        ImGuiWindowFlags.NoResize |
        ImGuiWindowFlags.NoMove |
        ImGuiWindowFlags.NoCollapse |
        ImGuiWindowFlags.NoTitleBar)

    if opponent.alive then
        ImGui.TextColored(0.3, 1.0, 0.3, 1.0, "OPPONENT: ALIVE")
    else
        ImGui.TextColored(1.0, 0.3, 0.3, 1.0, "OPPONENT: DEAD")
    end
    ImGui.Text("Room: " .. (opponent.room or "???"))
    ImGui.Text("Depth: " .. (opponent.depth or 0))
    ImGui.Text("HP: " .. (opponent.hp or 0))
    ImGui.Text("Time: " .. string.format("%.1fs", opponent.time or 0))

    ImGui.End()
end
```

---

### 6. Win/Loss Detection

**Rules:**
1. First player to complete the run wins.
2. If a player dies, the other player must still finish to win. If the surviving player also dies, it's a draw.
3. If both players are still alive, it's a pure speed race.

**Server-side logic:**
```
on "run_complete" from Player A:
    if A.victory == true:
        if B already sent run_complete:
            → A wins (faster completion)
        else:
            → A wins (first to finish)
            → notify B that opponent finished

    if A.victory == false (A died):
        if B already died:
            → DRAW
        else:
            → B must finish to win, otherwise draw
            → set timeout (e.g., 15 min) to auto-draw
```

---

## Networking Implementation in Lua

LuaSocket is available via `rom.socket`, but it is blocking by default. In a game mod you cannot block the main thread. Options:

### Option A: Non-blocking TCP with custom framing (recommended for MVP)
```lua
local socket = require("socket")

local tcp = socket.tcp()
tcp:settimeout(0)  -- non-blocking
tcp:connect(SERVER_HOST, SERVER_PORT)

-- Poll every frame in ImGui callback
function PollNetwork()
    local data, err, partial = tcp:receive("*l")
    if data then
        local msg = json.decode(data)
        HandleMessage(msg)
    end
end

function Send(msg)
    tcp:send(json.encode(msg) .. "\n")
end
```

Use newline-delimited JSON over raw TCP. The server also speaks this protocol.

### Option B: HTTP polling
Use `socket.http` to poll the server every 1-2 seconds. Higher latency but simpler. Acceptable for lobby/voting phases, not ideal for live progress updates.

### Option C: WebSocket in Lua
There are pure-Lua WebSocket client implementations that work with LuaSocket. This is the cleanest solution but requires bundling a Lua WebSocket library with your mod. Search for `lua-websockets` or implement the RFC 6455 handshake manually (it's straightforward for a client).

**Recommendation:** Start with Option A (non-blocking TCP + newline JSON). It's the simplest path to a working prototype. Your server can trivially handle this with Node.js `net.createServer`. Upgrade to WebSocket later if you need browser-based spectating or a web dashboard.

---

## Development Workflow (Mac + Steam Deck)

Since you're developing on Mac and testing on Steam Deck:

1. **Write Lua code on Mac** in VS Code. The mod is pure Lua text files — no compilation needed.
2. **Write and run the backend server on Mac** (or deploy to a cloud VPS). The server is platform-independent.
3. **Transfer mod files to Steam Deck** via one of:
   - **Git:** Push to a private repo, pull on Steam Deck (Desktop Mode has a terminal).
   - **SSH/SCP:** `scp -r src/ deck@steamdeck:/path/to/mod/` (enable SSH on Deck in Desktop Mode).
   - **Syncthing:** Continuous sync between Mac and Deck.
   - **USB drive / SD card:** Manual but simple.
4. **Test on Steam Deck** using r2modman installed in Desktop Mode. Create a symlink from your synced mod folder to the r2modman plugins directory.
5. **For two-player testing**, you'll need two Hades 2 installations. Options:
   - Two Steam accounts with Hades 2.
   - One account on Steam Deck + one via Family Sharing on another machine (or a friend).
   - For basic protocol testing, write a mock client in Python/Node that simulates the other player.

---

## Milestone Plan

### M0: Foundation (Week 1-2)
- [ ] Set up the mod project using Hades2ModTemplate
- [ ] Get a basic ImGui window rendering in-game (hello world)
- [ ] Set up the backend server project with WebSocket/TCP support
- [ ] Implement basic message protocol (connect, echo)
- [ ] Establish non-blocking TCP connection from mod to server

### M1: Lobbies (Week 3-4)
- [ ] Implement create/join lobby on server
- [ ] Build ImGui lobby UI (create button → shows code; join with text input)
- [ ] Display lobby state (waiting, opponent joined)
- [ ] Handle disconnections gracefully

### M2: Voting (Week 5-6)
- [ ] Research game scripts to enumerate weapons and keepsakes programmatically
- [ ] Implement voting protocol (server-side vote resolution)
- [ ] Build ImGui voting UI with weapon/keepsake selection
- [ ] Display vote results

### M3: Seed Injection & Run Start (Week 7-8)
- [ ] Deep-dive into `RunManager.lua`, `RoomManager.lua` to find seed injection point
- [ ] Implement `ModUtil.WrapBaseFunction` hook to override seed
- [ ] Implement weapon/keepsake forcing hooks
- [ ] Synchronized countdown and run start
- [ ] Verify two clients with the same seed get identical room layouts and boon offerings

### M4: Progress Tracking & HUD (Week 9-10)
- [ ] Hook room transitions to capture progress data
- [ ] Implement progress update sending (throttled to every ~2 seconds)
- [ ] Build opponent HUD overlay
- [ ] Hook death and victory events for run completion detection

### M5: Race Results & Polish (Week 11-12)
- [ ] Implement server-side win/loss/draw logic
- [ ] Display race result screen
- [ ] Handle edge cases (disconnect mid-race, reconnection, server timeout)
- [ ] Test end-to-end on Steam Deck with two players
- [ ] Publish to Thunderstore

### Future: ELO & Matchmaking
- Add user accounts (Steam ID or simple username/password)
- Persist match results to a database
- Implement ELO rating calculation
- Add a matchmaking queue (instead of manual lobby codes)
- Leaderboard web page

---

## Key Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **RNG seed doesn't fully determine the run** — some randomness may come from sources other than the main seed (e.g., timing-based events, enemy AI variance). | Runs might diverge despite same seed. | Test extensively. If divergence occurs, identify the secondary RNG sources and hook/override them too. Accept minor AI variance as part of the competition (same as Minecraft speedrun ranked). |
| **Game updates break hooks** — Supergiant patches can rename or restructure Lua functions. | Mod breaks on update. | Pin to a specific game version for competitive play. Join the H2M modding Discord for early patch notes. Use defensive coding (check if functions exist before hooking). |
| **LuaSocket blocking** — If the non-blocking socket setup is unreliable, network calls could freeze the game. | Game stutters or hangs. | Always use `settimeout(0)`. Poll in the ImGui render callback (which runs every frame). Never do synchronous I/O. |
| **Anti-cheat concerns** — Players could modify the mod or fake progress updates. | Unfair races. | MVP doesn't need anti-cheat. For ranked, validate progress server-side (e.g., room transitions must be sequential, times must be plausible). Consider requiring a specific mod version hash. |
| **Two-player testing is awkward** — Needs two game copies. | Slow development. | Build a CLI mock client early that simulates a second player. Use it for 90% of testing. |

---

## Key Files to Investigate in the Game

Before writing hooks, you'll need to read these game scripts (located in `<Hades2>/Content/Scripts/`):

| File | What to look for |
|---|---|
| `RunManager.lua` | `StartNewRun`, `StartNewRunFromLobby`, run initialization, seed parameter |
| `RoomManager.lua` | `DoRoomTransition`, `LeaveRoom`, `StartRoom` — room progression events |
| `HeroData.lua` | `CurrentRun.Hero`, health tracking, equipped weapon/keepsake |
| `WeaponData.lua` | List of all weapons and their internal names |
| `TraitData.lua` | List of all keepsakes (traits) and internal names |
| `DeathLoopData.lua` | Run end conditions, death handling |
| `UIScripts.lua` / `ScreenScripts.lua` | Main menu and screen management (for future native menu integration) |
| `RandomData.lua` or similar | RNG utilities, seed format |
| `CombatManager.lua` | Boss encounter handling, victory detection |

Access these by navigating to your Hades 2 install directory. On Steam Deck: right-click Hades 2 → Manage → Browse Local Files → Content → Scripts.

---

## Reference Links

- **Hades 2 Mod Wiki:** https://sgg-modding.github.io/Hades2ModWiki/
- **Hell2Modding GitHub:** https://github.com/SGG-Modding/Hell2Modding
- **Mod Template:** https://github.com/SGG-Modding/Hades2ModTemplate
- **H2M ImGui API:** https://sgg-modding.github.io/Hades2ModWiki/docs/h2m-docs/tables/ImGui
- **rom.socket (LuaSocket):** https://tst2005.github.io/lua-socket/socket.html
- **ModUtil:** https://thunderstore.io/c/hades-ii/p/SGG_Modding/ModUtil/
- **Thunderstore (Hades 2):** https://thunderstore.io/c/hades-ii/
- **Hades 1 RNG Routing Mod (reference):** https://github.com/Museus/HadesRoutingModPack
- **Modding Discord:** https://discord.gg/KuMbyrN
