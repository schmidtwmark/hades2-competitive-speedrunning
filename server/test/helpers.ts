import type { ServerMessage, VoteOption } from "../src/protocol.js";
import { RaceServer, type Connection, type Random, type Scheduler, type ServerOptions } from "../src/race-server.js";

export class FakeScheduler implements Scheduler {
  t = 1_000_000;
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private nextId = 1;

  now(): number {
    return this.t;
  }

  setTimeout(fn: () => void, ms: number): unknown {
    const id = this.nextId++;
    this.timers.push({ at: this.t + ms, fn, id });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.timers = this.timers.filter((x) => x.id !== handle);
  }

  advance(ms: number): void {
    const end = this.t + ms;
    for (;;) {
      this.timers.sort((a, b) => a.at - b.at || a.id - b.id);
      const next = this.timers[0];
      if (!next || next.at > end) break;
      this.timers.shift();
      this.t = next.at;
      next.fn();
    }
    this.t = end;
  }

  get pending(): number {
    return this.timers.length;
  }
}

/** Returns scripted values first, then 0. */
export class ScriptedRandom implements Random {
  queue: number[] = [];
  int(n: number): number {
    const v = this.queue.shift() ?? 0;
    return v % n;
  }
}

export const TEST_WEAPONS: VoteOption[] = [
  { id: "WeaponStaffSwing", name: "Staff" },
  { id: "WeaponDagger", name: "Blades" },
  { id: "WeaponAxe", name: "Axe" },
];
export const TEST_KEEPSAKES: VoteOption[] = [
  { id: "KeepsakeA", name: "A" },
  { id: "KeepsakeB", name: "B" },
];

export function makeServer(over: Partial<ServerOptions> = {}) {
  const scheduler = new FakeScheduler();
  const random = new ScriptedRandom();
  const logs: string[] = [];
  const server = new RaceServer({
    voteSeconds: 15,
    countdownMs: 3000,
    raceTimeLimitMs: 3_600_000,
    reconnectGraceMs: 10_000,
    idleLobbyMs: 30 * 60_000,
    pools: { weapon: TEST_WEAPONS, keepsake: TEST_KEEPSAKES },
    scheduler,
    random,
    log: (l) => logs.push(l),
    ...over,
  });
  return { server, scheduler, random, logs };
}

export class TestClient {
  inbox: ServerMessage[] = [];
  conn: Connection;
  constructor(
    private server: RaceServer,
    readonly name: string,
  ) {
    this.conn = server.connect((m) => this.inbox.push(structuredClone(m)));
  }

  send(msg: Record<string, unknown>): void {
    this.conn.receive(msg);
  }

  hello(token?: string, versions: { version?: string; game_build?: number } = {}): string {
    this.send({ type: "hello", name: this.name, ...(token ? { token } : {}), ...versions });
    return this.last("welcome").token;
  }

  all<T extends ServerMessage["type"]>(type: T): Extract<ServerMessage, { type: T }>[] {
    return this.inbox.filter((m) => m.type === type) as Extract<ServerMessage, { type: T }>[];
  }

  last<T extends ServerMessage["type"]>(type: T): Extract<ServerMessage, { type: T }> {
    const all = this.all(type);
    const m = all[all.length - 1];
    if (!m) throw new Error(`${this.name}: no '${type}' message; got ${this.inbox.map((x) => x.type).join(",")}`);
    return m;
  }

  state() {
    return this.last("lobby_state");
  }

  clear(): void {
    this.inbox = [];
  }
}

/** Two greeted clients in one lobby, in the weapon vote. */
export function pair(over: Partial<ServerOptions> = {}) {
  const env = makeServer(over);
  const a = new TestClient(env.server, "Alice");
  const b = new TestClient(env.server, "Bob");
  a.hello();
  b.hello();
  a.send({ type: "create_lobby" });
  const code = a.last("lobby_created").code;
  b.send({ type: "join_lobby", code });
  a.send({ type: "start_race" }); // the host starts once the rival is in
  return { ...env, a, b, code };
}

/** A private lobby with n racers (host first), started. */
export function group(n: number, over: Partial<ServerOptions> = {}) {
  const env = makeServer(over);
  const names = ["Alice", "Bob", "Cara", "Dion", "Eris", "Fae"];
  const cs = names.slice(0, n).map((name) => {
    const c = new TestClient(env.server, name);
    c.hello();
    return c;
  });
  cs[0]!.send({ type: "create_lobby" });
  const code = cs[0]!.last("lobby_created").code;
  for (const c of cs.slice(1)) c.send({ type: "join_lobby", code });
  cs[0]!.send({ type: "start_race" });
  return { ...env, cs, code };
}

/** n racers past the countdown. */
export function racingGroup(n: number, over: Partial<ServerOptions> = {}) {
  const env = group(n, over);
  for (const c of env.cs) c.send({ type: "vote_weapon", weapon: "WeaponAxe" });
  for (const c of env.cs) c.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
  for (const c of env.cs) c.send({ type: "ready" });
  env.scheduler.advance(3000);
  return env;
}

/** Two clients racing (countdown elapsed). */
export function racing(over: Partial<ServerOptions> = {}) {
  const env = pair(over);
  const { a, b, scheduler } = env;
  a.send({ type: "vote_weapon", weapon: "WeaponAxe" });
  b.send({ type: "vote_weapon", weapon: "WeaponAxe" });
  a.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
  b.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
  a.send({ type: "ready" });
  b.send({ type: "ready" });
  scheduler.advance(3000);
  return env;
}
