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
| Server: lobby, votes, ready, countdown, win/loss/draw, reconnect | built | `cd server && npm test`: 35 pass |
| Mod: JSON, protocol client, UI | built | `cd mod && lua test/run.lua`: 19 pass (Lua 5.2.4 and 5.5) |
| Mod: LuaSocket client vs real server | built | `scripts/test-protocol.sh`: PASS |
| Mod in a simulated game (2 clients) | built | `scripts/test-sim.sh`: PASS; 5 mutations each FAIL |
| **Real game: mod loads, all hooks found** | verified | LogOutput.log: "game: hooks installed", no missing targets |
| **Real game vs mock opponent** | verified | `scripts/e2e-vs-mock.sh game_wins` and `game_dies`: PASS |
| **Two real game clients race** | verified | `scripts/e2e-two-games.sh 3`: both bots PASS, survivor_finished |
| **Same seed -> same rooms (two different save copies)** | verified for 7 rooms | traces identical: room, per-room seed, encounter, reward, boon offered (incl. a shop) |
| Determinism check can fail | checked | `MUTATE=no_seed`: "seed applied" FAILs, rooms diverge from room 3 (rooms 1-2 are forced intro rooms) |
| Lobby window + HUD draw in game | verified | `show_ui` runs log no UI errors; window captures show the HUD with live opponent data |
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
