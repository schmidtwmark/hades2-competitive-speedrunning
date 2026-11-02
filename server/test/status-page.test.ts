import assert from "node:assert/strict";
import type http from "node:http";
import type { AddressInfo } from "node:net";
import { describe, it } from "node:test";
import vm from "node:vm";
import { RaceLogStore, type LogFs } from "../src/race-log-store.js";
import type { PublicPastRace } from "../src/race-server.js";
import { clock, how, listenStatus, LOCAL_TIME_JS, renderHistory, renderPage, when } from "../src/status-page.js";
import { makeServer, pair, racing, TestClient } from "./helpers.js";

/** An in-memory file system holding race records (path -> contents). */
function memFs(files = new Map<string, string>()): LogFs {
  return {
    mkdir: () => {},
    append: (p, t) => void files.set(p, (files.get(p) ?? "") + t),
    write: (p, t) => void files.set(p, t),
    list: (dir) => {
      const names = [...files.keys()].filter((k) => k.startsWith(`${dir}/`)).map((k) => k.slice(dir.length + 1).split("/")[0]!);
      if (names.length === 0) throw new Error(`no ${dir}`);
      return [...new Set(names)];
    },
    read: (p) => {
      const t = files.get(p);
      if (t === undefined) throw new Error(`no ${p}`);
      return t;
    },
  };
}

/** A race.json an earlier run of the server left: Nov 2, both fell. */
const OLD_RACE = {
  lobby: "CL76",
  race_id: 2,
  seed: 1487146878,
  weapon: "WeaponAxe",
  keepsake: "KeepsakeB",
  route: "",
  started_at: "2026-11-02T02:05:59.067Z",
  entrants: [
    { id: "p22", name: "Not Jao", bot: false },
    { id: "p21", name: "mossy_jpg", bot: false },
  ],
  results: [
    { id: "p21", name: "mossy_jpg", place: 1, finished: true, victory: false, outcome: "died", time: 1201.759, depth: 41, room: "I_Boss01" },
    { id: "p22", name: "Not Jao", place: 2, finished: true, victory: false, outcome: "died", time: 819.631, depth: 32, room: "H_Boss02" },
  ],
};

describe("public status", () => {
  it("lists a race under way: what was voted, each racer's name and region, the clock; no lobby code", () => {
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
      {
        state: "racing",
        route: null,
        weapon: "Axe",
        keepsake: "B",
        elapsed: 83,
        racers: [
          { name: "Alice", bot: false, region: "Oceanus", depth: 12, outcome: null, time: null },
          { name: "Bob", bot: false, region: "Erebus", depth: 4, outcome: null, time: null },
        ],
      },
    ]);
    assert.ok(!JSON.stringify(st).includes(code), "no lobby code");
    a.send({ type: "run_complete", victory: false, time: 90 });
    const alice = server.publicStatus().races[0]!.racers[0]!;
    assert.equal(alice.outcome, "died", "a fallen racer shows how they went out");
    assert.equal(alice.time, 83);
  });

  it("shows lobbies still voting, and the house bot as one", () => {
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
    assert.deepEqual(r!.racers.map((x) => [x.name, x.bot]), [["Ann", false], ["Bot", true]]);
  });

  it("keeps every race over: records from earlier runs, then each race as it ends, newest first", () => {
    // The test clock starts in 1970: the earlier race is from before it.
    const earlier = { ...OLD_RACE, started_at: "1970-01-01T00:00:00.000Z" };
    const files = new Map([["/data/races/19700101-000000-CL76-race2/race.json", JSON.stringify(earlier)]]);
    const store = new RaceLogStore("/data/races", () => {}, memFs(files));
    const { server, a, b } = racing({ raceLogs: store });
    assert.equal(server.publicHistory().length, 1, "the earlier run's race");
    a.send({ type: "progress_update", room: "F_Combat05", biome: "F", depth: 5, hp: 30, time: 80, alive: true });
    a.send({ type: "run_complete", victory: true, time: 1500, stats: { Fear: 4 } });
    b.send({ type: "run_complete", victory: false, time: 700 });
    const [now, old] = server.publicHistory();
    assert.equal(now!.results[0]!.name, "Alice");
    assert.equal(now!.results[0]!.victory, true);
    assert.equal(now!.results[0]!.fear, 4, "her Fear is on the record");
    assert.equal(now!.weapon, "Axe");
    assert.deepEqual(
      old!.results.map((x) => [x.place, x.name, x.outcome, x.region, x.depth]),
      [
        [1, "mossy_jpg", "died", "Tartarus", 41],
        [2, "Not Jao", "died", "Fields of Mourning", 32],
      ],
    );
    assert.equal(old!.keepsake, "B");
    assert.ok(!JSON.stringify(server.publicHistory()).includes("CL76"), "no lobby codes");
  });

  it("a record without results (the server stopped mid-race) lists its racers", () => {
    const files = new Map([["/data/races/x/race.json", JSON.stringify({ ...OLD_RACE, results: null })]]);
    const { server } = makeServer({ raceLogs: new RaceLogStore("/data/races", () => {}, memFs(files)) });
    assert.deepEqual(server.publicHistory()[0]!.results.map((x) => [x.place, x.name]), [
      [null, "Not Jao"],
      [null, "mossy_jpg"],
    ]);
  });
});

