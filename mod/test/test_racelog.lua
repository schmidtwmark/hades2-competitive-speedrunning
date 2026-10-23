local T = require('test.lib')
local json = T.load('json.lua')
local RaceLog = T.load('racelog.lua')

-- In-memory files.
local function fs()
	local files = {}
	local function open(path, mode)
		assert(mode == 'a')
		files[path] = files[path] or {}
		local buf = files[path]
		return { write = function(_, ...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end, close = function() end }
	end
	return files, open
end

T.case('racelog: one JSON line per event, tagged with the depth', function()
	local files, open = fs()
	local t = 1792550000.5
	local rl = RaceLog.new({ dir = 'races', json = json, now = function() return t end, open = open })
	T.eq(rl:event('room', {}), false, 'nothing before start')
	rl:start({ race_id = 7, seed = 42, name = 'Mark PC' })
	T.truthy(rl.path:find('^races/%d+%-%d+%-race7%-Mark_PC%.jsonl$'), rl.path)
	rl:set_depth(3)
	rl:event('doors', { doors = { { room = 'F_Combat01', reward = 'Boon' } } })
	rl:stop({ reason = 'completed_first' })
	T.eq(rl:event('room', {}), false, 'nothing after stop')
	local lines = {}
	for line in table.concat(files[next(files)]):gmatch('[^\n]+') do lines[#lines + 1] = json.decode(line) end
	T.eq(#lines, 3)
	T.eq(lines[1].ev, 'start')
	T.eq(lines[1].seed, 42)
	T.eq(lines[2].depth, 3)
	T.eq(lines[2].doors[1].reward, 'Boon')
	T.eq(lines[3].ev, 'end')
	T.eq(lines[3].reason, 'completed_first')
end)

T.case('racelog: every line also goes to the sink (the server), which can fail harmlessly', function()
	local files, open = fs()
	local sent = {}
	local rl = RaceLog.new({ dir = 'races', json = json, now = function() return 5 end, open = open,
		sink = function(line) sent[#sent + 1] = line end })
	rl:start({ race_id = 2, seed = 9, name = 'Mel' })
	rl:set_depth(1)
	rl:event('room', { name = 'F_Opening01' })
	T.eq(#sent, 2)
	T.eq(sent[2].ev, 'room')
	T.eq(sent[2].depth, 1)
	T.eq(sent[2].name, 'F_Opening01')
	rl.sink = function() error('offline') end
	T.eq(rl:event('doors', {}), true, 'the file still gets the line')
end)
