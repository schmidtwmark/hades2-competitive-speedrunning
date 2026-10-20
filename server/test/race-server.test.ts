import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { TestClient, makeServer, pair, racing } from "./helpers.js";

describe("session", () => {
  it("requires hello before anything else", () => {
    const { server } = makeServer();
    const c = new TestClient(server, "X");
    c.send({ type: "create_lobby" });
    assert.equal(c.last("error").code, "no_hello");
  });

  it("rejects malformed and unknown messages", () => {
    const { server } = makeServer();
    const c = new TestClient(server, "X");
    c.hello();
    c.send({ type: "nope" });
    assert.equal(c.last("error").code, "unknown_type");
    c.send({ type: "join_lobby" });
    assert.equal(c.last("error").code, "bad_field");
    c.conn.receive([1, 2]);
    assert.equal(c.last("error").code, "bad_message");
  });

  it("answers ping without hello", () => {
    const { server } = makeServer();
    const c = new TestClient(server, "X");
    c.send({ type: "ping", t: 42 });
    assert.equal(c.last("pong").t, 42);
  });
});

describe("lobbies", () => {
  it("creates a 4-character code and waits for an opponent", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "Alice");
    a.hello();
    a.send({ type: "create_lobby" });
    const { code } = a.last("lobby_created");
    assert.match(code, /^[A-Z2-9]{4}$/);
    assert.equal(a.state().phase, "waiting");
    assert.equal(a.state().players.length, 1);
  });

  it("join notifies both players and opens the weapon vote", () => {
    const { a, b, code } = pair();
    assert.equal(a.last("lobby_joined").opponent, "Bob");
    assert.equal(b.last("lobby_joined").opponent, "Alice");
    assert.equal(b.last("lobby_joined").code, code);
    for (const c of [a, b]) {
      const vp = c.last("vote_phase");
      assert.equal(vp.phase, "weapon");
      assert.equal(vp.timer, 15);
      assert.equal(vp.options.length, 3);
      assert.equal(c.state().phase, "voting_weapon");
    }
  });

  it("joins case-insensitively", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "A");
    const b = new TestClient(server, "B");
    a.hello();
    b.hello();
    a.send({ type: "create_lobby" });
    b.send({ type: "join_lobby", code: a.last("lobby_created").code.toLowerCase() });
    assert.equal(b.last("lobby_joined").opponent, "A");
  });

  it("rejects unknown and full lobbies", () => {
    const { server, a, code } = pair();
    const c = new TestClient(server, "Carol");
    c.hello();
    c.send({ type: "join_lobby", code: "ZZZZ" });
    assert.equal(c.last("error").code, "lobby_not_found");
    c.send({ type: "join_lobby", code });
    assert.equal(c.last("error").code, "lobby_full");
    assert.equal(a.state().players.length, 2);
  });

  it("leaving returns the other player to waiting; last one out closes it", () => {
    const { server, a, b } = pair();
    b.send({ type: "leave_lobby" });
    assert.ok(b.last("lobby_left"));
    assert.equal(a.state().phase, "waiting");
    assert.equal(a.state().players.length, 1);
    a.send({ type: "leave_lobby" });
    assert.equal(server.lobbyCount, 0);
  });

  it("sweep expires idle lobbies but not running races", () => {
    const { server, scheduler, a } = makeServerWithLobby();
    scheduler.advance(31 * 60_000);
    server.sweep();
    assert.equal(server.lobbyCount, 0);
    assert.equal(a.last("error").code, "lobby_expired");

    const r = racing();
    r.scheduler.advance(31 * 60_000);
    r.server.sweep();
    assert.equal(r.server.lobbyCount, 1);
  });
});

function makeServerWithLobby() {
  const env = makeServer();
  const a = new TestClient(env.server, "A");
  a.hello();
  a.send({ type: "create_lobby" });
  return { ...env, a };
}

