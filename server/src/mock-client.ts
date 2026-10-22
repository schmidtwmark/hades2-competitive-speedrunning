// Scriptable opponent over real TCP. Used by the integration tests and as the
// second player when only one real game client is available.
//
//   node dist/src/mock-client.js --name Bot --create --code-file /tmp/code
//   node dist/src/mock-client.js --name Bot --join ABCD --outcome win --finish-after 20
//   node dist/src/mock-client.js --name Bot --queue          (Find Match)
//   node dist/src/mock-client.js --name Bot --queue --follow (votes "any": the others' picks win)
//
// Prints one JSON line per received message and a final `RESULT: <json>` line.

import net from "node:net";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { parseArgs } from "node:util";
import { NO_PREFERENCE, type ServerMessage } from "./protocol.js";

export interface MockOptions {
  host: string;
  port: number;
  name: string;
  create: boolean;
  queue?: boolean;
  join?: string;
  joinFile?: string;
  codeFile?: string;
  route?: string;
  weapon?: string;
  keepsake?: string;
  outcome: "win" | "die" | "none";
  finishAfter: number;
  progressEvery: number;
  quiet: boolean;
  timeout: number;
  /** As host of a private lobby, start the race once this many racers are in (default 2). */
  startAt?: number;
  /** Vote "any" in every vote, so the other racers' picks decide (and the vote ends once they voted). */
  follow?: boolean;
  /** Pretend to be this mod version / game build (default: unknown, which never blocks). */
  version?: string;
  gameBuild?: number;
}

export interface MockResult {
  ok: boolean;
  code: string | null;
  race: { seed: number; weapon: string; keepsake: string; route: string } | null;
  result: Extract<ServerMessage, { type: "race_result" }> | null;
  opponentProgress: number;
  error: string | null;
}

export function runMock(o: MockOptions): Promise<MockResult> {
  return new Promise((resolve) => {
    const res: MockResult = { ok: false, code: null, race: null, result: null, opponentProgress: 0, error: null };
    const sock = net.connect(o.port, o.host);
    sock.setEncoding("utf8");
    const timers: NodeJS.Timeout[] = [];
    let done = false;
    const finish = (error: string | null) => {
      if (done) return;
      done = true;
      res.error = error;
      res.ok = error === null && res.result !== null;
      timers.forEach(clearTimeout);
      timers.forEach(clearInterval);
      sock.end();
      resolve(res);
    };
    timers.push(setTimeout(() => finish("timeout"), o.timeout * 1000));
    const send = (m: Record<string, unknown>) => sock.write(JSON.stringify(m) + "\n");
    const log = (m: unknown) => {
      if (!o.quiet) console.log(JSON.stringify(m));
    };

    let raceStart = 0;
    let startSent = false;
    let depth = 0;
    const handle = (m: ServerMessage) => {
      log(m);
      switch (m.type) {
        case "welcome":
          if (o.create) send({ type: "create_lobby" });
          else if (o.queue) send({ type: "find_match" });
          else if (o.join) send({ type: "join_lobby", code: o.join });
          else if (o.joinFile) {
            const path = o.joinFile;
            const poll = setInterval(() => {
              if (existsSync(path)) {
                const code = readFileSync(path, "utf8").trim();
                if (code.length > 0) {
                  clearInterval(poll);
                  send({ type: "join_lobby", code });
                }
              }
            }, 200);
            timers.push(poll);
          }
          break;
        case "lobby_created":
          res.code = m.code;
          if (o.codeFile) writeFileSync(o.codeFile, m.code + "\n");
          break;
        case "lobby_joined":
          res.code = m.code;
          break;
        case "vote_phase": {
          const want = m.phase === "route" ? o.route : m.phase === "weapon" ? o.weapon : o.keepsake;
          const choice = o.follow ? NO_PREFERENCE : (want ?? m.options[0]?.id);
          if (choice) send({ type: `vote_${m.phase}`, [m.phase]: choice });
          break;
        }
        case "lobby_state": {
          const me = m.players.find((p) => p.id === m.you);
          if (m.phase === "ready_check" && !me?.ready) send({ type: "ready" });
          // Host of a private lobby: start once enough racers are in.
          if (m.phase === "waiting" && !m.public && me?.host && m.players.length >= (o.startAt ?? 2) && !startSent) {
            startSent = true;
            send({ type: "start_race" });
          }
          if (m.phase !== "waiting") startSent = false;
          break;
        }
        case "race_start":
          res.race = { seed: m.seed, weapon: m.weapon, keepsake: m.keepsake, route: m.route };
          timers.push(
            setTimeout(() => {
              raceStart = Date.now();
              const elapsed = () => (Date.now() - raceStart) / 1000;
              timers.push(
                setInterval(() => {
                  depth += 1;
                  send({ type: "progress_update", room: `MockRoom${depth}`, biome: "F", depth, hp: 100, max_hp: 100, time: elapsed(), alive: true });
                }, o.progressEvery * 1000),
              );
              if (o.outcome !== "none") {
                timers.push(
                  setTimeout(() => send({ type: "run_complete", victory: o.outcome === "win", time: elapsed() }), o.finishAfter * 1000),
                );
              }
            }, m.countdown_ms),
          );
          break;
        case "opponent_progress":
          res.opponentProgress += 1;
          break;
        case "opponent_finished":
          // Rival dropped out (died/forfeited) and we have no scripted finish: finish our run shortly.
          if (!m.victory && o.outcome === "none") {
            timers.push(setTimeout(() => send({ type: "run_complete", victory: true, time: (Date.now() - raceStart) / 1000 }), 2000));
          }
          break;
        case "race_decided":
          // Lost with no scripted finish: give up like a player would, which ends the race.
          if (!m.you_won && o.outcome === "none") send({ type: "forfeit" });
          break;
        case "race_result":
          res.result = m;
          finish(null);
          break;
        case "error":
          if (m.code === "lobby_not_found" || m.code === "lobby_full") finish(m.code);
          break;
      }
    };

    let buf = "";
    sock.on("connect", () =>
      send({ type: "hello", name: o.name, version: o.version ?? "mock", ...(o.gameBuild ? { game_build: o.gameBuild } : {}) }),
    );
    sock.on("data", (chunk: string) => {
      buf += chunk;
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) handle(JSON.parse(line) as ServerMessage);
      }
    });
    sock.on("error", (e) => finish(`socket: ${e.message}`));
    sock.on("close", () => finish(res.result ? null : "closed"));
  });
}

