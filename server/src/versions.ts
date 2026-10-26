// Who may race whom. Both racers need a compatible Hades 2 Competitive Speedrunning (same
// major.minor, at least MIN_MOD_VERSION) and the identical Hades II build:
// the mod hooks native code by signature and the per-depth RNG only lines up
// on the same game scripts. The game build is the executable's PE link time
// (a Unix timestamp), so the older side is the one that needs to update.

/** Oldest mod version this server accepts (older clients speak another protocol). */
export const MIN_MOD_VERSION = "0.6.0";

/**
 * The newest mod release (mod/src/manifest.json; a test keeps them equal).
 * Clients older than this offer the player the update command.
 */
export const LATEST_MOD_VERSION = "0.6.6";

export interface ClientVersions {
  /** Mod version, e.g. "0.5.0" (anything unparsable counts as unknown). */
  mod: string | null;
  /** Hades II build: the game executable's link time, seconds since 1970. */
  gameBuild: number | null;
}

type Semver = [number, number, number];

export function parseVersion(v: string | null | undefined): Semver | null {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(v ?? "");
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function cmp(a: Semver, b: Semver): number {
  return a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
}

/** A client too old for this server at all (unknown versions, e.g. test tools, pass). */
export function modTooOld(v: string | null, min = MIN_MOD_VERSION): boolean {
  const have = parseVersion(v);
  const need = parseVersion(min);
  return have !== null && need !== null && cmp(have, need) < 0;
}

export interface Mismatch {
  what: "mod" | "game";
  /** Which side is behind: "a", "b", or "both" when it can't be told. */
  older: "a" | "b" | "both";
}

/** null when a and b can race each other. Unknown versions or builds don't block. */
export function compatibility(a: ClientVersions, b: ClientVersions): Mismatch | null {
  const va = parseVersion(a.mod);
  const vb = parseVersion(b.mod);
  if (va && vb && (va[0] !== vb[0] || va[1] !== vb[1])) {
    return { what: "mod", older: cmp(va, vb) < 0 ? "a" : "b" };
  }
  if (a.gameBuild && b.gameBuild && a.gameBuild !== b.gameBuild) {
    return { what: "game", older: a.gameBuild < b.gameBuild ? "a" : "b" };
  }
  return null;
}

export function buildDate(build: number | null): string {
  if (!build) return "unknown";
  return new Date(build * 1000).toISOString().slice(0, 10);
}

/**
 * The line shown to one racer (`me`) about a mismatch with `rival` (by name).
 * `meOlder` says whether `me` is the side that has to update.
 */
export function mismatchMessage(m: Mismatch, me: ClientVersions, rival: ClientVersions, rivalName: string, meOlder: boolean): string {
  if (m.what === "mod") {
    return meOlder
      ? `Can't race ${rivalName}: update Hades 2 Competitive Speedrunning (you have ${me.mod}, they have ${rival.mod}).`
      : `Can't race ${rivalName}: they need to update Hades 2 Competitive Speedrunning (they have ${rival.mod}, you have ${me.mod}).`;
  }
  return meOlder
    ? `Can't race ${rivalName}: update Hades II in Steam (your game build ${buildDate(me.gameBuild)} is older than theirs, ${buildDate(rival.gameBuild)}).`
    : `Can't race ${rivalName}: they need to update Hades II in Steam (their game build ${buildDate(rival.gameBuild)} is older than yours, ${buildDate(me.gameBuild)}).`;
}

export function tooOldMessage(v: string | null, min = MIN_MOD_VERSION): string {
  return `Hades 2 Competitive Speedrunning ${v} is too old for the race server: update to ${min} or newer (How to Update on the Race Board, or your mod manager).`;
}
