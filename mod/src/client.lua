-- Protocol client: mirrors server state, exposes player actions, and raises
-- callbacks the game layer acts on (race_start, go, race_result).
-- Pure Lua: the transport and clock are injected so this runs outside the game.
--
-- transport interface:
--   connect(host, port) -> ok, err      start connecting (non-blocking)
--   send(line) -> ok, err               queue one line (no trailing newline)
--   poll() -> lines, status             drain received lines; status is
--                                       'connecting' | 'connected' | 'closed'
--   close()

local Client = {}
Client.__index = Client

local PROGRESS_INTERVAL = 2.0
local GHOST_INTERVAL = 0.08 -- ~12 position updates per second for the opponent's shadow
local RECONNECT_MIN, RECONNECT_MAX = 1.0, 10.0
local PING_INTERVAL = 5.0

function Client.new(opts)
	local c = setmetatable({}, Client)
	c.json = assert(opts.json, 'json required')
	c.transport = assert(opts.transport, 'transport required')
	c.now = assert(opts.now, 'now required')
	c.log = opts.log or function() end
	c.host = opts.host or '127.0.0.1'
	c.port = opts.port or 7777
	c.name = opts.name or 'Player'
	c.version = opts.version or 'dev'
	c.on = opts.on or {}
	c.want_connected = false
	c.next_reconnect = 0
	c.reconnect_delay = RECONNECT_MIN
	c.last_ping = 0
	c.state = {
		conn = 'disconnected', -- disconnected | connecting | connected
		id = nil,
		token = nil,
		lobby = nil,          -- last lobby_state message
		vote = nil,           -- { phase, options, deadline, mine, opponent_voted }
		vote_results = {},    -- phase -> vote_result message
		race = nil,           -- race_start message + countdown_end, started
		opponent = nil,       -- last opponent_progress
		opponent_finished = nil,
		opponent_connected = true,
		result = nil,         -- race_result message
		last_error = nil,     -- { code, message, at }
		latency = nil,
	}
	c.last_progress_sent = -math.huge
	c.pending_progress = nil
	c.last_ghost_sent = -math.huge
	c.last_build_key = nil
	return c
end

-- connection ------------------------------------------------------------------

function Client:connect(host, port)
	if host then self.host = host end
	if port then self.port = port end
	self.want_connected = true
	self:_open()
end

function Client:disconnect()
	self.want_connected = false
	self.transport.close()
	self.state.conn = 'disconnected'
end

function Client:_open()
	self.state.conn = 'connecting'
	self.hello_sent = false
	local ok, err = self.transport.connect(self.host, self.port)
	if not ok then
		self.log('connect failed: ' .. tostring(err))
		self:_lost()
	end
end

function Client:_lost()
	self.state.conn = 'disconnected'
	self.hello_sent = false
	if self.want_connected then
		self.next_reconnect = self.now() + self.reconnect_delay
		self.reconnect_delay = math.min(self.reconnect_delay * 2, RECONNECT_MAX)
	end
end

function Client:send(msg)
	if self.state.conn ~= 'connected' then return false end
	local ok, err = self.transport.send(self.json.encode(msg))
	if not ok then self.log('send failed: ' .. tostring(err)) end
	return ok
end

-- Call once per frame.
function Client:update()
	local now = self.now()
	if self.state.conn == 'disconnected' then
		if self.want_connected and now >= self.next_reconnect then self:_open() end
	else
		local lines, status = self.transport.poll()
		if status == 'connected' and not self.hello_sent then
			self.hello_sent = true
			self.state.conn = 'connected'
			self:send({ type = 'hello', name = self.name, version = self.version, token = self.state.token })
		end
		for _, line in ipairs(lines or {}) do
			local ok, msg = pcall(self.json.decode, line)
			if ok and type(msg) == 'table' then
				local hok, herr = pcall(self._handle, self, msg)
				if not hok then self.log('handler error for ' .. tostring(msg.type) .. ': ' .. tostring(herr)) end
			else
				self.log('bad line from server: ' .. tostring(line))
			end
		end
		if status == 'closed' then
			self.log('connection closed')
			self:_lost()
		end
	end
	if self.state.conn == 'connected' then
		if now - self.last_ping >= PING_INTERVAL then
			self.last_ping = now
			self:send({ type = 'ping', t = now })
		end
		if self.pending_progress and now - self.last_progress_sent >= PROGRESS_INTERVAL then
			self:_flush_progress(now)
		end
	end
	self:_tick_race(now)
end