async function main() {
  const { values } = parseArgs({
    options: {
      host: { type: "string", default: "127.0.0.1" },
      port: { type: "string", default: "7777" },
      name: { type: "string", default: "MockBot" },
      create: { type: "boolean", default: false },
      queue: { type: "boolean", default: false },
      join: { type: "string" },
      "join-file": { type: "string" },
      "code-file": { type: "string" },
      route: { type: "string" },
      weapon: { type: "string" },
      keepsake: { type: "string" },
      outcome: { type: "string", default: "none" },
      "finish-after": { type: "string", default: "30" },
      "progress-every": { type: "string", default: "2" },
      timeout: { type: "string", default: "900" },
      quiet: { type: "boolean", default: false },
      version: { type: "string" },
      "start-at": { type: "string" },
      follow: { type: "boolean", default: false },
      "game-build": { type: "string" },
    },
  });
  const outcome = values.outcome as MockOptions["outcome"];
  if (!["win", "die", "none"].includes(outcome)) throw new Error("--outcome must be win|die|none");
  const res = await runMock({
    host: values.host!,
    port: Number(values.port),
    name: values.name!,
    create: values.create!,
    queue: values.queue!,
    join: values.join,
    joinFile: values["join-file"],
    codeFile: values["code-file"],
    route: values.route,
    weapon: values.weapon,
    keepsake: values.keepsake,
    outcome,
    finishAfter: Number(values["finish-after"]),
    progressEvery: Number(values["progress-every"]),
    quiet: values.quiet!,
    timeout: Number(values.timeout),
    version: values.version,
    startAt: values["start-at"] ? Number(values["start-at"]) : undefined,
    follow: values.follow!,
    gameBuild: values["game-build"] ? Number(values["game-build"]) : undefined,
  });
  console.log(`RESULT: ${JSON.stringify(res)}`);
  process.exit(res.ok ? 0 : 1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e);
    process.exit(2);
  });
}
