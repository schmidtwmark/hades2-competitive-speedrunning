// Transport-independent race server. The TCP layer (tcp.ts) feeds decoded
// messages in through Session.receive(); everything here is driven by an
// injectable clock/timer and RNG so tests can run it deterministically.

import { randomBytes } from "node:crypto";
import { BotBrain } from "./bot-brain.js";
import { isQuickLine } from "./chat.js";
import { PbStore } from "./pb-store.js";
import { RaceLogStore } from "./race-log-store.js";
import {
  NO_PREFERENCE,
  PROTOCOL_VERSION,
  ProtocolError,
  parseClientMessage,
  type ClientMessage,
  type Ghost,
  type LobbyPhase,
  type Progress,
  type RaceResultEntry,
  type RaceSetup,
  type ResultReason,
  type ServerMessage,
  type VoteOption,
  type VotePhase,
  type BuildEntry,
  type Outcome,
  type RunStats,
  type Split,
  VOTE_ORDER,
} from "./protocol.js";
import { type ClientVersions, compatibility, LATEST_MOD_VERSION, MIN_MOD_VERSION, type Mismatch, mismatchMessage, modTooOld, tooOldMessage } from "./versions.js";

export interface Scheduler {
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export interface Random {
  /** Uniform integer in [0, n). */
  int(n: number): number;
}

export const realScheduler: Scheduler = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as NodeJS.Timeout),
};

export const realRandom: Random = {
  int: (n) => randomBytes(4).readUInt32BE(0) % n,
};

export interface ServerOptions {
  voteSeconds: number;
  countdownMs: number;
  /** Hard cap on a race (real time from the start); anyone still running then is a DNF. */
  raceTimeLimitMs: number;
  /** How long a dropped player may reconnect before they leave / forfeit. */
  reconnectGraceMs: number;
  idleLobbyMs: number;
  /** Oldest mod version accepted (default MIN_MOD_VERSION). */
  minModVersion?: string;
  /** Newest mod release, told to clients (default LATEST_MOD_VERSION). */
  latestModVersion?: string;
  /** Racers per private lobby (default 5). */
  maxPlayers?: number;
  /** Racers per Find Match lobby (default 2; more race together through a private lobby). */
  matchPlayers?: number;
  /** House bots (add_bot): seconds per room in the progress they report (default 75). */
  botRoomSeconds?: number;
  /** Where each race's record and racers' choice logs go; none: not kept. */
  raceLogs?: RaceLogStore;
  /** Players' personal bests per route; none: not kept. */
  pbs?: PbStore;
  /** Options per vote; a missing or empty pool skips that vote. */
  pools: Partial<Record<VotePhase, VoteOption[]>>;
  /** After the votes: time to set Arcana/aspect/familiar before the race starts anyway (default 120 s). */
  prepMs?: number;
  /** Tests: every race uses this seed (replays a seed a bug showed up on). */
  fixedSeed?: number;
  scheduler: Scheduler;
  random: Random;
  log: (line: string) => void;
}

/** The vote a lobby phase is collecting, if any. */
function votePhaseOf(phase: LobbyPhase): VotePhase | null {
  const m = /^voting_(.+)$/.exec(phase);
  return m && (VOTE_ORDER as string[]).includes(m[1]!) ? (m[1] as VotePhase) : null;
}

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const isLobbyCode = (code: string) => code.length === 4 && [...code].every((ch) => CODE_ALPHABET.includes(ch));
const MAX_SEED = 2 ** 31 - 1;
/** A house bot answers this long after a message, like a player would. */
const BOT_DELAY_MS = 400;

interface RunResult {
  outcome: Outcome;
  victory: boolean;
  /** Official time: server clock since the race start, seconds (null for a DNF before the start). */
  time: number | null;
  clientTime: number | null;
  stats?: RunStats;
  build?: BuildEntry[];
  splits?: Split[];
}

interface RaceState extends RaceSetup {
  startAt: number | null;
  /** Everyone who started, kept even if they leave, so results stay complete. */
  entrants: { id: string; name: string; key: string | null; base: string }[];
  /** Insertion order is finishing order. */
  results: Map<string, RunResult>;
  progress: Map<string, Progress>;
  /** Latest build/stats per racer (progress only carries the build when it changes). */
  build: Map<string, BuildEntry[]>;
  stats: Map<string, RunStats>;
  /** undefined until decided; null = draw. */
  winner: string | null | undefined;
  reason: ResultReason | null;
  decidedSent: boolean;
  over: boolean;
}

class Lobby {
  phase: LobbyPhase = "waiting";
  /** players[0] is the host. */
  players: Session[] = [];
  /** Made by Find Match (two racers) rather than shared by its code. */
  isPublic = false;
  votes: Record<VotePhase, Map<string, string>> = { route: new Map(), weapon: new Map(), keepsake: new Map() };
  selected: Record<VotePhase, string | null> = { route: null, weapon: null, keepsake: null };
  /** ready_check: when the race starts even if not everyone is ready. */
  prepEndsAt: number | null = null;
  /** waiting: ready to vote; ready_check: ready for the start. */
  ready = new Set<string>();
  rematch = new Set<string>();
  race: RaceState | null = null;
  raceCounter = 0;
  timer: unknown = null;
  raceTimer: unknown = null;

  constructor(
    readonly code: string,
    public lastActivity: number,
    readonly maxPlayers: number,
  ) {}

  /** Two or more racers: enough to vote, start and rematch. */
  get enough(): boolean {
    return this.players.length >= 2;
  }

  others(s: Session): Session[] {
    return this.players.filter((p) => p !== s);
  }

  get host(): Session | undefined {
    return this.players[0];
  }
}

const who = (s: Session) => ({ id: s.id, name: s.name });

