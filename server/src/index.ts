import { KEEPSAKES, routes, WEAPONS } from "./pools.js";
import { PbStore } from "./pb-store.js";
import { RaceLogStore } from "./race-log-store.js";
import { RaceServer, realRandom, realScheduler } from "./race-server.js";
import { listenStatus } from "./status-page.js";
import { listen } from "./tcp.js";
import { LATEST_MOD_VERSION } from "./versions.js";

const env = process.env;
const port = Number(env.PORT ?? 7777);
const host = env.HOST ?? "0.0.0.0";
const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);

const server = new RaceServer({
  voteSeconds: Number(env.VOTE_SECONDS ?? 15),
  countdownMs: Number(env.COUNTDOWN_MS ?? 3000),
  raceTimeLimitMs: Number(env.RACE_TIME_LIMIT_MS ?? 3 * 60 * 60 * 1000),
  reconnectGraceMs: Number(env.RECONNECT_GRACE_MS ?? 60 * 1000),
  idleLobbyMs: Number(env.IDLE_LOBBY_MS ?? 30 * 60 * 1000),
  maxPlayers: Number(env.MAX_PLAYERS ?? 5),
  matchPlayers: Number(env.MATCH_PLAYERS ?? 2),
  botRoomSeconds: Number(env.BOT_ROOM_SECONDS ?? 75),
  latestModVersion: env.LATEST_MOD_VERSION || undefined, // tests: pretend a newer release exists
  raceLogs: env.RACE_LOG_DIR ? new RaceLogStore(env.RACE_LOG_DIR, log) : undefined,
  pbs: env.PB_FILE ? new PbStore(env.PB_FILE, log) : undefined,
  pools: { route: routes(env.ROUTES), weapon: WEAPONS, keepsake: KEEPSAKES },
  prepMs: Number(env.PREP_SECONDS ?? 120) * 1000,
  fixedSeed: env.RACE_SEED ? Number(env.RACE_SEED) : undefined,
  scheduler: realScheduler,
  random: realRandom,
  log,
});

const tcp = await listen(server, port, host, log);
log(`listening on ${host}:${port}`);
// The public status page (counts and races under way), on its own port.
const statusPort = env.STATUS_PORT ? Number(env.STATUS_PORT) : null;
const web =
  statusPort === null
    ? null
    : await listenStatus(server, statusPort, host, { latestMod: env.LATEST_MOD_VERSION || LATEST_MOD_VERSION });
if (web) log(`status page on ${host}:${statusPort}`);
const sweeper = setInterval(() => server.sweep(), 60_000);

const shutdown = () => {
  clearInterval(sweeper);
  tcp.close();
  web?.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
