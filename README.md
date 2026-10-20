# Hades II Ranked Race

A 1v1 race mod for Hades II. Two players join a lobby, vote on a weapon and a
keepsake, and start the same seeded run at the same moment, with a live HUD
showing the opponent's room, depth, HP and time. First to clear wins; if one
dies, the other has to finish to win (both dying is a draw).

## Play

1. Install [Hell2Modding](https://thunderstore.io/c/hades-ii/p/Hell2Modding/Hell2Modding/) and
   [ModUtil](https://thunderstore.io/c/hades-ii/p/SGG_Modding/ModUtil/) (r2modman or Gale does this),
   then copy `mod/src/` into `ReturnOfModding/plugins/schmidtwmark-RankedRace/`.
3. On the title screen pick **Play Competitive Speedrun** (identical maxed profile, never touches your
   saves), or press **F8** in your own game. The lobby window connects to the public server by default.
   One player clicks **Create Lobby** and shares the 4-letter code; the other joins with it.
4. Vote, press **Ready**, and the run starts for both of you after a 3-second countdown.

The race forces the voted weapon (base aspect) and keepsake (rank 3) for both
players and restores your own loadout afterwards. Other save progress (Arcana,
Fear, unlocks) is not normalized yet.

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
