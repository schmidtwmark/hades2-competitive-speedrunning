# Working notes

Running log of what was tried, what happened, and where each fact came from.
Observations, derivations, guesses and unknowns are kept in separate lists
(coop-anything rule 4). Private machine details (paths with usernames, dumps,
logs, downloaded packages) live in `local/`, which git ignores.

## Game identity

Tested build (details in `local/identity.md`): Hades II Steam build 25481925,
`Hades2.exe` SHA-256 `a6be16e9…9c30dc`, Proton 11.0-100 in SteamLinuxRuntime_4,
Bazzite 44 in Game Mode (gamescope). Hell2Modding 1.0.117. Script facts below
were re-checked against this build's own `Content/Scripts` (copied to `local/game-scripts`).

## Status

| Piece | State | Evidence |
|---|---|---|
| Server: lobbies of 2-5, host start, plurality votes, places, win/loss/draw, reconnect, Find Match, race by code, version check | built | `cd server && npm test`: 62 pass |
| Mod: JSON, protocol client, UI, Race Board pages, rival plate, several rivals | built | `cd mod && lua test/run.lua`: 51 pass (Lua 5.2.4) |
| Mod: LuaSocket client vs real server | built | `scripts/test-protocol.sh`: PASS |
| Mod in a simulated game (2 clients) | built | `scripts/test-sim.sh`: PASS; 5 mutations each FAIL |
| **Real game: mod loads, all hooks found** | verified | LogOutput.log: "game: hooks installed", no missing targets |
| **Real game vs mock opponent** | verified | `scripts/e2e-vs-mock.sh game_wins` and `game_dies`: PASS |
| **Two real game clients race** | verified | `scripts/e2e-two-games.sh 3`: both bots PASS, survivor_finished |
| **Same seed -> same rooms (two different save copies)** | verified for 7 rooms | traces identical: room, per-room seed, encounter, reward, boon offered (incl. a shop) |
| **Competitive mode: title entry, maxed profile, no saves** | verified | `COMPETITIVE=1 scripts/e2e-vs-mock.sh`: profile checks + 11 save files byte-identical |
| **Diverging choices -> same rooms/enemies/spawn order** | verified for 7 depths | `COMPETITIVE=1 DIVERGE=1 scripts/e2e-two-games.sh` |
| Determinism check can fail | checked | `MUTATE=no_seed`: "seed applied" FAILs, rooms diverge from room 3 (rooms 1-2 are forced intro rooms) |
| **Native Race Board drives the whole lobby (two real clients)** | verified | `BOARD=1 CODE=1 OVERLAY=1 COMPETITIVE=1 scripts/e2e-two-games.sh 3`: both typed the same code on the on-screen keys, voted on icon grids, readied; plate + shadow checks ok; captures in local/runs/tour |
| **Real controller input** | verified | `scripts/e2e-pad.sh`: virtual gamepad presses only (A, D-pad) -> Find Match, weapon vote Right Right A = WeaponTorch (the run started with it), Ready; run won |
| Rival plate, shadow Melinoë, VICTORY/DEFEAT banners in game | verified | captures (local/runs/tour); bot checks: plate built per map, shadow placed with 0 error |
| **Same offers despite different choices** | verified | `COMPETITIVE=1 DIVERGE=1 BOARD=1 READY_VIA_DOOR=true scripts/e2e-two-games.sh 9`: racers took different doors and boons at most depths; rooms, encounters (incl. Arachne), door rewards and gods, boon offers and well stock identical through depth 8 (`compare-race-logs.py`: SEEDING SAME). A 10-room run differed at one door at one depth (a reward one racer's history ruled out), then matched again |
| **Routes: Underworld, Surface, Dream Dive** | verified | Ready at each route's Crossroads exit ("Ready to Race"); Surface starts in Ephyra with identical hub doors; Dream Dive: same seeded dream biome (Summit) and rooms through depth 6, race decided. The test bot can't clear Ephyra's pylon rooms yet |
| **Race Menu, chat, death sequence, welcome** | verified | `PAD_SCENARIO=forfeit scripts/e2e-pad.sh`: Start -> Race Menu -> Forfeit Race -> confirm, pad presses only; bots' chat lines delivered both ways and shown in the feed; a death plays the game's death animation, then home and the results; welcome page and chat page checked in captures |
| **Races of more than two (two real clients + two mock racers)** | verified | `MOCKS=2 COMPETITIVE=1 BOARD=1 OVERLAY=1 scripts/e2e-two-games.sh 3` (via `MOCKS=2 scripts/screenshot-tour.sh local`): 4-racer private lobby, host pressed Start Race on the board, same seed for all four, plate with three coloured rows, shadows placed, standings table on both results screens, winner completed_first |
| **Full suite** | green | `scripts/suite.sh --game`: 9/9 gates (2026-10-20) |

"Win" in the real-game tests calls the game's own `RecordRunCleared` (what the
clear screen calls after Chronos/Typhon); beating a final boss is not exercised.
The two save copies differed only by a few test deaths/runs; far-apart saves are untested.

