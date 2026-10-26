// Wire protocol: newline-delimited JSON over raw TCP. Every message is an object
// with a string `type`. See plan.md "Message protocol" for the original table;
// this file is the authoritative list.

/** A vote for no option in particular: counts as voted, adds no vote (the mock bot's "follow" mode). */
export const NO_PREFERENCE = "any";

export const PROTOCOL_VERSION = 1;

/** Voted in this order: where the run goes, then the weapon, then the keepsake. */
export type VotePhase = "route" | "weapon" | "keepsake";
export const VOTE_ORDER: VotePhase[] = ["route", "weapon", "keepsake"];

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

/** The store a player's account is on. */
export type Platform = "steam" | "epic";

/** One region split of a clear: the region's name and the race time (seconds) it ended at. */
export interface Split {
  name: string;
  time: number;
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
  /** Counts the racer's attacks/dashes, so a repeat of the same animation replays. */
  act?: number;
  /** The racer has the game paused (their shadow freezes with a pause icon). */
  paused?: boolean;
  t: number;
}

export type ClientMessage =
  /**
   * version: the mod's version; game_build: the Hades II executable's link time (Unix seconds);
   * platform / platform_id: the store account (SteamID64 in decimal, or the Epic account id),
   * the player's key for personal bests. Self-reported: not verified yet.
   */
  | { type: "hello"; name: string; version?: string; token?: string; game_build?: number; platform?: Platform; platform_id?: string }
  | { type: "create_lobby" }
  /** The store account, found after hello (see hello); name: the store name, used from the next lobby on. */
  | { type: "identify"; platform?: Platform; platform_id?: string; name?: string }
  | { type: "find_match" }
  | { type: "cancel_match" }
  /** create: if no lobby has this code yet, open one under it and wait (both racers can type an agreed code). */
  | { type: "join_lobby"; code: string; create?: boolean }
  | { type: "leave_lobby" }
  | { type: "vote_route"; route: string }
  | { type: "vote_weapon"; weapon: string }
  | { type: "vote_keepsake"; keepsake: string }
  /**
   * waiting: ready to vote (voting starts once everyone in the lobby is, two or more);
   * ready: false takes it back. ready_check: ready for the start (in game: activating
   * the voted route's start in the Crossroads).
   */
  | { type: "ready"; ready?: boolean }
  | ({ type: "progress_update" } & Progress)
  | { type: "run_complete"; time: number; victory: boolean; stats?: RunStats; build?: BuildEntry[]; splits?: Split[] }
  | ({ type: "ghost" } & Ghost)
  /** Give up the run: a DNF, exactly like dying (the rival still has to finish to win). */
  | { type: "forfeit"; stats?: RunStats; build?: BuildEntry[] }
  | { type: "rematch" }
  /** A private lobby still waiting: a house bot joins (votes "any", readies, never clears first). */
  | { type: "add_bot" }
  /**
   * One line of the racer's choice log (mod/src/racelog.lua: rooms, encounters,
   * doors, offers, picks), kept by the server per race for fairness checks.
   */
  | { type: "race_log"; race_id: number; entry: Record<string, unknown> }
  /** A chat line to everyone in the lobby: one of the quick lines (chat.ts), nothing else. */
  | { type: "chat"; text: string }
  | { type: "ping"; t?: number };

export type LobbyPhase =
  | "waiting"
  | "voting_route"
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
  /** The lobby's host: starts a private race once enough racers have joined. */
  host: boolean;
  /** Asked for a rematch after the last race. */
  rematch: boolean;
  /** A house bot (add_bot), not a person. */
  bot: boolean;
  /** Personal best clear per route (official seconds), for players with a store account. */
  best: Record<string, number>;
}

/** Who a relayed message is about (races have up to five racers). */
export interface Who {
  id: string;
  name: string;
}

export interface RaceResultEntry {
  id: string;
  name: string;
  /** 1 = winner. Clears by time, then DNFs by depth reached. */
  place: number;
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
  /** Voted route id ("underworld", "surface", ...); "" when routes aren't voted on. */
  route: string;
}

