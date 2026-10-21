# Hades II Ranked Race

A race mod for Hades II for two to five players. Racers meet on the in-game
Race Board, vote on the route (Underworld, Surface or Dream Dive), a weapon and a keepsake,
get two minutes to set Arcana, aspect and familiar, and start the same seeded
run at the same moment. Every racer is offered the same rooms, foes, rewards,
gods, boons and shop stock as far as their build allows. Quick-chat lines and an
on-screen keyboard work from the board and the pause menu. During the run you see each rival as a translucent shadow
Melinoë (one colour per rival, attacking and dashing as they do) whenever you
are in the same room, plus a rival
plate (top right) with their biome and depth, how far ahead or behind you they
are, their HP and (in a 1v1) their boons, under a single real-time race clock
that never pauses (the game's own timer, which stops for menus and boon
choices, is hidden). Everything works with a controller; no keyboard or mod
keys needed.

Rules: the first racer to clear the run wins. Dying, forfeiting (pause menu →
Forfeit Race) or disconnecting is a DNF: the others still have to clear to
win, and if nobody clears it is a draw. If a rival clears first you have lost,
but you can keep going to finish your run and post your time and place. When
everyone is done, a results screen compares the runs: place, result and time,
depth, damage dealt and taken, foes slain, healing, gold, death defiances and
every racer's boons (side by side in a 1v1, a standings table for three or
more).

## Play

See **[INSTALL.md](INSTALL.md)**: one script per system (Windows, Linux / Steam
Deck) installs the mod loader, its dependencies and the mod; then set one Steam
launch option and pick **Play Competitive Speedrun** on the title screen. It also
has step-by-step instructions for an AI agent installing it for you.

Competitive mode gives both players the same fully maxed profile (every weapon, aspect, keepsake,
familiar and Arcana card at max rank, Grasp 30, Fear 0) built in memory; it never reads or writes
your saves. Each depth has the same room and enemies for both players whatever doors and boons they
pick; choices only change rewards. Racing from your own save (F8 opens a debug lobby window) forces
the voted weapon at its base aspect and keepsake at rank 3, and restores your loadout afterwards.

## Server

The public server runs on Railway (project `hades2-ranked-race`, service
`race-server`) at **`hopper.proxy.rlwy.net:16303`**, which is the mod's default.
It is plain TCP behind Railway's TCP proxy, not HTTP. Redeploy after server
changes with:

```bash
scripts/railway-deploy.sh
```

To run your own instead:

```bash
cd server && npm install && npm run build && PORT=7777 npm start
```

Plain TCP, newline-delimited JSON; message types are in `server/src/protocol.ts`.

## Development

See [CLAUDE.md](CLAUDE.md) for layout and commands and [NOTES.md](NOTES.md) for
what has been verified in the game. `scripts/suite.sh --game` runs everything,
including two real game clients racing each other on the Linux test PC.

## How it was made, and license

This mod was developed with AI (Claude, by Anthropic), and it is fully open
source under the [MIT License](LICENSE). It is a fan project, not affiliated with
Supergiant Games; Hades II and its assets belong to Supergiant. The installers
download the mod loader and libraries from Thunderstore; nothing from the game is
included here.