## Real-game findings (verified on the tested build)

- `/DirectLoadShell=false` skips the title screen and continues the active profile (the
  default argument list has `/DirectLoadShell=true`). Engine config options take `/Name=Value`.
- `/RequireFocusToUpdate=false` is required for headless test instances: otherwise game-time
  coroutines (`wait`) stall when the window isn't focused, while ImGui callbacks keep running.
- Under SSH, the game must run in its own systemd user unit (`systemd-run --user`); started from
  the SSH session it is killed when the session ends.
- In the hub, `CurrentRun.CurrentRoom` still names the last run room and `Hero.IsDead` stays true;
  the hub map is `CurrentHubRoom.Name` (set on arrival, cleared by `StartOver`).
- Encounters can wait for the hero to reach an `EncounterStartPoint`; rewards (boons) are
  `MapState.RoomRequiredObjects` that block the exits until used; using one goes through the
  `OnUsed` path (`CallFunctionName(obj.OnUsedFunctionName, obj, obj.OnUsedFunctionArgs, hero)`),
  first-meeting god dialogue waits for `NarrativeLineNextInput`, the boon screen is
  `ScreenAnchors.ChoiceScreen` and `HandleUpgradeChoiceSelection(screen, button)` picks.
- `RandomInit` never clears `NextSeeds`; `StartNewRun` draws save-dependent randomness
  (`GetRandomUnequippedWeapon(prevRun)`) before `InitializeRewardStores` and `ChooseStartingRoom`,
  so the mod re-seeds right before each of those.
- Keepsake rank 3 = "Epic" (`TraitRarityData.RarityUpgradeOrder`).
- Hot reload needs in-place writes (`rsync --inplace`).
- An earlier attempt's r2modman profile (June 13, older game build) crashed with an access
  violation inside its d3d12.dll. Not reproduced with H2M 1.0.117 on this build.

## Competitive mode (title screen, maxed profile, no saves) — verified on the tested build

- The main menu is engine C++ (`sgg::MainMenuScreen`); layout comes from `Content/Game/GUI/MainMenuScreen.sjson`,
  behaviour from per-button `eastl::function` callbacks bound by component name in the constructor. Lua does
  not run on the title screen (H2M's Lua callbacks ride `ScriptManager::Update`).
- The hidden `AnnouncementButton`'s only callback target is `MainMenuScreen::OpenPatchNotes` (rva 0x16cda0;
  sole caller is that lambda thunk at 0x16eb80). The mod relabels the button via `rom.data.on_sjson_read_as_string`
  (MainMenuScreen.sjson + ShellText.*.sjson) and hooks the function with `rom.memory.dynamic_hook`, found by a
  unique 32-byte signature (no hook if the signature is missing).
- From that hook: `LoadMapInternal({Name="Hub_PreRun"})` (Lua `LoadMap` wait()s, no coroutine there), then
  `MenuScreen::ExitScreen(menu)` (rva 0x140b70, via `dynamic_call`) to close the title screen.
- With `GameState == nil` the scripts call `StartNewGame(map)`; the mod replaces it with `profile.lua`
  (fresh `GameStateInit` + everything maxed). Verified in game: 6 weapons, 24 aspects rank 5, 33 keepsakes
  level 3, 5 familiars with 45/45 upgrades, 25/25 Arcana at max rank, Grasp 30, Fear 0.