export type ServerMessage =
  /** latest_mod: the newest mod release (older clients show how to update). */
  | { type: "welcome"; id: string; token: string; protocol: number; server_time: number; resumed: boolean; latest_mod: string }
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
      /** A Find Match lobby (two racers) rather than a private one (shared by its code). */
      public: boolean;
      max_players: number;
      /** ready_check: seconds until the race starts anyway (prep time for Arcana, aspect, familiar). */
      prep_ends_in: number | null;
    }
  | { type: "lobby_left" }
  | { type: "vote_phase"; phase: VotePhase; options: VoteOption[]; timer: number }
  | { type: "vote_cast"; phase: VotePhase; by: "you" | "opponent"; id: string; name: string; voted: number; of: number }
  | {
      type: "vote_result";
      phase: VotePhase;
      selected: string;
      /** opponent: the other racer's vote in a 1v1, null otherwise; counts: votes per option. */
      votes: { you: string | null; opponent: string | null };
      counts: Record<string, number>;
    }
  /** best: this racer's personal best on the route (time + region splits), for the split targets. */
  | ({ type: "race_start"; countdown: number; countdown_ms: number; best?: { time: number; splits: Split[] } } & RaceSetup)
  | ({ type: "opponent_progress" } & Progress & Who)
  | ({ type: "opponent_ghost" } & Ghost & { id: string })
  | ({ type: "opponent_finished"; victory: boolean; time: number | null; outcome: Outcome } & Who)
  /** The winner is known while someone is still running (they may finish their run); race_result follows. */
  | { type: "race_decided"; race_id: number; winner: string | null; winner_name: string | null; draw: boolean; you_won: boolean; reason: ResultReason }
  | ({ type: "opponent_disconnected"; grace: number } & Who)
  | ({ type: "opponent_reconnected" } & Who)
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
  /** A chat line from someone in the lobby (also echoed to the sender). */
  | ({ type: "chat"; text: string } & Who)
  | { type: "pong"; t: number | null; server_time: number }
  /** How many racers are connected, in Find Match and in a race (sent on hello and when it changes). */
  | { type: "presence"; online: number; searching: number; racing: number };

export class ProtocolError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

/** A store account: Steam ids are decimal SteamID64s, Epic ids hex. Anything else is dropped. */
function platformId(o: Record<string, unknown>): { platform?: Platform; platform_id?: string } {
  const id = typeof o.platform_id === "string" ? o.platform_id : "";
  if (o.platform === "steam" && /^\d{1,20}$/.test(id)) return { platform: "steam", platform_id: id };
  if (o.platform === "epic" && /^[0-9a-f]{8,64}$/.test(id)) return { platform: "epic", platform_id: id };
  return {};
}

function optSplits(o: Record<string, unknown>): Split[] | undefined {
  const v = o.splits;
  if (v === undefined || v === null) return undefined;
  if (typeof v === "object" && !Array.isArray(v) && Object.keys(v as object).length === 0) return [];
  if (!Array.isArray(v) || v.length > 16) throw new ProtocolError("bad_field", "field 'splits' must be a list (max 16)");
  return v.map((e) => {
    if (typeof e !== "object" || e === null) throw new ProtocolError("bad_field", "splits must be objects");
    const r = e as Record<string, unknown>;
    return { name: str(r, "name", 40), time: num(r, "time") };
  });
}

/** A race log line: a JSON object of at most MAX_LOG_ENTRY characters. */
export const MAX_LOG_ENTRY = 8192;
function logEntry(o: Record<string, unknown>): Record<string, unknown> {
  const v = o.entry;
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new ProtocolError("bad_field", "field 'entry' must be an object");
  if (JSON.stringify(v).length > MAX_LOG_ENTRY) throw new ProtocolError("bad_field", `race log entries are at most ${MAX_LOG_ENTRY} characters`);
  return v as Record<string, unknown>;
}

/** Chat text: control characters removed, whitespace collapsed, 1-80 characters. */
function chatText(o: Record<string, unknown>): string {
  const raw = typeof o.text === "string" ? o.text : "";
  const text = raw.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (text.length === 0 || text.length > 80) throw new ProtocolError("bad_field", "chat text must be 1-80 characters");
  return text;
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
        ...platformId(o),
      };
    case "ready":
      return { type, ...(o.ready === false ? { ready: false } : {}) };
    case "identify":
      return { type, ...platformId(o), ...(typeof o.name === "string" ? { name: str(o, "name", 32) } : {}) };
    case "create_lobby":
    case "find_match":
    case "cancel_match":
    case "leave_lobby":
    case "rematch":
    case "add_bot":
      return { type };
    case "forfeit":
      return { type, stats: optStats(o), build: optBuild(o) };
    case "join_lobby":
      return { type, code: str(o, "code", 16).toUpperCase(), ...(o.create === true ? { create: true } : {}) };
    case "vote_route":
      return { type, route: str(o, "route") };
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
        act: optNum(o, "act"),
        paused: o.paused === true ? true : undefined,
        t: num(o, "t"),
      };
    case "run_complete":
      return { type, time: num(o, "time"), victory: bool(o, "victory"), stats: optStats(o), build: optBuild(o), splits: optSplits(o) };
    case "race_log":
      return { type, race_id: num(o, "race_id"), entry: logEntry(o) };
    case "chat":
      return { type, text: chatText(o) };
    case "ping":
      return { type, t: optNum(o, "t") };
    default:
      throw new ProtocolError("unknown_type", `unknown message type '${String(type)}'`);
  }
}