describe("voting", () => {
  it("same vote wins outright", () => {
    const { a, b } = pair();
    a.send({ type: "vote_weapon", weapon: "WeaponDagger" });
    assert.equal(b.last("vote_cast").by, "opponent");
    assert.equal(a.last("vote_cast").by, "you");
    b.send({ type: "vote_weapon", weapon: "WeaponDagger" });
    const r = a.last("vote_result");
    assert.equal(r.selected, "WeaponDagger");
    assert.deepEqual(r.votes, { you: "WeaponDagger", opponent: "WeaponDagger" });
    assert.equal(a.last("vote_phase").phase, "keepsake");
  });

  it("different votes: coin flip between the two", () => {
    const { a, b, random } = pair();
    random.queue = [1];
    a.send({ type: "vote_weapon", weapon: "WeaponDagger" });
    b.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    assert.equal(a.last("vote_result").selected, "WeaponAxe");
    assert.deepEqual(b.last("vote_result").votes, { you: "WeaponAxe", opponent: "WeaponDagger" });
  });

  it("timer resolves with a random pool pick for the non-voter", () => {
    const { a, b, random, scheduler } = pair();
    a.send({ type: "vote_weapon", weapon: "WeaponStaffSwing" });
    // b's missing vote -> pool[2] (Axe); coin flip -> index 1 (b's slot)
    random.queue = [2, 1];
    scheduler.advance(14_999);
    assert.equal(a.all("vote_result").length, 0);
    scheduler.advance(1);
    assert.equal(a.last("vote_result").selected, "WeaponAxe");
    assert.equal(b.last("vote_result").votes.you, null);
  });

  it("rejects options outside the pool and votes in the wrong phase", () => {
    const { a } = pair();
    a.send({ type: "vote_weapon", weapon: "WeaponBanana" });
    assert.equal(a.last("error").code, "bad_choice");
    a.send({ type: "vote_keepsake", keepsake: "KeepsakeA" });
    assert.equal(a.last("error").code, "not_voting");
  });

  it("allows changing a vote until both have voted", () => {
    const { a, b } = pair();
    a.send({ type: "vote_weapon", weapon: "WeaponDagger" });
    a.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    b.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    assert.equal(a.last("vote_result").selected, "WeaponAxe");
  });

  it("skips a phase whose pool is empty", () => {
    const { a, b } = pair({ pools: { weapon: [{ id: "W", name: "W" }], keepsake: [] } });
    a.send({ type: "vote_weapon", weapon: "W" });
    b.send({ type: "vote_weapon", weapon: "W" });
    assert.equal(a.state().phase, "ready_check");
    assert.equal(a.all("vote_phase").length, 1);
  });
});

describe("race start", () => {
  it("both ready -> identical race_start, then racing after the countdown", () => {
    const { a, b, scheduler, random } = pair();
    a.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    b.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    a.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
    b.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
    assert.equal(a.state().phase, "ready_check");
    a.send({ type: "ready" });
    assert.equal(a.all("race_start").length, 0);
    assert.deepEqual(
      b.state().players.map((p) => p.ready),
      [true, false],
    );
    random.queue = [123456];
    b.send({ type: "ready" });
    const ra = a.last("race_start");
    const rb = b.last("race_start");
    assert.deepEqual(ra, rb);
    assert.equal(ra.seed, 123457);
    assert.equal(ra.weapon, "WeaponAxe");
    assert.equal(ra.keepsake, "KeepsakeB");
    assert.equal(ra.countdown, 3);
    assert.equal(a.state().phase, "countdown");
    scheduler.advance(3000);
    assert.equal(a.state().phase, "racing");
    assert.equal(a.state().race?.seed, 123457);
  });

  it("ready outside ready_check is an error", () => {
    const { a } = pair();
    a.send({ type: "ready" });
    assert.equal(a.last("error").code, "not_ready_check");
  });
});

