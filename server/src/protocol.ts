// Wire protocol: newline-delimited JSON over raw TCP. Every message is an object
// with a string `type`. See plan.md "Message protocol" for the original table;
// this file is the authoritative list.

export const PROTOCOL_VERSION = 1;

export type VotePhase = "weapon" | "keepsake";

export interface VoteOption {
  id: string;
  name: string;
}

export interface BuildEntry {
  name: string;
  rarity?: string;
  /** Loot source (e.g. "ZeusUpgrade", "TrialUpgrade" for Chaos). */
  source?: string;
  level?: number;
}

/** Per-run numbers for the results screen (damage dealt/taken, kills, ...). Opaque to the server. */
export type RunStats = Record<string, number>;

export interface Progress {
  room: string;
  biome?: string;
  depth: number;
  hp: number;
  max_hp?: number;
  time: number;
  alive: boolean;
  /** Present only when the build changed since the last update. */
  build?: BuildEntry[];
  stats?: RunStats;
}

/** High-rate position snapshot for the opponent's shadow (never stored). */
export interface Ghost {
  room: string;
  depth: number;
  x: number;
  y: number;
  angle?: number;
  anim?: string;
  t: number;
}

export type ClientMessage =
  /** version: the mod's version; game_build: the Hades II executable's link time (Unix seconds). */
  | { type: "hello"; name: string; version?: string; token?: string; game_build?: number }
  | { type: "create_lobby" }
  | { type: "find_match" }
  | { type: "cancel_match" }
  /** create: if no lobby has this code yet, open one under it and wait (both racers can type an agreed code). */
  | { type: "join_lobby"; code: string; create?: boolean }
  | { type: "leave_lobby" }
  | { type: "vote_weapon"; weapon: string }
  | { type: "vote_keepsake"; keepsake: string }
  | { type: "ready" }
  | ({ type: "progress_update" } & Progress)
  | { type: "run_complete"; time: number; victory: boolean; stats?: RunStats; build?: BuildEntry[] }
  | ({ type: "ghost" } & Ghost)
  /** Give up the run: a DNF, exactly like dying (the rival still has to finish to win). */
  | { type: "forfeit"; stats?: RunStats; build?: BuildEntry[] }
  | { type: "rematch" }
  | { type: "ping"; t?: number };

export type LobbyPhase =
  | "waiting"
  | "voting_weapon"
  | "voting_keepsake"
  | "ready_check"
  | "countdown"
  | "racing"
  | "finished";

/**
 * Why the race went the way it did. The first racer to clear wins; a racer who
 * dies, forfeits or disconnects is a DNF and the other must still clear to win;
 * no clears at all is a draw.
 */
export type ResultReason =
  | "completed_first"
  | "survivor_finished"
  | "no_finishers"
  | "time_limit";

/** How one racer's run ended. */
export type Outcome = "cleared" | "died" | "forfeit" | "disconnect" | "timeout";

export interface PlayerSummary {
  id: string;
  name: string;
  connected: boolean;
  ready: boolean;
}

export interface RaceResultEntry {
  id: string;
  name: string;
  finished: boolean;
  victory: boolean;
  outcome: Outcome;
  /** Official real time from the race start (server clock), seconds; null for a DNF without a time. */
  time: number | null;
  depth: number | null;
  room: string | null;
  build: BuildEntry[];
  stats: RunStats;
}

export interface RaceSetup {
  race_id: number;
  seed: number;
  weapon: string;
  keepsake: string;
}

export type ServerMessage =
  | { type: "welcome"; id: string; token: string; protocol: number; server_time: number; resumed: boolean }
  | { type: "lobby_created"; code: string }
  | { type: "queued"; waiting: number }
  | { type: "match_cancelled" }
  | { type: "lobby_joined"; code: string; opponent: string | null }
  | {
      type: "lobby_state";
      code: string;
      phase: LobbyPhase;
      you: string;
      players: PlayerSummary[];
      race: RaceSetup | null;
    }
  | { type: "lobby_left" }
  | { type: "vote_phase"; phase: VotePhase; options: VoteOption[]; timer: number }
  | { type: "vote_cast"; phase: VotePhase; by: "you" | "opponent" }
  | { type: "vote_result"; phase: VotePhase; selected: string; votes: { you: string | null; opponent: string | null } }
  | ({ type: "race_start"; countdown: number; countdown_ms: number } & RaceSetup)
  | ({ type: "opponent_progress" } & Progress)
  | ({ type: "opponent_ghost" } & Ghost)
  | { type: "opponent_finished"; victory: boolean; time: number | null; outcome: Outcome }
  /** The winner is known while someone is still running (they may finish their run); race_result follows. */
  | { type: "race_decided"; race_id: number; winner: string | null; winner_name: string | null; draw: boolean; you_won: boolean; reason: ResultReason }
  | { type: "opponent_disconnected"; grace: number }
  | { type: "opponent_reconnected" }
  | {
      type: "race_result";
      race_id: number;
      winner: string | null;
      winner_name: string | null;
      draw: boolean;
      you_won: boolean;
      reason: ResultReason;
      results: RaceResultEntry[];
    }
  /**
   * update_required: this client's mod is too old for the server.
   * version_mismatch: can't race `rival`; `who` must update `what` ("you", "rival" or "both").
   */
  | { type: "error"; message: string; code: string; who?: "you" | "rival" | "both"; what?: "mod" | "game"; rival?: string }
  | { type: "pong"; t: number | null; server_time: number };

