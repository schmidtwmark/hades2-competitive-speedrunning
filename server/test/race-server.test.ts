import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { QUICK_LINES } from "../src/chat.js";
import { RaceLogStore } from "../src/race-log-store.js";
import { TEST_KEEPSAKES, TEST_WEAPONS, TestClient, group, makeServer, pair, racing, racingGroup } from "./helpers.js";

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

  it("join notifies both players; voting opens once both are ready", () => {
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

  it("rejects unknown lobbies, lobbies already racing, and full ones", () => {
    const { server, a, code } = pair();
    const c = new TestClient(server, "Carol");
    c.hello();
    c.send({ type: "join_lobby", code: "ZZZZ" });
    assert.equal(c.last("error").code, "lobby_not_found");
    c.send({ type: "join_lobby", code });
    assert.equal(c.last("error").code, "lobby_busy");
    assert.equal(a.state().players.length, 2);
    const full = makeServer({ maxPlayers: 2 });
    const x = new TestClient(full.server, "X");
    const y = new TestClient(full.server, "Y");
    const z = new TestClient(full.server, "Z");
    for (const t of [x, y, z]) t.hello();
    x.send({ type: "create_lobby" });
    y.send({ type: "join_lobby", code: x.last("lobby_created").code });
    z.send({ type: "join_lobby", code: x.last("lobby_created").code });
    assert.equal(z.last("error").code, "lobby_full");
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

  it("the timer resolves with the votes cast; nobody voting picks from the pool", () => {
    const { a, b, random, scheduler } = pair();
    a.send({ type: "vote_weapon", weapon: "WeaponStaffSwing" });
    scheduler.advance(14_999);
    assert.equal(a.all("vote_result").length, 0);
    scheduler.advance(1);
    assert.equal(a.last("vote_result").selected, "WeaponStaffSwing");
    assert.equal(b.last("vote_result").votes.you, null);
    random.queue = [1];
    scheduler.advance(15_000); // keepsake: no votes at all
    assert.equal(a.last("vote_result").selected, "KeepsakeB");
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

  it("first clear decides at once; the other keeps racing and their finish ends the race", () => {
    const { a, b, scheduler } = racing();
    scheduler.advance(300_000);
    a.send({ type: "run_complete", victory: true, time: 299.9 });
    for (const c of [a, b]) {
      const d = c.last("race_decided");
      assert.equal(d.reason, "completed_first");
      assert.equal(d.winner_name, "Alice");
      assert.equal(c.all("race_result").length, 0);
      assert.equal(c.state().phase, "racing");
    }
    assert.equal(a.last("race_decided").you_won, true);
    assert.equal(b.last("race_decided").you_won, false);
    assert.equal(b.last("opponent_finished").outcome, "cleared");
    // Bob keeps going and posts his own time.
    b.send({ type: "progress_update", room: "R", depth: 9, hp: 1, time: 1, alive: true });
    assert.equal(a.last("opponent_progress").depth, 9);
    scheduler.advance(30_000);
    b.send({ type: "run_complete", victory: true, time: 330 });
    const r = a.last("race_result");
    assert.equal(r.reason, "completed_first");
    assert.equal(r.winner_name, "Alice");
    assert.deepEqual(r.results.map((x) => [x.name, x.outcome, x.time]), [["Alice", "cleared", 300], ["Bob", "cleared", 330]]);
    assert.equal(b.last("race_result").you_won, false);
    assert.equal(a.state().phase, "finished");
    assert.equal(b.all("race_decided").length, 1);
  });

  it("the official time is the server clock, not the client's number", () => {
    const { a, b, scheduler } = racing();
    scheduler.advance(61_234);
    b.send({ type: "run_complete", victory: false, time: 5 });
    scheduler.advance(10_000);
    a.send({ type: "run_complete", victory: true, time: 9999 });
    assert.deepEqual(a.last("race_result").results.map((x) => x.time), [71.234, 61.234]);
  });

  it("opponent dies: the survivor must still clear to win, with no time pressure", () => {
    const { a, b, scheduler } = racing();
    a.send({ type: "run_complete", victory: false, time: 100 });
    assert.equal(b.last("opponent_finished").outcome, "died");
    assert.equal(b.all("race_decided").length, 0);
    scheduler.advance(60 * 60 * 1000 - 1);
    assert.equal(b.all("race_result").length, 0);
    b.send({ type: "run_complete", victory: true, time: 400 });
    const r = a.last("race_result");
    assert.equal(r.reason, "survivor_finished");
    assert.equal(r.winner_name, "Bob");
    assert.deepEqual(r.results.map((x) => [x.name, x.victory, x.outcome]), [["Bob", true, "cleared"], ["Alice", false, "died"]]);
  });

  it("both die -> draw", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: false, time: 100 });
    b.send({ type: "run_complete", victory: false, time: 200 });
    const r = b.last("race_result");
    assert.equal(r.draw, true);
    assert.equal(r.reason, "no_finishers");
    assert.equal(r.winner, null);
  });

  it("forfeit is a DNF like dying: the rival still has to finish", () => {
    const { a, b } = racing();
    b.send({ type: "forfeit", stats: { DamageDealt: 1200 } });
    assert.equal(a.last("opponent_finished").outcome, "forfeit");
    assert.equal(a.all("race_result").length, 0);
    a.send({ type: "run_complete", victory: true, time: 500 });
    const r = a.last("race_result");
    assert.equal(r.reason, "survivor_finished");
    assert.equal(r.you_won, true);
    assert.equal(r.results[1]?.outcome, "forfeit");
    assert.equal(r.results[1]?.stats.DamageDealt, 1200);
  });

  it("forfeit after the rival cleared ends the race; after the rival died it is a draw", () => {
    const one = racing();
    one.a.send({ type: "run_complete", victory: true, time: 10 });
    one.b.send({ type: "forfeit" });
    assert.equal(one.b.last("race_result").winner_name, "Alice");
    assert.equal(one.b.last("race_result").reason, "completed_first");
    const two = racing();
    two.a.send({ type: "run_complete", victory: false, time: 50 });
    two.b.send({ type: "forfeit" });
    assert.equal(two.a.last("race_result").draw, true);
    assert.equal(two.a.last("race_result").reason, "no_finishers");
  });

  it("time limit: anyone still running is a DNF", () => {
    const { a, b, scheduler } = racing();
    a.send({ type: "run_complete", victory: true, time: 10 });
    scheduler.advance(3_600_000);
    const r = b.last("race_result");
    assert.equal(r.winner_name, "Alice");
    assert.equal(r.results[1]?.outcome, "timeout");
    const other = racing();
    other.scheduler.advance(3_600_000);
    assert.equal(other.a.last("race_result").reason, "time_limit");
    assert.equal(other.a.last("race_result").draw, true);
  });

  it("results carry each racer's last build, depth and stats", () => {
    const { a, b } = racing();
    a.send({ ...progress, depth: 7, build: [{ name: "ZeusWeaponBoon", rarity: "Epic" }], stats: { Kills: 40 } });
    a.send({ ...progress, depth: 8 });
    b.send({ type: "run_complete", victory: false, time: 1, build: [{ name: "AresWeaponBoon" }], stats: { Kills: 3 } });
    a.send({ type: "run_complete", victory: true, time: 2, stats: { Kills: 55, DamageTaken: 120 } });
    const [ra, rb] = b.last("race_result").results;
    assert.equal(ra?.depth, 8);
    assert.equal(ra?.build[0]?.name, "ZeusWeaponBoon");
    assert.deepEqual(ra?.stats, { Kills: 55, DamageTaken: 120 });
    assert.equal(rb?.build[0]?.name, "AresWeaponBoon");
    a.send({ ...progress, stats: { Kills: "many" } });
    assert.equal(a.last("error").code, "bad_field");
  });

  it("leaving mid-race is a DNF; the one who stays races on to the result", () => {
    const { a, b } = racing();
    b.send({ type: "leave_lobby" });
    assert.equal(a.last("opponent_finished").outcome, "forfeit");
    assert.equal(a.state().phase, "racing");
    a.send({ type: "run_complete", victory: true, time: 9 });
    const r = a.last("race_result");
    assert.equal(r.reason, "survivor_finished");
    assert.deepEqual(r.results.map((x) => x.name), ["Alice", "Bob"]);
    assert.equal(a.state().phase, "finished");
  });

  it("rematch after both agree starts a fresh vote", () => {
    const { a, b } = racing();
    a.send({ type: "run_complete", victory: true, time: 300 });
    b.send({ type: "forfeit" });
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
    b.send({ type: "run_complete", victory: false, time: 2 });
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
    assert.equal(b.last("race_decided").winner_name, "Alice");
  });

  it("grace expiry mid-race is a DNF; the rival still has to finish", () => {
    const { a, b, scheduler } = racing();
    a.conn.close();
    scheduler.advance(10_000);
    assert.equal(b.last("opponent_finished").outcome, "disconnect");
    assert.equal(b.state().players.length, 1);
    b.send({ type: "run_complete", victory: true, time: 99 });
    const r = b.last("race_result");
    assert.equal(r.reason, "survivor_finished");
    assert.equal(r.you_won, true);
  });

  it("a racer who reconnects after the race was decided is told again", () => {
    const { server, a, b } = racing();
    const token = b.last("welcome").token;
    a.send({ type: "run_complete", victory: true, time: 5 });
    b.conn.close();
    const b2 = new TestClient(server, "Bob");
    b2.hello(token);
    assert.equal(b2.last("race_decided").winner_name, "Alice");
    assert.equal(b2.last("opponent_finished").outcome, "cleared");
    assert.equal(b2.state().phase, "racing");
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
  it("pairs two racers; voting starts once both are ready, and ready can be taken back", () => {
    const { server } = makeServer();
    const a = new TestClient(server, "A");
    const b = new TestClient(server, "B");
    a.hello();
    b.hello();
    a.send({ type: "find_match" });
    assert.equal(a.state().public, true);
    assert.equal(a.state().max_players, 2);
    b.send({ type: "find_match" });
    assert.equal(a.state().players.length, 2);
    a.send({ type: "ready" });
    assert.equal(b.state().players[0]!.ready, true);
    a.send({ type: "ready", ready: false });
    assert.equal(b.state().players[0]!.ready, false);
    b.send({ type: "ready" });
    assert.equal(a.all("vote_phase").length, 0, "A took it back");
    a.send({ type: "ready" });
    assert.equal(a.last("vote_phase").phase, "weapon");
    assert.equal(b.state().phase, "voting_weapon");
    assert.equal(server.lobbyCount, 1);
  });

  it("races two: a third racer opens the next lobby", () => {
    const { server } = makeServer();
    const cs = ["A", "B", "C"].map((n) => {
      const c = new TestClient(server, n);
      c.hello();
      c.send({ type: "find_match" });
      return c;
    });
    assert.equal(cs[0]!.state().players.length, 2);
    assert.equal(cs[2]!.state().players.length, 1, "a new lobby for the next racer");
    assert.equal(server.lobbyCount, 2);
  });

  it("cancel leaves the lobby; the one left searches on, still ready", () => {
    const { server } = makeServer();
    const [a, b, c] = ["A", "B", "C"].map((n) => {
      const t = new TestClient(server, n);
      t.hello();
      return t;
    }) as [TestClient, TestClient, TestClient];
    a.send({ type: "find_match" });
    b.send({ type: "find_match" });
    a.send({ type: "ready" });
    b.send({ type: "cancel_match" });
    assert.ok(b.last("match_cancelled"));
    assert.equal(a.state().players.length, 1);
    assert.equal(a.state().phase, "waiting");
    assert.equal(a.state().players[0]!.ready, true);
    c.send({ type: "find_match" });
    assert.equal(c.state().code, a.state().code);
    c.send({ type: "ready" });
    assert.equal(a.last("vote_phase").phase, "weapon");
  });

  it("refuses while already in a lobby", () => {
    const { a } = pair();
    a.send({ type: "find_match" });
    assert.equal(a.last("error").code, "already_in_lobby");
  });
});

describe("races with more than two", () => {
  it("up to five racers; voting starts once all of them are ready, and never alone", () => {
    const { server } = makeServer();
    const cs = ["Alice", "Bob", "Cara", "Dion", "Eris", "Fae"].map((n) => {
      const c = new TestClient(server, n);
      c.hello();
      return c;
    });
    cs[0]!.send({ type: "create_lobby" });
    cs[0]!.send({ type: "ready" });
    assert.equal(cs[0]!.state().phase, "waiting", "ready alone: still waiting for a rival");
    const code = cs[0]!.last("lobby_created").code;
    for (const c of cs.slice(1)) c.send({ type: "join_lobby", code });
    assert.equal(cs[5]!.last("error").code, "lobby_full");
    const st = cs[1]!.state();
    assert.equal(st.players.length, 5);
    assert.equal(st.players[0]!.host, true);
    assert.equal(st.max_players, 5);
    for (const c of cs.slice(1, 4)) c.send({ type: "ready" });
    assert.equal(cs[0]!.all("vote_phase").length, 0, "Eris isn't ready");
    cs[4]!.send({ type: "ready" });
    for (const c of cs.slice(0, 5)) assert.equal(c.last("vote_phase").phase, "weapon");
  });

  it("someone leaving before the vote can be the last one awaited", () => {
    const { server } = makeServer();
    const cs = ["Alice", "Bob", "Cara"].map((n) => {
      const c = new TestClient(server, n);
      c.hello();
      return c;
    });
    cs[0]!.send({ type: "create_lobby" });
    for (const c of cs.slice(1)) c.send({ type: "join_lobby", code: cs[0]!.last("lobby_created").code });
    cs[0]!.send({ type: "ready" });
    cs[1]!.send({ type: "ready" });
    cs[2]!.send({ type: "leave_lobby" });
    assert.equal(cs[0]!.last("vote_phase").phase, "weapon");
  });

  it("most votes wins; a tie picks among the tied", () => {
    const { cs, random } = group(4);
    cs[0]!.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    cs[1]!.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    cs[2]!.send({ type: "vote_weapon", weapon: "WeaponDagger" });
    assert.equal(cs[3]!.last("vote_cast").voted, 3);
    assert.equal(cs[3]!.last("vote_cast").of, 4);
    cs[3]!.send({ type: "vote_weapon", weapon: "WeaponStaffSwing" });
    const r = cs[0]!.last("vote_result");
    assert.equal(r.selected, "WeaponAxe");
    assert.deepEqual(r.counts, { WeaponAxe: 2, WeaponDagger: 1, WeaponStaffSwing: 1 });
    assert.equal(r.votes.opponent, null, "no single opponent with three rivals");
    random.queue = [1];
    for (const [i, k] of [[0, "KeepsakeA"], [1, "KeepsakeB"], [2, "KeepsakeA"], [3, "KeepsakeB"]] as const) {
      cs[i]!.send({ type: "vote_keepsake", keepsake: k });
    }
    assert.equal(cs[0]!.last("vote_result").selected, "KeepsakeB");
  });

  it("relays progress and ghosts to every other racer, saying whose they are", () => {
    const { cs } = racingGroup(3);
    cs[1]!.send({ type: "progress_update", room: "R", depth: 4, hp: 9, time: 1, alive: true });
    for (const i of [0, 2]) {
      const p = cs[i]!.last("opponent_progress");
      assert.equal(p.name, "Bob");
      assert.equal(p.depth, 4);
    }
    assert.equal(cs[1]!.all("opponent_progress").length, 0);
    cs[2]!.send({ type: "ghost", room: "R", depth: 4, x: 1, y: 2, t: 1 });
    assert.equal(cs[0]!.last("opponent_ghost").id, cs[2]!.last("welcome").id);
  });

  it("first clear wins; the rest race on for places: clears by time, then DNFs by depth", () => {
    const { cs, scheduler } = racingGroup(4);
    const [a, b, c, d] = cs as [TestClient, TestClient, TestClient, TestClient];
    c.send({ type: "progress_update", room: "R", depth: 9, hp: 0, time: 1, alive: true });
    d.send({ type: "progress_update", room: "R", depth: 5, hp: 0, time: 1, alive: true });
    scheduler.advance(10_000);
    c.send({ type: "run_complete", victory: false, time: 10 });
    assert.equal(a.last("opponent_finished").name, "Cara");
    assert.equal(a.all("race_decided").length, 0);
    scheduler.advance(10_000);
    b.send({ type: "run_complete", victory: true, time: 20 });
    for (const x of cs) assert.equal(x.last("race_decided").winner_name, "Bob");
    assert.equal(b.last("race_decided").reason, "completed_first", "others were still running");
    scheduler.advance(10_000);
    a.send({ type: "run_complete", victory: true, time: 30 });
    assert.equal(a.all("race_result").length, 0, "Dion is still running");
    scheduler.advance(10_000);
    d.send({ type: "forfeit" });
    const r = a.last("race_result");
    assert.equal(r.winner_name, "Bob");
    assert.deepEqual(r.results.map((x) => [x.place, x.name, x.outcome]), [
      [1, "Bob", "cleared"],
      [2, "Alice", "cleared"],
      [3, "Cara", "died"],
      [4, "Dion", "forfeit"],
    ]);
  });

  it("the last one standing who clears wins as the survivor; nobody clearing is a draw", () => {
    const one = racingGroup(3);
    one.cs[0]!.send({ type: "run_complete", victory: false, time: 1 });
    one.cs[1]!.send({ type: "forfeit" });
    one.cs[2]!.send({ type: "run_complete", victory: true, time: 9 });
    assert.equal(one.cs[0]!.last("race_result").reason, "survivor_finished");
    const two = racingGroup(3);
    for (const c of two.cs) c.send({ type: "run_complete", victory: false, time: 1 });
    assert.equal(two.cs[0]!.last("race_result").draw, true);
    assert.equal(two.cs[0]!.last("race_result").reason, "no_finishers");
  });

  it("someone leaving during the votes doesn't stop the others", () => {
    const { cs } = group(3);
    cs[0]!.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    cs[1]!.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    cs[2]!.send({ type: "leave_lobby" });
    assert.equal(cs[0]!.last("vote_result").selected, "WeaponAxe", "the leaver was the last vote awaited");
    assert.equal(cs[0]!.state().phase, "voting_keepsake");
    assert.equal(cs[0]!.state().players.length, 2);
  });

  it("a rematch starts once everyone still here asked", () => {
    const { cs } = racingGroup(3);
    for (const c of cs) c.send({ type: "run_complete", victory: false, time: 1 });
    const before = cs[0]!.all("vote_phase").length;
    cs[0]!.send({ type: "rematch" });
    assert.equal(cs[1]!.state().players[0]!.rematch, true);
    cs[1]!.send({ type: "rematch" });
    assert.equal(cs[0]!.all("vote_phase").length, before, "Dion hasn't asked yet");
    cs[2]!.send({ type: "leave_lobby" });
    assert.equal(cs[0]!.all("vote_phase").length, before + 1, "the one who hadn't asked left");
    assert.equal(cs[0]!.last("vote_phase").phase, "weapon");
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
    a.send({ type: "ready" });
    b.send({ type: "ready" });
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

  it("a lobby already racing under the code is reported, not replaced", () => {
    const { server, code } = pair();
    const c = new TestClient(server, "C");
    c.hello();
    c.send({ type: "join_lobby", code, create: true });
    assert.equal(c.last("error").code, "lobby_busy");
  });
});

describe("route vote and prep time", () => {
  const ROUTES = [
    { id: "underworld", name: "Underworld" },
    { id: "surface", name: "Surface" },
  ];
  const withRoutes = { pools: { route: ROUTES, weapon: TEST_WEAPONS, keepsake: TEST_KEEPSAKES }, prepMs: 120_000 };

  it("votes route, then weapon, then keepsake; the race carries the route", () => {
    const { cs } = group(3, withRoutes);
    const [a, b, c] = cs as [TestClient, TestClient, TestClient];
    assert.equal(a.state().phase, "voting_route");
    assert.deepEqual(a.last("vote_phase").options.map((o) => o.id), ["underworld", "surface"]);
    a.send({ type: "vote_route", route: "surface" });
    b.send({ type: "vote_route", route: "surface" });
    c.send({ type: "vote_route", route: "underworld" });
    assert.equal(a.last("vote_result").selected, "surface");
    assert.equal(a.state().phase, "voting_weapon");
    for (const x of cs) x.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    for (const x of cs) x.send({ type: "vote_keepsake", keepsake: "KeepsakeA" });
    assert.equal(a.state().phase, "ready_check");
    assert.equal(a.state().prep_ends_in, 120);
    for (const x of cs) x.send({ type: "ready" });
    assert.equal(a.last("race_start").route, "surface");
    assert.equal(a.state().race?.route, "surface");
    assert.equal(a.state().prep_ends_in, null);
  });

  it("starts by itself when the prep time runs out, ready or not", () => {
    const { cs, scheduler } = group(2, withRoutes);
    const [a, b] = cs as [TestClient, TestClient];
    for (const x of cs) x.send({ type: "vote_route", route: "underworld" });
    for (const x of cs) x.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    for (const x of cs) x.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
    a.send({ type: "ready" });
    scheduler.advance(60_000);
    assert.equal(b.state().phase, "ready_check", "one racer ready is not enough");
    scheduler.advance(60_000);
    assert.equal(b.state().phase, "countdown");
    assert.equal(b.last("race_start").route, "underworld");
    scheduler.advance(3000);
    assert.equal(b.state().phase, "racing");
  });

  it("an unknown route is refused; without a route pool the vote is skipped", () => {
    const { cs } = group(2, withRoutes);
    cs[0]!.send({ type: "vote_route", route: "olympus" });
    assert.equal(cs[0]!.last("error").code, "bad_choice");
    const plain = group(2);
    assert.equal(plain.cs[0]!.state().phase, "voting_weapon");
  });
});

describe("no-preference votes", () => {
  it("an \"any\" vote counts as voted but not toward an option, so the others' pick wins at once", () => {
    const { a, b } = pair();
    assert.equal(a.state().phase, "voting_weapon");
    const weapon = a.last("vote_phase").options[2]!.id;
    b.send({ type: "vote_weapon", weapon: "any" });
    assert.equal(b.all("error").length, 0, "accepted");
    a.send({ type: "vote_weapon", weapon });
    const r = a.last("vote_result");
    assert.equal(r.selected, weapon, "resolved without waiting for the timer");
    assert.deepEqual(r.counts, { [weapon]: 1 });
    assert.equal(r.votes.opponent, null, "shown as no vote");
  });
});

describe("presence", () => {
  it("tells racers how many are online, searching and racing, once a second at most", () => {
    const { server, scheduler } = makeServer();
    const a = new TestClient(server, "Ann");
    a.hello();
    assert.deepEqual(a.last("presence"), { type: "presence", online: 1, searching: 0, racing: 0 }, "on hello");
    const b = new TestClient(server, "Bob");
    b.hello();
    a.send({ type: "find_match" });
    scheduler.advance(1000);
    assert.deepEqual(b.last("presence"), { type: "presence", online: 2, searching: 1, racing: 0 });
    const sent = b.all("presence").length;
    scheduler.advance(5000);
    assert.equal(b.all("presence").length, sent, "nothing new: nothing sent");
    b.send({ type: "find_match" }); // pairs with Ann; voting waits for both to ready
    scheduler.advance(1000);
    assert.equal(a.last("presence").searching, 2);
    b.conn.close();
    scheduler.advance(1000);
    assert.equal(a.last("presence").online, 1, "a closed connection is offline");
  });
});

describe("chat", () => {
  it("goes to everyone in the lobby with the sender's name, at most one line a second", () => {
    const { cs, scheduler } = group(3);
    const [a, b, c] = cs as [TestClient, TestClient, TestClient];
    b.send({ type: "chat", text: "  Good   luck!\n " });
    for (const x of cs) assert.deepEqual(x.last("chat"), { type: "chat", text: "Good luck!", id: b.last("chat").id, name: "Bob" });
    b.send({ type: "chat", text: "Nice!" });
    assert.equal(c.all("chat").length, 1, "too soon: dropped");
    scheduler.advance(1000);
    b.send({ type: "chat", text: "GG" });
    assert.equal(a.last("chat").text, "GG");
  });

  it("relays only the quick lines: no free text", () => {
    const { cs, scheduler } = group(2);
    const [a, b] = cs as [TestClient, TestClient];
    a.send({ type: "chat", text: "you are bad" });
    assert.equal(a.last("error").code, "chat_not_allowed");
    assert.equal(b.all("chat").length, 0, "nothing relayed");
    scheduler.advance(1000);
    a.send({ type: "chat", text: "gg" });
    assert.equal(b.all("chat").length, 0, "exact lines only");
  });

  it("keeps the server's quick lines equal to the Race Board's", () => {
    const lua = readFileSync(new URL("../../../mod/src/board.lua", import.meta.url), "utf8");
    const block = lua.match(/Board\.QUICK_LINES = \{([^}]*)\}/);
    assert.ok(block, "Board.QUICK_LINES in board.lua");
    const lines = [...block![1]!.matchAll(/'([^']*)'|"([^"]*)"/g)].map((m) => m[1] ?? m[2]);
    assert.deepEqual(lines, [...QUICK_LINES]);
  });

  it("refuses empty or long lines and racers outside a lobby", () => {
    const { cs } = group(2);
    cs[0]!.send({ type: "chat", text: "   " });
    assert.equal(cs[0]!.last("error").code, "bad_field");
    cs[0]!.send({ type: "chat", text: "x".repeat(81) });
    assert.equal(cs[0]!.last("error").code, "bad_field");
    const { server } = makeServer();
    const lone = new TestClient(server, "Lone");
    lone.hello();
    lone.send({ type: "chat", text: "hi" });
    assert.equal(lone.last("error").code, "not_in_lobby");
  });
});

describe("house bots", () => {
  const ROOM = 75_000;

  /** Ann in a private lobby with a house bot, both ready, through the votes and the countdown. */
  function raceTheBot() {
    const env = makeServer();
    const a = new TestClient(env.server, "Ann");
    a.hello();
    a.send({ type: "create_lobby" });
    a.send({ type: "add_bot" });
    const bot = a.state().players.find((p) => p.bot)!;
    assert.equal(bot.name, "Bot");
    env.scheduler.advance(1000);
    assert.equal(a.state().players.find((p) => p.bot)!.ready, true, "the bot readies itself");
    a.send({ type: "ready" });
    assert.equal(a.last("vote_phase").phase, "weapon");
    a.send({ type: "vote_weapon", weapon: "WeaponDagger" });
    env.scheduler.advance(1000);
    a.send({ type: "vote_keepsake", keepsake: "KeepsakeB" });
    env.scheduler.advance(1000);
    a.send({ type: "ready" });
    env.scheduler.advance(1000);
    return { ...env, a, bot };
  }

  it("a bot follows your votes, readies, and reports a room every so often", () => {
    const { a, scheduler } = raceTheBot();
    const start = a.last("race_start");
    assert.equal(start.weapon, "WeaponDagger", "the bot voted \"any\"");
    assert.equal(start.keepsake, "KeepsakeB");
    scheduler.advance(3000 + ROOM);
    const p = a.last("opponent_progress");
    assert.equal(p.name, "Bot");
    assert.equal(p.depth, 1);
    assert.equal(p.room, "F_Bot1", "an Erebus room on the rival plate");
  });

  it("you clear: the bot gives up and the race ends; you fall: the bot clears", () => {
    const won = raceTheBot();
    won.scheduler.advance(3000 + ROOM);
    won.a.send({ type: "run_complete", victory: true, time: 80 });
    won.scheduler.advance(1000);
    assert.equal(won.a.last("race_result").you_won, true);
    assert.equal(won.a.last("race_result").results.find((r) => r.name === "Bot")!.outcome, "forfeit");

    const lost = raceTheBot();
    lost.scheduler.advance(3000);
    lost.a.send({ type: "run_complete", victory: false, time: 20 });
    lost.scheduler.advance(3000);
    assert.equal(lost.a.last("race_result").winner_name, "Bot");
  });

  it("asks for a rematch when you do", () => {
    const { a, scheduler } = raceTheBot();
    scheduler.advance(3000);
    a.send({ type: "run_complete", victory: true, time: 80 });
    scheduler.advance(1000);
    a.send({ type: "rematch" });
    scheduler.advance(1000);
    assert.equal(a.state().phase, "voting_weapon");
  });

  it("joins private lobbies only, before the vote; numbered; not counted as online; gone with the last person", () => {
    const { server, scheduler } = makeServer();
    const a = new TestClient(server, "Ann");
    const q = new TestClient(server, "Quinn");
    a.hello();
    q.hello();
    q.send({ type: "find_match" });
    q.send({ type: "add_bot" });
    assert.equal(q.last("error").code, "not_private");
    a.send({ type: "create_lobby" });
    a.send({ type: "add_bot" });
    a.send({ type: "add_bot" });
    assert.deepEqual(a.state().players.map((p) => p.name), ["Ann", "Bot", "Bot 2"]);
    scheduler.advance(1000);
    assert.equal(a.last("presence").online, 2, "Ann and Quinn");
    a.send({ type: "leave_lobby" });
    assert.equal(server.lobbyCount, 1, "only Quinn's search is left");
    scheduler.advance(10_000);
  });
});

describe("race logs", () => {
  /** An in-memory file system: path -> contents. */
  function memFs() {
    const files = new Map<string, string>();
    return {
      files,
      fs: {
        mkdir: () => {},
        append: (p: string, t: string) => void files.set(p, (files.get(p) ?? "") + t),
        write: (p: string, t: string) => void files.set(p, t),
      },
      lines: (suffix: string) => {
        const k = [...files.keys()].find((x) => x.endsWith(suffix))!;
        return files.get(k)!.trim().split("\n").map((l) => JSON.parse(l));
      },
    };
  }

  it("keep each race's setup, every racer's choice log and the results", () => {
    const mem = memFs();
    const store = new RaceLogStore("/data/races", () => {}, mem.fs);
    const { a, b, scheduler } = racing({ raceLogs: store });
    const id = a.last("race_start").race_id;
    a.send({ type: "race_log", race_id: id, entry: { ev: "room", depth: 1, name: "F_Opening01", encounter: "OpeningGeneratedF" } });
    b.send({ type: "race_log", race_id: id, entry: { ev: "room", depth: 1, name: "F_Opening01", encounter: "OpeningGeneratedF" } });
    a.send({ type: "race_log", race_id: id, entry: { ev: "start", depth: 0, name: "fake" } });
    a.send({ type: "race_log", race_id: id + 1, entry: { ev: "room", depth: 9, name: "wrong race" } });
    a.send({ type: "race_log", race_id: id, entry: { ev: "boon", depth: 1, blob: "x".repeat(9000) } });
    assert.equal(a.last("error").code, "bad_field", "oversized lines are refused");
    const folder = [...mem.files.keys()].find((k) => k.endsWith("race.json"))!;
    assert.match(folder, /^\/data\/races\/\d{8}-\d{6}-[A-Z2-9]{4}-race1\/race\.json$/);
    const alice = mem.lines("1-Alice.jsonl");
    assert.deepEqual(alice.map((e) => e.ev), ["start", "room"], "our start line, then hers (not her own start, not the wrong race)");
    assert.equal(alice[0].seed, a.last("race_start").seed);
    assert.equal(alice[0].name, "Alice");
    assert.equal(mem.lines("2-Bob.jsonl").length, 2);
    a.send({ type: "run_complete", victory: true, time: 100 });
    b.send({ type: "run_complete", victory: false, time: 50 });
    const summary = JSON.parse(mem.files.get(folder)!);
    assert.deepEqual(summary.entrants.map((e: { name: string }) => e.name), ["Alice", "Bob"]);
    assert.equal(summary.results[0].name, "Alice");
    assert.equal(summary.results[0].build, undefined, "no builds in the summary");
    a.send({ type: "race_log", race_id: id, entry: { ev: "end", depth: 1, reason: "completed_first" } });
    assert.equal(mem.lines("1-Alice.jsonl").at(-1).ev, "end", "a line after the result still lands");
    void scheduler;
  });

  it("give house bots no log; without a directory nothing is written", () => {
    const mem = memFs();
    const env = makeServer({ raceLogs: new RaceLogStore("/data/races", () => {}, mem.fs) });
    const a = new TestClient(env.server, "Ann");
    a.hello();
    a.send({ type: "create_lobby" });
    a.send({ type: "add_bot" });
    env.scheduler.advance(1000);
    a.send({ type: "ready" });
    a.send({ type: "vote_weapon", weapon: "WeaponAxe" });
    env.scheduler.advance(1000);
    a.send({ type: "vote_keepsake", keepsake: "KeepsakeA" });
    env.scheduler.advance(1000);
    a.send({ type: "ready" });
    env.scheduler.advance(1000);
    const logs = [...mem.files.keys()].filter((k) => k.endsWith(".jsonl"));
    assert.deepEqual(logs.map((k) => k.split("/").at(-1)), ["1-Ann.jsonl"]);
    const none = memFs();
    const off = new RaceLogStore(null, () => {}, none.fs);
    off.start("ABCD", { race_id: 1, seed: 1, weapon: "W", keepsake: "K", route: "" }, [{ id: "p1", name: "A", bot: false }], 0);
    assert.equal(none.files.size, 0);
  });
});
