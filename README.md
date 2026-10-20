# Hades II Ranked Race

A 1v1 race mod for Hades II. Two players join a lobby, vote on a weapon and a
keepsake, and start the same seeded run at the same moment, with a live HUD
showing the opponent's room, depth, HP and time. First to clear wins; if one
dies, the other has to finish to win (both dying is a draw).

## Play

1. Install [Hell2Modding](https://thunderstore.io/c/hades-ii/p/Hell2Modding/Hell2Modding/) and
   [ModUtil](https://thunderstore.io/c/hades-ii/p/SGG_Modding/ModUtil/) (r2modman or Gale does this),
   then copy `mod/src/` into `ReturnOfModding/plugins/schmidtwmark-RankedRace/`.
2. Someone runs the server (below) where both players can reach it.
3. In the Crossroads, press **F8**, enter the server address and your name, **Connect**.
   One player clicks **Create Lobby** and shares the 4-letter code; the other joins with it.
4. Vote, press **Ready**, and the run starts for both of you after a 3-second countdown.

The race forces the voted weapon (base aspect) and keepsake (rank 3) for both
players and restores your own loadout afterwards. Other save progress (Arcana,
Fear, unlocks) is not normalized yet.

## Server

```bash
cd server && npm install && npm run build && PORT=7777 npm start
```

Plain TCP, newline-delimited JSON; message types are in `server/src/protocol.ts`.

## Development

See [CLAUDE.md](CLAUDE.md) for layout and commands and [NOTES.md](NOTES.md) for
what has been verified in the game. `scripts/suite.sh --game` runs everything,
including two real game clients racing each other on the Linux test PC.