/** One transport connection. After a resume it points at the resumed session. */
export class Connection {
  constructor(
    private readonly server: RaceServer,
    readonly sendRaw: (msg: ServerMessage) => void,
    public session: Session,
  ) {}

  /** Feed one decoded JSON value from the transport. */
  receive(raw: unknown): void {
    this.server.handle(this, raw);
  }

  /** Transport closed. */
  close(): void {
    this.server.closed(this);
  }
}

export class Session {
  readonly token = randomBytes(16).toString("hex");
  name = "";
  greeted = false;
  conn: Connection | null = null;
  lobby: Lobby | null = null;
  graceTimer: unknown = null;
  versions: ClientVersions = { mod: null, gameBuild: null };
  lastChat = -Infinity;
  /** A house bot's brain (add_bot): it has no transport and never reconnects. */
  bot: BotBrain | null = null;
  /** The store account ("steam:<id>" / "epic:<id>"): the player's key for personal bests. */
  key: string | null = null;
  /** The name from hello; name may carry a " (2)" while a same-named racer is in the lobby. */
  baseName = "";

  constructor(readonly id: string) {}

  get connected(): boolean {
    return this.conn !== null;
  }

  send(msg: ServerMessage): void {
    this.conn?.sendRaw(msg);
  }
}

export class RaceServer {
  private sessions = new Map<string, Session>();
  private byToken = new Map<string, Session>();
  private lobbies = new Map<string, Lobby>();
  private nextId = 1;
  private presenceTimer: unknown = null;
  private lastPresence = "";

  constructor(private readonly opts: ServerOptions) {}

  get lobbyCount(): number {
    return this.lobbies.size;
  }

  private get maxPlayers(): number {
    return this.opts.maxPlayers ?? 5;
  }

  connect(send: (msg: ServerMessage) => void): Connection {
    const s = new Session(`p${this.nextId++}`);
    const conn = new Connection(this, send, s);
    s.conn = conn;
    this.sessions.set(s.id, s);
    this.byToken.set(s.token, s);
    return conn;
  }

  // ---------------------------------------------------------------- dispatch

  handle(conn: Connection, raw: unknown): void {
    const s = conn.session;
    let msg: ClientMessage;
    try {
      msg = parseClientMessage(raw);
    } catch (e) {
      if (e instanceof ProtocolError) return this.error(s, e.code, e.message);
      throw e;
    }
    if (!s.greeted && msg.type !== "hello" && msg.type !== "ping") {
      return this.error(s, "no_hello", "send hello first");
    }
    if (s.lobby) s.lobby.lastActivity = this.opts.scheduler.now();
    switch (msg.type) {
      case "hello":
        return this.onHello(conn, msg.name, msg.token, { mod: msg.version ?? null, gameBuild: msg.game_build ?? null },
          msg.platform && msg.platform_id ? `${msg.platform}:${msg.platform_id}` : null);
      case "chat":
        return this.onChat(s, msg.text);
      case "race_log":
        return this.onRaceLog(s, msg.race_id, msg.entry);
      case "ping":
        return s.send({ type: "pong", t: msg.t ?? null, server_time: this.opts.scheduler.now() });
      case "create_lobby":
        return this.onCreate(s);
      case "find_match":
        return this.onFindMatch(s);
      case "cancel_match":
        return this.onCancelMatch(s);
      case "join_lobby":
        return this.onJoin(s, msg.code, msg.create === true);
      case "leave_lobby":
        return this.onLeave(s);
      case "vote_route":
        return this.onVote(s, "route", msg.route);
      case "vote_weapon":
        return this.onVote(s, "weapon", msg.weapon);
      case "vote_keepsake":
        return this.onVote(s, "keepsake", msg.keepsake);
      case "ready":
        return this.onReady(s, msg.ready !== false);
      case "progress_update": {
        const { type: _t, ...progress } = msg;
        return this.onProgress(s, progress);
      }
      case "run_complete":
        return this.onRunComplete(s, msg.victory, msg.time, msg.stats, msg.build, msg.splits);
      case "ghost": {
        const { type: _t, ...ghost } = msg;
        return this.onGhost(s, ghost);
      }
      case "forfeit":
        return this.onForfeit(s, "forfeit", msg.stats, msg.build);
      case "rematch":
        return this.onRematch(s);
      case "add_bot":
        return this.onAddBot(s);
      case "identify":
        return this.onIdentify(s, msg.platform && msg.platform_id ? `${msg.platform}:${msg.platform_id}` : null, msg.name);
    }
  }

  private error(s: Session, code: string, message: string): void {
    s.send({ type: "error", code, message });
  }

  private log(line: string): void {
    this.opts.log(line);
  }

  // ---------------------------------------------------------------- session

  private onHello(conn: Connection, name: string, token: string | undefined, versions: ClientVersions, key: string | null): void {
    const s = conn.session;
    const prev = token ? this.byToken.get(token) : undefined;
    if (prev && prev !== s) {
      // Resume: attach this transport to the old session and discard the fresh one.
      this.forget(s);
      s.conn = null;
      const stale = prev.conn;
      prev.conn = conn;
      conn.session = prev;
      if (stale) stale.session = s; // a late close() of the old socket now hits the discarded session
      prev.greeted = true;
      if (prev.graceTimer !== null) {
        this.opts.scheduler.clearTimeout(prev.graceTimer);
        prev.graceTimer = null;
      }
      prev.versions = versions;
      prev.key = key ?? prev.key;
      this.log(`resume ${prev.id} (${prev.name})`);
      prev.send(this.welcome(prev, true));
      prev.send({ type: "presence", ...this.presence() });
      this.presenceChanged();
      this.warnIfOutdated(prev);
      const lobby = prev.lobby;
      if (lobby) {
        if (!stale) for (const o of lobby.others(prev)) o.send({ type: "opponent_reconnected", ...who(prev) });
        this.broadcastState(lobby);
        const phase = votePhaseOf(lobby.phase);
        if (phase) prev.send({ type: "vote_phase", phase, options: this.pool(phase), timer: this.opts.voteSeconds });
        // A race still running: replay what decided-but-unfinished state they missed.
        const race = lobby.race;
        if (race && !race.over && lobby.phase === "racing") {
          for (const e of race.entrants) {
            const r = race.results.get(e.id);
            if (e.id !== prev.id && r) {
              prev.send({ type: "opponent_finished", victory: r.victory, time: r.time, outcome: r.outcome, id: e.id, name: e.name });
            }
          }
          if (race.decidedSent) prev.send(this.decidedMessage(race, prev));
        }
      }
      return;
    }
    s.name = s.baseName = name;
    s.greeted = true;
    s.versions = versions;
    s.key = key;
    this.log(`hello ${s.id} name=${name} mod=${versions.mod ?? "?"} game=${versions.gameBuild ?? "?"}${key ? ` ${key.split(":")[0]}` : ""}`);
    s.send(this.welcome(s, false));
    s.send({ type: "presence", ...this.presence() });
    this.presenceChanged();
    this.warnIfOutdated(s);
  }

