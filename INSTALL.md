# Installing Ranked Race

Ranked Race is a race mod for two to five players of **Hades II on Steam**
(Windows, Linux, Steam Deck). Every racer needs it installed. It is not on Thunderstore or in any mod
manager yet; install it from this repository with the script for your system.
macOS is not supported (the mod loader is Windows-only and Hades II on Mac does
not run through Proton).

The installer puts three things in place and nothing else:

- **Hell2Modding** (the mod loader): `d3d12.dll` next to `Hades2.exe` in the game's
  `Ship` folder (an existing `d3d12.dll` is backed up first);
- **ModUtil** and its helper libraries, the exact versions the mod is tested with,
  downloaded from Thunderstore and checked against the SHA-256 sums in
  [`install/packages.txt`](install/packages.txt);
- **Ranked Race** itself, from this repository.

Mods go in `Hades II/Ship/ReturnOfModding/plugins`. Your saves are never touched.

## Install

1. **Get the files.** Either `git clone https://github.com/schmidtwmark/hades2-ranked-race`
   or download the ZIP (green **Code** button → **Download ZIP**) and unzip it.

2. **Run the installer** from that folder:

   - **Windows** (PowerShell):
     ```powershell
     powershell -ExecutionPolicy Bypass -File install\install.ps1 -Name "Your Name"
     ```
   - **Linux / Steam Deck** (on the Deck: Desktop Mode → Konsole):
     ```bash
     bash install/install.sh --name "Your Name"
     ```

   `--name` / `-Name` is the name your rival sees (1–24 letters, digits, spaces
   or `_ . ' -`); without it you are "Melinoe 123". If the game isn't found,
   pass its folder: `--game-dir "/path/to/Hades II"` / `-GameDir "D:\...\Hades II"`
   (Steam → Hades II → ⚙ → Manage → Browse local files shows it).
   `--dry-run` / `-DryRun` shows what would happen without changing anything.

3. **Set the Steam launch options** (Steam → Library → right-click Hades II →
   Properties → General → Launch Options; on the Deck in Game Mode: Hades II → ⚙ →
   Properties). Steam keeps these itself, so the installer can't do this step.

   | System | Launch options |
   |---|---|
   | Windows | `%command% --rom_enabled true` |
   | Linux / Steam Deck | `WINEDLLOVERRIDES="d3d12=n,b" %command% --rom_enabled true` |

   If the box already has something (for example a `gamescope ... --` wrapper),
   keep it: put `WINEDLLOVERRIDES="d3d12=n,b"` at the very start and
   `--rom_enabled true` right after `%command%`.

4. **Play.** Start Hades II and pick **Play Competitive Speedrun** on the title
   screen. You arrive in the Crossroads and the Race Board opens (the first time
   with a welcome page: competitive mode uses a 100% completed save, so expect
   story spoilers). Everything works with a controller.

## Racing

- Races have two to five racers.
- **Find Match** puts you in a public race with whoever else is searching; once a
  second racer is in, the setup starts by itself 15 seconds later (or at once with
  five). **Create Private Race** gives you a 4-character code for your friends;
  you are the host and press **Start Race** once everyone is in. **Race by Code**
  joins a friend's code, or any code you agree on (the first to enter it opens the
  race and hosts it).
- Vote on the route (Underworld, Surface or Dream Dive), the weapon and the keepsake (most
  votes wins, ties are drawn at random).
- Then you have **2 minutes** in the Crossroads to set your Arcana, familiar and
  aspect (close the board with B; the hint at the bottom of the screen says where
  to reopen it: the Pitch-Black Stone). Walk to the voted route's exit and use it
  ("Ready to Race"), or press **Ready Now** on the board. The race starts as soon as
  everyone is ready, or when the 2 minutes run out, after a 3-2-1.
- Every racer gets the same fully upgraded profile, kept in memory only: your own
  save is never loaded or written, and it can't earn achievements. It has seen
  the whole story, so no first-meeting dialogue or tutorials play. Your Arcana,
  familiar and aspects are remembered for next time.
- Every room has the same layout and enemies for everyone whatever doors and
  boons you pick, and the same rewards, gods, shop and well stock are on offer
  as far as your build allows; choices only change what you take.
- One real-time race clock (top right) never pauses. Each rival shows as a shadow
  Melinoë (in their own colour, attacking and dashing as they do) when you share
  a room (marked PAUSED while their game is paused), plus a row on the rival
  plate with their depth, HP and (in a 1v1) boons.