- No save writes: `GameState.IllegalConversationModification` (RequestSave's own guard) plus hooks on
  `RequestSave`, `ValidateCheckpoint`, `InvalidateCheckpoint` (the last two write `<Profile>.v.sav`'s
  checkpoint-valid byte). Gate `COMPETITIVE=1 scripts/e2e-vs-mock.sh` hashes all 11 profile files before and
  after; without the checkpoint hooks it caught `Profile1.v.sav` changing.
- Arrive in `Hub_PreRun` with `NextHeroStartPoint 40009 / NextHeroEndPoint 40012` (as from the Crossroads door).
- H2M quirk: while its overlay is open it skips `Player::HandleInput` and flips a jump in
  `PlayerManager::HandleInput` (pattern `74 7C 38 05`); in that state the hub's `AutoActivate` doors fire by
  themselves (Hub_Main <-> Hub_PreRun bounce). The mod ignores `DeathAreaSwitchRoom` from AutoActivate doors
  while the overlay is open.
- Under gamescope, xdotool input does not reach the game; the test bot presses the menu entry by calling
  `OpenPatchNotes(this)` from a `MainMenuScreen::Update` hook (test mode only).
- Tools: `scripts/pdb_symbols.py` (PDB publics -> RVAs), `scripts/disasm.py` (annotated disassembly).

## Per-depth RNG (same rooms and enemies regardless of choices) — verified on the tested build

Rule (from the owner): both racers face the same room and enemies at each depth; choices only change
rewards. Vanilla chains each room's seed from the previous room's RNG state (LeaveRoom ->
`RandomSetNextInitSeed()`), so in-room actions and door choices change everything after.

Inside a race run the mod re-seeds from `hash(raceSeed, tag, depth, ...)` at each decision and restores
`NextSeeds`, so the game's own `RandomSynchronize` calls still work:
- `LeaveRoom`: mirroring (unless geometry decides it), next room seed (`RandomSetNextInitSeed` args),
  next encounter (`ChooseEncounter`), shop stock (`RunShopGeneration`).
- `DoUnlockRoomExits`: every generic door gets the same `ChooseNextRoomData` result; `CreateRoom` re-seeded per
  depth; each door keeps its own reward; `ChooseRoomReward` uses the run's starting reroll count.
- `GetNextSpawn` / `HandleNextSpawn`: re-seeded per (depth, encounter, spawn #); combat RNG resumes from a value
  drawn before, so crits/procs aren't predictable from spawns. Spawn *points* still depend on hero position.

Evidence: `COMPETITIVE=1 DIVERGE=1 scripts/e2e-two-games.sh 6` on two real clients, B taking other doors
(depths 2, 4, 5) and other boons: rooms, room seeds, mirroring, encounters, enemy rosters and spawn order
identical for 7 depths (incl. the Treant miniboss, a Nemesis event); door rewards differed only where god
eligibility did. An earlier run was hollow (the bot picked before doors had rooms); the comparison now fails a
divergence run in which the players never took different doors. Offline twin: `MUTATE=no_depth_seed
scripts/test-sim.sh` fails.

Consequences: a shop/fountain at a depth is compulsory for both players; Chaos gates are just another door.

### Same offers, not just the same rooms (0.5)

A real 2-player race (2026-10-20, Deck vs PC) still diverged: the same room at every depth, but Artemis
in one racer's depth-5 room and a plain fight in the other's, Nemesis at depth 7 for one only, different
miniboss gods, different Well of Charon stock and shop gold. Cause (research, file:line in game scripts):
the reseeds fixed the RNG, but most picks are `GetRandomValue(eligibleList)` (UtilityLogic.lua:1026): one
draw indexed into the list of *eligible* options, so a list one entry shorter shifts the pick. Lists
differed because (a) encounters check the room's door reward (NemesisRandomEvent and Arachne ban
StackUpgrade, RunLogic.lua:1687), (b) god/reward eligibility reads GameState records the race itself wrote
(Aphrodite needs `UseRecord` Poseidon/Demeter; hammers need 4 god first-pickup lines; Hermes/Selene their
first-pickup lines), (c) run history. `GetRandomValueFromWeightedList` also iterates `pairs()`, whose order
can differ between two game processes.

Fixes in `game.lua`:
- **Rank picks** (`Game:rank_scope`): inside a race pick the game's `GetRandomValue`, `RemoveRandomValue` and
  `GetRandomValueFromWeightedList` are replaced: each option scores `hash(seed, tags, pick #, name, copy #)`,
  best eligible wins, prunes drop the worst, weighted picks use `-ln(u)/weight` (order-independent).
  Used for: the encounter pick (one pick, then the game generates it), door rewards (keyed by the store
  entry's reward name, not its index), the god of each loot door (`ChooseLoot`), the next room
  (`ChooseNextRoomData`), shop/well stock (`FillInShopOptions`), boon offers and their rarity rolls
  (`SetTraitsOnLoot`, per depth and god).
- **Encounters fit every door:** while choosing the encounter for the room behind the doors, an encounter is
  eligible only if it is for every door's reward (`room.ChosenRewardType` tried per reward); if none fits,
  falls back to the taken door's reward.
- **Seeded side rolls** (`Game:seeded_call`, like spawns): golden urns (`HandleBreakableSwap`), gold drops
  (`CheckMoneyDrop`, per enemy name and count), object values, the Charon swap item check.
- **Lifetime totals** (0.5.1): every resource's `LifetimeResourcesGained` starts at 100000, past the
  game's highest lifetime threshold (10000). ~150 reward/room/shop rules read them; e.g. Bones
  (`MetaCurrencyDrop`, LootData MetaProgress store) need 5 lifetime Ashes. Starting at 0, a racer who
  picked up Ashes at depth 4 unlocked Bones for themselves only; at depth 8 the other racer's top
  pick fell to Nectar (seen in a 10-room diverging run).
- **Profile** (`profile.lua` `mark_story_seen`): every text line set and VO cue heard, first pickups
  (`UseRecord`, `LootPickups`), tutorials (`Flags`), screens, objectives, quests, rooms entered, traits seen,
  `ReachedTrueEnding` (without it the fully-heard story leaves Hecate "missing": no Erebus boss, and a Typhon
  kill locks the Surface). So no god starts locked for one racer and not the other.

What can still differ, by design: anything a racer's build rules out for them (a god after the 4-god cap, a
boon they already have, Pom on nothing upgradable) changes that one pick only.

Each race writes a choice log (`racelog.lua`: rooms, door encounters, doors, rewards, boon offers and picks,
stock, purchases) to `plugins_data/.../races/`; `scripts/compare-race-logs.py` diffs two by depth and
`scripts/fetch-race-logs.sh` pulls the newest from the Deck and the PC.

## Native UI: Race Board, rival plate, shadow, banners

Everything a player touches is native Hades UI driven by the game's own menu
machinery, so a controller works everywhere; the ImGui window (F8) is debug only.

- **Race Board** (`mod/src/board.lua`): opens by itself on arrival in the competitive hub
  and whenever a vote, ready check or result needs the player; the Pitch-Black Stone
  (Hub_PreRun obstacle 561146) becomes its entrance (`OnUsedFunctionName`, UseText
  `RankedRace_UseBoard` = "{I} Race", added to ScreenText.*.sjson). Built like the
  StoryReset prompt / Keepsake rack: `OnScreenOpened`, `CreateScreenFromData` (tint +
  `MythmakerBoxDefault`), `ButtonDefault` / `ButtonKeepsakeItem` components,
  `ExclusiveInteractGroup`, `TeleportCursor`, and a copy of `HandleScreenInput` that uses a
  fresh notify name per page build (a press meant for a rebuilt page is dropped, not
  replayed). Pages are a pure function of client state (`Board.view`, unit tested).
  Weapon icons: each weapon's base aspect `TraitData[...].Icon`; keepsakes:
  `InRackIcon or Icon`. Code entry is an 8x4 on-screen keyboard of the server's code alphabet.
- **Matchmaking** (2-5 racers per race, `maxPlayers`): Find Match joins an open public
  lobby whose racers are all version-compatible (or opens one); once two are in it starts
  by itself after `matchGatherMs` (15 s), or at once when full. Create Private Race (random
  code) makes you the host, who presses Start Race (`start_race`) once everyone is in. Race
  by Code (`join_lobby` with `create`: an unused code opens a lobby under it, so friends can
  type an agreed code; the first one hosts). Joining a lobby that is already racing is
  refused (`lobby_busy`).
- **Rival plate** (`mod/src/hud.lua`, top right, Combat_UI group): HUD fonts/colours, the
  player's `HPBarFill` art (its fraction is the *missing* part), boon icons with
  `Frame_Boon_Menu_<Rarity>`; fades with the game's HUD while `MapState.CombatUIHide` is set.
  One rival gets the full plate (name, status, depth, delta, HP, boons); two to four get a
  compact row each in their own colour (violet, teal, gold, coral), rebuilt when the count
  changes.
- **Shadow Melinoë** (`mod/src/shadow.lua`): `BlankObstacle3D` + GrannyModel `Melinoe_Mesh`,
  tinted (the rival's plate colour), alpha'd and scaled down (the obstacle draws the model larger
  than the hero unit), one per rival in your room, teleported toward that rival's 12 Hz ghost
  reports. Attacks/casts/dashes replay: the sender hooks `CheckPlayerOnFirePowers` (called by
  `OnWeaponFired` for every hero fire), sends the weapon's `FireGraphic` (`GetWeaponDataValue`) with an
  action counter, and the receiver `SetAnimation`s it (the game's per-weapon `SwapAnimation`s apply
  to the shadow too). A rival whose updates stop (pause: `SessionMapState.IsPaused`, sent as
  `paused`; or lag) stays put with "PAUSED" above her head (an overhead text on a
  `BlankObstacleNoTimeModifier` anchor, like the game's `PopOverheadText`; the music player's pause
  graphic doesn't draw in the world); she only goes away on a room change, a finish or a disconnect.
  Size: scale 0.75 matches the hero (checked side by side with bot.json `shadow_mirror`).
- **Welcome** (first board open, and the home page's About): spoiler warning for the 100%-completed
  profile first, what the mod does, the AI disclosure and the repository link; remembered in
  `plugins_data/.../welcome-seen`. Hell2Modding's own first-launch window is skipped by the installers
  (`config/Hell2Modding-Hell2Modding-GUI.cfg`: `onboarded = true`). (Lua `update()` stops while the game is paused; the ImGui
  frame callback doesn't, so the paused racer keeps reporting.)
- **Chat** (`chatfeed.lua`, board pages, server `chat`): quick lines and an on-screen keyboard on the
  Race Board (lobby, prep, results) and, mid-run, from the pause menu's "Race Menu" (the relabelled
  Undo Night: Chat / Forfeit Race / Back; Quit still asks to forfeit). The server relays a line to
  the whole lobby (sender included), 1-80 characters, one a second. The last four lines show top
  left for 10 s, above menus.
- **Banners** (`mod/src/banner.lua`): 3-2-1-GO from the server start time; result via
  `DisplayInfoBanner` (the biome-cleared banner).
- **Map loads destroy objects and the engine reuses their ids.** Every object id the mod
  keeps lives in `MapState` (replaced by `MapStateInit` on each load); an id kept elsewhere
  ended up pointing at Zeus's dialogue box and our text appeared there.
- **Real controller test**: `scripts/e2e-pad.sh` creates a virtual gamepad on the test PC
  (`scripts/bazzite/pad.py`, uinput + python-evdev) and drives the board with A / D-pad
  presses only, against a mock rival from Find Match. Two findings: (1) with an Xbox
  VID/PID, Steam Input claims the pad and Proton opens only Steam's virtual copy, which
  stays silent for a game Steam didn't launch, so the pad uses a generic VID/PID;
  (2) the game starts selection from the mouse pointer when it switches to controller
  mode, so the board re-places the cursor on its focus when `UseMouse` turns false, and
  it only auto-opens once `IsInputAllowed` (the hub arrival blocks input for seconds).

## Race rules, forfeit, timer, results (verified in game)

- **Rules (server):** first clear decides the winner (`race_decided` goes to everyone while
  others may still be running); dying, forfeiting and disconnecting are DNFs, so the others
  must still clear to win; no clears = draw (`no_finishers`); a 3 h cap turns anyone
  still running into `timeout`. The race ends (`race_result`, with each racer's outcome,
  official time, depth, build, stats and place) once every entrant has finished one way or
  another. Places: clears by time, then DNFs by depth (deeper first), then by time (later
  first). Official times are the server clock from the race start. Votes: plurality, ties
  drawn at random among the tied options, no votes at all = a random option.
- **One timer:** the game's own run timer (native `InGameUI`, "Timer Display" setting) shows
  `CurrentRun.GameplayTime`, which stops for menus, boon choices and room transitions. In
  competitive mode it is hidden (`BlockGameplayTimer`) and the mod draws one real-time race
  clock at the top right, above menus. The run clear screen shows the race time too
  (`GameplayTime` is set to it in the `RecordRunCleared` hook).
- **Forfeit:** the native pause menu's "Undo Night" (`sgg::PauseScreen::GiveUpToMainMenu`) is
  hooked and relabelled "Forfeit Race"; Quit mid-race (`QuitToMainMenu`) is hooked too. Both
  close the pause menu (`PauseScreen::Resume`) and open the board's prompt (Keep Racing
  focused). Verified with real controller input (`PAD_SCENARIO=forfeit scripts/e2e-pad.sh`).
- **Save guard:** those pause actions call native `ProfileManager::SaveProfile` /
  `ProgressManager::SaveValidCheckpoint`, which the Lua `IllegalConversationModification`
  gate does not cover; both are hooked and skipped while competitive mode is active.
- **Back home:** after a clear (clear screen closed), a forfeit or a death in a competitive
  race the mod loads Hub_PreRun directly (walk-in points 40009 -> 40012) instead of the death
  sequence, which plays story scenes in Hub_Main and waits for input. A death first plays what
  `KillHero` does up to `DeathPresentation` (spawns stopped, `EndMusic`/`EndAmbience`, Melinoë's death
  animation and banner), then loads the hub and releases what that presentation locked (input
  block, mouse tether, camera, combat controls, combat UI). Back home with others still running,
  the board opens on "Out of the Race" / "Victory": your result plus every running rival's depth,
  biome and HP, live.
- **Prep time and routes:** after the votes (route, weapon, keepsake) the server gives 2 minutes
  (`prepMs`, `PREP_SECONDS`) and starts the race when everyone is ready or the time is up. The voted
  route's Crossroads exit (DeathLoopData Hub_PreRun: Underworld door 420947 and Surface 555784 via
  `UseEscapeDoor`, Dream door 780651 via `UseDreamRunDoor`) is hooked: during prep it reads "{I}
  Ready to Race" and marks you ready; while a race is set up or running the exits don't start runs
  of their own. At GO the mod calls `StartOver` with what that door passes (Surface:
  `StartingBiome = "N", RandomOffset = 1`; Dream: `StartingRoomName = "Dream_Intro"`,
  `RunOverrides = { IsDreamRun = true, BiomeDepthCache = 1 }`). Dream biomes (`SelectNextDreamBiome`)
  and mid-run starting rooms are seeded per race. A hint at the bottom of the competitive hub says
  where the board is while it's closed.
- **Results screen:** the board's finished page compares both racers of a 1v1 like the run
  clear screen (result + time, depth, damage dealt/taken, foes slain, healing, gold, chambers,
  death defiances, boons, hammers; better value in gold; both boon lists). With three or more
  it is a standings table: a column per racer in finishing order (place, name, result, time,
  depth, small boon icons) and a row per stat, best in gold. Stats come from `CurrentRun`
  (see `Game:run_stats`).
- **Recordings:** `scripts/record.sh NAME WINDOWS -- <test command>` records the game windows
  on the test PC (x11grab + VAAPI, wall-clock timestamps) and builds `local/videos/NAME.mp4`.

## Version check

The mod sends its version and the game build in `hello`; the game build is the running
`Hades2.exe`'s PE link time, read from its header in memory (`rom.memory.get_module_base_address`,
`e_lfanew` + 8): 1790167264 = 2026-09-23 on the tested build. The server (`server/src/versions.ts`)
refuses mods older than `MIN_MOD_VERSION` (`update_required`) and pairs only racers with the same
mod major.minor and the same game build (`version_mismatch` with `who`/`what`/`rival` to both, on
join (checked against every racer in the lobby) and in Find Match, which only groups compatible
racers); unknown values don't block (test tools). The board turns these
into "Can't race X / Your Hades II is out of date / how to update". Verified in game with a mock
rival claiming a newer build.

## Public server (Railway)

Project `hades2-ranked-race`, service `race-server`, built from `server/Dockerfile`, listening on `::7777`
behind a Railway TCP proxy at `hopper.proxy.rlwy.net:16303` (the mod's default). The CLI has no TCP-proxy
command; `scripts/railway-deploy.sh` creates it through the GraphQL API (needs an explicit User-Agent; the
default urllib one gets 403). Verified: two mock bots over the internet, and the real game in competitive
mode (`REMOTE_SERVER=hopper.proxy.rlwy.net:16303 COMPETITIVE=1 scripts/e2e-vs-mock.sh`): PASS, saves untouched.
The first deploy waited out a Railway-wide build pause (2026-10-20).

## Deployment (owner's r2modman profile on the test PC)

`scripts/bazzite/deploy-r2modman.sh` installs the mod and the tested Hell2Modding 1.0.117 / ModUtil 4.0.1
dependency set into the r2modman "Default" profile (and the game's `Ship/d3d12.dll`), updating `mods.yml`
versions. First deploy replaced H2M 1.0.103 and the earlier attempt's symlink; backup in `~/h2r-backup-*`.

## Test bed (test PC)

`~/h2r-testbed`: btrfs reflink (copy-on-write) copies of the install and of the Proton prefix
(one per instance), our pinned `d3d12.dll` only in the copy, per-instance ReturnOfModding roots
via `--rom_modding_root_folder`. The owner's install, prefix, saves and r2modman profile are
never written. Scripts: `scripts/bazzite/{triage,testbed-setup,push,instance,capture}.sh`.

## Hell2Modding facts (verified in source)

Read at H2M `bb00457`, ReturnOfModdingBase `6933605`, ModUtil 4.0.1.

- Lua 5.2.2 (not LuaJIT), the game's own state. Code here stays 5.1–5.5 compatible; `goto` is a keyword.
- LuaSocket is compiled in: use `require("socket")`. `rom.socket` is documented but the binding only sets `rom["socket.core"]`. Plain HTTP only.
- `io.open` works on any path; `os.execute`, `io.popen`, `package.loadlib` are blocked.
- `rom.gui.add_always_draw_imgui` runs every frame; `add_imgui` only while the H2M overlay is open. Both run on the game's script thread under the Lua lock (`hook_sgg_scriptmanager_update_for_imgui_callbacks`), so game state access is safe. A frame can be skipped when the draw-data lock is busy.
- Plugin env copies only lowercase globals: game globals must be read through `rom.game`.
- Plugin folder must be `Author-Name` with a `manifest.json`; GUID = folder name. Thunderstore zips are flat, so each goes in `plugins/<Ns>-<Name>/`.
- Install: `d3d12.dll` next to `Hades2.exe` in `Ship/`; Linux launch option `WINEDLLOVERRIDES=d3d12=n,b`. Mod root defaults to `Ship/ReturnOfModding`; `--rom_modding_root_folder <dir>` overrides it (uses `<dir>/ReturnOfModding`).
- If H2M is first enabled via that argument, later launches without it stay vanilla (`Ship/ReturnOfModdingFirstEnabledReason.txt`). Useful to keep the owner's normal launches unmodded.
- Log: `ReturnOfModding/LogOutput.log`, truncated per launch. Our mod also writes `plugins_data/<guid>/ranked.log`.
- No macOS support (official wiki); testing must happen on the Linux PC.

Pinned packages (Thunderstore, hashes in `local/thunderstore/sha256.txt`):
Hell2Modding 1.0.117, ModUtil 4.0.1, DemonDaemon 1.1.1, SGG_Modding-ENVY 1.2.1,
LuaENVY-ENVY 1.2.1, Chalk 2.1.2, ReLoad 1.0.3, SJSON 1.0.3.

## Hades II script facts

Source: cevasonic/Hades-II-Mod copy of `Content/Scripts` @ `eeae74cf` (post-1.0,
exact patch unknown), names cross-checked against SGG-Modding/Hades2GameDef 2.1.0.
CLAUDE.md and plan.md name Hades 1 files; in Hades II they are `RunLogic.lua`,
`RoomLogic.lua`, `DeathLoopLogic.lua`, `RandomLogic.lua`, `BountyLogic.lua`.

- Run start: hub map `Hub_PreRun` door calls `UseEscapeDoor` → `StartOver(args)`:
  `EndRun`, optional `RandomSetNextInitSeed(GameState.NextRunSeed)`, `StartNewRun`, `LoadMap`.
  `StartNewRun` equips `GameState.LastAwardTrait` (keepsake) and the weapon aspect.
- RNG: `RandomSetNextInitSeed{Seed}` queues a seed; `RandomInit` (on every map load) applies it;
  `RandomSynchronize` re-inits now. `LeaveRoom` queues the next room's seed from the current RNG,
  so rooms form a seed chain. `DebugRNGSeed` would override every seed (avoid).
- Weapons: `WeaponStaffSwing`, `WeaponAxe`, `WeaponDagger`, `WeaponTorch`, `WeaponLob`, `WeaponSuit`;
  equip with `EquipPlayerWeapon(WeaponData[name], {SkipPresentation=true})`; aspect via
  `GameState.LastWeaponUpgradeName[weapon]`. Keepsake rarity comes from the save unless
  `EquipKeepsake(..., {ForceRarity=...})`.
- Rooms: `StartRoom(run, room)`, `LeaveRoom(run, door)`, `DoUnlockRoomExits`, doors in `MapState.OfferedExitDoors`.
- Death: `KillHero(victim, args)`. Clear: `RecordRunCleared()` sets `CurrentRun.Cleared` (called by `OpenRunClearScreen`
  after Chronos / Typhon).
- Bot helpers: `Kill(CurrentRun.Hero)`, `DestroyRequiredKills{BlockLoot=true}`.
- Prior art: ARRAY-OnlineCoop (LuaSocket UDP co-op; says enemy counts depend on save progress),
  adamantSpeedrun-LiveSplit and HadesSpeedrunning-SpeedrunTimer (timer hooks), zerp-GameOverScreen
  and PonyMenu (programmatic run starts). No ranked/versus race mod found.

## How the mod starts a race (derived, unverified in game)

At GO: back up the loadout, `EquipPlayerWeapon`, set the base aspect and `LastAwardTrait`,
then `thread(StartOver, {StartingBiome="F"})`. A `StartNewRun` wrap seeds the RNG
(`RandomSetNextInitSeed` + `RandomSynchronize`) before the original runs and queues the same
seed again after, so both StartNewRun's choices and the first map's `RandomInit` use the race seed.
`EquipKeepsake` is wrapped to force rank 3 rarity for both players. The loadout is restored when
the race ends.

## Risks

- Same seed on two different saves can still diverge: room/encounter eligibility and enemy counts
  read `GameState` (save progress). ARRAY-OnlineCoop's README says as much. The bot writes a
  per-room trace (room, seed, encounter, reward) so two clients can be diffed.

## Unknowns

- Determinism over a whole run (tested: 4 rooms) and across saves with very different progress.
- Dialogue lines with choices (the bot only advances plain lines).
- Final-boss victory path (`OpenRunClearScreen` after Chronos/Typhon) end to end.
- A real two-machine, two-account race over the internet.

## Tooling

- `local/tools/lua52`: Lua 5.2.4 (lua.org, sha256 b9e2e4aa…f4b, matches published) + LuaSocket 3.1.0
  (GitHub tag tarball, sha256 bf033aeb…a6e), built from source on the Mac for the offline tests.
