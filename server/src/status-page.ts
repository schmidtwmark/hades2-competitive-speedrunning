// The public status page: an HTTP listener next to the race protocol's TCP one.
// GET / is a page rendered on the server (it reloads itself, no scripts) with
// the races under way and the latest ones over; GET /races lists every race
// over. GET /status.json and /races.json are the same as data. Everything is
// cached for a few seconds, so any number of viewers costs one snapshot per
// interval.

import { createHash } from "node:crypto";
import http from "node:http";
import type { Outcome } from "./protocol.js";
import type { PublicPastRace, PublicRace, PublicRacer, PublicStatus, RaceServer } from "./race-server.js";

export interface StatusPageOptions {
  /** How long one snapshot is served (default 10 s). */
  cacheMs?: number;
  /** The newest mod release, shown with the download link. */
  latestMod: string;
  now?: () => number;
}

const REFRESH_SECONDS = 15;
/** Races over shown on the live page; /races has them all. */
const RECENT = 10;
const MOD_URL = "https://thunderstore.io/c/hades-ii/p/schmidtwmark/Hades_2_Competitive_Speedrunning/";
const REPO_URL = "https://github.com/schmidtwmark/hades2-competitive-speedrunning";

const CSS = `
:root { color-scheme: dark; --bg: #0f0b17; --panel: #1a1324; --line: #2f2442; --text: #ece6f5;
  --muted: #a79fb8; --gold: #e8c36a; --green: #8fd48a; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 32px 16px 48px; }
h1 { margin: 0; font-size: 24px; color: var(--gold); letter-spacing: 0.02em; }
.sub { margin: 4px 0 24px; color: var(--muted); }
.counts { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 32px; }
.tile { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
.n { display: block; font-size: 34px; font-weight: 700; font-variant-numeric: tabular-nums; }
.l { color: var(--muted); font-size: 14px; }
.head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; margin: 32px 0 12px; }
.head:first-of-type { margin-top: 0; }
h2 { font-size: 17px; margin: 0; }
.races { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.race { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px 16px; }
.race.racing { border-left: 3px solid var(--green); }
.top { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; }
.what { font-weight: 600; }
.clock { font-variant-numeric: tabular-nums; color: var(--green); white-space: nowrap; }
.wait, .when { color: var(--muted); white-space: nowrap; font-size: 14px; }
.who { list-style: none; margin: 8px 0 0; padding: 0; display: grid; gap: 4px; }
.row { display: grid; grid-template-columns: 1.6em 1fr auto; gap: 8px; align-items: baseline; }
.row.live { grid-template-columns: 1fr auto; }
.pl { color: var(--muted); font-variant-numeric: tabular-nums; }
.name { overflow-wrap: anywhere; }
.how { display: block; color: var(--muted); font-size: 14px; }
.t { font-variant-numeric: tabular-nums; color: var(--muted); }
.win .pl, .win .name, .win .t { color: var(--gold); }
.win .name { font-weight: 600; }
.empty { color: var(--muted); background: var(--panel); border: 1px dashed var(--line); border-radius: 10px;
  padding: 16px; margin: 0; }
footer { margin-top: 32px; color: var(--muted); font-size: 13px; }
a { color: var(--gold); }
@media (max-width: 480px) { .counts { gap: 8px; } .tile { padding: 10px 12px; } .n { font-size: 26px; }
  .top { flex-direction: column; gap: 0; } }
`;
const CSS_HASH = createHash("sha256").update(CSS).digest("base64");
const PAGE_CSP = `default-src 'none'; style-src 'sha256-${CSS_HASH}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`;

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export function clock(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "Nov 2, 02:05 UTC" (the page can't know the viewer's time zone). */
export function when(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.toISOString().slice(11, 16)} UTC`;
}

const ENDED: Record<Outcome, string> = {
  cleared: "Cleared",
  died: "Fell",
  forfeit: "Forfeited",
  disconnect: "Disconnected",
  timeout: "Out of time",
};

const where = (r: PublicRacer) =>
  r.region && r.depth !== null ? `${r.region}, depth ${r.depth}` : r.region ?? (r.depth !== null ? `depth ${r.depth}` : "");

/** How a racer's run went: "Fell in Tartarus, depth 41", "Cleared", or where they are now. */
export function how(r: PublicRacer, fear: number | null = null): string {
  let text: string;
  if (r.outcome === "cleared") text = ENDED.cleared;
  else if (r.outcome) text = where(r) ? `${ENDED[r.outcome]} in ${where(r)}` : ENDED[r.outcome];
  else text = where(r);
  if (fear) text = text ? `${text} · Fear ${fear}` : `Fear ${fear}`;
  return text;
}

/** One racer: their place (none while racing), name, how it went and their time. */
function row(r: PublicRacer, place: string | null, extra: { win?: boolean; fear?: number | null } = {}): string {
  const name = r.bot ? `${r.name} (house bot)` : r.name;
  const detail = how(r, extra.fear ?? null);
  const time = r.time !== null ? clock(Math.floor(r.time)) : "";
  return (
    `<li class="row${place === null ? " live" : ""}${extra.win ? " win" : ""}">${place === null ? "" : `<span class="pl">${place}</span>`}` +
    `<span><span class="name">${esc(name)}</span>${detail ? `<span class="how">${esc(detail)}</span>` : ""}</span>` +
    `<span class="t">${time}</span></li>`
  );
}

const title = (r: { route: string | null; weapon: string | null; keepsake: string | null }) =>
  [r.route, r.weapon, r.keepsake].filter((x) => x).join(" · ");

function liveItem(r: PublicRace): string {
  const right =
    r.state === "racing"
      ? `<span class="clock">${clock(r.elapsed ?? 0)}</span>`
      : `<span class="wait">${r.state === "voting" ? "Voting" : "Getting ready"}</span>`;
  // Racing: whoever is deepest first.
  const racers =
    r.state === "racing"
      ? [...r.racers].sort((a, b) => (b.depth ?? -1) - (a.depth ?? -1))
      : r.racers;
  return (
    `<li class="race ${r.state === "racing" ? "racing" : ""}"><div class="top"><span class="what">${esc(title(r) || "Choosing a route")}</span>${right}</div>` +
    `<ol class="who">${racers.map((x) => row(x, null)).join("")}</ol></li>`
  );
}

function pastItem(r: PublicPastRace): string {
  // No places: the server stopped (a redeploy) before the race was over.
  const unfinished = r.results.every((x) => x.place === null);
  const results = r.results.map((x) => (unfinished ? row(x, null) : row(x, String(x.place), { win: x.victory, fear: x.fear })));
  return (
    `<li class="race"><div class="top"><span class="what">${esc(title(r) || "Race")}</span><span class="when">${esc(when(r.started_at))}</span></div>` +
    `<ol class="who">${results.join("")}</ol>${unfinished ? `<span class="how">No result on record</span>` : ""}</li>`
  );
}

function page(body: string, refresh: boolean, latestMod: string, at: number): string {
  const updated = new Date(at).toISOString().slice(11, 19);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${refresh ? `<meta http-equiv="refresh" content="${REFRESH_SECONDS}">\n` : ""}<title>H2CS Live</title>
<meta name="description" content="Who is racing on the Hades 2 Competitive Speedrunning server, and every race so far.">
<style>${CSS}</style>
</head>
<body>
<main>
<h1>Hades 2 Competitive Speedrunning</h1>
${body}
<footer>Updated ${updated} UTC${refresh ? `, refreshes every ${REFRESH_SECONDS} s` : ""} ·
<a href="${MOD_URL}">Get the mod</a> (${esc(latestMod)}) · <a href="${REPO_URL}">GitHub</a> · <a href="/status.json">JSON</a></footer>
</main>
</body>
</html>
`;
}

