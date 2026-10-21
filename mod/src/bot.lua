-- In-game test bot. Inactive unless <plugins_data>/bot.json exists (the test
-- launcher writes it; players never have one). It drives the same client
-- actions a player's clicks would, lets the game layer play the run, asserts
-- on real game state, and writes `RESULT: PASS|FAIL ...` to bot-result.txt.
--
-- bot.json fields:
--   role          "host" | "join" | "queue" (Find Match; both bots queue)
--                 | "code" (both type race_code; the first opens it)
--                 | "pad" (hands off the lobby: a real controller drives the board)
--   code_file     host writes the lobby code here, joiner polls it
--   start_at      private lobby host: press Start Race once this many racers are in (default 2)
--   weapon, keepsake  what to vote for (default: first option)
--   rooms         room transitions to drive before the outcome (default 2)
--   outcome       "win" | "die" | "forfeit" (pause-menu path: prompt, then Forfeit) | "none"
--   clear_screen  win through the game's run clear screen (then home, like a player)
--                 outcome "external": the test ends the run itself (e.g. a gamepad); just check the result
--   timeout       seconds before giving up (default 600)
--   trace_file    where to write the per-room trace (optional)
--   quit_after    exit the game this many seconds after the result (optional)
--   use_board     do lobby actions by pressing Race Board controls (the same
--                 path a controller press takes) instead of calling the client

local Bot = {}
Bot.__index = Bot

function Bot.new(deps)
	local b = setmetatable({}, Bot)
	b.client, b.game, b.log, b.now, b.json = deps.client, deps.game, deps.log, deps.now, deps.json
	b.board = deps.board
	b.press_queue = {}
	b.dir = deps.dir
	b.active = false
	local f = io.open(b.dir .. '/bot.json', 'r')
	if not f then return b end
	local ok, cfg = pcall(b.json.decode, f:read('*a'))
	f:close()
	if not ok or type(cfg) ~= 'table' then
		b.log('bot: bad bot.json: ' .. tostring(cfg))
		return b
	end
	b.cfg = cfg
	b.active = true
	-- role "idle": load the mod in test mode without connecting or racing.
	b.step = cfg.role == 'idle' and 'idle' or 'connect'
	b.started = b.now()
	b.step_started = b.started
	b.checks = {}
	b.rooms_done = 0
	b.result_path = cfg.result_file or (b.dir .. '/bot-result.txt')
	cfg.trace_file = cfg.trace_file or (b.dir .. '/trace.json')
	os.remove(b.result_path)
	if cfg.server_host then b.client.host = cfg.server_host end
	if cfg.server_port then b.client.port = cfg.server_port end
	if cfg.name then b.client.name = cfg.name end
	-- Mutation twins: deliberately break a feature so its test must fail.
	b.game.mutations = cfg.mutations or {}
	b.game.bot_cfg = cfg
	b.log('bot: active role=' .. tostring(cfg.role) .. ' outcome=' .. tostring(cfg.outcome))
	b.client.on.vote_phase = function(v) b:on_vote(v) end
	return b
end

function Bot:go_step(step)
	self.log('bot: step ' .. self.step .. ' -> ' .. step)
	self.step = step
	self.step_started = self.now()
end

