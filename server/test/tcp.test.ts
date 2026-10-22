import assert from "node:assert/strict";
import net from "node:net";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { runMock, type MockOptions } from "../src/mock-client.js";
import { RaceServer, realRandom, realScheduler } from "../src/race-server.js";
import { listen } from "../src/tcp.js";
import { TEST_KEEPSAKES, TEST_WEAPONS } from "./helpers.js";

describe("tcp transport + mock clients", () => {
  let tcp: net.Server;
  let port: number;

  before(async () => {
    const server = new RaceServer({
      voteSeconds: 2,
      countdownMs: 300,
      raceTimeLimitMs: 60_000,
      reconnectGraceMs: 1000,
      idleLobbyMs: 60_000,
      pools: { weapon: TEST_WEAPONS, keepsake: TEST_KEEPSAKES },
      scheduler: realScheduler,
      random: realRandom,
      log: () => {},
    });
    tcp = await listen(server, 0, "127.0.0.1", () => {});
    port = (tcp.address() as net.AddressInfo).port;
  });

  after(() => tcp.close());

  const base = (): MockOptions => ({
    host: "127.0.0.1",
    port,
    name: "Bot",
    create: false,
    outcome: "none",
    finishAfter: 1,
    progressEvery: 0.1,
    quiet: true,
    timeout: 15,
  });

  it("two bots race end to end: same seed, winner decided", async () => {
    const codeFile = join(mkdtempSync(join(tmpdir(), "h2r-")), "code");
    const [host, guest] = await Promise.all([
      runMock({ ...base(), name: "Host", create: true, codeFile, weapon: "WeaponAxe", outcome: "win", finishAfter: 1 }),
      runMock({ ...base(), name: "Guest", joinFile: codeFile, weapon: "WeaponAxe", outcome: "die", finishAfter: 0.5 }),
    ]);
    assert.equal(host.error, null);
    assert.equal(guest.error, null);
    assert.ok(host.race && guest.race);
    assert.deepEqual(host.race, guest.race);
    assert.equal(host.race.weapon, "WeaponAxe");
    assert.equal(host.result?.reason, "survivor_finished");
    assert.equal(host.result?.you_won, true);
    assert.equal(guest.result?.you_won, false);
    assert.ok(host.opponentProgress > 0, "host saw guest progress");
  });

  it("two bots meet through Find Match over TCP", async () => {
    const [a, b] = await Promise.all([
      runMock({ ...base(), name: "QA", queue: true, outcome: "win", finishAfter: 1 }),
      runMock({ ...base(), name: "QB", queue: true, outcome: "die", finishAfter: 0.5 }),
    ]);
    assert.equal(a.error, null);
    assert.equal(b.error, null);
    assert.equal(a.code, b.code);
    assert.deepEqual(a.race, b.race);
    assert.equal(a.result?.you_won, true);
  });

  it("handles split and coalesced lines and bad JSON", async () => {
    const sock = net.connect(port, "127.0.0.1");
    sock.setEncoding("utf8");
    const lines: string[] = [];
    let buf = "";
    sock.on("data", (c: string) => {
      buf += c;
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        lines.push(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
      }
    });
    await new Promise((r) => sock.once("connect", r));
    sock.write('{"type":"hel');
    await new Promise((r) => setTimeout(r, 50));
    sock.write('lo","name":"X"}\n{not json}\n{"type":"ping","t":7}\n');
    await new Promise((r) => setTimeout(r, 100));
    sock.end();
    const msgs = lines.map((l) => JSON.parse(l)).filter((m) => m.type !== "presence");
    assert.deepEqual(
      msgs.map((m) => m.type),
      ["welcome", "error", "pong"],
    );
    assert.equal(msgs[1].code, "bad_json");
    assert.equal(msgs[2].t, 7);
  });
});
