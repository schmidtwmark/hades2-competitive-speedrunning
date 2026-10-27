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
- `DoPatches` (PatchLogic.lua) runs in `OnPreThingCreation` on every map load, but on the first one it runs
  before the profile exists. Until 0.5.3 the Arcana altar in that first Crossroads visit hit a script error
  (`MetaUpgradeCardScreenPresentation.lua:436`, `GameState.MetaUpgradeLayoutsArt` nil, set only by
  `DoMetaUpgradePatches`) and left the screen stuck open. `Profile.build` now sets the layout tables and
  calls `DoPatches` itself.
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

Mirroring is the engine config option `FlipMapThings`: every map loads mirrored while it is on, and the
game sets it on arrival only for the run's own room (RoomLogic OnAnyLoad). KillHero and StartOver turn it
off before their maps; the mod's own trip home (forfeit, death, clear) must too, or the training grounds
load mirrored after a race that ended in a mirrored room (seen in a real race; fixed in 0.6.7, checked by
`SCENARIO=forfeit` with bot.json `forfeit_flipped`: forfeit in F_Combat08 mirrored, home with
FlipMapThings=false).

Fear (Oath of the Unseen): DoPatches, on every map load, empties `GameState.ShrineUpgrades` unless
RequirementsData `ShrineUnlocked` holds (I_Boss01 entered, ClearedRunsCache >= 1, Chronos killed or a
story reset). The competitive profile had no clears and no Chronos kill, so vows set in the prep time were
gone by the first room (bot log: Fear 4 at StartNewRun, 0 in room 2). Since 0.6.7 the profile has both;
Fear 4 then lasted every room (`scripts/e2e-house-bot.sh 3` with bot.json `fear`). Vows change foes and
offers for that racer only, so the race report says FEAR DIFFERS rather than judging those offers.

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

**Chaos detours** (0.5.2): a Chaos room counts as one of the biome's rooms in the game itself
(`GetRunDepth`/`GetBiomeDepth` count all of `RoomHistory`; Chaos rooms have `UsePreviousRoomSet` and no
`NextRoomSet`, so the biome counter doesn't reset): a racer who detours reaches the shop/miniboss/boss
one main room sooner, i.e. the Chaos room replaces a main room. The per-depth seeds key on the same
counter, so the room after a detour is the room the others have at that depth. Two drifts showed up in
tests with forced Chaos gates (bot.json `force_chaos_door`, `CHAOS=1 scripts/e2e-two-games.sh`) and are
fixed: (1) `ChooseNextRewardStore` (RunProgress vs MetaProgress pool for a room's doors) nudges its
chance by the rewards in your history (`CalcMetaProgressRatio`); in races it rolls the plain target ratio
on the depth's room seed. (2) The skipped main room still counted as unvisited for the detouring racer,
so it could be offered to them later where the others couldn't get it (rooms don't repeat:
`MaxAppearancesThisBiome`); room choice now counts every main-path room as visited
(`with_main_path_visited`). Verified: after two detours, the next rooms (and their encounters) matched the
other racer's at those depths.

What can still differ, by design: anything a racer's build rules out for them (a god after the 4-god cap, a
boon they already have, Pom on nothing upgradable) changes that one pick only.

Each race writes a choice log (`racelog.lua`: rooms, door encounters, doors, rewards, boon offers and picks,
stock, purchases) to `plugins_data/.../races/`; `scripts/compare-race-logs.py` diffs two by depth and
`scripts/fetch-race-logs.sh` pulls the newest from the Deck and the PC.

## Native UI: Race Board, rival plate, shadow, banners

Everything a player touches is native Hades UI driven by the game's own menu
machinery, so a controller works everywhere; the ImGui window (F8) is debug only.

