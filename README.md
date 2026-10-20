# Hades II Ranked Race

A 1v1 race mod for Hades II. Two players join a lobby, vote on a weapon and a
keepsake, and start the same seeded run at the same moment, with a live HUD
showing the opponent's room, depth, HP and time. First to clear wins; if one
dies, the other has to finish to win (both dying is a draw).

## Play

1. Install [Hell2Modding](https://thunderstore.io/c/hades-ii/p/Hell2Modding/Hell2Modding/) and
   [ModUtil](https://thunderstore.io/c/hades-ii/p/SGG_Modding/ModUtil/) (r2modman or Gale does this),
   then copy `mod/src/` into `ReturnOfModding/plugins/schmidtwmark-RankedRace/`.
2. On the title screen pick **Play Competitive Speedrun**, or press **F8** in your own game. The lobby
   window connects to the public server by default. One player clicks **Create Lobby** and shares the
   4-letter code; the other joins with it.
3. Vote on weapon and keepsake. In competitive mode, set your Arcana, familiar and aspect in the
   Training Grounds, then press **Ready**; the run starts for both of you after a 3-second countdown.

Competitive mode gives both players the same fully maxed profile (every weapon, aspect, keepsake,
familiar and Arcana card at max rank, Grasp 30, Fear 0) built in memory; it never reads or writes
your saves. Each depth has the same room and enemies for both players whatever doors and boons they
pick; choices only change rewards. Racing from your own save (F8) forces the voted weapon at its base
aspect and keepsake at rank 3, and restores your loadout afterwards.

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
