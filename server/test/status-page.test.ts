import assert from "node:assert/strict";
import type http from "node:http";
import type { AddressInfo } from "node:net";
import { describe, it } from "node:test";
import { clock, listenStatus, renderPage } from "../src/status-page.js";
import { makeServer, pair, racing, TestClient } from "./helpers.js";

describe("public status", () => {
  it("lists a race under way: what was voted, racers, clock and the furthest region, no names or codes", () => {
    const { server, scheduler, a, b, code } = racing();
    a.send({ type: "progress_update", room: "G_Combat03", biome: "G", depth: 12, hp: 30, time: 80, alive: true });
    b.send({ type: "progress_update", room: "F_Combat05", biome: "F", depth: 4, hp: 30, time: 80, alive: true });
    scheduler.advance(83_000);
    const st = server.publicStatus();
    assert.deepEqual(
      { online: st.online, searching: st.searching, racing: st.racing },
      { online: 2, searching: 0, racing: 2 },
    );
    assert.deepEqual(st.races, [
      { state: "racing", route: null, weapon: "Axe", racers: 2, bot: false, elapsed: 83, done: 0, furthest: { region: "Oceanus", depth: 12 } },
    ]);
    const json = JSON.stringify(st);
    for (const secret of ["Alice", "Bob", code]) assert.ok(!json.includes(secret), `no ${secret}`);
    a.send({ type: "run_complete", victory: false, time: 90 });
    assert.equal(server.publicStatus().races[0]!.done, 1, "a fallen racer is done");
  });

  it("shows lobbies still voting, and a race against the house bot as such", () => {
    assert.equal(pair().server.publicStatus().races[0]!.state, "voting");
    const { server, scheduler } = makeServer();
    const ann = new TestClient(server, "Ann");
    ann.hello();
    ann.send({ type: "create_lobby" });
    assert.equal(server.publicStatus().races.length, 0, "a lobby still waiting is not listed");
    ann.send({ type: "add_bot" });
    scheduler.advance(1000); // the bot readies itself
    ann.send({ type: "ready" });
    const [r] = server.publicStatus().races;
    assert.equal(r!.racers, 1);
    assert.equal(r!.bot, true);
  });

  it("formats race clocks", () => {
    assert.equal(clock(0), "0:00");
    assert.equal(clock(83), "1:23");
    assert.equal(clock(3725), "1:02:05");
  });

  it("renders the counts and each race", () => {
    const page = renderPage(
      {
        online: 3,
        searching: 1,
        racing: 2,
        races: [{ state: "racing", route: "Underworld", weapon: "Witch's Staff", racers: 2, bot: false, elapsed: 1421, done: 1, furthest: { region: "Oceanus", depth: 12 } }],
      },
      "0.6.7",
      Date.UTC(2026, 9, 27, 18, 44, 12),
    );
    assert.match(page, /<span class="n">3<\/span><span class="l">online/);
    assert.match(page, /Underworld · Witch&#39;s Staff/);
    assert.match(page, /23:41/);
    assert.match(page, /2 racers · furthest: Oceanus, depth 12 · 1 done/);
    assert.match(page, /Updated 18:44:12 UTC/);
    assert.match(renderPage({ online: 0, searching: 0, racing: 0, races: [] }, "0.6.7", 0), /No races right now/);
  });
});

describe("status page over HTTP", () => {
  async function serve() {
    const env = makeServer();
    let t = 1_000;
    const web: http.Server = await listenStatus(env.server, 0, "127.0.0.1", { latestMod: "9.9.9", cacheMs: 10_000, now: () => t });
    const base = `http://127.0.0.1:${(web.address() as AddressInfo).port}`;
    return { ...env, web, base, tick: (ms: number) => (t += ms) };
  }

  it("serves the page and the JSON, cached, and nothing else", async () => {
    const { server, web, base, tick } = await serve();
    try {
      const page = await fetch(`${base}/`);
      assert.equal(page.status, 200);
      assert.match(page.headers.get("content-type") ?? "", /^text\/html/);
      assert.match(page.headers.get("content-security-policy") ?? "", /default-src 'none'; style-src 'sha256-/);
      assert.match(await page.text(), /No races right now/);

      const first = await (await fetch(`${base}/status.json`)).json();
      assert.equal(first.online, 0);
      assert.equal(first.latest_mod, "9.9.9");
      new TestClient(server, "Ann").hello();
      assert.equal((await (await fetch(`${base}/status.json`)).json()).online, 0, "inside the cache window: the same snapshot");
      tick(10_000);
      assert.equal((await (await fetch(`${base}/status.json`)).json()).online, 1, "then a fresh one");

      assert.equal((await fetch(`${base}/nope`)).status, 404);
      assert.equal((await fetch(`${base}/`, { method: "POST", body: "x" })).status, 405);
    } finally {
      web.close();
    }
  });
});
