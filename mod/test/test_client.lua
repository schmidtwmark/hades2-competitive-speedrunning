local T = require('test.lib')
local json = T.load('json.lua')
local Client = T.load('client.lua')

-- Fake transport: test pushes server messages, inspects what the client sent.
local function fake()
	local f = { sent = {}, inbox = {}, status = 'connecting', connects = 0, t = 0 }
	f.transport = {
		connect = function() f.connects = f.connects + 1; f.status = 'connecting'; return true end,
		send = function(line) f.sent[#f.sent + 1] = json.decode(line); return true end,
		poll = function()
			local lines = f.inbox
			f.inbox = {}
			return lines, f.status
		end,
		close = function() f.status = 'closed' end,
	}
	function f.push(m) f.inbox[#f.inbox + 1] = json.encode(m) end
	function f.last(type_)
		for i = #f.sent, 1, -1 do
			if f.sent[i].type == type_ then return f.sent[i] end
		end
	end
	function f.count(type_)
		local n = 0
		for _, m in ipairs(f.sent) do if m.type == type_ then n = n + 1 end end
		return n
	end
	return f
end

local function make(on)
	local f = fake()
	local c = Client.new({ json = json, transport = f.transport, now = function() return f.t end, name = 'Mel', on = on })
	c:connect('h', 1)
	f.status = 'connected'
	c:update()
	f.push({ type = 'welcome', id = 'p1', token = 'tok', protocol = 1, server_time = 0, resumed = false })
	c:update()
	return c, f
end

local function lobby_state(phase, extra)
	local m = { type = 'lobby_state', code = 'ABCD', phase = phase, you = 'p1',
		players = { { id = 'p1', name = 'Mel', connected = true, ready = false }, { id = 'p2', name = 'Zag', connected = true, ready = false } } }
	for k, v in pairs(extra or {}) do m[k] = v end
	return m
end

T.case('sends hello once connected and stores the token', function()
	local c, f = make()
	local hello = f.last('hello')
	T.eq(hello.name, 'Mel')
	T.eq(hello.token, nil)
	T.eq(c.state.token, 'tok')
	T.eq(c.state.conn, 'connected')
end)

T.case('join_lobby normalises the code', function()
	local c, f = make()
	c:join_lobby(' ab cd ')
	T.eq(f.last('join_lobby').code, 'ABCD')
end)

T.case('mirrors lobby_state, vote phases and opponent votes', function()
	local c, f = make()
	f.push(lobby_state('voting_weapon'))
	f.push({ type = 'vote_phase', phase = 'weapon', options = { { id = 'WeaponAxe', name = 'Axe' } }, timer = 15 })
	c:update()
	T.eq(c:phase(), 'voting_weapon')
	T.eq(c:opponent_name(), 'Zag')
	T.eq(c.state.vote.deadline, 15)
	c:vote('weapon', 'WeaponAxe')
	T.eq(f.last('vote_weapon').weapon, 'WeaponAxe')
	T.eq(c.state.vote.mine, 'WeaponAxe')
	f.push({ type = 'vote_cast', phase = 'weapon', by = 'opponent', id = 'p2', name = 'Zag', voted = 2, of = 2 })
	c:update()
	T.truthy(c.state.vote.voters.p2)
	T.eq(c.state.vote.voted, 2)
	f.push({ type = 'vote_result', phase = 'weapon', selected = 'WeaponAxe', votes = { you = 'WeaponAxe' } })
	f.push(lobby_state('ready_check'))
	c:update()
	T.eq(c.state.vote, nil)
	T.eq(c.state.vote_results.weapon.selected, 'WeaponAxe')
end)

T.case('countdown fires go exactly once at countdown end', function()
	local gos = {}
	local c, f = make({ go = function(r) gos[#gos + 1] = r end })
	f.t = 100
	f.push({ type = 'race_start', race_id = 1, seed = 42, weapon = 'WeaponAxe', keepsake = 'K', countdown = 3, countdown_ms = 3000 })
	c:update()
	T.eq(c:countdown_remaining(), 3)
	T.eq(#gos, 0)
	f.t = 102.9
	c:update()
	T.eq(#gos, 0)
	T.eq(c:racing(), false)
	f.t = 103
	c:update()
	c:update()
	T.eq(#gos, 1)
	T.eq(gos[1].seed, 42)
	T.truthy(c:racing())
	f.t = 110
	T.eq(c:race_time(), 7)
end)

T.case('progress is throttled to every 2s, forced updates go immediately', function()
	local c, f = make()
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	T.truthy(c:racing())
	c:report_progress({ room = 'R1', depth = 1, hp = 10 })
	c:update()
	T.eq(f.count('progress_update'), 1)
	f.t = 1
	c:report_progress({ room = 'R1', depth = 1, hp = 9 })
	c:update()
	T.eq(f.count('progress_update'), 1)
	f.t = 2.5
	c:update()
	T.eq(f.count('progress_update'), 2)
	T.eq(f.last('progress_update').hp, 9)
	T.eq(f.last('progress_update').alive, true)
	f.t = 3
	c:report_progress({ room = 'R2', depth = 2, hp = 9 }, true)
	T.eq(f.count('progress_update'), 3)
	T.eq(f.last('progress_update').room, 'R2')
end)

T.case('no progress or completion outside a race', function()
	local c, f = make()
	c:report_progress({ room = 'R', depth = 1, hp = 1 }, true)
	T.eq(c:report_complete(true, 1), false)
	T.eq(f.count('progress_update'), 0)
	T.eq(f.count('run_complete'), 0)
end)

T.case('run_complete is sent once and race_result ends the race', function()
	local results = {}
	local c, f = make({ race_result = function(r) results[#results + 1] = r end })
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	f.t = 50
	c:report_complete(true)
	c:report_complete(true)
	T.eq(f.count('run_complete'), 1)
	T.eq(f.last('run_complete').time, 50)
	f.push({ type = 'race_result', race_id = 1, winner = 'p1', winner_name = 'Mel', draw = false, you_won = true, reason = 'completed_first', results = {} })
	c:update()
	T.eq(#results, 1)
	T.eq(c:racing(), false)
end)

T.case('reconnects with backoff and resumes with the token', function()
	local c, f = make()
	f.status = 'closed'
	f.t = 10
	c:update()
	T.eq(c.state.conn, 'disconnected')
	T.eq(f.connects, 1)
	f.t = 10.5
	c:update()
	T.eq(f.connects, 1)
	f.t = 11
	c:update()
	T.eq(f.connects, 2)
	f.status = 'connected'
	c:update()
	T.eq(f.last('hello').token, 'tok')
end)

T.case('opponent progress and errors are recorded', function()
	local c, f = make()
	f.push({ type = 'opponent_progress', id = 'p2', name = 'Zag', room = 'F_Boss01', depth = 12, hp = 150, time = 94.5, alive = true })
	f.push({ type = 'error', code = 'lobby_full', message = 'Lobby ABCD is full' })
	c:update()
	T.eq(c.state.rivals.p2.progress.room, 'F_Boss01')
	T.eq(c.state.last_error.code, 'lobby_full')
end)

T.case('a throwing callback does not break the client', function()
	local logs = {}
	local f = fake()
	local c = Client.new({ json = json, transport = f.transport, now = function() return f.t end,
		log = function(l) logs[#logs + 1] = l end, on = { race_start = function() error('boom') end } })
	c:connect()
	f.status = 'connected'
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 1, countdown_ms = 1000 })
	c:update()
	T.truthy(c.state.race)
	T.truthy(table.concat(logs, '\n'):find('boom'))
end)

T.case('builds travel only when they change; opponent build is kept between updates', function()
	local c, f = make()
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	local build = { { name = 'ZeusWeaponBoon', rarity = 'Rare' } }
	c:report_progress({ room = 'R', depth = 1, hp = 1, build = build }, true)
	T.eq(f.last('progress_update').build[1].name, 'ZeusWeaponBoon')
	f.t = 1
	c:report_progress({ room = 'R', depth = 2, hp = 1, build = build }, true)
	T.eq(f.last('progress_update').build, nil)
	f.push({ type = 'opponent_progress', id = 'p2', room = 'X', depth = 3, hp = 5, time = 1, alive = true, build = { { name = 'B' } } })
	f.push({ type = 'opponent_progress', id = 'p2', room = 'Y', depth = 4, hp = 5, time = 2, alive = true })
	c:update()
	T.eq(c.state.rivals.p2.progress.room, 'Y')
	T.eq(c.state.rivals.p2.progress.build[1].name, 'B')
end)

T.case('ghost updates are rate limited and only sent while racing', function()
	local c, f = make()
	T.eq(c:report_ghost({ room = 'R', depth = 1, x = 1, y = 2 }), false)
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	T.eq(c:report_ghost({ room = 'R', depth = 1, x = 1, y = 2, angle = 90 }), true)
	T.eq(c:report_ghost({ room = 'R', depth = 1, x = 2, y = 2 }), false)
	f.t = 0.1
	T.eq(c:report_ghost({ room = 'R', depth = 1, x = 3, y = 2 }), true)
	T.eq(f.count('ghost'), 2)
	T.eq(f.last('ghost').x, 3)
	f.push({ type = 'opponent_ghost', id = 'p2', room = 'R', depth = 1, x = 9, y = 8, t = 1 })
	c:update()
	T.eq(c.state.rivals.p2.ghost.x, 9)
end)

T.case('find match: a rival found, ready to vote and back; cancel leaves it', function()
	local c, f = make()
	f.t = 5
	c:find_match()
	T.eq(f.last('find_match').type, 'find_match')
	T.truthy(c.state.queue)
	f.push({ type = 'lobby_joined', code = 'ABCD', opponent = nil })
	f.push(lobby_state('waiting', { public = true, max_players = 2 }))
	c:update()
	T.eq(c.state.queue, nil)
	T.eq(c.state.search_since, 5)
	T.eq(c:is_host(), false)
	T.eq(c:is_ready(), false)
	c:ready()
	T.eq(f.last('ready').ready, nil)
	local st = lobby_state('waiting', { public = true, max_players = 2 })
	st.players[1].ready = true
	f.push(st)
	c:update()
	T.eq(c:is_ready(), true)
	c:ready(false)
	T.eq(f.last('ready').ready, false)
	c:cancel_match()
	T.eq(f.last('cancel_match').type, 'cancel_match')
	f.push({ type = 'match_cancelled' })
	f.push({ type = 'lobby_left' })
	c:update()
	T.eq(c.state.lobby, nil)
	T.eq(c.state.search_since, nil)
end)

T.case('several rivals: each keeps its own progress, ghost and result', function()
	local c, f = make()
	local players = { { id = 'p1', name = 'Mel', host = true }, { id = 'p2', name = 'Zag' }, { id = 'p3', name = 'Nemesis' },
		{ id = 'p4', name = 'Hecate' } }
	f.push(lobby_state('waiting', { players = players, max_players = 5 }))
	c:update()
	T.truthy(c:is_host())
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	f.push(lobby_state('racing', { players = players }))
	f.push({ type = 'opponent_progress', id = 'p3', name = 'Nemesis', room = 'F_Opening01', depth = 2, hp = 30, time = 9 })
	f.push({ type = 'opponent_progress', id = 'p2', name = 'Zag', room = 'F_Combat01', depth = 3, hp = 20, time = 9 })
	f.push({ type = 'opponent_ghost', id = 'p4', room = 'F_Opening01', depth = 1, x = 1, y = 2 })
	f.push({ type = 'opponent_finished', id = 'p3', name = 'Nemesis', victory = false, time = 20, outcome = 'died' })
	c:update()
	local rs = c:rivals()
	T.eq(#rs, 3)
	T.eq(rs[1].name, 'Zag')
	T.eq(rs[2].progress.depth, 2)
	T.eq(rs[3].ghost.x, 1)
	T.eq(c:rivals_running(), 1, 'Zag runs; Nemesis fell; Hecate has no progress yet')
	-- Zag leaves mid-race: still listed (their result counts), after the lobby members.
	f.push(lobby_state('racing', { players = { players[1], players[3], players[4] } }))
	f.push({ type = 'opponent_finished', id = 'p2', name = 'Zag', victory = false, time = 25, outcome = 'disconnect' })
	c:update()
	rs = c:rivals()
	T.eq(#rs, 3)
	T.eq(rs[3].name, 'Zag')
	T.eq(rs[3].finished.outcome, 'disconnect')
	-- A new race forgets the last one's rivals.
	f.push({ type = 'race_start', race_id = 2, seed = 2, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	T.eq(#c:rivals(), 2)
	T.eq(c:rivals()[1].progress, nil)
end)

T.case('race_decided keeps the race going; forfeit is sent once with stats', function()
	local results = {}
	local c, f = make({ race_result = function(r) results[#results + 1] = r end })
	f.push({ type = 'race_start', race_id = 1, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	f.push({ type = 'opponent_finished', victory = true, time = 300, outcome = 'cleared' })
	f.push({ type = 'race_decided', race_id = 1, winner = 'p2', winner_name = 'Zag', draw = false, you_won = false, reason = 'completed_first' })
	c:update()
	T.eq(c.state.decided.winner_name, 'Zag')
	T.truthy(c:racing(), 'still racing after the rival won')
	c:report_progress({ room = 'R', depth = 5, hp = 3, stats = { Kills = 9 } }, true)
	T.eq(f.last('progress_update').stats.Kills, 9)
	T.truthy(c:forfeit({ Kills = 10 }, { { name = 'B' } }))
	T.eq(c:forfeit(), false)
	T.eq(f.count('forfeit'), 1)
	T.eq(f.last('forfeit').stats.Kills, 10)
	T.eq(c:report_complete(false), false, 'no run_complete after forfeiting')
	f.push({ type = 'race_result', race_id = 1, winner = 'p2', winner_name = 'Zag', draw = false, you_won = false,
		reason = 'completed_first', results = {} })
	c:update()
	T.eq(#results, 1)
	T.eq(c:racing(), false)
end)

T.case('hello carries the game build; version errors become a mismatch until the next try', function()
	local f = fake()
	local c = Client.new({ json = json, transport = f.transport, now = function() return f.t end, name = 'Mel', version = '0.3.0' })
	c.game_build = 1790167264
	c:connect('h', 1)
	f.status = 'connected'
	c:update()
	T.eq(f.last('hello').game_build, 1790167264)
	T.eq(f.last('hello').version, '0.3.0')
	f.push({ type = 'welcome', id = 'p1', token = 't', resumed = false })
	f.push({ type = 'error', code = 'version_mismatch', who = 'you', what = 'game', rival = 'Zag', message = 'x' })
	c:update()
	T.eq(c.state.mismatch.who, 'you')
	T.eq(c.state.mismatch.rival, 'Zag')
	c:find_match()
	T.eq(c.state.mismatch, nil, 'searching again clears it')
	f.push({ type = 'error', code = 'lobby_full', message = 'full' })
	c:update()
	T.eq(c.state.mismatch, nil, 'other errors are not mismatches')
	-- Find Match against an incompatible searcher: the mismatch arrives just
	-- before our own (empty) Find Match lobby and stays for the board.
	f.push({ type = 'error', code = 'version_mismatch', who = 'rival', what = 'mod', rival = 'Zag', message = 'x' })
	f.push({ type = 'lobby_joined', code = 'WXYZ', opponent = nil })
	c:update()
	T.eq(c.state.mismatch.who, 'rival')
end)

T.case('a vote opening clears its own and later results; a result carries the option name', function()
	local c, f = make()
	f.push({ type = 'vote_phase', phase = 'weapon', timer = 15, options = { { id = 'WeaponAxe', name = 'Axe' } } })
	f.push({ type = 'vote_result', phase = 'weapon', selected = 'WeaponAxe', votes = {}, counts = {} })
	f.push({ type = 'vote_phase', phase = 'keepsake', timer = 15, options = { { id = 'K', name = 'Kay' } } })
	f.push({ type = 'vote_result', phase = 'keepsake', selected = 'K', votes = {}, counts = {} })
	c:update()
	T.eq(c.state.vote_results.weapon.name, 'Axe')
	T.eq(c.state.vote_results.keepsake.name, 'Kay')
	-- A rematch votes again straight from the results: last race's picks must go.
	f.push({ type = 'vote_phase', phase = 'route', timer = 15, options = { { id = 'surface', name = 'Surface' } } })
	c:update()
	T.eq(c.state.vote_results.weapon, nil)
	T.eq(c.state.vote_results.keepsake, nil)
	f.push({ type = 'vote_result', phase = 'route', selected = 'surface', votes = {}, counts = {} })
	f.push({ type = 'vote_phase', phase = 'weapon', timer = 15, options = { { id = 'WeaponAxe', name = 'Axe' } } })
	c:update()
	T.eq(c.state.vote_results.route.name, 'Surface', 'an earlier vote stays')
end)

T.case('add_bot asks for a house bot', function()
	local c, f = make()
	c:create_lobby()
	T.eq(f.last('create_lobby').type, 'create_lobby')
	c:add_bot()
	T.eq(f.last('add_bot').type, 'add_bot')
end)

T.case('update_available: only a newer release than ours, compared by number', function()
	local c, f = make()
	c.version = '0.6.0'
	T.eq(c:update_available(), nil, 'nothing known yet')
	for latest, want in pairs({ ['0.6.1'] = '0.6.1', ['0.6.0'] = false, ['0.5.9'] = false, ['0.10.0'] = '0.10.0', ['1.0.0'] = '1.0.0' }) do
		f.push({ type = 'welcome', id = 'p1', token = 't', resumed = false, latest_mod = latest })
		c:update()
		T.eq(c:update_available(), want or nil, latest)
	end
	c.version = 'dev'
	T.eq(c:update_available(), nil, 'a dev build never nags')
end)

T.case('race_log sends a choice-log line tagged with the race', function()
	local c, f = make()
	T.eq(c:race_log({ ev = 'room' }), false, 'no race: nothing to tag it with')
	f.push({ type = 'race_start', race_id = 4, seed = 1, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	c:update()
	c:race_log({ ev = 'room', depth = 1, name = 'F_Opening01' })
	local m = f.last('race_log')
	T.eq(m.race_id, 4)
	T.eq(m.entry.name, 'F_Opening01')
end)
