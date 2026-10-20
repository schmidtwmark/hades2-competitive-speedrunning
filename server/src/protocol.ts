// Wire protocol: newline-delimited JSON over raw TCP. Every message is an object
// with a string `type`. See plan.md "Message protocol" for the original table;
// this file is the authoritative list.

export const PROTOCOL_VERSION = 1;

export type VotePhase = "weapon" | "keepsake";

export interface VoteOption {
  id: string;
  name: string;
}

export interface Progress {
  room: string;
  biome?: string;
  depth: number;
  hp: number;
  max_hp?: number;
  time: number;
  alive: boolean;
}

export type ClientMessage =
  | { type: "hello"; name: string; version?: string; token?: string }
  | { type: "create_lobby" }
  | { type: "join_lobby"; code: string }
  | { type: "leave_lobby" }
  | { type: "vote_weapon"; weapon: string }
  | { type: "vote_keepsake"; keepsake: string }
  | { type: "ready" }
  | ({ type: "progress_update" } & Progress)
  | { type: "run_complete"; time: number; victory: boolean }
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
    case "leave_lobby":
    case "ready":
    case "forfeit":
    case "rematch":
      return { type };
    case "join_lobby":
      return { type, code: str(o, "code", 16).toUpperCase() };
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
      };
    case "run_complete":
      return { type, time: num(o, "time"), victory: bool(o, "victory") };
    case "ping":
      return { type, t: optNum(o, "t") };
    default:
      throw new ProtocolError("unknown_type", `unknown message type '${String(type)}'`);
  }
}
