// Personal bests per player and route, kept by the server: each player's
// fastest clear (official race time, the server's clock) with its region
// splits. Players are keyed by their store account ("steam:<SteamID64>",
// "epic:<account id>"), so reinstalling the mod keeps them. One JSON file
// (PB_FILE; on Railway /data/pbs.json), rewritten on every new best.

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import type { Split } from "./protocol.js";

export interface PbFs {
  read(path: string): string | null;
  write(path: string, text: string): void;
}

const nodeFs: PbFs = {
  read: (p) => {
    try {
      return readFileSync(p, "utf8");
    } catch {
      return null;
    }
  },
  // Write a temporary file, then rename: a crash mid-write leaves the old file.
  write: (p, t) => {
    writeFileSync(`${p}.tmp`, t);
    renameSync(`${p}.tmp`, p);
  },
};

export interface RouteBest {
  time: number;
  splits: Split[];
  /** When it was set (ISO) and in which lobby's race. */
  at: string;
  race: string;
}

interface PlayerBests {
  name: string;
  routes: Record<string, RouteBest>;
}

export class PbStore {
  private players: Record<string, PlayerBests> = {};

  constructor(
    private readonly path: string | null,
    private readonly log: (line: string) => void,
    private readonly fs: PbFs = nodeFs,
  ) {
    const text = path ? this.fs.read(path) : null;
    if (!text) return;
    try {
      const data = JSON.parse(text) as { players?: Record<string, PlayerBests> };
      this.players = data.players ?? {};
      this.log(`personal bests: ${Object.keys(this.players).length} players from ${path}`);
    } catch (err) {
      this.log(`personal bests: can't read ${path}: ${(err as Error).message}`);
    }
  }

  /** Best clear time per route for this player (empty when none or no key). */
  best(key: string | null): Record<string, number> {
    const out: Record<string, number> = {};
    if (!key) return out;
    for (const [route, b] of Object.entries(this.players[key]?.routes ?? {})) out[route] = b.time;
    return out;
  }

  /** A clear: kept if it beats the player's best on that route. Returns whether it did. */
  record(key: string, name: string, route: string, time: number, splits: Split[], race: string, now: number): boolean {
    const player = (this.players[key] ??= { name, routes: {} });
    player.name = name;
    const old = player.routes[route];
    if (old && old.time <= time) return false;
    player.routes[route] = { time, splits, at: new Date(now).toISOString(), race };
    this.log(`personal best: ${key} (${name}) ${route} ${time}s${old ? ` (was ${old.time}s)` : ""}`);
    if (this.path) {
      try {
        this.fs.write(this.path, JSON.stringify({ version: 1, players: this.players }, null, 1) + "\n");
      } catch (err) {
        this.log(`personal bests: can't write ${this.path}: ${(err as Error).message}`);
      }
    }
    return true;
  }
}