-- actions -----------------------------------------------------------------------

function Client:create_lobby() return self:send({ type = 'create_lobby' }) end

-- create=true: if nobody has opened this code yet, open it and wait there,
-- so two racers can both type a code they agreed on.
function Client:join_lobby(code, create)
	code = tostring(code or ''):upper():gsub('%s', '')
	return self:send({ type = 'join_lobby', code = code, create = create or nil })
end

function Client:leave_lobby() return self:send({ type = 'leave_lobby' }) end

-- Quick match: the server pairs us with the next player who asks.
function Client:find_match()
	local ok = self:send({ type = 'find_match' })
	if ok then self.state.queue = { since = self.now(), waiting = nil } end
	return ok
end

function Client:cancel_match()
	self.state.queue = nil
	return self:send({ type = 'cancel_match' })
end

function Client:vote(phase, choice)
	local ok = self:send({ type = 'vote_' .. phase, [phase] = choice })
	if ok and self.state.vote and self.state.vote.phase == phase then self.state.vote.mine = choice end
	return ok
end

function Client:ready() return self:send({ type = 'ready' }) end

function Client:forfeit() return self:send({ type = 'forfeit' }) end

function Client:rematch()
	self.state.rematch_requested = true
	return self:send({ type = 'rematch' })
end

-- Throttled to one message per PROGRESS_INTERVAL; the latest snapshot wins.
-- Pass force=true for room changes so the opponent sees them promptly.
function Client:report_progress(p, force)
	if not self:racing() then return end
	self.pending_progress = p
	if force then self:_flush_progress(self.now()) end
end

local function build_key(build)
	local parts = {}
	for i, e in ipairs(build or {}) do parts[i] = tostring(e.name) .. ':' .. tostring(e.rarity) .. ':' .. tostring(e.level) end
	return table.concat(parts, ',')
end

function Client:_flush_progress(now)
	local p = self.pending_progress
	if not p then return end
	self.pending_progress = nil
	self.last_progress_sent = now
	local msg = {
		type = 'progress_update', room = p.room, biome = p.biome, depth = p.depth,
		hp = p.hp, max_hp = p.max_hp, time = p.time or self:race_time(), alive = p.alive ~= false,
	}
	-- The build only travels when it changed.
	if p.build then
		local key = build_key(p.build)
		if key ~= self.last_build_key then
			self.last_build_key = key
			msg.build = p.build
		end
	end
	self:send(msg)
end

-- Position for the opponent's shadow: rate-limited, unthrottled otherwise.
function Client:report_ghost(g)
	if not self:racing() or self.state.race.completed then return false end
	local now = self.now()
	if now - self.last_ghost_sent < GHOST_INTERVAL then return false end
	self.last_ghost_sent = now
	return self:send({ type = 'ghost', room = g.room, depth = g.depth, x = g.x, y = g.y, angle = g.angle, anim = g.anim,
		t = self:race_time() })
end

function Client:report_complete(victory, time)
	if not self:racing() or self.state.race.completed then return false end
	self:_flush_progress(self.now())
	self.state.race.completed = { victory = victory, time = time or self:race_time() }
	return self:send({ type = 'run_complete', victory = victory and true or false, time = self.state.race.completed.time })
end

-- queries -----------------------------------------------------------------------

function Client:phase()
	return self.state.lobby and self.state.lobby.phase or nil
end

function Client:racing()
	local r = self.state.race
	return r ~= nil and r.started and not self.state.result
end

function Client:race_time()
	local r = self.state.race
	if not r or not r.started then return 0 end
	return self.now() - r.countdown_end
end

function Client:countdown_remaining()
	local r = self.state.race
	if not r or r.started then return nil end
	return math.max(0, r.countdown_end - self.now())
end

function Client:opponent_name()
	local l = self.state.lobby
	if not l then return nil end
	for _, p in ipairs(l.players or {}) do
		if p.id ~= l.you then return p.name end
	end
end

-- internals -----------------------------------------------------------------------

function Client:_emit(name, ...)
	local fn = self.on[name]
	if fn then
		local ok, err = pcall(fn, ...)
		if not ok then self.log('callback ' .. name .. ' failed: ' .. tostring(err)) end
	end
end

function Client:_tick_race(now)
	local r = self.state.race
	if r and not r.started and now >= r.countdown_end then
		r.started = true
		self.log('GO race ' .. tostring(r.race_id))
		self:_emit('go', r)
	end
end

local handlers = {}