  private welcome(s: Session, resumed: boolean): ServerMessage {
    return {
      type: "welcome",
      id: s.id,
      token: s.token,
      protocol: PROTOCOL_VERSION,
      server_time: this.opts.scheduler.now(),
      resumed,
      latest_mod: this.opts.latestModVersion ?? LATEST_MOD_VERSION,
    };
  }

  closed(conn: Connection): void {
    const s = conn.session;
    if (s.conn !== conn) return;
    s.conn = null;
    this.presenceChanged();
    const lobby = s.lobby;
    if (!lobby) {
      this.forget(s);
      return;
    }
    this.log(`drop ${s.id} in lobby ${lobby.code} phase=${lobby.phase}`);
    const grace = this.opts.reconnectGraceMs;
    for (const o of lobby.others(s)) o.send({ type: "opponent_disconnected", grace: Math.round(grace / 1000), ...who(s) });
    this.broadcastState(lobby);
    s.graceTimer = this.opts.scheduler.setTimeout(() => {
      s.graceTimer = null;
      if (s.connected) return;
      this.log(`grace expired ${s.id}`);
      this.removeFromLobby(s, "disconnect");
      this.forget(s);
    }, grace);
  }

  private forget(s: Session): void {
    this.sessions.delete(s.id);
    this.byToken.delete(s.token);
    this.presenceChanged();
  }

  // ---------------------------------------------------------------- presence

  /** Connected racers; of those, in Find Match (a public lobby still waiting) and in a race. */
  presence(): { online: number; searching: number; racing: number } {
    let online = 0;
    let searching = 0;
    let racing = 0;
    for (const s of this.sessions.values()) {
      if (!s.greeted || !s.connected || s.bot) continue;
      online++;
      const lobby = s.lobby;
      if (!lobby) continue;
      if (lobby.phase === "waiting") {
        if (lobby.isPublic) searching++;
      } else if (lobby.phase !== "finished") {
        racing++;
      }
    }
    return { online, searching, racing };
  }

  /** The counts may have changed: tell everyone, at most once a second and only on a change. */
  private presenceChanged(): void {
    if (this.presenceTimer !== null) return;
    this.presenceTimer = this.opts.scheduler.setTimeout(() => {
      this.presenceTimer = null;
      const p = this.presence();
      const key = `${p.online}/${p.searching}/${p.racing}`;
      if (key === this.lastPresence) return;
      this.lastPresence = key;
      for (const s of this.sessions.values()) if (s.greeted && !s.bot) s.send({ type: "presence", ...p });
    }, 1000);
  }

  // ---------------------------------------------------------------- lobbies

  // ---------------------------------------------------------------- versions

  private outdated(s: Session): boolean {
    return modTooOld(s.versions.mod, this.opts.minModVersion ?? MIN_MOD_VERSION);
  }

  private warnIfOutdated(s: Session): boolean {
    if (!this.outdated(s)) return false;
    const min = this.opts.minModVersion ?? MIN_MOD_VERSION;
    s.send({ type: "error", code: "update_required", who: "you", what: "mod", message: tooOldMessage(s.versions.mod, min) });
    return true;
  }

  /** Tell both racers why they can't be paired and who has to update. */
  private sendMismatch(a: Session, b: Session, m: Mismatch): void {
    for (const [me, rival, side] of [[a, b, "a"], [b, a, "b"]] as const) {
      const meOlder = m.older === side || m.older === "both";
      const who = m.older === "both" ? "both" : meOlder ? "you" : "rival";
      me.send({
        type: "error",
        code: "version_mismatch",
        who,
        what: m.what,
        rival: rival.name,
        message: mismatchMessage(m, me.versions, rival.versions, rival.name, meOlder),
      });
    }
    this.log(`version mismatch ${a.id} ${JSON.stringify(a.versions)} vs ${b.id} ${JSON.stringify(b.versions)}: ${m.what}`);
  }

  private newCode(): string {
    for (let tries = 0; tries < 50; tries++) {
      let code = "";
      for (let i = 0; i < 4; i++) code += CODE_ALPHABET[this.opts.random.int(CODE_ALPHABET.length)];
      if (!this.lobbies.has(code)) return code;
    }
    // Unlucky (or a scripted RNG in tests): take the first free code.
    const n = CODE_ALPHABET.length;
    for (let k = 0; k < n ** 4; k++) {
      let code = "";
      for (let i = 0, x = k; i < 4; i++, x = Math.floor(x / n)) code = CODE_ALPHABET[x % n] + code;
      if (!this.lobbies.has(code)) return code;
    }
    throw new Error("no free lobby codes");
  }

