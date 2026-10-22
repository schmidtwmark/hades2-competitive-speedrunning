-- Lua client (real LuaSocket transport) against a real server and a mock bot.
-- Usage: lua integration.lua <port> <code-file> <outcome win|die> <finish_after_s>
-- Hosts a lobby, writes its code to <code-file>, starts once the bot is in,
-- votes, readies, plays a fake run, and prints RESULT: PASS / RESULT: FAIL.

package.path = 'src/?.lua;' .. package.path
local socket = require('socket')
local json = require('json')
local Client = require('client')
local Net = require('net')

local port = tonumber(arg[1])
local code_file = arg[2]
local outcome = arg[3] or 'win'
local finish_after = tonumber(arg[4] or '2')

local logs = {}
local function log(l)
	logs[#logs + 1] = string.format('%.3f %s', socket.gettime(), l)
	print('[lua] ' .. l)
end

local transport = Net.new(socket, log)
local events = {}
local c
c = Client.new({
	json = json, transport = transport, now = socket.gettime, log = log, name = 'LuaClient', version = 'test',
	on = {
		lobby_created = function(code)
			local f = assert(io.open(code_file, 'w'))
			f:write(code .. '\n')
			f:close()
			events.code = code
		end,
		vote_phase = function(v) c:vote(v.phase, v.options[#v.options].id) end,
		phase = function(p) if p == 'ready_check' then c:ready() end end,
		race_start = function(r) events.race = r end,
		go = function(r) events.go_at = socket.gettime() end,
		race_result = function(r) events.result = r end,
	},
})
c:connect('127.0.0.1', port)

local deadline = socket.gettime() + 30
local created, started, completed = false, false, false
local depth = 0
local last_room = 0
while socket.gettime() < deadline and not events.result do
	c:update()
	if c.state.conn == 'connected' and c.state.id and not created then
		created = true
		c:create_lobby()
	end
	local lobby = c.state.lobby
	if not started and lobby and lobby.phase == 'waiting' and #(lobby.players or {}) >= 2 then
		started = true
		c:ready() -- ready to vote: the vote starts once the bot is too
	end
	if c:racing() then
		local t = c:race_time()
		if t - last_room >= 0.3 then
			last_room = t
			depth = depth + 1
			c:report_progress({ room = 'LuaRoom' .. depth, biome = 'F', depth = depth, hp = 50, max_hp = 50 }, true)
		end
		if t >= finish_after and not completed then
			completed = true
			c:report_complete(outcome == 'win')
		end
	end
	socket.sleep(0.016)
end

local function check(cond, what)
	if not cond then
		print('RESULT: FAIL ' .. what)
		os.exit(1)
	end
end
check(events.code, 'no lobby code')
check(events.race and events.race.seed and events.race.seed > 0, 'no race_start with seed')
check(events.go_at, 'countdown never fired')
check(c:rivals()[1] and c:rivals()[1].progress ~= nil, 'never saw opponent progress')
check(events.result, 'no race_result')
local expect_win = outcome == 'win'
check(events.result.you_won == expect_win, 'you_won=' .. tostring(events.result.you_won))
print(string.format('RESULT: PASS seed=%d weapon=%s keepsake=%s reason=%s', events.race.seed, events.race.weapon,
	events.race.keepsake, events.result.reason))
