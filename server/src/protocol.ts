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
  | { type: "hello"; name: string; version?: string; token?: string }
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
  | { type: "run_complete"; time: number; victory: boolean }
  | ({ type: "ghost" } & Ghost)
  | { type: "forfeit" }
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

export type ResultReason =
  | "completed_first"
  | "survivor_finished"
  | "both_died"
  | "survivor_timeout"
  | "forfeit"
  | "disconnect";

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
  time: number | null;
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
  | { type: "opponent_finished"; victory: boolean; time: number }
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
  | { type: "error"; message: string; code: string }
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

/** Parse and validate one decoded JSON value into a ClientMessage. */
export function parseClientMessage(raw: unknown): ClientMessage {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new ProtocolError("bad_message", "message must be a JSON object");
  }
  const o = raw as Record<string, unknown>;
  const type = o.type;
  switch (type) {
    case "hello":
      return { type, name: str(o, "name", 32), version: optStr(o, "version"), token: optStr(o, "token", 128) };
    case "create_lobby":
    case "find_match":
    case "cancel_match":
    case "leave_lobby":
    case "ready":
    case "forfeit":
    case "rematch":
      return { type };
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
      return { type, time: num(o, "time"), victory: bool(o, "victory") };
    case "ping":
      return { type, t: optNum(o, "t") };
    default:
      throw new ProtocolError("unknown_type", `unknown message type '${String(type)}'`);
  }
}
