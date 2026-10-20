import { KEEPSAKES, WEAPONS } from "./pools.js";
import { RaceServer, realRandom, realScheduler } from "./race-server.js";
import { listen } from "./tcp.js";

const env = process.env;
const port = Number(env.PORT ?? 7777);
const host = env.HOST ?? "0.0.0.0";
const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);

const server = new RaceServer({
  voteSeconds: Number(env.VOTE_SECONDS ?? 15),
  countdownMs: Number(env.COUNTDOWN_MS ?? 3000),
  deathTimeoutMs: Number(env.DEATH_TIMEOUT_MS ?? 15 * 60 * 1000),
  reconnectGraceMs: Number(env.RECONNECT_GRACE_MS ?? 60 * 1000),
  idleLobbyMs: Number(env.IDLE_LOBBY_MS ?? 30 * 60 * 1000),
  pools: { weapon: WEAPONS, keepsake: KEEPSAKES },
  scheduler: realScheduler,
  random: realRandom,
  log,
});

const tcp = await listen(server, port, host, log);
log(`listening on ${host}:${port}`);
const sweeper = setInterval(() => server.sweep(), 60_000);

const shutdown = () => {
  clearInterval(sweeper);
  tcp.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
