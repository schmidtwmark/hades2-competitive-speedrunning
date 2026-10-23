// Per-race records for checking afterwards that a race was fair: what each
// racer was offered and took, depth by depth. One folder per race under the
// store's directory (RACE_LOG_DIR; on Railway a volume at /data/races):
//   <stamp>-<lobby>-race<id>/race.json        setup, entrants, results
//   <stamp>-<lobby>-race<id>/<n>-<name>.jsonl  that racer's choice log
// The .jsonl files have the clients' own format (mod/src/racelog.lua) behind a
// start line written here, so scripts/compare-race-logs.py reads them as is.
// scripts/race-report.sh fetches and compares them.

import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { RaceResultEntry, RaceSetup } from "./protocol.js";

export interface LogFs {
  mkdir(path: string): void;
  append(path: string, text: string): void;
  write(path: string, text: string): void;
}

const nodeFs: LogFs = {
  mkdir: (p) => mkdirSync(p, { recursive: true }),
  append: (p, t) => appendFileSync(p, t),
  write: (p, t) => writeFileSync(p, t),
};

/** Lines kept per racer and race: a whole run logs a few hundred. */
export const MAX_LOG_LINES = 5000;

interface Entrant {
  id: string;
  name: string;
  bot: boolean;
}

interface RaceRecord {
  folder: string;
  summary: Record<string, unknown>;
  files: Map<string, { path: string; lines: number }>;
}

const safe = (s: string) => s.replace(/[^A-Za-z0-9-]/g, "_").slice(0, 32) || "racer";

export class RaceLogStore {
  private races = new Map<string, RaceRecord>();

  constructor(
    private readonly dir: string | null,
    private readonly log: (line: string) => void,
    private readonly fs: LogFs = nodeFs,
  ) {}

  private key(lobby: string, raceId: number): string {
    return `${lobby}/${raceId}`;
  }

  /** A race started: its folder, summary and one log per (human) racer. */
  start(lobby: string, race: RaceSetup, entrants: Entrant[], now: number): void {
    if (!this.dir) return;
    this.forget(lobby); // one race per lobby at a time
    const stamp = new Date(now).toISOString().replace(/[-:]/g, "").replace(/\..*/, "").replace("T", "-");
    const folder = join(this.dir, `${stamp}-${lobby}-race${race.race_id}`);
    const summary = { lobby, ...race, started_at: new Date(now).toISOString(), entrants, results: null };
    const rec: RaceRecord = { folder, summary, files: new Map() };
    try {
      this.fs.mkdir(folder);
      this.fs.write(join(folder, "race.json"), JSON.stringify(summary, null, 2) + "\n");
      entrants.forEach((e, i) => {
        if (e.bot) return;
        const path = join(folder, `${i + 1}-${safe(e.name)}.jsonl`);
        const start = { ev: "start", depth: 0, name: e.name, id: e.id, ...race };
        this.fs.write(path, JSON.stringify(start) + "\n");
        rec.files.set(e.id, { path, lines: 1 });
      });
      this.races.set(this.key(lobby, race.race_id), rec);
    } catch (err) {
      this.log(`race log: can't write ${folder}: ${(err as Error).message}`);
    }
  }

  /** One line of a racer's choice log (their own start line is ours instead). */
  event(lobby: string, raceId: number, racerId: string, entry: Record<string, unknown>): void {
    const file = this.races.get(this.key(lobby, raceId))?.files.get(racerId);
    if (!file || entry.ev === "start" || file.lines >= MAX_LOG_LINES) return;
    file.lines += 1;
    try {
      this.fs.append(file.path, JSON.stringify(entry) + "\n");
    } catch (err) {
      this.log(`race log: can't append to ${file.path}: ${(err as Error).message}`);
    }
  }

  /** The race is over: the summary gets the results. Late lines (a racer's "end") still land. */
  finish(lobby: string, raceId: number, results: RaceResultEntry[]): void {
    const rec = this.races.get(this.key(lobby, raceId));
    if (!rec) return;
    rec.summary.results = results.map(({ build: _b, stats: _s, ...r }) => r);
    try {
      this.fs.write(join(rec.folder, "race.json"), JSON.stringify(rec.summary, null, 2) + "\n");
      this.log(`race log: ${rec.folder}`);
    } catch (err) {
      this.log(`race log: can't finish ${rec.folder}: ${(err as Error).message}`);
    }
  }

  /** Stop tracking a lobby's races (their files stay). */
  forget(lobby: string): void {
    for (const k of [...this.races.keys()]) if (k.startsWith(`${lobby}/`)) this.races.delete(k);
  }
}
