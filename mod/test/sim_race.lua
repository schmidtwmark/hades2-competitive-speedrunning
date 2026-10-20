-- Two simulated game clients, each running the real src/main.lua + bot, race
-- through a real server. Usage (from mod/): lua test/sim_race.lua <port> <workdir> [progress_b]
-- Prints RESULT: PASS / RESULT: FAIL.

package.path = 'test/?.lua;src/?.lua;' .. package.path
local socket = require('socket')
local json = require('json')
local Sim = require('h2m_sim')

local port = tonumber(arg[1])
local work = arg[2]
local progress_b = tonumber(arg[3] or '0')
local echo = os.getenv('SIM_ECHO') == '1'

local function mkdir(p) os.execute('mkdir -p "' .. p .. '"') end

local function make(name, bot, progress, action_noise)
	local base = work .. '/' .. name
	mkdir(base .. '/data')
	mkdir(base .. '/config')
	bot.server_host = '127.0.0.1'
	bot.server_port = port
	bot.name = name
	bot.code_file = work .. '/code'
	bot.trace_file = base .. '/trace.json'
	bot.result_file = base .. '/result.txt'
	bot.timeout = 60
	return Sim.new({ name = name, src_dir = 'src', data_dir = base .. '/data', config_dir = base .. '/config', bot = bot,
		json = json, echo = echo, progress = progress, action_noise = action_noise })
end

local failures = {}
local function check(ok, what)
	print((ok and 'ok   ' or 'FAIL ') .. what)
	if not ok then failures[#failures + 1] = what end
end

-- 1. A game with none of the hooked functions: the mod must load and degrade.
do
	local base = work .. '/empty'
	mkdir(base .. '/data')
	mkdir(base .. '/config')
	local ok, sim = pcall(Sim.new, { name = 'empty', game = 'empty', src_dir = 'src', data_dir = base .. '/data',
		config_dir = base .. '/config', json = json })
	check(ok, 'mod loads against a game with no known functions: ' .. tostring(ok or sim))
	if ok then
		local fok, ferr = pcall(function() for _ = 1, 5 do sim:frame() end end)
		check(fok, 'frames run without errors on the empty game ' .. tostring(ferr or ''))
		check(sim:saw('hook target missing: StartNewRun'), 'missing hook targets are logged')
	end
end

-- 2. Joiner dies, then host clears: host wins as the survivor.
local mutate = os.getenv('MUTATE')
local mutations = mutate and { [mutate] = true } or {}
-- The guest deliberately diverges: other door, and its in-room actions use a
-- different amount of RNG (like different crits/procs in the real game).
local host = make('Host', { role = 'host', weapon = 'WeaponAxe', keepsake = 'LowHealthCritKeepsake', rooms = 4, outcome = 'win',
	win_after_opponent_death = true, expect = 'win', expect_reason = 'survivor_finished', mutations = mutations }, 0)
local guest = make('Guest', { role = 'join', weapon = 'WeaponAxe', keepsake = 'LowHealthCritKeepsake', rooms = 4, outcome = 'die', expect = 'lose',
	expect_reason = 'survivor_finished', door_pick = 'highest', mutations = mutations }, progress_b, 7)

local function read(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

local deadline = socket.gettime() + 60
while socket.gettime() < deadline do
	host:frame()
	guest:frame()
	if read(work .. '/Host/result.txt') and read(work .. '/Guest/result.txt') then break end
	socket.sleep(0.01)
end

for _, name in ipairs({ 'Host', 'Guest' }) do
	local res = read(work .. '/' .. name .. '/result.txt') or 'RESULT: FAIL (no result file)'
	print('--- ' .. name .. ' bot\n' .. res)
	check(res:find('^RESULT: PASS') ~= nil, name .. ' bot passed')
end

check(host.wraps.StartNewRun == 1 and guest.wraps.StartNewRun == 1, 'each hook wrapped exactly once')
check(host.G.GameState.LastAwardTrait == 'OriginalKeepsake', 'host loadout restored after the race: ' .. tostring(host.G.GameState.LastAwardTrait))
check(host.G.GameState.LastWeaponUpgradeName.WeaponAxe == 'AxeArmCastAspect', 'host aspect restored after the race')

local ta = read(work .. '/Host/trace.json')
local tb = read(work .. '/Guest/trace.json')
check(ta and tb, 'both bots wrote a room trace')
if ta and tb then
	local a, b = json.decode(ta), json.decode(tb)
	check(a.seed == b.seed, 'same first-room seed: ' .. tostring(a.seed) .. ' vs ' .. tostring(b.seed))
	local same = #a.rooms == #b.rooms
	for i = 1, math.max(#a.rooms, #b.rooms) do
		if a.rooms[i] ~= b.rooms[i] then same = false end
	end
	print('host rooms:  ' .. table.concat(a.rooms, ' > '))
	print('guest rooms: ' .. table.concat(b.rooms, ' > '))
	check(same, 'identical room sequence despite different doors and in-room RNG use')
	local da, db = a.details.rooms or {}, b.details.rooms or {}
	local enc_same = #da == #db and #da > 1
	for i = 1, math.max(#da, #db) do
		local x, y = da[i] or {}, db[i] or {}
		if x.encounter ~= y.encounter or x.enemies ~= y.enemies or x.flipped ~= y.flipped then enc_same = false end
	end
	check(enc_same, 'identical encounters, enemies and mirroring per depth')
end

-- 3. Reload safety: re-running main.lua must not double-wrap.
do
	local env = host.env
	local chunk = assert(loadfile('src/main.lua', 't', env))
	local ok, err = pcall(chunk)
	check(ok, 'hot reload of main.lua runs: ' .. tostring(err or ''))
	check(host.wraps.StartNewRun == 1, 'hot reload did not wrap again')
end

if #failures == 0 then
	print('RESULT: PASS')
	os.exit(0)
end
print('RESULT: FAIL ' .. table.concat(failures, '; '))
os.exit(1)