- **Race Board** (`mod/src/board.lua`): opens by itself only when a vote, ready check or
  result needs the player (since 0.5.5 not on arrival, and the welcome page waits for the
  stone too; the test bot uses the stone with `CallFunctionName`, once input is allowed —
  using it during the arrival walk-in leaves the board deaf to the pad); the Pitch-Black Stone
  (Hub_PreRun obstacle 561146) becomes its entrance (`OnUsedFunctionName`, UseText
  `RankedRace_UseBoard` = "{I} Race", added to ScreenText.*.sjson). Built like the
  StoryReset prompt / Keepsake rack: `OnScreenOpened`, `CreateScreenFromData` (tint +
  `MythmakerBoxDefault`), `ButtonDefault` / `ButtonKeepsakeItem` components,
  `ExclusiveInteractGroup`, `TeleportCursor`, and a copy of `HandleScreenInput` that uses a
  fresh notify name per page build (a press meant for a rebuilt page is dropped, not
  replayed). Pages are a pure function of client state (`Board.view`, unit tested).
  Weapon icons: each weapon's base aspect `TraitData[...].Icon`; keepsakes:
  `InRackIcon or Icon`. Code entry is an 8x4 on-screen keyboard of the server's code alphabet.
- **Matchmaking** (0.6.0): Find Match lobbies hold two (`matchPlayers`), private ones up to
  five (`maxPlayers`). Find Match joins an open public lobby whose racer is version-compatible
  (or opens one). Create Private Race makes a random code; Race by Code (`join_lobby` with
  `create`: an unused code opens a lobby under it, so friends can type an agreed code).
  Joining a lobby that is already racing is refused (`lobby_busy`). In "waiting", `ready`
  (with `ready: false` to take it back) is ready to vote; the vote starts once everyone in the
  lobby, two or more, is ready (no host start and no gather countdown any more; 0.5 clients
  are told to update, `MIN_MOD_VERSION` 0.6.0). A rematch goes straight to the votes, so the
  client clears a vote's own and later `vote_results` when it opens.
- **Name** (0.6.6): the mod is Hades 2 Competitive Speedrunning (H2CS; "H2CS" where a board line
  would wrap), a beta. The GitHub repo is `schmidtwmark/hades2-competitive-speedrunning` (renamed from
  hades2-ranked-race; GitHub still serves the old raw/codeload URLs, which 0.6.0-0.6.5's How to Update
  shows). The package is `Hades_2_Competitive_Speedrunning` (Thunderstore shows underscores as
  spaces), so the plugin folder is `schmidtwmark-Hades_2_Competitive_Speedrunning`; the installers
  remove the old `schmidtwmark-RankedRace` plugin folder (two copies would load) and move its
  `plugins_data` and `config` folders over. Internal names (`RankedRace_*` globals, MapState keys,
  the Railway project `hades2-ranked-race`) stay.
- **Thunderstore release** (first published 0.6.7 on 2026-10-27 by the workflow, tag `v0.6.7`;
  thunderstore.io/c/hades-ii/p/schmidtwmark/Hades_2_Competitive_Speedrunning/): `scripts/thunderstore-package.sh` builds
  `build/schmidtwmark-Hades_2_Competitive_Speedrunning-<version>.zip` (flat: mod/src, `thunderstore/` icon + README +
  CHANGELOG, LICENSE; the layout of SGG_Modding-ModUtil's package) and `build/thunderstore.toml`
  for tcli, both from `mod/src/manifest.json`, after checking Thunderstore's rules (name, Major.
  Minor.Patch, description <= 250, website_url, `Team-Name-x.y.z` dependencies = install/packages.txt
  pins, 256x256 icon, a changelog section for the version, LATEST_MOD_VERSION and main.lua's VERSION
  equal). Community `hades-ii`, categories mods, gameplay, ai-generated. `.github/workflows/thunderstore.yml`
  (manual; dry run by default) builds, keeps the zip, and on a real run `tcli publish`es with the
  `TCLI_AUTH_TOKEN` secret and tags `v<version>`. The Thunderstore team is `schmidtwmark` (the plugin folder); its
  service-account token is the GitHub secret. A mod-manager install (`Board.install_kind`: r2modman / Thunderstore
  Mod Manager / Gale profile folders) gets "update in your mod manager" on How to Update. Store
  screenshots are `docs/screenshots/*.jpg`, linked by raw.githubusercontent.com URLs.