- **Chat:** quick lines (GG, Good luck!, I'm using tilt controls, ...) or your own
  on the on-screen keyboard, from the board's Chat button or, mid-run, the pause
  menu's **Race Menu** (which also has Forfeit Race).
- **Rules:** first to clear wins. Dying, **Forfeit Race** (pause menu) or
  disconnecting is a DNF: the others still have to clear to win, and if nobody
  clears it's a draw. If a rival clears first you can keep going to post your
  time and place. If you're out while others race on, the board shows your
  result and their progress live. When everyone is done, a results screen
  compares the runs.
- The public race server is the default; nothing to configure.
- **Every racer needs matching versions:** the same Ranked Race release line
  (e.g. any 0.5.x) and the same Hades II build. If they differ, the board says
  "Can't race <name>" and who has to update what.

## Update

Get the new files (`git pull`, or a fresh ZIP) and run the installer again. Your
name and settings are kept.

## Uninstall

Run the installer with `--uninstall` (`-Uninstall` on Windows), then clear the
Hades II launch options in Steam. That removes the mods and Hell2Modding (or puts
back the `d3d12.dll` that was there before).

## Good to know

- **Other mods / r2modman:** this install lives in the game folder and is separate
  from r2modman or Gale profiles. Launching through a mod manager uses that
  manager's profile instead (where Ranked Race isn't installed).
- **Normal play** still works with the mod installed; one visible change is that
  the pause menu's "Undo Night" reads "Forfeit Race" (outside a race it still
  undoes the night as usual).
- **Game updates** can move the code the mod hooks into. If that happens the
  title-screen entry or pause-menu forfeit disappears instead of breaking the
  game; update the mod when a new version is out. Tested with Hades II Steam
  build 25481925 (October 2026).
- **Where it's been tested:** the mod and the Linux installer on Linux with Proton
  (the same Windows game build Steam Deck runs). The Windows installer has been
  run through its install/update/uninstall paths, but not yet on a Windows PC.
- **Antivirus** on Windows sometimes flags `d3d12.dll`; it is Hell2Modding's loader
  from Thunderstore (checked by hash).

## For AI agents installing this for someone

Follow these steps exactly; ask the human before anything not listed here.

1. Clone `https://github.com/schmidtwmark/hades2-ranked-race` (or download the ZIP)
   into a working folder. Ask the human what name they want to race under.
2. Run the installer for their OS from the repository root:
   - Windows: `powershell -ExecutionPolicy Bypass -File install\install.ps1 -Name "<name>"`
   - Linux / Steam Deck: `bash install/install.sh --name "<name>"`
   If it reports that Hades II wasn't found, ask the human for the "Hades II"
   folder (Steam → Manage → Browse local files) and pass `--game-dir` / `-GameDir`.
   Use `--dry-run` / `-DryRun` first if you want to show the human the plan.
3. **You cannot set Steam launch options.** Steam keeps them in its own synced
   storage and overwrites edits to its config files, so do not edit
   `localconfig.vdf` or other Steam files. Give the human the exact line the
   installer printed and where to paste it (step 3 above), and wait until they
   confirm.
4. Ask the human to start Hades II once and reach the title screen, then verify
   `<Hades II>/Ship/ReturnOfModding/LogOutput.log` contains all of:
   - `schmidtwmark-RankedRace: === Ranked Race`
   - `competitive: native save guard on 2/2 functions`
   - `competitive: main menu sjson patched`
   and that the title screen shows **Play Competitive Speedrun**.
5. Do not modify save files (Windows `%USERPROFILE%\Saved Games\Hades II`, or
   `.../compatdata/1145350/pfx/drive_c/users/steamuser/Saved Games/Hades II` under
   Proton), install other mods, or change the race server settings.

| Symptom | Cause / fix |
|---|---|
| No `ReturnOfModding/LogOutput.log` at all | Hell2Modding didn't load: on Linux/Deck the `WINEDLLOVERRIDES="d3d12=n,b"` part is missing; on Windows `d3d12.dll` isn't next to `Hades2.exe`. |
| Log says `ReturnOfModding disabled because first enabled launch was explicit` | `--rom_enabled true` is missing from the launch options (this happens after a mod manager was used once). |
| Log has `signature not found` lines | The game updated; those features are off until the mod is updated. Report it. |
| Title screen has no **Play Competitive Speedrun** | Same as above, or the launch went through a mod manager profile instead of Steam. |
| Board says the race server is unreachable | Network/firewall; the server is `hopper.proxy.rlwy.net:16303` (TCP). |
| Board: "This Ranked Race is out of date" | The server needs a newer mod: `git pull` (or a fresh ZIP) and run the installer again. |
| Board: "Can't race X" / "Your Hades II is out of date" | Update Hades II in Steam (Library → Hades II → Update), restart the game. |
| Board: "Can't race X" / "X's Ranked Race (or Hades II) is out of date" | Your rival has to update; search again afterwards. |
| Two racers saw different rooms, encounters or offers | Each race writes a choice log to `ReturnOfModding/plugins_data/schmidtwmark-RankedRace/races/`. Send both racers' logs from that race (`scripts/compare-race-logs.py A.jsonl B.jsonl` shows where they differ). |