describe("status page", () => {
  const PAST: PublicPastRace = {
    started_at: "2026-11-02T02:05:59.067Z",
    route: "Underworld",
    weapon: "Moonstone Axe",
    keepsake: "Jeweled Pom",
    results: [
      { place: 1, name: "<b>Zag</b>", bot: false, region: null, depth: 50, outcome: "cleared", time: 1694.2, victory: true, fear: 4 },
      { place: 2, name: "Mel", bot: false, region: "Tartarus", depth: 41, outcome: "died", time: 1201.759, victory: false, fear: null },
    ],
  };

  it("formats clocks, dates and how a run went", () => {
    assert.equal(clock(0), "0:00");
    assert.equal(clock(83), "1:23");
    assert.equal(clock(3725), "1:02:05");
    assert.equal(when("2026-11-02T02:05:59.067Z"), "Nov 2, 02:05 UTC");
    assert.equal(how(PAST.results[1]!), "Fell in Tartarus, depth 41");
    assert.equal(how(PAST.results[0]!, 4), "Cleared · Fear 4");
    assert.equal(how({ ...PAST.results[1]!, outcome: null, region: "Oceanus", depth: 12 }), "Oceanus, depth 12", "still racing");
    assert.equal(how({ ...PAST.results[1]!, outcome: "forfeit", region: null, depth: null }), "Forfeited");
  });

  it("renders the counts, the races under way and the latest races over", () => {
    const page = renderPage(
      {
        online: 3,
        searching: 1,
        racing: 2,
        races: [
          {
            state: "racing",
            route: "Underworld",
            weapon: "Witch's Staff",
            keepsake: null,
            elapsed: 1421,
            racers: [
              { name: "Bob", bot: false, region: "Erebus", depth: 4, outcome: null, time: null },
              { name: "Alice", bot: false, region: "Oceanus", depth: 12, outcome: null, time: null },
            ],
          },
        ],
      },
      Array.from({ length: 12 }, () => PAST),
      "0.6.7",
      Date.UTC(2026, 9, 27, 18, 44, 12),
    );
    assert.match(page, /<span class="n">3<\/span><span class="l">online/);
    assert.match(page, /Underworld · Witch&#39;s Staff/);
    assert.match(page, /23:41/);
    assert.ok(page.indexOf("Alice") < page.indexOf("Bob"), "the deepest racer first");
    assert.match(page, /Oceanus, depth 12/);
    assert.equal(page.split("Nov 2, 02:05 UTC").length - 1, 10, "the latest ten races");
    assert.match(page, /<a href="\/races">All 12 races<\/a>/);
    assert.match(page, /&lt;b&gt;Zag&lt;\/b&gt;/, "names are text, not markup");
    assert.match(page, /Updated <time datetime="2026-10-27T18:44:12.000Z" data-fmt="clock">18:44:12 UTC<\/time>/);
    assert.match(page, /<time datetime="2026-11-02T02:05:59.067Z">Nov 2, 02:05 UTC<\/time>/);
    assert.match(page, /<script src="\/local-time.js" defer><\/script>/);
    assert.match(page, /http-equiv="refresh"/);
    const empty = renderPage({ online: 0, searching: 0, racing: 0, races: [] }, [], "0.6.7", 0);
    assert.match(empty, /No races right now/);
    assert.match(empty, /No races yet/);
  });

  it("renders every race over on the history page, the winner marked", () => {
    const page = renderHistory(Array.from({ length: 12 }, () => PAST), "0.6.7", 0);
    assert.equal(page.split("Nov 2, 02:05 UTC").length - 1, 12);
    assert.match(page, /<li class="row win"><span class="pl">1<\/span><span><span class="name">&lt;b&gt;Zag/);
    assert.match(page, /Cleared · Fear 4<\/span><\/span><span class="t">28:14<\/span>/);
    assert.ok(!page.includes('http-equiv="refresh"'), "the history page doesn't reload itself");
    const stopped = renderHistory([{ ...PAST, results: PAST.results.map((x) => ({ ...x, place: null, outcome: null })) }], "0.6.7", 0);
    assert.match(stopped, /No result on record/);
    assert.ok(!stopped.includes('class="pl"'), "no places");
  });
});

describe("local times", () => {
  it("rewrites each time in the viewer's zone, keeping the UTC text as its tooltip", () => {
    const el = (iso: string, fmt?: string) => ({
      textContent: "UTC text",
      title: "",
      dataset: fmt ? { fmt } : {},
      getAttribute: () => iso,
    });
    const date = el("2026-11-02T02:05:59.067Z");
    const time = el("2026-10-27T18:44:12.000Z", "clock");
    const bad = el("not a date");
    vm.runInNewContext(LOCAL_TIME_JS, { document: { querySelectorAll: () => [date, time, bad] } });
    assert.equal(
      date.textContent,
      new Date("2026-11-02T02:05:59.067Z").toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }),
    );
    assert.match(time.textContent, /\d:44:12/);
    assert.equal(date.title, "UTC text");
    assert.equal(bad.textContent, "UTC text", "a bad date stays as it was");
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

  it("serves the pages and the JSON, cached, and nothing else", async () => {
    const { server, web, base, tick } = await serve();
    try {
      const page = await fetch(`${base}/`);
      assert.equal(page.status, 200);
      assert.match(page.headers.get("content-type") ?? "", /^text\/html/);
      assert.match(page.headers.get("content-security-policy") ?? "", /default-src 'none'; style-src 'sha256-[^;]+; script-src 'self';/);
      const js = await fetch(`${base}/local-time.js`);
      assert.match(js.headers.get("content-type") ?? "", /^text\/javascript/);
      assert.equal(await js.text(), LOCAL_TIME_JS);
      assert.match(await page.text(), /No races right now/);
      const history = await fetch(`${base}/races`);
      assert.equal(history.status, 200);
      assert.match(await history.text(), /Every race on the server/);
      assert.deepEqual((await (await fetch(`${base}/races.json`)).json()).races, []);

      const first = await (await fetch(`${base}/status.json`)).json();
      assert.equal(first.online, 0);
      assert.equal(first.latest_mod, "9.9.9");
      new TestClient(server, "Ann").hello();
      assert.equal((await (await fetch(`${base}/status.json`)).json()).online, 0, "inside the cache window: the same snapshot");
      tick(10_000);
      assert.equal((await (await fetch(`${base}/status.json`)).json()).online, 1, "then a fresh one");

      assert.equal((await fetch(`${base}/nope`)).status, 404);
      assert.equal((await fetch(`${base}/toString`)).status, 404, "only the pages, not object keys");
      assert.equal((await fetch(`${base}/`, { method: "POST", body: "x" })).status, 405);
    } finally {
      web.close();
    }
  });
});