function handlers.welcome(c, m)
	c.state.id = m.id
	c.state.token = m.token
	c.reconnect_delay = RECONNECT_MIN
	if not m.resumed then
		-- Server doesn't know us (fresh session or grace expired): local lobby state is stale.
		c.state.lobby = nil
		c.state.vote = nil
	end
	-- The server drops queued players when the connection drops: queue again.
	if c.state.queue and not c.state.lobby then c:send({ type = 'find_match' }) end
	c:_emit('welcome', m)
end

function handlers.pong(c, m)
	if type(m.t) == 'number' then c.state.latency = c.now() - m.t end
end

function handlers.lobby_created(c, m)
	c:_emit('lobby_created', m.code)
end

function handlers.lobby_joined(c, m)
	c.state.queue = nil
	c:_emit('lobby_joined', m)
end

function handlers.queued(c, m)
	c.state.queue = c.state.queue or { since = c.now() }
	c.state.queue.waiting = m.waiting
	c:_emit('queued', m)
end

function handlers.match_cancelled(c)
	c.state.queue = nil
	c:_emit('match_cancelled')
end

function handlers.lobby_left(c)
	c.state.lobby = nil
	c.state.vote = nil
	c.state.race = nil
	c.state.result = nil
	c:_emit('lobby_left')
end

function handlers.lobby_state(c, m)
	local prev = c.state.lobby
	c.state.lobby = m
	if m.phase == 'waiting' then
		c.state.vote = nil
		c.state.vote_results = {}
		c.state.opponent = nil
		c.state.opponent_finished = nil
	end
	if m.phase ~= 'voting_weapon' and m.phase ~= 'voting_keepsake' then c.state.vote = nil end
	if m.phase == 'racing' and c.state.race == nil and m.race then
		-- Resumed into a running race (e.g. after a reconnect with a fresh client).
		c.state.race = { race_id = m.race.race_id, seed = m.race.seed, weapon = m.race.weapon, keepsake = m.race.keepsake,
			countdown_end = c.now(), started = true, resumed = true }
	end
	if prev and prev.phase ~= m.phase then c:_emit('phase', m.phase, prev.phase) end
end

function handlers.vote_phase(c, m)
	c.state.vote = { phase = m.phase, options = m.options or {}, deadline = c.now() + (m.timer or 0) }
	c:_emit('vote_phase', c.state.vote)
end

function handlers.vote_cast(c, m)
	local v = c.state.vote
	if v and v.phase == m.phase and m.by == 'opponent' then v.opponent_voted = true end
end

function handlers.vote_result(c, m)
	c.state.vote_results[m.phase] = m
	c:_emit('vote_result', m)
end

function handlers.race_start(c, m)
	c.state.result = nil
	c.state.opponent = nil
	c.state.ghost = nil
	c.last_build_key = nil
	c.state.opponent_finished = nil
	c.state.rematch_requested = nil
	c.pending_progress = nil
	m.countdown_end = c.now() + (m.countdown_ms or 0) / 1000
	m.started = false
	c.state.race = m
	c.log(string.format('race_start id=%s seed=%s weapon=%s keepsake=%s', tostring(m.race_id), tostring(m.seed),
		tostring(m.weapon), tostring(m.keepsake)))
	c:_emit('race_start', m)
end

function handlers.opponent_progress(c, m)
	m.type = nil
	m.received = c.now()
	-- Builds arrive only on change; keep the last one.
	if m.build == nil and c.state.opponent then m.build = c.state.opponent.build end
	c.state.opponent = m
end

function handlers.opponent_ghost(c, m)
	m.type = nil
	m.received = c.now()
	c.state.ghost = m
end

function handlers.opponent_finished(c, m)
	c.state.opponent_finished = m
end

function handlers.opponent_disconnected(c)
	c.state.opponent_connected = false
end

function handlers.opponent_reconnected(c)
	c.state.opponent_connected = true
end

function handlers.race_result(c, m)
	c.state.result = m
	c.log(string.format('race_result winner=%s reason=%s you_won=%s', tostring(m.winner_name), tostring(m.reason),
		tostring(m.you_won)))
	c:_emit('race_result', m)
end

function handlers.error(c, m)
	c.state.last_error = { code = m.code, message = m.message, at = c.now() }
	c.log('server error ' .. tostring(m.code) .. ': ' .. tostring(m.message))
	c:_emit('error', m)
end

function Client:_handle(m)
	local h = handlers[m.type]
	if h then h(self, m) else self.log('unhandled message ' .. tostring(m.type)) end
end

return Client