describe("race", () => {
  const progress = { type: "progress_update", room: "F_Opening01", depth: 2, hp: 30, time: 12.5, alive: true };

  it("relays progress to the opponent only", () => {
    const { a, b } = racing();
    a.clear();
    b.clear();
    a.send(progress);
    assert.equal(a.all("opponent_progress").length, 0);
    const p = b.last("opponent_progress");
    assert.equal(p.room, "F_Opening01");
    assert.equal(p.depth, 2);
  });

  it("relays builds with progress and ghosts only while racing", () => {
    const { a, b } = racing();
    b.clear();
    a.send({ ...progress, build: [{ name: "ZeusWeaponBoon", rarity: "Rare" }] });
    assert.deepEqual(b.last("opponent_progress").build, [{ name: "ZeusWeaponBoon", rarity: "Rare", source: undefined, level: undefined }]);
    a.send({ ...progress, build: {} });
    assert.deepEqual(b.last("opponent_progress").build, []);
    a.send({ type: "ghost", room: "F_Combat01", depth: 2, x: 100.5, y: -20, angle: 90, anim: "run", t: 12.25 });
    const g = b.last("opponent_ghost");
    assert.equal(g.x, 100.5);
    assert.equal(g.room, "F_Combat01");
    assert.equal(a.all("opponent_ghost").length, 0);
    a.send({ type: "ghost", room: "R", depth: 1, x: "nope", y: 0, t: 0 });
    assert.equal(a.last("error").code, "bad_field");
  });

  it("drops ghosts outside a race and after finishing", () => {
    const { a, b } = pair();
    a.send({ type: "ghost", room: "R", depth: 1, x: 0, y: 0, t: 0 });
    assert.equal(b.all("opponent_ghost").length, 0);
    const r = racing();
    r.a.send({ type: "run_complete", victory: false, time: 5 });
    r.b.clear();
    r.a.send({ type: "ghost", room: "R", depth: 1, x: 0, y: 0, t: 0 });
    assert.equal(r.b.all("opponent_ghost").length, 0);
  });

  it("ignores progress before the race starts", () => {
    const { a, b } = pair();
    a.send(progress);
    assert.equal(b.all("opponent_progress").length, 0);
  });

  it("first victory wins", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: true, time: 300 });
    for (const c of [a, b]) {
      const r = c.last("race_result");
      assert.equal(r.reason, "completed_first");
      assert.equal(r.winner_name, "Alice");
      assert.equal(r.draw, false);
      assert.equal(c.state().phase, "finished");
    }
    assert.equal(a.last("race_result").you_won, true);
    assert.equal(b.last("race_result").you_won, false);
    b.send({ type: "run_complete", victory: true, time: 310 });
    assert.equal(b.all("race_result").length, 1);
    assert.equal(b.last("error").code, "not_racing");
  });

  it("death: survivor must finish to win", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: false, time: 100 });
    assert.equal(a.all("race_result").length, 0);
    assert.equal(b.last("opponent_finished").victory, false);
    b.send({ type: "run_complete", victory: true, time: 400 });
    const r = a.last("race_result");
    assert.equal(r.reason, "survivor_finished");
    assert.equal(r.winner_name, "Bob");
    assert.deepEqual(
      r.results.map((x) => [x.name, x.victory, x.time]),
      [
        ["Alice", false, 100],
        ["Bob", true, 400],
      ],
    );
  });

  it("both die -> draw", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: false, time: 100 });
    b.send({ type: "run_complete", victory: false, time: 200 });
    const r = b.last("race_result");
    assert.equal(r.draw, true);
    assert.equal(r.reason, "both_died");
    assert.equal(r.winner, null);
  });

  it("survivor timeout -> draw", () => {
    const { a, b, scheduler } = racing();
    a.send({ type: "run_complete", victory: false, time: 100 });
    scheduler.advance(59_999);
    assert.equal(b.all("race_result").length, 0);
    scheduler.advance(1);
    assert.equal(b.last("race_result").reason, "survivor_timeout");
    assert.equal(b.last("race_result").draw, true);
  });

  it("forfeit hands the win to the opponent", () => {
    const { a, b } = racing();
    b.send({ type: "forfeit" });
    assert.equal(a.last("race_result").reason, "forfeit");
    assert.equal(a.last("race_result").you_won, true);
  });

  it("forfeit after the opponent died is a draw", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: false, time: 50 });
    b.send({ type: "forfeit" });
    assert.equal(a.last("race_result").draw, true);
  });

  it("leaving mid-race forfeits", () => {
    const { a, b } = racing();
    b.send({ type: "leave_lobby" });
    assert.equal(a.last("race_result").reason, "forfeit");
    assert.equal(a.state().phase, "waiting");
  });

  it("rematch after both agree starts a fresh vote", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: true, time: 300 });
    a.clear();
    a.send({ type: "rematch" });
    assert.equal(a.all("vote_phase").length, 0);
    b.send({ type: "rematch" });
    assert.equal(a.last("vote_phase").phase, "weapon");
    assert.equal(a.state().race, null);
  });

  it("race ids increase across rematches", () => {
    const { a, b, scheduler } = racing();
    assert.equal(a.last("race_start").race_id, 1);
    a.send({ type: "run_complete", victory: true, time: 1 });
    a.send({ type: "rematch" });
    b.send({ type: "rematch" });
    for (const c of [a, b]) c.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    for (const c of [a, b]) c.send({ type: "vote_keepsake", keepsake: "KeepsakeA" });
    for (const c of [a, b]) c.send({ type: "ready" });
    scheduler.advance(3000);
    assert.equal(b.last("race_start").race_id, 2);
  });
});