  private onCreate(s: Session, code = this.newCode()): void {
    if (this.warnIfOutdated(s)) return;
    if (s.lobby) this.removeFromLobby(s, "forfeit");
    const lobby = new Lobby(code, this.opts.scheduler.now(), this.maxPlayers);
    this.lobbies.set(lobby.code, lobby);
    this.log(`lobby ${lobby.code} created by ${s.id}`);
    this.addToLobby(s, lobby);
    s.send({ type: "lobby_created", code: lobby.code });
  }

  /**
   * Find Match: join an open Find Match lobby whose racer can race us, or open
   * one. Voting starts once both racers are ready.
   */
  private onFindMatch(s: Session): void {
    if (this.warnIfOutdated(s)) return;
    if (s.lobby) return this.error(s, "already_in_lobby", "Leave your lobby first");
    const open = [...this.lobbies.values()].filter(
      (l) => l.isPublic && l.phase === "waiting" && l.players.length < l.maxPlayers,
    );
    const fit = open.find((l) => l.players.every((p) => !compatibility(s.versions, p.versions)));
    if (fit) {
      this.log(`queue ${s.id} joins ${fit.code}`);
      return this.addToLobby(s, fit);
    }
    // Someone is searching but can't be raced: say who has to update.
    for (const p of open.flatMap((l) => l.players)) {
      const m = compatibility(s.versions, p.versions);
      if (m) {
        this.sendMismatch(s, p, m);
        break;
      }
    }
    const lobby = new Lobby(this.newCode(), this.opts.scheduler.now(), this.opts.matchPlayers ?? 2);
    lobby.isPublic = true;
    this.lobbies.set(lobby.code, lobby);
    this.log(`queue ${s.id} opens ${lobby.code}`);
    this.addToLobby(s, lobby);
  }

  /** Leave a Find Match lobby that hasn't started yet. */
  private onCancelMatch(s: Session): void {
    const lobby = s.lobby;
    if (!lobby || !lobby.isPublic || lobby.phase !== "waiting") return;
    this.removeFromLobby(s, "forfeit");
    s.send({ type: "match_cancelled" });
    s.send({ type: "lobby_left" });
  }

  private onJoin(s: Session, code: string, create: boolean): void {
    if (this.warnIfOutdated(s)) return;
    const lobby = this.lobbies.get(code);
    if (!lobby && create) {
      if (!isLobbyCode(code)) return this.error(s, "bad_code", `${code} is not a valid race code`);
      return this.onCreate(s, code);
    }
    if (!lobby) return this.error(s, "lobby_not_found", `Lobby ${code} not found`);
    if (lobby === s.lobby) return this.error(s, "already_in_lobby", "Already in this lobby");
    if (lobby.players.length >= lobby.maxPlayers) return this.error(s, "lobby_full", `Lobby ${code} is full`);
    if (lobby.phase !== "waiting") return this.error(s, "lobby_busy", `Lobby ${code} is already racing; try again after this race`);
    for (const p of lobby.players) {
      const m = compatibility(s.versions, p.versions);
      if (m) return this.sendMismatch(s, p, m);
    }
    this.addToLobby(s, lobby);
  }

  private addToLobby(s: Session, lobby: Lobby): void {
    if (s.lobby && s.lobby !== lobby) this.removeFromLobby(s, "forfeit");
    // Same name as someone here (e.g. one Steam account on two machines): "Mark (2)".
    s.name = s.baseName || s.name;
    const taken = new Set(lobby.players.map((p) => p.name));
    for (let n = 2; taken.has(s.name); n++) s.name = `${s.baseName} (${n})`;
    lobby.players.push(s);
    s.lobby = lobby;
    lobby.lastActivity = this.opts.scheduler.now();
    this.log(`lobby ${lobby.code} joined by ${s.id} (${lobby.players.length}/${lobby.maxPlayers})`);
    for (const p of lobby.players) {
      p.send({ type: "lobby_joined", code: lobby.code, opponent: lobby.others(p)[0]?.name ?? null });
    }
    this.broadcastState(lobby);
  }

  /** The store account found after hello: the session's key now, the name from the next lobby on. */
  private onIdentify(s: Session, key: string | null, name: string | undefined): void {
    if (key) s.key = key;
    if (name) {
      s.baseName = name;
      if (!s.lobby) s.name = name;
    }
    this.log(`identify ${s.id}${key ? ` ${key.split(":")[0]}` : ""}${name ? ` name=${name}` : ""}`);
    if (s.lobby) this.broadcastState(s.lobby); // their bests
  }

  /** A private lobby still waiting: a house bot joins it. */
  private onAddBot(s: Session): void {
    const lobby = s.lobby;
    if (!lobby || lobby.phase !== "waiting") return this.error(s, "not_waiting", "Bots join a race before the vote");
    if (lobby.isPublic) return this.error(s, "not_private", "Bots only join private races");
    if (lobby.players.length >= lobby.maxPlayers) return this.error(s, "lobby_full", `Lobby ${lobby.code} is full`);
    this.addBot(lobby);
  }

  /**
   * A house bot: a session without a transport whose brain follows the others'
   * votes, readies, reports a room every botRoomSeconds and never clears first.
   * Its messages arrive a moment later, like a player's, never inside the
   * server's own loops.
   */
  private addBot(lobby: Lobby): void {
    const n = lobby.players.filter((p) => p.bot).length + 1;
    const scheduler = this.opts.scheduler;
    let conn: Connection | null = null;
    const brain = new BotBrain(
      { follow: true, outcome: "none", finishAfter: 0, progressEvery: this.opts.botRoomSeconds ?? 75, rematch: true },
      (m) => scheduler.setTimeout(() => { if (conn && conn.session.lobby) conn.receive(m); }, BOT_DELAY_MS),
      scheduler,
    );
    conn = this.connect((m) => brain.handle(m));
    const bot = conn.session;
    bot.name = n === 1 ? "Bot" : `Bot ${n}`;
    bot.greeted = true;
    bot.bot = brain;
    this.log(`bot ${bot.id} for lobby ${lobby.code}`);
    this.addToLobby(bot, lobby);
  }

