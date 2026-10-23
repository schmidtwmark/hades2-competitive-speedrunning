-- Per-race choice log: everything a race run offered and what the racer took
-- (rooms, encounters, doors, boon offers and picks, store stock, purchases),
-- one JSON object per line in <plugins_data>/races/<stamp>-race<id>-<name>.jsonl.
-- Two racers' logs line up by depth (scripts/compare-race-logs.py), which is
-- how seeding drift between them shows. Each line also goes to `sink` (the
-- race server keeps every racer's log per race: scripts/race-report.sh).
-- Pure Lua: file opening, clock and JSON are injected.

local RaceLog = {}
RaceLog.__index = RaceLog

function RaceLog.new(deps)
	local r = setmetatable({}, RaceLog)
	r.dir, r.json, r.now, r.log = deps.dir, deps.json, deps.now, deps.log or function() end
	r.open = deps.open or io.open
	r.sink = deps.sink
	r.path = nil
	r.depth = 0
	return r
end

local function file_safe(s)
	return (tostring(s or 'racer'):gsub('[^%w%-]', '_'))
end

-- Start a log for this race; `info` goes into the first line.
function RaceLog:start(info)
	local stamp = os.date('!%Y%m%d-%H%M%S', math.floor(self.now()))
	self.path = string.format('%s/%s-race%s-%s.jsonl', self.dir, stamp, file_safe(info.race_id), file_safe(info.name))
	self.depth = 0
	self:event('start', info)
	self.log('racelog: writing ' .. self.path)
end

function RaceLog:set_depth(depth)
	self.depth = depth or self.depth
end

-- Append one event. Opened and closed per line so a crash loses nothing.
function RaceLog:event(ev, fields)
	if not self.path then return false end
	local line = { t = math.floor(self.now() * 1000) / 1000, ev = ev, depth = self.depth }
	for k, v in pairs(fields or {}) do line[k] = v end
	if self.sink then pcall(self.sink, line) end
	local ok, text = pcall(self.json.encode, line)
	if not ok then return false end
	local f = self.open(self.path, 'a')
	if not f then return false end
	f:write(text, '\n')
	f:close()
	return true
end

function RaceLog:stop(fields)
	if not self.path then return end
	self:event('end', fields)
	self.path = nil
end

return RaceLog