describe("disconnects", () => {
  it("reconnect within grace resumes the race", () => {
    const env = racing();
    const { server, a, b, scheduler } = env;
    const token = a.last("welcome").token;
    a.conn.close();
    assert.equal(b.last("opponent_disconnected").grace, 10);
    assert.equal(b.state().players.find((p) => p.name === "Alice")?.connected, false);
    scheduler.advance(5000);
    const a2 = new TestClient(server, "Alice");
    a2.hello(token);
    assert.equal(a2.last("welcome").resumed, true);
    assert.equal(a2.state().phase, "racing");
    assert.ok(b.last("opponent_reconnected"));
    scheduler.advance(10_000);
    assert.equal(b.all("race_result").length, 0);
    a2.send({ type: "run_complete", victory: true, time: 99 });
    assert.equal(b.last("race_result").winner_name, "Alice");
  });

  it("grace expiry mid-race forfeits", () => {
    const { a, b, scheduler } = racing();
    a.conn.close();
    scheduler.advance(10_000);
    const r = b.last("race_result");
    assert.equal(r.reason, "disconnect");
    assert.equal(r.you_won, true);
    assert.equal(b.state().players.length, 1);
  });

  it("a stale socket closing after a resume does not drop the session", () => {
    const { server, a, b } = racing();
    const token = a.last("welcome").token;
    // New socket resumes while the old one is still open (TCP hasn't noticed the drop).
    const a2 = new TestClient(server, "Alice");
    a2.hello(token);
    a.conn.close();
    assert.equal(b.all("opponent_disconnected").length, 0);
    assert.equal(b.state().players.every((p) => p.connected), true);
    a2.send({ type: "progress_update", room: "R", depth: 3, hp: 1, time: 1, alive: true });
    assert.equal(b.last("opponent_progress").room, "R");
  });

  it("disconnect before joining a lobby just forgets the session", () => {
    const { server } = makeServer();
    const c = new TestClient(server, "X");
    const token = c.hello();
    c.conn.close();
    const c2 = new TestClient(server, "X");
    c2.hello(token);
    assert.equal(c2.last("welcome").resumed, false);
  });

  it("resume during a vote re-sends the vote phase", () => {
    const { server, a } = pair();
    const token = a.last("welcome").token;
    a.conn.close();
    const a2 = new TestClient(server, "Alice");
    a2.hello(token);
    assert.equal(a2.last("vote_phase").phase, "weapon");
  });
});

describe("find match", () => {
  it("first player waits, second is paired into a fresh lobby and voting starts", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "A");
    const b = new TestClient(server, "B");
    a.hello();
    b.hello();
    a.send({ type: "find_match" });
    assert.equal(a.last("queued").waiting, 1);
    b.send({ type: "find_match" });
    assert.equal(a.last("lobby_joined").opponent, "B");
    assert.equal(b.last("lobby_joined").opponent, "A");
    assert.equal(a.last("vote_phase").phase, "weapon");
    assert.equal(a.state().code, b.state().code);
    assert.equal(server.lobbyCount, 1);
  });

  it("cancel and disconnect leave the queue", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "A");
    const b = new TestClient(server, "B");
    const c = new TestClient(server, "C");
    for (const x of [a, b, c]) x.hello();
    a.send({ type: "find_match" });
    a.send({ type: "cancel_match" });
    assert.ok(a.last("match_cancelled"));
    b.send({ type: "find_match" });
    b.conn.close();
    c.send({ type: "find_match" });
    assert.equal(c.last("queued").waiting, 1);
    assert.equal(c.all("lobby_joined").length, 0);
  });

  it("refuses while already in a lobby; creating a lobby leaves the queue", () => {
    const { server, random, a } = pair();
    a.send({ type: "find_match" });
    assert.equal(a.last("error").code, "already_in_lobby");
    const x = new TestClient(server, "X");
    const y = new TestClient(server, "Y");
    x.hello();
    y.hello();
    x.send({ type: "find_match" });
    random.queue.push(1, 1, 1, 1); // a second code, not AAAA again
    x.send({ type: "create_lobby" });
    y.send({ type: "find_match" });
    assert.equal(y.last("queued").waiting, 1);
  });
});

describe("join by code (create if missing)", () => {
  it("the first racer to enter an agreed code opens it, the second joins it", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "A");
    const b = new TestClient(server, "B");
    a.hello();
    b.hello();
    a.send({ type: "join_lobby", code: "wxyz", create: true });
    assert.equal(a.last("lobby_created").code, "WXYZ");
    b.send({ type: "join_lobby", code: "WXYZ", create: true });
    assert.equal(b.last("lobby_joined").opponent, "A");
    assert.equal(a.last("vote_phase").phase, "weapon");
  });

  it("rejects codes outside the alphabet; plain joins still need an existing lobby", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "A");
    a.hello();
    a.send({ type: "join_lobby", code: "AB0O", create: true });
    assert.equal(a.last("error").code, "bad_code");
    a.send({ type: "join_lobby", code: "ABCD" });
    assert.equal(a.last("error").code, "lobby_not_found");
    assert.equal(server.lobbyCount, 0);
  });

  it("a full lobby under the code is reported, not replaced", () => {
    const { server, code } = pair();
    const c = new TestClient(server, "C");
    c.hello();
    c.send({ type: "join_lobby", code, create: true });
    assert.equal(c.last("error").code, "lobby_full");
  });
});
