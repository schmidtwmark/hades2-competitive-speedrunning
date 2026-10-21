import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { compatibility, mismatchMessage, modTooOld, parseVersion } from "../src/versions.js";
import { TestClient, makeServer } from "./helpers.js";

const SEP23 = 1790167264; // 2026-09-23 (the tested build)
const OCT15 = 1792065600; // 2026-10-15

describe("version rules", () => {
  it("parses versions and rejects only known-old mods", () => {
    assert.deepEqual(parseVersion("0.3.1"), [0, 3, 1]);
    assert.equal(parseVersion("mock"), null);
    assert.equal(modTooOld("0.2.0", "0.3.0"), true);
    assert.equal(modTooOld("0.3.0", "0.3.0"), false);
    assert.equal(modTooOld(null, "0.3.0"), false);
    assert.equal(modTooOld("mock", "0.3.0"), false);
  });

  it("same major.minor and the same game build can race; patches and unknowns don't block", () => {
    assert.equal(compatibility({ mod: "0.3.0", gameBuild: SEP23 }, { mod: "0.3.4", gameBuild: SEP23 }), null);
    assert.equal(compatibility({ mod: "0.3.0", gameBuild: null }, { mod: null, gameBuild: SEP23 }), null);
    assert.deepEqual(compatibility({ mod: "0.3.0", gameBuild: SEP23 }, { mod: "0.4.0", gameBuild: SEP23 }), { what: "mod", older: "a" });
    assert.deepEqual(compatibility({ mod: "0.3.0", gameBuild: OCT15 }, { mod: "0.3.0", gameBuild: SEP23 }), { what: "game", older: "b" });
  });

  it("messages say who updates what", () => {
    const me = { mod: "0.3.0", gameBuild: SEP23 };
    const them = { mod: "0.3.0", gameBuild: OCT15 };
    assert.match(mismatchMessage({ what: "game", older: "a" }, me, them, "Zag", true), /update Hades II in Steam \(your game build 2026-09-23 is older than theirs, 2026-10-15\)/);
    assert.match(mismatchMessage({ what: "game", older: "a" }, them, me, "Mel", false), /they need to update Hades II/);
  });
});

describe("version checks on the server", () => {
  const hello = (server: ReturnType<typeof makeServer>["server"], name: string, version?: string, game_build?: number) => {
    const c = new TestClient(server, name);
    c.hello(undefined, { ...(version ? { version } : {}), ...(game_build ? { game_build } : {}) });
    return c;
  };

  it("an outdated mod is told to update and can't create, queue or join", () => {
    const { server } = makeServer();
    const old = hello(server, "Old", "0.2.0", SEP23);
    assert.equal(old.last("error").code, "update_required");
    assert.match(old.last("error").message, /too old.*update to 0\.4\.0/);
    for (const m of [{ type: "create_lobby" }, { type: "find_match" }, { type: "join_lobby", code: "ABCD", create: true }]) {
      old.clear();
      old.send(m);
      assert.equal(old.last("error").code, "update_required");
    }
    assert.equal(server.lobbyCount, 0);
  });

  it("joining a lobby with another game build is refused; both are told who updates", () => {
    const { server } = makeServer();
    const host = hello(server, "Mel", "0.4.0", OCT15);
    const guest = hello(server, "Zag", "0.4.0", SEP23);
    host.send({ type: "create_lobby" });
    guest.send({ type: "join_lobby", code: host.last("lobby_created").code });
    const g = guest.last("error");
    assert.equal(g.code, "version_mismatch");
    assert.equal(g.who, "you");
    assert.equal(g.what, "game");
    assert.equal(g.rival, "Mel");
    assert.match(g.message, /update Hades II in Steam/);
    const h = host.last("error");
    assert.equal(h.who, "rival");
    assert.match(h.message, /Zag.*they need to update Hades II/);
    assert.equal(host.state().players.length, 1);
  });

  it("a different mod minor version is refused; a patch difference races", () => {
    const { server, random } = makeServer();
    const a = hello(server, "A", "0.4.0", SEP23);
    const b = hello(server, "B", "0.5.1", SEP23);
    a.send({ type: "create_lobby" });
    b.send({ type: "join_lobby", code: a.last("lobby_created").code });
    assert.equal(b.last("error").who, "rival");
    assert.equal(a.last("error").who, "you");
    assert.match(a.last("error").message, /update Ranked Race \(you have 0\.4\.0, they have 0\.5\.1\)/);
    const c = hello(server, "C", "0.4.2", SEP23);
    c.send({ type: "join_lobby", code: a.last("lobby_created").code });
    assert.equal(c.last("lobby_joined").opponent, "A");
    void random;
  });

  it("Find Match only groups compatible racers and explains a mismatch to both", () => {
    const { server } = makeServer();
    const a = hello(server, "A", "0.4.0", SEP23);
    const b = hello(server, "B", "0.4.0", OCT15);
    a.send({ type: "find_match" });
    b.send({ type: "find_match" });
    assert.equal(a.last("error").code, "version_mismatch");
    assert.equal(a.last("error").who, "you");
    assert.equal(b.last("error").who, "rival");
    assert.equal(a.state().players.length, 1);
    assert.equal(b.state().players.length, 1, "B opened its own lobby");
    const c = hello(server, "C", "0.4.0", OCT15);
    c.send({ type: "find_match" });
    assert.deepEqual(c.state().players.map((p) => p.name), ["B", "C"]);
    assert.equal(a.state().players.length, 1);
  });
});