  /** Waiting: everyone in the lobby (two or more) is ready, so the vote starts. */
  private maybeStartVoting(lobby: Lobby): void {
    if (lobby.phase === "waiting" && lobby.enough && lobby.players.every((p) => lobby.ready.has(p.id))) {
      this.log(`lobby ${lobby.code} everyone ready with ${lobby.players.length}; voting`);
      this.startVoting(lobby);
    }
  }

  private onLeave(s: Session): void {
    if (!s.lobby) return this.error(s, "not_in_lobby", "Not in a lobby");
    this.removeFromLobby(s, "forfeit");
    s.send({ type: "lobby_left" });
  }

  /** Take a player out of their lobby; an unfinished run counts as a DNF for them. */
  private removeFromLobby(s: Session, outcome: "forfeit" | "disconnect"): void {
    const lobby = s.lobby;
    if (!lobby) return;
    this.presenceChanged();
    if (lobby.phase === "racing" || lobby.phase === "countdown") this.onForfeit(s, outcome);
    lobby.players = lobby.players.filter((p) => p !== s);
    if (s.baseName) s.name = s.baseName;
    lobby.ready.delete(s.id);
    lobby.rematch.delete(s.id);
    s.lobby = null;
    if (s.graceTimer !== null) {
      this.opts.scheduler.clearTimeout(s.graceTimer);
      s.graceTimer = null;
    }
    this.log(`lobby ${lobby.code} left by ${s.id}`);
    if (s.bot) this.dropBot(s);
    if (lobby.players.every((p) => p.bot)) {
      // Only bots left: they go too.
      for (const b of lobby.players) {
        b.lobby = null;
        this.dropBot(b);
      }
      lobby.players = [];
    }
    if (lobby.players.length === 0) {
      this.closeLobby(lobby);
      return;
    }
    // A race still running goes on to the end for the others.
    if (lobby.race && !lobby.race.over && (lobby.phase === "racing" || lobby.phase === "countdown")) {
      this.broadcastState(lobby);
      return;
    }
    if (lobby.phase === "waiting") {
      // The others stay ready; they may have been waiting only on the leaver.
      this.broadcastState(lobby);
      this.maybeStartVoting(lobby);
      return;
    }
    const voting = votePhaseOf(lobby.phase);
    if (lobby.enough && (voting || lobby.phase === "ready_check" || lobby.phase === "finished")) {
      // Enough racers left: carry on (the leaver may have been the last one we waited for).
      this.broadcastState(lobby);
      if (voting) this.maybeResolveVote(lobby, voting);
      else if (lobby.phase === "ready_check") this.maybeStartCountdown(lobby);
      else this.maybeRematch(lobby);
      return;
    }
    // Back to waiting for more racers (and everyone readying again).
    this.clearTimers(lobby);
    lobby.phase = "waiting";
    lobby.prepEndsAt = null;
    lobby.race = null;
    lobby.ready.clear();
    lobby.rematch.clear();
    this.broadcastState(lobby);
  }

  /** A house bot leaves for good: its timers stop and its session goes. */
  private dropBot(b: Session): void {
    b.bot?.stop();
    b.conn = null;
    this.forget(b);
  }

  private closeLobby(lobby: Lobby): void {
    this.opts.raceLogs?.forget(lobby.code);
    this.clearTimers(lobby);
    this.lobbies.delete(lobby.code);
    this.log(`lobby ${lobby.code} closed`);
  }

  private clearTimers(lobby: Lobby): void {
    if (lobby.timer !== null) this.opts.scheduler.clearTimeout(lobby.timer);
    if (lobby.raceTimer !== null) this.opts.scheduler.clearTimeout(lobby.raceTimer);
    lobby.timer = null;
    lobby.raceTimer = null;
  }

  /** Drop lobbies idle for longer than idleLobbyMs. Call periodically. */
  sweep(): void {
    const now = this.opts.scheduler.now();
    for (const lobby of [...this.lobbies.values()]) {
      if (now - lobby.lastActivity < this.opts.idleLobbyMs) continue;
      if (lobby.phase === "racing") continue;
      for (const p of lobby.players) {
        p.lobby = null;
        if (p.bot) {
          this.dropBot(p);
          continue;
        }
        p.send({ type: "error", code: "lobby_expired", message: `Lobby ${lobby.code} expired` });
        p.send({ type: "lobby_left" });
        if (!p.connected) this.forget(p);
      }
      this.closeLobby(lobby);
    }
  }

  private broadcastState(lobby: Lobby): void {
    this.presenceChanged();
    for (const p of lobby.players) {
      p.send({
        type: "lobby_state",
        code: lobby.code,
        phase: lobby.phase,
        you: p.id,
        players: lobby.players.map((q, i) => ({
          id: q.id,
          name: q.name,
          connected: q.connected,
          ready: lobby.ready.has(q.id),
          host: i === 0,
          rematch: lobby.rematch.has(q.id),
          bot: q.bot !== null,
          best: this.opts.pbs?.best(q.key) ?? {},
        })),
        race: lobby.race
          ? {
              race_id: lobby.race.race_id,
              seed: lobby.race.seed,
              weapon: lobby.race.weapon,
              keepsake: lobby.race.keepsake,
              route: lobby.race.route,
            }
          : null,
        public: lobby.isPublic,
        max_players: lobby.maxPlayers,
        prep_ends_in:
          lobby.prepEndsAt !== null ? Math.max(0, Math.ceil((lobby.prepEndsAt - this.opts.scheduler.now()) / 1000)) : null,
      });
    }
  }

