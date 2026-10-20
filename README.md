# Hades II Ranked Race

A 1v1 race mod for Hades II. Two players meet on the in-game Race Board, vote
on a weapon and a keepsake, and start the same seeded run at the same moment.
During the run you see your rival as a translucent shadow Melinoë whenever you
are in the same room, plus a rival plate (top right) with their biome and
depth, how far ahead or behind you they are, their HP and their boons. First
to clear wins; if one dies, the other has to finish to win (both dying is a
draw). Everything works with a controller; no keyboard or mod keys needed.

## Play

1. Install [Hell2Modding](https://thunderstore.io/c/hades-ii/p/Hell2Modding/Hell2Modding/) and
   [ModUtil](https://thunderstore.io/c/hades-ii/p/SGG_Modding/ModUtil/) (r2modman or Gale does this),
   then copy `mod/src/` into `ReturnOfModding/plugins/schmidtwmark-RankedRace/`.
2. On the title screen pick **Play Competitive Speedrun**. You arrive at the Crossroads and the
   **Race Board** opens (later, walk to the Pitch-Black Stone and press Interact: "Race"):
   - **Find Match** pairs you with the next player who also picks it.
   - **Create Private Race** gives you a 4-character code to share.
   - **Race by Code** types a code with the on-screen keys: your rival's code, or any code you two
     agreed on (the first to enter it opens the race, the second joins).
3. Vote on weapon and keepsake (icons, D-pad + A). Close the board with B to set your Arcana,
   familiar and aspect, come back to the stone, press **Ready**; a 3-2-1 countdown starts the run
   for both of you. Afterwards the board shows the result with **Rematch**.

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