export function renderPage(st: PublicStatus, history: PublicPastRace[], latestMod: string, at: number): string {
  const tile = (n: number, label: string) => `<div class="tile"><span class="n">${n}</span><span class="l">${label}</span></div>`;
  const live = st.races.length
    ? `<ul class="races">${st.races.map(liveItem).join("")}</ul>`
    : `<p class="empty">No races right now.</p>`;
  const recent = history.length
    ? `<ul class="races">${history.slice(0, RECENT).map(pastItem).join("")}</ul>`
    : `<p class="empty">No races yet.</p>`;
  const all = history.length > 0 ? `<a href="/races">All ${history.length} race${history.length === 1 ? "" : "s"}</a>` : "";
  return page(
    `<p class="sub">Live on the race server</p>
<section class="counts">${tile(st.online, "online")}${tile(st.searching, "looking for a match")}${tile(st.racing, "in a race")}</section>
<div class="head"><h2>Racing now</h2></div>
${live}
<div class="head"><h2>Latest races</h2>${all}</div>
${recent}`,
    true,
    latestMod,
    at,
  );
}

export function renderHistory(history: PublicPastRace[], latestMod: string, at: number): string {
  const list = history.length
    ? `<ul class="races">${history.map(pastItem).join("")}</ul>`
    : `<p class="empty">No races yet.</p>`;
  return page(
    `<p class="sub">Every race on the server, newest first · <a href="/">Racing now</a></p>
${list}`,
    false,
    latestMod,
    at,
  );
}