  // ---------------------------------------------------------------- voting

  private pool(phase: VotePhase): VoteOption[] {
    return this.opts.pools[phase] ?? [];
  }

  private startVoting(lobby: Lobby): void {
    if (lobby.timer !== null) this.opts.scheduler.clearTimeout(lobby.timer);
    lobby.timer = null;
    lobby.prepEndsAt = null;
    for (const phase of VOTE_ORDER) {
      lobby.votes[phase].clear();
      lobby.selected[phase] = null;
    }
    lobby.ready.clear();
    lobby.rematch.clear();
    lobby.race = null;
    this.startVotePhase(lobby, VOTE_ORDER[0]!);
  }

  private startVotePhase(lobby: Lobby, phase: VotePhase): void {
    if (this.pool(phase).length === 0) {
      // Nothing to vote on (e.g. no route pool configured): skip.
      lobby.selected[phase] = "";
      return this.afterVote(lobby, phase);
    }
    lobby.phase = `voting_${phase}`;
    this.broadcastState(lobby);
    for (const p of lobby.players) {
      p.send({ type: "vote_phase", phase, options: this.pool(phase), timer: this.opts.voteSeconds });
    }
    lobby.timer = this.opts.scheduler.setTimeout(() => {
      lobby.timer = null;
      this.resolveVote(lobby, phase);
    }, this.opts.voteSeconds * 1000);
  }

  private onVote(s: Session, phase: VotePhase, choice: string): void {
    const lobby = s.lobby;
    if (!lobby || lobby.phase !== `voting_${phase}`) return this.error(s, "not_voting", `Not in ${phase} vote`);
    if (choice !== NO_PREFERENCE && !this.pool(phase).some((o) => o.id === choice)) {
      return this.error(s, "bad_choice", `Unknown ${phase} '${choice}'`);
    }
    lobby.votes[phase].set(s.id, choice);
    const voted = lobby.players.filter((p) => lobby.votes[phase].has(p.id)).length;
    const of = lobby.players.length;
    s.send({ type: "vote_cast", phase, by: "you", ...who(s), voted, of });
    for (const o of lobby.others(s)) o.send({ type: "vote_cast", phase, by: "opponent", ...who(s), voted, of });
    this.maybeResolveVote(lobby, phase);
  }

  private maybeResolveVote(lobby: Lobby, phase: VotePhase): void {
    if (lobby.enough && lobby.players.every((p) => lobby.votes[phase].has(p.id))) {
      if (lobby.timer !== null) this.opts.scheduler.clearTimeout(lobby.timer);
      lobby.timer = null;
      this.resolveVote(lobby, phase);
    }
  }

  /**
   * Most votes wins; a tie is broken at random among the tied options; with no
   * votes at all (or only "any"), a random option from the pool.
   */
  private resolveVote(lobby: Lobby, phase: VotePhase): void {
    const pool = this.pool(phase);
    const counts: Record<string, number> = {};
    for (const p of lobby.players) {
      const v = lobby.votes[phase].get(p.id);
      if (v && v !== NO_PREFERENCE) counts[v] = (counts[v] ?? 0) + 1;
    }
    const best = Math.max(0, ...Object.values(counts));
    const tied = Object.keys(counts).filter((k) => counts[k] === best);
    const selected = tied.length > 0 ? tied[this.opts.random.int(tied.length)]! : pool[this.opts.random.int(pool.length)]!.id;
    lobby.selected[phase] = selected;
    this.log(`lobby ${lobby.code} ${phase} -> ${selected} ${JSON.stringify(counts)}`);
    for (const p of lobby.players) {
      const others = lobby.others(p);
      p.send({
        type: "vote_result",
        phase,
        selected,
        votes: {
          you: this.shownVote(lobby, phase, p.id),
          opponent: others.length === 1 ? this.shownVote(lobby, phase, others[0]!.id) : null,
        },
        counts,
      });
    }
    this.afterVote(lobby, phase);
  }

  private shownVote(lobby: Lobby, phase: VotePhase, id: string): string | null {
    const v = lobby.votes[phase].get(id);
    return v && v !== NO_PREFERENCE ? v : null;
  }

  /** Next vote, or the prep time: the race starts once everyone is ready, or when it runs out. */
  private afterVote(lobby: Lobby, phase: VotePhase): void {
    const next = VOTE_ORDER[VOTE_ORDER.indexOf(phase) + 1];
    if (next) return this.startVotePhase(lobby, next);
    lobby.phase = "ready_check";
    lobby.ready.clear();
    const prepMs = this.opts.prepMs ?? 120_000;
    lobby.prepEndsAt = this.opts.scheduler.now() + prepMs;
    lobby.timer = this.opts.scheduler.setTimeout(() => {
      lobby.timer = null;
      if (lobby.phase !== "ready_check" || !lobby.enough) return;
      this.log(`lobby ${lobby.code} prep time over; starting`);
      this.startCountdown(lobby);
    }, prepMs);
    this.broadcastState(lobby);
  }

  /** waiting: ready to vote (or not any more); ready_check: ready for the start. */
  private onReady(s: Session, ready: boolean): void {
    const lobby = s.lobby;
    if (lobby && lobby.phase === "waiting") {
      if (ready) lobby.ready.add(s.id);
      else lobby.ready.delete(s.id);
      this.log(`lobby ${lobby.code} ${s.id} ${ready ? "ready" : "not ready"} to vote`);
      this.broadcastState(lobby);
      return this.maybeStartVoting(lobby);
    }
    if (!lobby || lobby.phase !== "ready_check") return this.error(s, "not_ready_check", "Nothing to ready for");
    if (!ready) return;
    lobby.ready.add(s.id);
    this.broadcastState(lobby);
    this.maybeStartCountdown(lobby);
  }