- **Keepsake grants** (0.6.4): Jeweled Pom (`HadesAndPersephoneKeepsake`,
  `GiveRandomHadesBoonAndBoostBoons`), the temporary hammer (`AddRandomHammer`) and the Chaos
  blessing keepsake (`AddRandomChaosBlessing`) each draw one `GetRandomArrayValue` from an
  eligible list when the keepsake is equipped (inside `StartNewRun`). Rank picks didn't cover
  `GetRandomArrayValue`, and Arcana change the list: Last Stand sets
  `DeathDefianceDamageBoonEligible`, one more Hades boon (a real race: the two racers got
  different Hades boons, one had Last Stand). Now ranked (`keepsake_grant`, rank_scope with
  `GetRandomArrayValue`); the grant is a `granted` race-log line (depth 0, written once the log
  starts), compared as "keepsake grant" at run start.
- **Board across a map load** (0.6.4): `LoadMap` calls `KillNonPersistentThreads`, ending the
  board's input loop; a chat page opened in the Crossroads kept the board open through the race's
  map load (prompts outrank the countdown page that closes it). The dead screen kept
  `ExclusiveInteractGroup` and its ActiveScreens entry, so the in-run forfeit prompt drew into it
  and took no presses (user report: menu controls stopped after a rematch). The board remembers
  its `MapState`; a changed one releases the screen (`Board:release`, no `CloseScreen`: the
  frame callback can't wait) and the Crossroads chat page closes when the racer leaves.
- **Split targets** (0.6.4): `race_start.best` is the racer's server-kept best on the route
  (time + splits); the client takes the faster of it and `pb.json`. Under the clock: the region
  being run and its best split ("Erebus  best 6:32.10", gold), a split's result for 10 s.
- **Store identity** (0.6.3, `identity.lua`): the name and player key come from the store
  account. Verified 2026-10-24 on the owner's bazzite install (launched by Steam): the SteamID64
  and persona name read at the Crossroads hello, the live server logged the steam key. The test
  bed's games run outside Steam, so there `SteamAPI_SteamUser` returns no user. Steam: steam_api64.dll's exports, found by walking its PE export table
  (`get_module_base_address` + `get_dword` / `get_word` / `get_string`; no Hades2.exe signature):
  `SteamAPI_SteamUser_v0xx()` gives ISteamUser; its vtable slot 2 (`+0x10`) is GetSteamID, which
  returns the CSteamID through a hidden pointer (Hades2.exe's `SteamWrapper::GetSteamId` calls it
  that way), so `dynamic_call(..., { this, buffer })` lands the 64 bits in `rom.memory.allocate`d
  memory, read as two exact dwords and printed by `Identity.u64_decimal` (a SteamID64 doesn't
  fit a Lua 5.2 double). Persona: `SteamAPI_SteamFriends_v0xx` + `SteamAPI_ISteamFriends_GetPersonaName`.
  Epic (untested: no Epic copy): `GetCommandLineA` (kernel32) for the launcher's `-epicuserid=` /
  `-epicusername=`. Read at the first hello (connecting waits for the competitive Crossroads, so
  Steam is up). The id goes to the server only (`hello.platform` / `platform_id`, self-reported:
  not verified; Steam auth tickets would be the next step for ratings), never to other players.
  One account twice in a lobby (the owner's Deck and PC share one) shows "Name (2)". Test bots
  keep their bot.json names and send no identity unless `identity: true`.
- **Personal bests on the server** (0.6.3, `pb-store.ts`): per store account and route, the
  fastest clear by official (server) time, with the region splits the clear reported
  (`run_complete.splits`), in `PB_FILE` (Railway: `/data/pbs.json`, written via a temp file and
  rename). `lobby_state` players carry `best` {route: seconds}; the route vote lists them.
  The HUD's split deltas still use the local `pb.json`.
- **Log console** (0.6.2): Hell2Modding's `[Logging] Console Enabled = true` (its default, in
  `config/Hell2Modding-Hell2Modding-General.cfg`) opens a separate "Hell2Modding" window of log
  lines at startup (user report: logs on screen at launch). The installers and the test bed set
  it false; `LogOutput.log` still gets every line.
- **Training grounds only** (0.6.2): Hub_PreRun's doorway into the rest of the Crossroads is
  obstacle 421119 (`DeathAreaSwitchRoom` to `Hub_Main`, AutoActivate). In competitive mode the
  `DeathAreaSwitchRoom` hook refuses `Hub_Main` and shows "Training Grounds Only" (at most every
  4 s: walking into it fires again). Probe: `PROBE_PREP` uses the doorway and checks the map.
- **First-time presentations** (0.6.2): `GameState.IntroducedEagle` gates Olympus's eagle intro
  (camera pan and a few seconds at 0.18 sim speed, `OlympusEagleFirstSpawnPresentation`). The
  profile sets it. A scan of flags the scripts check unset and then set true found no other
  presentation flag (the rest are save patches; `ReachedTrueEnding` was already set).
- **Race records** (0.6.2): each choice-log line (`racelog.lua`) also goes to the server
  (`race_log`, at most 8 KB a line, 5000 a racer); with `RACE_LOG_DIR` set (Railway: a volume at
  `/data`, `RACE_LOG_DIR=/data/races`) `race-log-store.ts` keeps a folder per race: `race.json`
  (setup, entrants, results) and one `.jsonl` per human racer in the client format behind the
  server's start line. A `loadout` line (aspect, Arcana, familiar, keepsake) follows the start:
  Daedalus Hammer offers depend on the aspect, so racers with different aspects can see different
  hammers on the same seed (a diverging test run did at depth 1). `scripts/race-report.sh [n]`
  lists the records over `railway ssh` and reports one: `compare-race-logs.py` per depth and a
  FAIRNESS line (a difference counts only while both racers' choices still matched).
- **Encounter counts** (0.6.1): `EncountersCompletedCache` / `EncountersOccurredCache` hold
  counts, and rooms and boss attacks gate on them: Erebus's `F_MiniBoss02` (Shadow-Spiller) and
  `F_MiniBoss03` need `MiniBossTreant >= 2`, Hecate's meteor hex needs `BossHecate01 >= 10`,
  some Chronos attacks `BossTyphonHead02 >= 2`. The profile set every count to 1, so each
  Erebus run met the Root-Stalker and bosses kept first-encounter movesets (user report: "the
  first miniboss is always the tree guy"). Now `Profile.ENCOUNTER_COUNT` = 10; the only
  `<` check (`MiniBossCharybdis` occurred `< 1`) was already false. Profile check: every
  Erebus miniboss room passes `IsGameStateEligible`.
- **Button labels** (0.6.1): `ButtonDefault` art is ~268 units wide at scale 1 and its text box
  doesn't shrink to fit. `Board.button_stretch` estimates a label (small caps ~0.67 em a
  letter) and `SetScaleX` widens the button; the attached text keeps its shape (screenshots).
  A page's buttons share the widest stretch so columns line up.
- **Updates** (0.6.0): `welcome` carries `latest_mod` (`LATEST_MOD_VERSION` in
  `server/src/versions.ts`; a server test keeps it equal to `mod/src/manifest.json`, so bump
  both together). A client older than that shows "Update available" on the board's home page,
  a line in the in-run Race Menu, and a How to Update page with the one-line updaters
  (`install/update.sh`: `curl ... | bash`; `install/update.ps1`: `irm ... | iex`). They
  refuse while Hades II runs, download the main branch from codeload.github.com and run the
  installer, which keeps the racer name. The mod itself downloads and runs nothing.
- **House bots** (0.6.0; 0.6.0's Practice page and solo runs are gone in 0.6.1, the server
  ignores their `create_lobby` flags): `add_bot` in a private lobby still waiting adds a
  house bot: a session with no transport whose
  `BotBrain` (`server/src/bot-brain.ts`, shared with mock-client) votes "any", readies,
  reports a room every `botRoomSeconds` (75 s; room names like `F_Bot3`, so the rival plate
  says Erebus), forfeits once someone else clears and clears when every rival is out. Its
  replies are scheduled 400 ms later, never inside the server's own loops. Bots don't count
  as online and leave with the last person. Gate: `scripts/e2e-house-bot.sh`.
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
  (`config/Hell2Modding-Hell2Modding-GUI.cfg`: `onboarded = true`).
  Hell2Modding's overlay (Insert) blocks `PlayerHandleInput` while open, so a controller can't touch the
  game or close it. Twice (10-20, 10-22) it opened by itself in the frame the competitive Crossroads
  loaded: a Lua `rom.gui.toggle()` (no "Toggled Modding GUI" line, which only the Insert path logs), and
  the only caller on a player's install was the F8 debug-window check `ImGui.IsKeyPressed(ImGuiKey.F8)`.
  Since 0.5.4 F8 goes through `rom.inputs.on_key_pressed` (real key presses only) and B closes the
  overlay: `IsControlDown({Name="Cancel"})` still reads the pad while the overlay blocks input; ImGui's
  gamepad keys don't (Back does nothing). Gate: `scripts/e2e-overlay-pad.sh` (virtual pad, B). (Lua `update()` stops while the game is paused; the ImGui
  frame callback doesn't, so the paused racer keeps reporting.)
- **Chat** (`chatfeed.lua`, board pages, server `chat`): quick lines on the Race Board (lobby, prep,
  results) and, mid-run, from the pause menu's "Race Menu" (the relabelled Undo Night: Chat / Forfeit
  Race / Back; Quit still asks to forfeit). Since 0.5.6 there is no free text: the board's keyboard is
  gone and the server relays only the exact quick lines (`server/src/chat.ts`, kept equal to
  `Board.QUICK_LINES` by a server test), to the whole lobby (sender included), one a second. The last four lines show top
  left for 10 s, above menus.
- **The race clock while paused** stays frozen on screen (it jumps to the right real time on
  resume). Checked in game (0.5.6 attempts): the mod's frame callbacks ride the game's script
  update, which stops while paused ("no frames for 7 s"); a hook on native `PauseScreen::Update`
  (RVA 0x17fcd0, runs every paused frame) can call `ModifyTextBox`, but the paused picture is a
  frozen, dimmed image of everything except the pause screen's own native components, so neither
  native text boxes nor ImGui from Lua can show a counting clock.
- **Vote grids** (0.5.6): the hover frame is the Keepsake rack's portrait `AwardMenuCursorHighlight`;
  around the square weapon icons it is `SetScaleX` 1.1 / `SetScaleY` 0.8 and moved up 8 units
  (`Board.WEAPON_FRAME`, measured on screenshots). The shops' `BoonSlotHighlight` is a large
  decorative swoosh, not an icon frame.
- **Game revision** (0.5.7): the engine sets the global `Revision` from a loaded save (143476 on
  build 25481925); the in-memory competitive profile had none, so `DoPatches` (every map load) used
  0 and ran all ~30 `Revision <= N` trait patches in every room: those traits (HeraSpecialBoon,
  AphroditeSprintBoon, several Poseidon boons, some aspects, familiar traits, ChannelSlowMetaUpgrade,
  ...) were removed and re-added during each load. Visible symptom (user report): their HUD icons
  were created before the new HUD, outside its lists, under the empty-slot art: blank in combat,
  shown while the combat UI hid. `Profile.build` now sets `Revision` to the higher of
  `Profile.REVISION` and save file 1's. Reproduced and verified with bot.json `swap_boon_test`
  (special boon swapped on the boon screen, pommed, next room: screenshots in combat / UI hidden).
- **Title screen, then competitive** (0.5.8): two things a save load does that the competitive
  entry has to do itself. (1) The title music (`/Music/IrisMainTheme`, started natively; its id is
  `MainMenuScreen::mMusicId`, found through the store in the menu's constructor,
  `competitive.lua` MENU_MUSIC_STORE_SIG) is stopped with `StopSound`. (2) The scripts' clock:
  `wait()` schedules against `_worldTime`, which the engine sets each frame and a save load restores;
  a new session's engine clock starts at 0, so after a quit the Crossroads arrival scheduled its waits
  against the last session's time and held its input blocks (DeathAreaTransition,
  StartRoomPresentation) that long. `Game:restart_script_clock` rebases waiting threads and sets it to
  0 on entry. Leftover script input blocks (tracked through AddInputBlock/RemoveInputBlock hooks) are
  released too. Gate: `scripts/e2e-reenter.sh` moves the hero with the stick on both visits.