interface Snapshot {
  at: number;
  status: PublicStatus;
  history: PublicPastRace[];
  /** Each view of it, rendered on first request. */
  views: Map<string, string>;
}

type View = { type: string; render: (s: Snapshot, latestMod: string) => string };

const VIEWS: Record<string, View> = {
  "/": { type: "text/html; charset=utf-8", render: (s, mod) => renderPage(s.status, s.history, mod, s.at) },
  "/races": { type: "text/html; charset=utf-8", render: (s, mod) => renderHistory(s.history, mod, s.at) },
  "/status.json": {
    type: "application/json",
    render: (s, mod) => JSON.stringify({ ...s.status, latest_mod: mod, updated: new Date(s.at).toISOString() }),
  },
  "/races.json": { type: "application/json", render: (s) => JSON.stringify({ races: s.history, updated: new Date(s.at).toISOString() }) },
};

export function listenStatus(
  server: RaceServer,
  port: number,
  host: string,
  opts: StatusPageOptions,
): Promise<http.Server> {
  const cacheMs = opts.cacheMs ?? 10_000;
  const now = opts.now ?? Date.now;
  let snap: Snapshot | null = null;
  const view = (path: string, v: View) => {
    const at = now();
    if (!snap || at - snap.at >= cacheMs) {
      snap = { at, status: server.publicStatus(), history: server.publicHistory(), views: new Map() };
    }
    let body = snap.views.get(path);
    if (body === undefined) {
      body = v.render(snap, opts.latestMod);
      snap.views.set(path, body);
    }
    return body;
  };

  const web = http.createServer((req, res) => {
    const path = (req.url ?? "/").split("?")[0] ?? "/";
    const reply = (status: number, type: string, body: string, headers: Record<string, string> = {}) => {
      res.writeHead(status, {
        "Content-Type": type,
        "Content-Length": Buffer.byteLength(body),
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        ...headers,
      });
      res.end(req.method === "HEAD" ? undefined : body);
    };
    if (req.method !== "GET" && req.method !== "HEAD") return reply(405, "text/plain", "method not allowed\n", { Allow: "GET, HEAD" });
    const v = Object.hasOwn(VIEWS, path) ? VIEWS[path] : undefined;
    if (!v) return reply(404, "text/plain", "not found\n");
    const html = v.type.startsWith("text/html");
    return reply(200, v.type, view(path, v), {
      "Cache-Control": `public, max-age=${Math.round(cacheMs / 1000)}`,
      ...(html ? { "Content-Security-Policy": PAGE_CSP } : { "Access-Control-Allow-Origin": "*" }),
    });
  });
  web.headersTimeout = 10_000;
  web.requestTimeout = 10_000;
  return new Promise((resolve, reject) => {
    web.once("error", reject);
    web.listen(port, host, () => {
      web.off("error", reject);
      resolve(web);
    });
  });
}