  private maybeStartCountdown(lobby: Lobby): void {
    if (lobby.enough && lobby.players.every((p) => lobby.ready.has(p.id))) this.startCountdown(lobby);
  }

  // ---------------------------------------------------------------- race

  private startCountdown(lobby: Lobby): void {
    if (lobby.timer !== null) this.opts.scheduler.clearTimeout(lobby.timer);
    lobby.timer = null;
    lobby.prepEndsAt = null;
    lobby.raceCounter += 1;
    lobby.race = {
      race_id: lobby.raceCounter,
      seed: this.opts.fixedSeed ?? 1 + this.opts.random.int(MAX_SEED - 1),
      weapon: lobby.selected.weapon ?? "",
      keepsake: lobby.selected.keepsake ?? "",
      route: lobby.selected.route ?? "",
      startAt: null,
      entrants: lobby.players.map((p) => ({ id: p.id, name: p.name, key: p.key, base: p.baseName || p.name })),
      results: new Map(),
      progress: new Map(),
      build: new Map(),
      stats: new Map(),
      winner: undefined,
      reason: null,
      decidedSent: false,
      over: false,
    };
    lobby.phase = "countdown";
    const race = lobby.race;
    this.log(
      `lobby ${lobby.code} race ${race.race_id} seed=${race.seed} route=${race.route} weapon=${race.weapon} keepsake=${race.keepsake}`,
    );
    this.opts.raceLogs?.start(
      lobby.code,
      { race_id: race.race_id, seed: race.seed, weapon: race.weapon, keepsake: race.keepsake, route: race.route },
      lobby.players.map((p) => ({ id: p.id, name: p.name, bot: p.bot !== null })),
      this.opts.scheduler.now(),
    );
    this.broadcastState(lobby);
    for (const p of lobby.players) {
      const best = this.opts.pbs?.detail(p.key, race.route || "default");
      p.send({
        type: "race_start",
        race_id: race.race_id,
        seed: race.seed,
        weapon: race.weapon,
        keepsake: race.keepsake,
        route: race.route,
        countdown: Math.round(this.opts.countdownMs / 1000),
        countdown_ms: this.opts.countdownMs,
        ...(best ? { best } : {}),
      });
    }
    lobby.timer = this.opts.scheduler.setTimeout(() => {
      lobby.timer = null;
      race.startAt = this.opts.scheduler.now();
      lobby.phase = "racing";
      this.broadcastState(lobby);
      lobby.raceTimer = this.opts.scheduler.setTimeout(() => {
        lobby.raceTimer = null;
        this.onTimeLimit(lobby, race);
      }, this.opts.raceTimeLimitMs);
    }, this.opts.countdownMs);
  }

  private onProgress(s: Session, progress: Progress): void {
    const lobby = s.lobby;
    if (!lobby || lobby.phase !== "racing" || !lobby.race) return;
    const race = lobby.race;
    if (race.results.has(s.id)) return;
    race.progress.set(s.id, progress);
    if (progress.build) race.build.set(s.id, progress.build);
    if (progress.stats) race.stats.set(s.id, progress.stats);
    for (const o of lobby.others(s)) o.send({ type: "opponent_progress", ...progress, ...who(s) });
  }

  /** A line of a racer's choice log, kept with this race's record (the one in progress or just over). */
  private onRaceLog(s: Session, raceId: number, entry: Record<string, unknown>): void {
    const lobby = s.lobby;
    if (!lobby || lobby.race?.race_id !== raceId) return;
    this.opts.raceLogs?.event(lobby.code, raceId, s.id, entry);
  }

  /** Relay only: positions are useless a moment later, so nothing is stored. */
  /** Chat: a quick line to everyone in the lobby, the sender included; at most one a second each. */
  private onChat(s: Session, text: string): void {
    const lobby = s.lobby;
    if (!lobby) return this.error(s, "not_in_lobby", "Join a race to chat");
    if (!isQuickLine(text)) return this.error(s, "chat_not_allowed", "Only the quick lines can be sent");
    const now = this.opts.scheduler.now();
    if (now - s.lastChat < 1000) return;
    s.lastChat = now;
    this.log(`lobby ${lobby.code} chat ${s.id}: ${text}`);
    for (const p of lobby.players) p.send({ type: "chat", text, ...who(s) });
  }

  private onGhost(s: Session, ghost: Ghost): void {
    const lobby = s.lobby;
    if (!lobby || lobby.phase !== "racing" || !lobby.race || lobby.race.results.has(s.id)) return;
    for (const o of lobby.others(s)) o.send({ type: "opponent_ghost", ...ghost, id: s.id });
  }

  /** Real time since the race start on the server's clock: the one official timer. */
  private raceSeconds(race: RaceState): number | null {
    if (race.startAt === null) return null;
    return Math.round(this.opts.scheduler.now() - race.startAt) / 1000;
  }

  private onRunComplete(s: Session, victory: boolean, clientTime: number, stats?: RunStats, build?: BuildEntry[], splits?: Split[]): void {
    const lobby = s.lobby;
    const race = lobby?.race;
    if (!lobby || !race || lobby.phase !== "racing" || race.over) return this.error(s, "not_racing", "No race in progress");
    if (race.results.has(s.id)) return;
    this.record(lobby, s.id, { outcome: victory ? "cleared" : "died", victory, time: this.raceSeconds(race), clientTime, stats, build, splits });
  }

  /** Forfeit, leaving or a lost connection: a DNF, exactly like dying. */
  private onForfeit(s: Session, outcome: "forfeit" | "disconnect", stats?: RunStats, build?: BuildEntry[]): void {
    const lobby = s.lobby;
    const race = lobby?.race;
    if (!lobby || !race || race.over || (lobby.phase !== "racing" && lobby.phase !== "countdown")) {
      return this.error(s, "not_racing", "No race in progress");
    }
    if (race.results.has(s.id)) return; // already finished: nothing to give up
    this.record(lobby, s.id, { outcome, victory: false, time: this.raceSeconds(race), clientTime: null, stats, build });
  }

