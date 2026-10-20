-- In-game test bot. Inactive unless <plugins_data>/bot.json exists (the test
-- launcher writes it; players never have one). It drives the same client
-- actions a player's clicks would, lets the game layer play the run, asserts
-- on real game state, and writes `RESULT: PASS|FAIL ...` to bot-result.txt.
--
-- bot.json fields:
--   role          "host" | "join"
--   code_file     host writes the lobby code here, joiner polls it
--   weapon, keepsake  what to vote for (default: first option)
--   rooms         room transitions to drive before the outcome (default 2)
--   outcome       "win" | "die" | "none"
--   timeout       seconds before giving up (default 600)
--   trace_file    where to write the per-room trace (optional)
--   quit_after    exit the game this many seconds after the result (optional)

local Bot = {}
Bot.__index = Bot

function Bot.new(deps)
	local b = setmetatable({}, Bot)
	b.client, b.game, b.log, b.now, b.json = deps.client, deps.game, deps.log, deps.now, deps.json
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
	-- role "idle": only the eval channel, for poking at the live game by hand.
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

function Bot:on_vote(v)
	local want = self.cfg[v.phase]
	local choice = v.options[1] and v.options[1].id
	for _, o in ipairs(v.options) do
		if o.id == want then choice = o.id end
	end
	if choice then self.client:vote(v.phase, choice) end
end

local function read_file(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

-- Test-only REPL into the live game: <data>/eval.lua is run once inside a game
-- coroutine (so it may wait()), with G = the game's globals; whatever it
-- returns or raises goes to <data>/eval.out. Only exists while bot.json does.
function Bot:poll_eval(now)
	if now < (self.next_eval or 0) then return end
	self.next_eval = now + 0.5
	local path = self.dir .. '/eval.lua'
	local code = read_file(path)
	if not code then return end
	os.remove(path)
	local game, json, dir = self.game, self.json, self.dir
	local env = setmetatable({ G = game.G, game = game, bot = self, log = self.log, json = json }, { __index = _G })
	local function out(text)
		local f = io.open(dir .. '/eval.out', 'a')
		if f then f:write(text, '\n--END--\n'); f:close() end
	end
	local chunk, err = load(code, 'eval', 't', env)
	if not chunk then return out('compile error: ' .. tostring(err)) end
	game:spawn(function()
		local res = { xpcall(chunk, debug.traceback) }
		if not res[1] then return out('error: ' .. tostring(res[2])) end
		local parts = {}
		for i = 2, #res do
			local v = res[i]
			local ok, enc = pcall(json.encode, v)
			parts[#parts + 1] = ok and enc or tostring(v)
		end
		out(table.concat(parts, '\t'))
	end)
end

function Bot:update()
	if not self.active then return end
	local now = self.now()
	self:poll_eval(now)
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
	if self.step == 'connect' or self.step == 'wait_game' then self:reset_to_hub(now) end
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
	if self.game:ready_for_race() then
		if self.cfg.role == 'host' then
			c:create_lobby()
			self:go_step('hosting')
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

function Bot:step_joining(now, c, st)
	if not st.lobby then
		if now - (self.last_join or 0) > 1 then
			self.last_join = now
			local code = read_file(self.cfg.code_file)
			if code and code:match('%w') then c:join_lobby(code) end
		end
		return
	end
	self:step_lobby(now, c, st)
end

function Bot:step_lobby(now, c, st)
	local phase = c:phase()
	if phase == 'ready_check' and not self.readied then
		self.readied = true
		c:ready()
	end
	if st.race then
		self:check('race_start', st.race.seed and st.race.seed > 0, 'seed=' .. tostring(st.race.seed))
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
		self:write_trace()
		local outcome = self.cfg.outcome or 'none'
		if outcome == 'die' then
			self.game:bot_kill_hero()
		elseif outcome == 'win' and not self.cfg.win_after_opponent_death then
			self.game:bot_win()
		end
		if outcome == 'none' then self:go_step('result') end
	end
	-- Scenario: finish only once the server told us the opponent died.
	if self.cfg.win_after_opponent_death and not self.won and st.opponent_finished then
		self.won = true
		self:check('saw opponent death', st.opponent_finished.victory == false)
		self.game:bot_win()
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
		if now - self.step_started > 120 then self:finish(false, 'no race_result') end
		return
	end
	local r = st.result
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
