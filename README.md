# Hades II Ranked Race

A 1v1 race mod for Hades II. Two players meet on the in-game Race Board, vote
on a weapon and a keepsake, and start the same seeded run at the same moment.
During the run you see your rival as a translucent shadow Melinoë whenever you
are in the same room, plus a rival plate (top right) with their biome and
depth, how far ahead or behind you they are, their HP and their boons, under a
single real-time race clock that never pauses (the game's own timer, which
stops for menus and boon choices, is hidden). Everything works with a
controller; no keyboard or mod keys needed.

Rules: the first racer to clear the run wins. Dying, forfeiting (pause menu →
Forfeit Race) or disconnecting is a DNF: the other racer still has to clear to
win, and if neither clears it is a draw. If your rival clears first you have
lost, but you can keep going to finish your run and post your time. When both
are done, a results screen compares your run with your rival's: result and
time, depth, damage dealt and taken, foes slain, healing, gold, death defiances
and both boon lists.

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