  private onTimeLimit(lobby: Lobby, race: RaceState): void {
    if (lobby.race !== race || race.over) return;
    this.log(`lobby ${lobby.code} race ${race.race_id} hit the time limit`);
    for (const e of race.entrants) {
      if (!race.results.has(e.id)) {
        race.results.set(e.id, { outcome: "timeout", victory: false, time: this.raceSeconds(race), clientTime: null });
      }
    }
    this.settle(lobby);
  }

  private record(lobby: Lobby, id: string, r: RunResult): void {
    const race = lobby.race!;
    race.results.set(id, r);
    if (r.build) race.build.set(id, r.build);
    if (r.stats) race.stats.set(id, r.stats);
    this.log(`lobby ${lobby.code} ${id} ${r.outcome} time=${r.time} client=${r.clientTime}`);
    const name = race.entrants.find((e) => e.id === id)?.name ?? "?";
    for (const o of lobby.players) {
      if (o.id !== id) o.send({ type: "opponent_finished", victory: r.victory, time: r.time, outcome: r.outcome, id, name });
    }
    this.settle(lobby);
  }

  /** First clear decides the winner; the race ends once every entrant has finished one way or another. */
  private settle(lobby: Lobby): void {
    const race = lobby.race;
    if (!race || race.over) return;
    const order = [...race.results.keys()];
    if (race.winner === undefined) {
      const first = order.find((id) => race.results.get(id)!.victory);
      if (first !== undefined) {
        // "survivor": everyone else had already dropped out when the winner cleared.
        const before = new Set(order.slice(0, order.indexOf(first)));
        const lastStanding = race.entrants.every((e) => e.id === first || before.has(e.id));
        race.winner = first;
        race.reason = lastStanding && before.size > 0 ? "survivor_finished" : "completed_first";
      } else if (race.entrants.every((e) => race.results.has(e.id))) {
        race.winner = null;
        race.reason = [...race.results.values()].some((r) => r.outcome === "timeout") ? "time_limit" : "no_finishers";
      }
    }
    if (race.entrants.every((e) => race.results.has(e.id))) return this.finishRace(lobby);
    if (race.winner !== undefined && !race.decidedSent) {
      race.decidedSent = true;
      this.log(`lobby ${lobby.code} race ${race.race_id} decided winner=${race.winner ?? "draw"} reason=${race.reason}`);
      for (const p of lobby.players) p.send(this.decidedMessage(race, p));
    }
  }

  private decidedMessage(race: RaceState, p: Session): ServerMessage {
    const winner = race.entrants.find((e) => e.id === race.winner);
    return {
      type: "race_decided",
      race_id: race.race_id,
      winner: race.winner ?? null,
      winner_name: winner?.name ?? null,
      draw: race.winner === null,
      you_won: race.winner === p.id,
      reason: race.reason!,
    };
  }

  private finishRace(lobby: Lobby): void {
    const race = lobby.race;
    if (!race || race.over) return;
    race.over = true;
    this.clearTimers(lobby);
    lobby.phase = "finished";
    lobby.rematch.clear();
    const results: RaceResultEntry[] = race.entrants.map((e) => {
      const r = race.results.get(e.id)!;
      const prog = race.progress.get(e.id);
      return {
        id: e.id,
        name: e.name,
        place: 0,
        finished: true,
        victory: r.victory,
        outcome: r.outcome,
        time: r.time,
        depth: prog?.depth ?? null,
        room: prog?.room ?? null,
        build: race.build.get(e.id) ?? [],
        stats: race.stats.get(e.id) ?? {},
      };
    });
    // Places: clears by time, then those who dropped out by how far they got
    // (and how long they lasted).
    results.sort((a, b) => {
      if (a.victory !== b.victory) return a.victory ? -1 : 1;
      if (a.victory) return (a.time ?? Infinity) - (b.time ?? Infinity);
      return (b.depth ?? 0) - (a.depth ?? 0) || (b.time ?? 0) - (a.time ?? 0);
    });
    results.forEach((r, i) => (r.place = i + 1));
    this.opts.raceLogs?.finish(lobby.code, race.race_id, results);
    // Clears count for each racer's personal best on this route (official time).
    for (const e of race.entrants) {
      const r = race.results.get(e.id);
      if (e.key && r?.victory && r.time !== null) {
        this.opts.pbs?.record(e.key, e.base, race.route || "default", r.time, r.splits ?? [], `${lobby.code}/race${race.race_id}`, this.opts.scheduler.now());
      }
    }
    const winner = race.entrants.find((e) => e.id === race.winner);
    this.log(`lobby ${lobby.code} race ${race.race_id} result winner=${winner?.id ?? "draw"} reason=${race.reason}`);
    this.broadcastState(lobby);
    for (const p of lobby.players) {
      p.send({
        type: "race_result",
        race_id: race.race_id,
        winner: winner?.id ?? null,
        winner_name: winner?.name ?? null,
        draw: winner === undefined,
        you_won: race.winner === p.id,
        reason: race.reason!,
        results,
      });
    }
  }

  private onRematch(s: Session): void {
    const lobby = s.lobby;
    if (!lobby || lobby.phase !== "finished") return this.error(s, "not_finished", "No finished race to rematch");
    lobby.rematch.add(s.id);
    this.broadcastState(lobby);
    this.maybeRematch(lobby);
  }

  /** Everyone still here (two or more) asked for a rematch. */
  private maybeRematch(lobby: Lobby): void {
    if (lobby.phase === "finished" && lobby.enough && lobby.players.every((p) => lobby.rematch.has(p.id))) {
      this.startVoting(lobby);
    }
  }
}
