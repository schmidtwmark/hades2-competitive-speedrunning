# Hades 2 Competitive Speedrunning (Beta)

Race your friends through Hades II. Two to five players vote on a route, a weapon and a
keepsake, then start the **same seeded run at the same moment**: the same rooms, foes,
rewards, gods, boon offers and shop stock for everyone, as far as each build allows. First
to clear wins.

**Beta:** it runs real races, but expect rough edges. Please report bugs on
[GitHub](https://github.com/schmidtwmark/hades2-competitive-speedrunning/issues).

![The Race Board: a private race, ready to vote](https://raw.githubusercontent.com/schmidtwmark/hades2-competitive-speedrunning/main/docs/screenshots/board.jpg)

## Features

- **Find Match** pairs you with another racer; a **private race** (a 4-character code) holds
  up to five. **Add Bot** puts the server's bot in a private race to practice on your own.
- **Votes** on the route (Underworld, Surface or Dream Dive), the weapon and the keepsake,
  then two minutes in the Crossroads to set your Arcana, aspect and familiar.
- **Same seed, same run:** every room has the same layout and enemies whatever doors and
  boons you pick; choices only change what you take.
- **See your rivals:** a translucent shadow Melinoë for each rival in your room, and a rival
  plate with their region, depth, HP and how far ahead or behind they are.
- **One race clock** that never pauses, with region splits and your best split for the
  region you're in.
- **Personal bests** per route, kept by the race server with your Steam or Epic account and
  shown on the route vote for everyone in the race.
- **Results** comparing the runs: time, depth, damage, foes slain, boons.
- **Quick chat only** (GG, Good luck!, ...): no free text, so nobody can send you anything else.
- **Controller first:** everything is native Hades UI; no keyboard needed.

![Voting on the keepsake](https://raw.githubusercontent.com/schmidtwmark/hades2-competitive-speedrunning/main/docs/screenshots/vote.jpg)

![A rival's shadow and the rival plate](https://raw.githubusercontent.com/schmidtwmark/hades2-competitive-speedrunning/main/docs/screenshots/race.jpg)

![The results](https://raw.githubusercontent.com/schmidtwmark/hades2-competitive-speedrunning/main/docs/screenshots/results.jpg)

## Install

1. In **r2modman** or **Gale**, pick Hades II and install **Hades 2 Competitive Speedrunning** (it brings
   Hell2Modding and ModUtil with it).
2. **Steam Deck / Linux only:** in Steam, set the Hades II launch options (Library →
   right-click Hades II → Properties → Launch Options) to
   `WINEDLLOVERRIDES="d3d12=n,b" %command%`. Proton otherwise loads its own `d3d12.dll`
   and the mod loader never starts. Windows needs nothing here.
3. Launch through the mod manager (**Start modded**) and pick **Play Competitive Speedrun
   (Beta)** on the title screen. The Race Board is at the Pitch-Black Stone in the Crossroads.

Every racer needs Hades 2 Competitive Speedrunning, on the same Hades II version. Update in your mod manager when
a new version is out; the Race Board says when one is.

## Good to know

- **Spoilers:** competitive mode uses a fully completed save profile, kept in memory only:
  every weapon, aspect, keepsake, familiar and Arcana card at full rank. Expect late-game
  story and dialogue. Your own save is never loaded or written, and it earns no achievements.
- **Rules:** first to clear wins. Dying, **Forfeit Race** (pause menu) or disconnecting is a
  DNF: the others still have to clear to win, and if nobody clears it's a draw.
- Your name in races is your Steam (or Epic) name.
- **Normal play** still works with the mod installed.

## About

Open source: [github.com/schmidtwmark/hades2-competitive-speedrunning](https://github.com/schmidtwmark/hades2-competitive-speedrunning),
where you can also report problems. AI disclosure: this mod was developed with Claude
(Anthropic). Hades II and its assets belong to Supergiant Games.