function Bot:check(name, ok, detail)
	self.checks[#self.checks + 1] = { name = name, ok = ok and true or false, detail = detail }
	self.log(string.format('bot: check %s %s %s', ok and 'ok  ' or 'FAIL', name, detail and tostring(detail) or ''))
	return ok
end

function Bot:finish(pass, why)
	if self.step == 'done' then return end
	-- Always leave a trace (also on failure) so two clients can still be compared.
	if not self.trace_written and self.trace then
		self.trace_written = true
		pcall(self.write_trace, self)
	end
	for _, c in ipairs(self.checks) do
		if not c.ok then pass = false end
	end
	local line = string.format('RESULT: %s %s', pass and 'PASS' or 'FAIL', why or '')
	self.log('bot: ' .. line)
	local f = io.open(self.result_path, 'w')
	if f then
		f:write(line, '\n')
		for _, c in ipairs(self.checks) do
			f:write(string.format('%s %s %s\n', c.ok and 'ok' or 'FAIL', c.name, c.detail and tostring(c.detail) or ''))
		end
		f:close()
	end
	self.step = 'done'
	self.done_at = self.now()
end

-- cfg.dwell (seconds): pause before each lobby action, like a person reading
-- the screen. Used for screenshot runs; 0/absent acts immediately.
function Bot:wait_dwell(key, now)
	local dwell = self.cfg.dwell
	if not dwell or dwell <= 0 then return false end
	self.dwells = self.dwells or {}
	if not self.dwells[key] then self.dwells[key] = now + dwell end
	return now < self.dwells[key]
end

function Bot:on_vote(v)
	if self.cfg.role == 'pad' then return end -- the controller votes
	if self.cfg.dwell and not self.cfg.use_board then -- board presses dwell on their own
		self.pending_vote = v
		return
	end
	self:cast_vote(v)
end

function Bot:cast_vote(v)
	local want = self.cfg[v.phase]
	local choice = v.options[1] and v.options[1].id
	for _, o in ipairs(v.options) do
		if o.id == want then choice = o.id end
	end
	if not choice then return end
	if self.cfg.use_board then return self:queue_press('opt_' .. choice) end
	self.client:vote(v.phase, choice)
end

-- use_board: presses wait (one per frame) until the open board shows the
-- control, so each lands on the page a player would see it on.
function Bot:queue_press(...)
	for _, key in ipairs({ ... }) do self.press_queue[#self.press_queue + 1] = key end
end

function Bot:pump_presses(now)
	local key = self.press_queue[1]
	local b = self.board
	if not key then return end
	-- A press whose page never shows (e.g. the vote timed out) must not block the rest.
	self.press_head = self.press_head or { key = key, since = now }
	if self.press_head.key ~= key then self.press_head = { key = key, since = now } end
	if now - self.press_head.since > 10 then
		self.log('bot: dropped press ' .. key .. ' (never on the board)')
		table.remove(self.press_queue, 1)
		return
	end
	if not (b and b:is_open() and b.desc) then return end
	if self:wait_dwell('press_' .. key .. '_' .. #self.press_queue, now) then return end
	if b:press(key) then
		table.remove(self.press_queue, 1)
		self.press_head = nil
		self.log('bot: pressed ' .. key .. ' on board page ' .. tostring(b.desc.id))
	end
end

-- A lobby action: through the board when use_board, else straight to the client.
function Bot:lobby_action(keys, direct)
	if self.cfg.use_board then
		self:queue_press((table.unpack or unpack)(keys))
	else
		direct()
	end
end

local function read_file(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

function Bot:update()
	if not self.active then return end
	local now = self.now()
	if self.step == 'done' then
		if self.cfg.quit_after and now - self.done_at >= self.cfg.quit_after then self.game:quit() end
		return
	end
	if now - self.started > (self.cfg.timeout or 600) then
		return self:finish(false, 'timeout in step ' .. self.step)
	end
	local c, st = self.client, self.client.state
	if self.step == 'idle' then return end
	if self.game.bot_advance_dialogue then self.game:bot_advance_dialogue() end
	if self.game.bot_wake_death_loop and self.cfg.role ~= 'pad' then self.game:bot_wake_death_loop() end
	if self.step == 'connect' or self.step == 'wait_game' then self:reset_to_hub(now) end
	self:pump_presses(now)
	local handler = self['step_' .. self.step]
	if handler then handler(self, now, c, st) end
end

function Bot:step_connect(now, c, st)
	if st.conn == 'connected' and st.id then
		self:check('connected', true, c.host .. ':' .. tostring(c.port))
		self:go_step('wait_game')
	end
end

-- Lobby work waits until the game is idle in the hub, as a player would. A
-- save that loads mid-run is sent home by dying once (test copies only).
function Bot:reset_to_hub(now)
	if self.cfg.reset_to_hub == false or self.reset_done then return end
	if self.game:in_live_run() and now - self.started > 5 then
		self.reset_done = true
		self.log('bot: save loaded mid-run; dying once to reach the hub')
		self.game:bot_kill_hero()
	end
end

function Bot:step_wait_game(now, c)
	if self.game:ready_for_race() and self.cfg.expect_competitive and not self.profile_checked then
		self.profile_checked = true
		for _, chk in ipairs(self.game:verify_competitive_profile()) do
			self:check('profile: ' .. chk.name, chk.ok, chk.detail)
		end
	end
	if self.game:ready_for_race() then
		if self:wait_dwell('lobby', now) then return end
		if self.cfg.use_board and not (self.board and self.board:is_open()) then return end
		if self.cfg.role == 'pad' then
			self:go_step('pad_lobby')
		elseif self.cfg.role == 'host' then
			self:lobby_action({ 'create' }, function() c:create_lobby() end)
			self:go_step('hosting')
		elseif self.cfg.role == 'queue' then
			self:lobby_action({ 'find' }, function() c:find_match() end)
			self:go_step('queueing')
		elseif self.cfg.role == 'code' then
			local code = tostring(self.cfg.race_code or 'RACE')
			local keys = { 'join_page' }
			for ch in code:gmatch('.') do keys[#keys + 1] = 'key_' .. ch end
			keys[#keys + 1] = 'join'
			self:lobby_action(keys, function() c:join_lobby(code, true) end)
			self:go_step('queueing')
		else
			self:go_step('joining')
		end
	end
end

function Bot:step_hosting(now, c, st)
	local lobby = st.lobby
	if lobby and lobby.code and not self.code_written then
		local f = io.open(self.cfg.code_file, 'w')
		if f then
			f:write(lobby.code, '\n')
			f:close()
			self.code_written = true
			self.log('bot: wrote lobby code ' .. lobby.code)
		end
	end
	self:step_lobby(now, c, st)
end

-- role "pad": the test drives the board with a virtual gamepad; wait for the race.
function Bot:step_pad_lobby(now, c, st)
	if st.race then
		local b = self.board
		self:check('lobby driven by controller input', b and b.stats.presses >= 3,
			b and string.format('opens=%d builds=%d presses=%d', b.stats.opens, b.stats.builds, b.stats.presses))
		self:check('race_start', st.race.seed and st.race.seed > 0, 'seed=' .. tostring(st.race.seed))
		self:go_step('countdown')
	end
end

function Bot:step_queueing(now, c, st)
	if not st.lobby then return end
	-- The first racer to enter a code opens the lobby and waits there.
	if not self.matched and c:opponent_name() == nil then return end
	if not self.matched then
		self.matched = true
		self:check(self.cfg.role == 'code' and 'matched by race code' or 'matched by Find Match',
			c:opponent_name() ~= nil and (self.cfg.role ~= 'code' or st.lobby.code == self.cfg.race_code),
			'lobby ' .. tostring(st.lobby.code))
	end
	self:step_lobby(now, c, st)
end

function Bot:step_joining(now, c, st)
	if not st.lobby then
		if now - (self.last_join or 0) > 1 then
			self.last_join = now
			local code = read_file(self.cfg.code_file)
			code = code and code:match('%w+')
			if code and not self:wait_dwell('join', now) and not self.join_queued then
				if self.cfg.use_board then
					self.join_queued = true
					self:queue_press('join_page')
					for ch in code:gmatch('.') do self:queue_press('key_' .. ch) end
					self:queue_press('join')
				else
					c:join_lobby(code)
				end
			end
		end
		return
	end
	self:step_lobby(now, c, st)
end

function Bot:step_lobby(now, c, st)
	local phase = c:phase()
	-- Private lobby host (also the first to enter a race code): start once enough racers are in.
	local lobby = st.lobby
	if phase == 'waiting' and lobby and not lobby.public and c:is_host() and not self.start_sent
		and #(lobby.players or {}) >= (self.cfg.start_at or 2) and not self:wait_dwell('start', now) then
		self.start_sent = true
		self:check('lobby filled', true, #lobby.players .. ' racers')
		self:lobby_action({ 'start' }, function() c:start_race() end)
	end
	local v = self.pending_vote
	if v and st.vote and st.vote.phase == v.phase and not self:wait_dwell('vote_' .. v.phase, now) then
		self.pending_vote = nil
		self:cast_vote(v)
	end
	if phase == 'ready_check' and not self.readied and not self:wait_dwell('ready', now) then
		self.readied = true
		self:lobby_action({ 'ready' }, function() c:ready() end)
	end
	if st.race then
		self:check('race_start', st.race.seed and st.race.seed > 0, 'seed=' .. tostring(st.race.seed))
		if self.cfg.use_board then
			local b = self.board
			self:check('lobby driven through the Race Board', b and b.stats.opens > 0 and b.stats.presses >= 3 and #self.press_queue == 0,
				b and string.format('opens=%d builds=%d presses=%d queued=%d', b.stats.opens, b.stats.builds, b.stats.presses, #self.press_queue))
		end
		self:go_step('countdown')
	end
end

function Bot:step_countdown(now, c, st)
	if st.race.started then self:go_step('wait_run') end
end

function Bot:step_wait_run(now, c, st)
	if now - self.step_started > 60 then return self:finish(false, 'run never started') end
	local info = self.game:run_info()
	if info and info.in_run then
		local race = st.race
		self:check('seed applied', info.seed == race.seed, string.format('game=%s race=%s', tostring(info.seed), tostring(race.seed)))
		self:check('weapon applied', race.weapon == '' or info.weapon == race.weapon,
			string.format('game=%s race=%s', tostring(info.weapon), tostring(race.weapon)))
		self:check('keepsake applied', race.keepsake == '' or info.keepsake == race.keepsake,
			string.format('game=%s race=%s', tostring(info.keepsake), tostring(race.keepsake)))
		self.trace = { info.room }
		self:go_step('play')
	end
end

function Bot:step_play(now, c, st)
	if st.result then return self:go_step('result') end
	local target = self.cfg.rooms or 2
	if self.rooms_done < target then
		local res = self.game:bot_advance_room()
		if res == 'advanced' then
			self.rooms_done = self.rooms_done + 1
			local info = self.game:run_info()
			self.trace[#self.trace + 1] = info and info.room or '?'
			self.log('bot: advanced to room ' .. tostring(info and info.room) .. ' (' .. self.rooms_done .. '/' .. target .. ')')
		elseif res == 'failed' then
			return self:finish(false, 'could not advance room ' .. self.rooms_done)
		end
		return
	end
	if not self.trace_written then
		self.trace_written = true
		self:check('rooms driven', self.rooms_done >= target, self.rooms_done)
		if self.cfg.expect_overlay then
			local hud, shadow = self.game.hud, self.game.shadow
			self:check('native opponent panel built', hud and not hud.disabled and hud.stats.builds > 0,
				hud and string.format('builds=%d refreshes=%d', hud.stats.builds, hud.stats.refreshes))
			self:check('shadow shown and placed', shadow and not shadow.disabled and shadow.stats.frames_visible > 0
				and shadow.stats.max_error < 5, shadow and string.format('spawns=%d frames=%d max_error=%.1f',
				shadow.stats.spawns, shadow.stats.frames_visible, shadow.stats.max_error))
		end
		self:write_trace()
		local outcome = self.cfg.outcome or 'none'
		if outcome == 'die' then
			self.game:bot_kill_hero()
		elseif outcome == 'forfeit' then
			-- What "Forfeit Race" in the pause menu does, then the prompt's Forfeit.
			self:check('forfeit prompt offered', self.game:request_forfeit())
			if self.cfg.use_board then
				self:queue_press('forfeit')
			else
				self.game:forfeit_now()
			end
		elseif outcome == 'win' and not self.cfg.win_after_opponent_death then
			self.game:bot_win()
		end
		if outcome == 'none' or outcome == 'external' then
			self.log('bot: rooms done; outcome ' .. outcome)
			self:go_step('result')
		end
	end
	-- Scenario: finish only once the server told us a rival died.
	if self.cfg.win_after_opponent_death and not self.won then
		for _, r in ipairs(c:rivals()) do
			if r.finished and not self.won then
				self.won = true
				self:check('saw opponent death', r.finished.victory == false)
				self.game:bot_win()
			end
		end
	end
end

function Bot:write_trace()
	local path = self.cfg.trace_file
	if not path then return end
	local f = io.open(path, 'w')
	if not f then return end
	local info = self.game:run_info() or {}
	f:write(self.json.encode({ seed = info.seed, weapon = info.weapon, keepsake = info.keepsake, rooms = self.trace,
		details = self.game:trace_details() }), '\n')
	f:close()
end

function Bot:step_result(now, c, st)
	local outcome = self.cfg.outcome or 'none'
	if outcome == 'none' then return self:finish(true, 'rooms driven, no outcome requested') end
	if not st.result then
		local wait = outcome == 'external' and 300 or 120
		if now - self.step_started > wait then self:finish(false, 'no race_result') end
		return
	end
	local r = st.result
	-- On the board, the race ends on the results screen once the racer is home.
	if self.cfg.expect_results_screen then
		local b = self.board
		local shown = b and b.rendered and tostring(b.rendered):find('^finished') ~= nil
		if not shown and now - (self.result_seen or now) < 60 then
			self.result_seen = self.result_seen or now
			return
		end
		self:check('results screen shown', shown, b and tostring(b.rendered))
	end
	if self.cfg.expect then
		local got = r.draw and 'draw' or (r.you_won and 'win' or 'lose')
		self:check('expected result', got == self.cfg.expect, string.format('got=%s reason=%s', got, tostring(r.reason)))
	end
	if self.cfg.expect_reason then
		self:check('expected reason', r.reason == self.cfg.expect_reason, 'reason=' .. tostring(r.reason))
	end
	self:finish(true, string.format('reason=%s you_won=%s', tostring(r.reason), tostring(r.you_won)))
end

return Bot
