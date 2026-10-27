// The public status page: an HTTP listener next to the race protocol's TCP one.
// GET / is a page rendered on the server (it reloads itself, no scripts) and
// GET /status.json the same snapshot as data. Both are cached for a few
// seconds, so any number of viewers costs one snapshot per interval.

import { createHash } from "node:crypto";
import http from "node:http";
import type { PublicRace, PublicStatus, RaceServer } from "./race-server.js";

export interface StatusPageOptions {
  /** How long one snapshot is served (default 10 s). */
  cacheMs?: number;
  /** The newest mod release, shown with the download link. */
  latestMod: string;
  now?: () => number;
}

const REFRESH_SECONDS = 15;
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
h2 { font-size: 17px; margin: 0 0 12px; }
.races { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.race { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 12px 16px; }
.race.racing { border-left: 3px solid var(--green); }
.top { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; }
.what { font-weight: 600; }
.clock { font-variant-numeric: tabular-nums; color: var(--green); white-space: nowrap; }
.wait { color: var(--muted); white-space: nowrap; }
.meta { color: var(--muted); font-size: 14px; margin-top: 2px; }
.empty { color: var(--muted); background: var(--panel); border: 1px dashed var(--line); border-radius: 10px;
  padding: 16px; margin: 0; }
footer { margin-top: 32px; color: var(--muted); font-size: 13px; }
a { color: var(--gold); }
@media (max-width: 480px) { .counts { gap: 8px; } .tile { padding: 10px 12px; } .n { font-size: 26px; } }
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

function raceItem(r: PublicRace): string {
  const what = [r.route, r.weapon].filter((x) => x).join(" · ") || "Choosing a route";
  const who = r.bot ? `${r.racers} vs the house bot` : `${r.racers} racers`;
  const meta = [who];
  if (r.state === "racing") {
    if (r.furthest) meta.push(`furthest: ${r.furthest.region ? `${r.furthest.region}, ` : ""}depth ${r.furthest.depth}`);
    if (r.done > 0) meta.push(`${r.done} done`);
  }
  const right =
    r.state === "racing"
      ? `<span class="clock">${clock(r.elapsed ?? 0)}</span>`
      : `<span class="wait">${r.state === "voting" ? "Voting" : "Getting ready"}</span>`;
  return (
    `<li class="race ${r.state === "racing" ? "racing" : ""}"><div class="top"><span class="what">${esc(what)}</span>${right}</div>` +
    `<div class="meta">${esc(meta.join(" · "))}</div></li>`
  );
}

export function renderPage(st: PublicStatus, latestMod: string, at: number): string {
  const tile = (n: number, label: string) => `<div class="tile"><span class="n">${n}</span><span class="l">${label}</span></div>`;
  const races = st.races.length
    ? `<ul class="races">${st.races.map(raceItem).join("")}</ul>`
    : `<p class="empty">No races right now.</p>`;
  const updated = new Date(at).toISOString().slice(11, 19);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="${REFRESH_SECONDS}">
<title>H2CS Live</title>
<meta name="description" content="Who is racing on the Hades 2 Competitive Speedrunning server right now.">
<style>${CSS}</style>
</head>
<body>
<main>
<h1>Hades 2 Competitive Speedrunning</h1>
<p class="sub">Live on the race server</p>
<section class="counts">${tile(st.online, "online")}${tile(st.searching, "looking for a match")}${tile(st.racing, "in a race")}</section>
<h2>Races</h2>
${races}
<footer>Updated ${updated} UTC, refreshes every ${REFRESH_SECONDS} s ·
<a href="${MOD_URL}">Get the mod</a> (${esc(latestMod)}) · <a href="${REPO_URL}">GitHub</a> · <a href="/status.json">JSON</a></footer>
</main>
</body>
</html>
`;
}

export function listenStatus(
  server: RaceServer,
  port: number,
  host: string,
  opts: StatusPageOptions,
): Promise<http.Server> {
  const cacheMs = opts.cacheMs ?? 10_000;
  const now = opts.now ?? Date.now;
  let cached: { at: number; page: string; json: string } | null = null;
  const snapshot = () => {
    const at = now();
    if (!cached || at - cached.at >= cacheMs) {
      const st = server.publicStatus();
      cached = {
        at,
        page: renderPage(st, opts.latestMod, at),
        json: JSON.stringify({ ...st, latest_mod: opts.latestMod, updated: new Date(at).toISOString() }),
      };
    }
    return cached;
  };

  const web = http.createServer((req, res) => {
    const path = (req.url ?? "/").split("?")[0];
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
    const cache = { "Cache-Control": `public, max-age=${Math.round(cacheMs / 1000)}` };
    if (path === "/") return reply(200, "text/html; charset=utf-8", snapshot().page, { ...cache, "Content-Security-Policy": PAGE_CSP });
    if (path === "/status.json")
      return reply(200, "application/json", snapshot().json, { ...cache, "Access-Control-Allow-Origin": "*" });
    return reply(404, "text/plain", "not found\n");
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