export class ProtocolError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

function str(o: Record<string, unknown>, key: string, max = 64): string {
  const v = o[key];
  if (typeof v !== "string" || v.length === 0 || v.length > max) {
    throw new ProtocolError("bad_field", `field '${key}' must be a non-empty string`);
  }
  return v;
}

function num(o: Record<string, unknown>, key: string): number {
  const v = o[key];
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new ProtocolError("bad_field", `field '${key}' must be a number`);
  }
  return v;
}

function bool(o: Record<string, unknown>, key: string): boolean {
  const v = o[key];
  if (typeof v !== "boolean") {
    throw new ProtocolError("bad_field", `field '${key}' must be a boolean`);
  }
  return v;
}

function optStr(o: Record<string, unknown>, key: string, max = 64): string | undefined {
  return o[key] === undefined || o[key] === null ? undefined : str(o, key, max);
}

function optNum(o: Record<string, unknown>, key: string): number | undefined {
  return o[key] === undefined || o[key] === null ? undefined : num(o, key);
}

function optBuild(o: Record<string, unknown>): BuildEntry[] | undefined {
  const v = o.build;
  if (v === undefined || v === null) return undefined;
  // An empty build arrives as {} from the Lua encoder (empty tables are objects).
  if (typeof v === "object" && !Array.isArray(v) && Object.keys(v as object).length === 0) return [];
  if (!Array.isArray(v) || v.length > 64) throw new ProtocolError("bad_field", "field 'build' must be a list (max 64)");
  return v.map((e) => {
    if (typeof e !== "object" || e === null) throw new ProtocolError("bad_field", "build entries must be objects");
    const r = e as Record<string, unknown>;
    return { name: str(r, "name"), rarity: optStr(r, "rarity"), source: optStr(r, "source"), level: optNum(r, "level") };
  });
}

function optStats(o: Record<string, unknown>): RunStats | undefined {
  const v = o.stats;
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "object" || Array.isArray(v)) throw new ProtocolError("bad_field", "field 'stats' must be an object");
  const entries = Object.entries(v as Record<string, unknown>);
  if (entries.length > 32) throw new ProtocolError("bad_field", "field 'stats' has too many entries (max 32)");
  const out: RunStats = {};
  for (const [k, n] of entries) {
    if (k.length > 40 || typeof n !== "number" || !Number.isFinite(n)) {
      throw new ProtocolError("bad_field", "stats must map short names to finite numbers");
    }
    out[k] = n;
  }
  return out;
}

/** Parse and validate one decoded JSON value into a ClientMessage. */
export function parseClientMessage(raw: unknown): ClientMessage {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new ProtocolError("bad_message", "message must be a JSON object");
  }
  const o = raw as Record<string, unknown>;
  const type = o.type;
  switch (type) {
    case "hello":
      return {
        type,
        name: str(o, "name", 32),
        version: optStr(o, "version"),
        token: optStr(o, "token", 128),
        game_build: optNum(o, "game_build"),
      };
    case "create_lobby":
    case "find_match":
    case "cancel_match":
    case "leave_lobby":
    case "ready":
    case "rematch":
      return { type };
    case "forfeit":
      return { type, stats: optStats(o), build: optBuild(o) };
    case "join_lobby":
      return { type, code: str(o, "code", 16).toUpperCase(), ...(o.create === true ? { create: true } : {}) };
    case "vote_weapon":
      return { type, weapon: str(o, "weapon") };
    case "vote_keepsake":
      return { type, keepsake: str(o, "keepsake") };
    case "progress_update":
      return {
        type,
        room: str(o, "room"),
        biome: optStr(o, "biome"),
        depth: num(o, "depth"),
        hp: num(o, "hp"),
        max_hp: optNum(o, "max_hp"),
        time: num(o, "time"),
        alive: bool(o, "alive"),
        build: optBuild(o),
        stats: optStats(o),
      };
    case "ghost":
      return {
        type,
        room: str(o, "room"),
        depth: num(o, "depth"),
        x: num(o, "x"),
        y: num(o, "y"),
        angle: optNum(o, "angle"),
        anim: optStr(o, "anim"),
        t: num(o, "t"),
      };
    case "run_complete":
      return { type, time: num(o, "time"), victory: bool(o, "victory"), stats: optStats(o), build: optBuild(o) };
    case "ping":
      return { type, t: optNum(o, "t") };
    default:
      throw new ProtocolError("unknown_type", `unknown message type '${String(type)}'`);
  }
}
