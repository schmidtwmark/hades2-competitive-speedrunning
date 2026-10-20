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
	f.push({ type = 'vote_cast', phase = 'weapon', by = 'opponent' })
	c:update()
	T.truthy(c.state.vote.opponent_voted)
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
	f.push({ type = 'opponent_progress', room = 'F_Boss01', depth = 12, hp = 150, time = 94.5, alive = true })
	f.push({ type = 'error', code = 'lobby_full', message = 'Lobby ABCD is full' })
	c:update()
	T.eq(c.state.opponent.room, 'F_Boss01')
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
	f.push({ type = 'opponent_progress', room = 'X', depth = 3, hp = 5, time = 1, alive = true, build = { { name = 'B' } } })
	f.push({ type = 'opponent_progress', room = 'Y', depth = 4, hp = 5, time = 2, alive = true })
	c:update()
	T.eq(c.state.opponent.room, 'Y')
	T.eq(c.state.opponent.build[1].name, 'B')
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
	f.push({ type = 'opponent_ghost', room = 'R', depth = 1, x = 9, y = 8, t = 1 })
	c:update()
	T.eq(c.state.ghost.x, 9)
end)

T.case('find match: queued until paired, cancel clears it', function()
	local c, f = make()
	c:find_match()
	T.eq(f.last('find_match').type, 'find_match')
	T.truthy(c.state.queue)
	f.push({ type = 'queued', waiting = 1 })
	c:update()
	T.eq(c.state.queue.waiting, 1)
	f.push({ type = 'lobby_joined', code = 'ABCD', opponent = 'Zag' })
	c:update()
	T.eq(c.state.queue, nil)
	c:find_match()
	c:cancel_match()
	T.eq(f.last('cancel_match').type, 'cancel_match')
	T.eq(c.state.queue, nil)
end)
