// The racing half of a bot opponent: what it votes, when it readies, the
// progress it reports and how its run ends. Shared by the house bot (add_bot,
// inside the server) and mock-client (a separate process over TCP).

import { NO_PREFERENCE, type ServerMessage } from "./protocol.js";

export interface BotClock {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
  now(): number;
}

export interface BotPlan {
  /** Vote "any" in every vote, so the other racers' picks decide. */
  follow?: boolean;
  route?: string;
  weapon?: string;
  keepsake?: string;
  /** win / die after finishAfter seconds; none: run on until the race is decided by someone else. */
  outcome: "win" | "die" | "none";
  finishAfter: number;
  /** Seconds per room in the progress it reports. */
  progressEvery: number;
  /** Ready to vote once the lobby has this many racers (default 2). */
  readyAt?: number;
  /** Ask for a rematch as soon as someone else does. */
  rematch?: boolean;
}

/** Each route's regions, by the room-name letter the rival plate turns into a region name. */
const REGION_LETTERS: Record<string, string[]> = {
  underworld: ["F", "G", "H", "I"],
  surface: ["N", "O", "P", "Q"],
};
const ROOMS_PER_REGION = 10;

export class BotBrain {
  private timers = new Set<unknown>();
  private raceTimers = new Set<unknown>();
  private raceStart = 0;
  private depth = 0;
  private route = "";
  private voteReady = false;
  private rematchSent = false;
  /** The lobby's other racers (latest state), and those still running this race. */
  private others: string[] = [];
  private running = new Set<string>();

  constructor(
    private readonly plan: BotPlan,
    private readonly send: (m: Record<string, unknown>) => void,
    private readonly clock: BotClock,
  ) {}

  /** Cancel everything still scheduled. */
  stop(): void {
    for (const t of [...this.timers, ...this.raceTimers]) this.clock.clearTimeout(t);
    this.timers.clear();
    this.raceTimers.clear();
  }

  private later(ms: number, fn: () => void, set = this.timers): void {
    const handle = this.clock.setTimeout(() => {
      set.delete(handle);
      fn();
    }, ms);
    set.add(handle);
  }

  private elapsed(): number {
    return (this.clock.now() - this.raceStart) / 1000;
  }

  /** Where the run is at a depth: "F_Bot3" reads as Erebus on the rival plate. */
  private room(depth: number): string {
    const letters = REGION_LETTERS[this.route] ?? REGION_LETTERS.underworld!;
    const region = Math.min(letters.length - 1, Math.floor((depth - 1) / ROOMS_PER_REGION));
    return `${letters[region]}_Bot${depth}`;
  }

  handle(m: ServerMessage): void {
    switch (m.type) {
      case "vote_phase": {
        const want = m.phase === "route" ? this.plan.route : m.phase === "weapon" ? this.plan.weapon : this.plan.keepsake;
        const choice = this.plan.follow ? NO_PREFERENCE : (want ?? m.options[0]?.id);
        if (choice) this.send({ type: `vote_${m.phase}`, [m.phase]: choice });
        break;
      }
      case "lobby_state": {
        const me = m.players.find((p) => p.id === m.you);
        this.others = m.players.filter((p) => p.id !== m.you).map((p) => p.id);
        if (m.phase !== "waiting") this.voteReady = false;
        if (m.phase === "waiting" && !me?.ready && !this.voteReady && m.players.length >= (this.plan.readyAt ?? 2)) {
          this.voteReady = true;
          this.send({ type: "ready" });
        }
        if (m.phase === "ready_check" && !me?.ready) this.send({ type: "ready" });
        if (m.phase !== "finished") this.rematchSent = false;
        if (m.phase === "finished" && this.plan.rematch && !this.rematchSent && !me?.rematch) {
          if (m.players.some((p) => p.id !== m.you && p.rematch)) {
            this.rematchSent = true;
            this.send({ type: "rematch" });
          }
        }
        break;
      }
      case "race_start":
        for (const t of this.raceTimers) this.clock.clearTimeout(t);
        this.raceTimers.clear();
        this.depth = 0;
        this.route = m.route;
        this.running = new Set(this.others);
        this.later(
          m.countdown_ms,
          () => {
            this.raceStart = this.clock.now();
            const step = () => {
              this.depth += 1;
              const depth = this.depth;
              this.send({ type: "progress_update", room: this.room(depth), biome: this.room(depth)[0], depth, hp: 100, max_hp: 100, time: this.elapsed(), alive: true });
              this.later(this.plan.progressEvery * 1000, step, this.raceTimers);
            };
            this.later(this.plan.progressEvery * 1000, step, this.raceTimers);
            if (this.plan.outcome !== "none") {
              const victory = this.plan.outcome === "win";
              this.later(this.plan.finishAfter * 1000, () => this.finish(victory), this.raceTimers);
            }
          },
          this.raceTimers,
        );
        break;
      case "opponent_finished":
        // Every rival dropped out (died/forfeited) and our run has no scripted end: clear shortly.
        this.running.delete(m.id);
        if (!m.victory && this.running.size === 0 && this.plan.outcome === "none") {
          this.later(2000, () => this.finish(true), this.raceTimers);
        }
        break;
      case "race_decided":
        // Lost with no scripted end: give up like a player would, which ends the race.
        if (!m.you_won && this.plan.outcome === "none") {
          for (const t of this.raceTimers) this.clock.clearTimeout(t);
          this.raceTimers.clear();
          this.send({ type: "forfeit" });
        }
        break;
      case "race_result":
        for (const t of this.raceTimers) this.clock.clearTimeout(t);
        this.raceTimers.clear();
        break;
    }
  }

  private finish(victory: boolean): void {
    for (const t of this.raceTimers) this.clock.clearTimeout(t);
    this.raceTimers.clear();
    this.send({ type: "run_complete", victory, time: this.elapsed() });
  }
}