- **The last run's room** (0.5.9): in the Crossroads `CurrentRun` is the last run, and the hub's
  scripts read its current room. The competitive profile's bookkeeping run (`StartNewRun` with
  `SkipChooseEncounter`) left that room without an `Encounter`, and ManaLogic's `ManaRegen`
  (started once Magick is below max; user report: after an aspect change) crashed indexing it,
  leaving the script error up and the controls dead. `Profile.build` gives the room
  `SetupEncounter(EncounterData.Empty)`. Gate: probe_prep lowers Magick, starts `ManaRegen` and
  checks it climbs back.
- **Pressing a screen button from code** (test bot, 0.5.9): `HandleScreenInput` waits on
  `ScreenInput<screen name>` and reads the pressed id from `NotifyResultsTable`; closing a screen only
  sets `KeepOpen = false`, so a handler called directly (`AcceptAndCloseSpellScreen`) leaves that loop
  parked and whatever opened the screen never resumes. Opening rooms with Selene's hex stalled the
  bot that way: the fight waits on `OnUsed<id>`, which the OnUsed handler sends only after
  `OpenSpellScreen` returns. `Game:bot_press` sets the result and notifies, like a real press. The
  local test server takes `RACE_SEED` (seed 824876918 opens with the hex).
- **Presence** (0.5.6): the server sends `presence` {online, searching, racing} on hello and when the
  counts change (at most once a second); the board's home and Find Match pages show it. Older
  clients log it as unhandled; older servers never send it.
- **Region splits and PBs** (0.5.6, `splits.lua`): a region is a room name's biome letter (Chaos,
  the Crossroads and Dream_Intro have none); leaving it (the next region's first room) is its split,
  the clear the last. Race times, kept per route in `plugins_data/.../pb.json` (the fastest cleared
  run's splits; Dream Dive regions are numbered). The latest split shows under the race clock with
  its delta on the PB's split; the results page says how the clear compares.
- **Back home after a race** (0.5.6): `go_home` / `die_and_go_home` now call `ClearUpgrades()` as
  `KillHero` does before the death map; before, the hero walked into the Crossroads with the whole
  build. The profile marks each familiar's traits taken (`GameState.TraitsTaken`): an untaken one
  puts a "!" over the familiar (FamiliarLogic).
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
- **Ready page** (0.5.2): opens by itself after the votes, focused on **Set Up My Run** (closes the
  board), with **Ready Now** beside it. Two user races started instantly because a confirm press a few
  seconds after the page opened hit the old focused Ready button. Confirm presses are also ignored for
  0.8 s after the board switches to a different page (`Board.SETTLE`; B is never held back).
- **Prep panel** (0.5.5, `hud.lua` `prep_view`): during the prep time, top right in the
  `Combat_Menu_TraitTray_Overlay` group (above menus): "Race starts in m:ss" from the
  lobby's `prep_ends_in`, then one line per racer (ready / setting up / away). The Arcana
  screen keeps its Grasp meter and layout decks in that corner, so while it is open the
  panel sits 400 px from the right edge.
- **Countdown font** (0.5.5): fonts are bitmaps (Fonts.sjson `FontSize` is the stored
  size); P22UndergroundSCHeavy (35) drawn at 150 was blocky, on a 4K screen most of all.
  SpectralSCLightTitling (64, a much larger glyph file) at 128 stays sharp at 1080p and 4K
  (`PREVIEW_SIZES="Font:size ..." RES="/X=3840 /Y=2160" scripts/e2e-reenter.sh`).
- **Quit to the title screen, then competitive again** (0.5.5): the quit leaves the screen
  faded to black and a save's own load is what fades it back in, so the second entry was a
  black screen. `Game:fade_in_hub` calls `FadeIn({Duration=0.5})` once the hub is up after
  each entry. Gate: `scripts/e2e-reenter.sh` (virtual pad: Start, Quit, OK; brightness of
  both visits, and an Arcana change carried across).
- **Loadouts from save file 1** (0.5.5, `savefile.lua`): `%USERPROFILE%\Saved Games\Hades
  II\Profile1.sav`, opened read-only. Format (save version 18): `SGB1`, checksum u32,
  version u32, timestamp u64, location string, five u32 and two u8, a count of strings and
  the strings, two map names, a u32 length and an LZ4 block holding the Lua state as luabins
  (`T` tables with u32 array/hash counts, `S` u32-length strings, `N` doubles, `0`/`1`/`-`).
  A 696 KB save is 2.7 MB of state; the Lua decoder takes ~0.12 s and builds only GameState's
  loadout keys. Cards, `SavedMetaUpgradeLayouts`, `MetaUpgradeLayoutsArt` and
  `CurrentMetaUpgradeLayout` move as one (the game rewrites the current layout from the
  equipped cards); the remembered competitive loadout (`loadout.json`, now written whenever
  it changes in the competitive hub) wins once it has layouts, the save fills in the rest.
  The profile also marks the `*Tutorial` objective sets complete (the weapon controls list
  that showed after each aspect change); in-run challenge objectives are left alone.
- **Race loadout in the Crossroads** (0.5.3): once a weapon or keepsake vote lands, `UseWeaponKit`
  refuses every other weapon's kit ("Locked" notice) while the voted weapon's kit still opens its
  aspect screen, and `UseKeepsakeRack` refuses the Crossroads rack (the game's locked-rack shake).
  Keepsake racks in later regions (`WorldUpgradePostBossGiftRack`) work as usual: only the starting
  keepsake is the voted one. In competitive mode the voted weapon is picked up (`PickupWeaponKit`)
  and the keepsake equipped (as `KeepsakeScreenClose` does) as the votes land. `start_race` still
  forces both at GO, so an older client ends up with the same start.
- **Prep time and routes:** after the votes (route, weapon, keepsake) the server gives 2 minutes
  (`prepMs`, `PREP_SECONDS`) and starts the race when everyone is ready or the time is up. The voted
  route's Crossroads exit (DeathLoopData Hub_PreRun: Underworld door 420947 and Surface 555784 via
  `UseEscapeDoor`, Dream door 780651 via `UseDreamRunDoor`) is hooked: during prep it reads "{I}
  Ready to Race" and marks you ready; while a race is set up or running the exits don't start runs
  of their own. At GO the mod calls `StartOver` with what that door passes (Surface:
  `StartingBiome = "N", RandomOffset = 1`; Dream: `StartingRoomName = "Dream_Intro"`,
  `RunOverrides = { IsDreamRun = true, BiomeDepthCache = 1 }`). Dream biomes (`SelectNextDreamBiome`)
  and mid-run starting rooms are seeded per race. A hint at the top of the competitive hub says
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
