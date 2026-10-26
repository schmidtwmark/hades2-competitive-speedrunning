-- Region splits for a race run, compared with the racer's personal best.
--
-- A region is a room name's biome letter (F_Combat03 -> F; Chaos_01, the
-- Crossroads and Dream_Intro have none and never split). Leaving a region
-- (the first room of the next one) is that region's split; the clear is the
-- last. Splits are race times (seconds since GO). Underworld and Surface
-- name their regions; the Dream Dive's biomes come in a random order, so
-- there they are Region 1, 2, 3, 4. The PB is the cleared run with the best
-- total, kept per route by main.lua (pb.json).

local Splits = {}
Splits.__index = Splits

Splits.NAMES = {
	F = 'Erebus', G = 'Oceanus', H = 'Fields of Mourning', I = 'Tartarus',
	N = 'Ephyra', O = 'Thessaly', P = 'Olympus', Q = 'Summit',
}

function Splits.region(room_name)
	return type(room_name) == 'string' and room_name:match('^(%u)_') or nil
end

-- pb: { total = seconds, splits = { seconds, ... } } for this route, or nil.
function Splits.new(route, pb)
	return setmetatable({ route = route, pb = type(pb) == 'table' and pb or nil, current = nil, times = {}, names = {} }, Splits)
end

function Splits:name_of(i, region)
	if self.route == 'dream' then return 'Region ' .. i end
	return Splits.NAMES[region] or region
end

-- The split just made: { index, name, time, delta (vs the PB split, or nil) }.
function Splits:record(t)
	local i = #self.times + 1
	self.times[i] = t
	self.names[i] = self:name_of(i, self.current)
	local pb = self.pb and self.pb.splits and self.pb.splits[i]
	self.last = { index = i, name = self.names[i], time = t, delta = type(pb) == 'number' and (t - pb) or nil }
	return self.last
end

-- A room started at race time t; returns the split if this left a region.
function Splits:room(room_name, t)
	local region = Splits.region(room_name)
	if not region or region == self.current then return nil end
	local split
	if self.current then split = self:record(t) end
	self.current = region
	return split
end

-- The split being run toward: { name, time = the PB's time for it }, or nil
-- before the first room, after the clear, or without a PB split for it.
function Splits:target()
	if self.cleared or not self.current then return nil end
	local i = #self.times + 1
	local t = self.pb and self.pb.splits and self.pb.splits[i]
	if type(t) ~= 'number' then return nil end
	return { index = i, name = self:name_of(i, self.current), time = t }
end

-- The race server's best for this route ({ time, splits = { { name, time }, ... } })
-- in our PB form; nil if it has no splits.
function Splits.from_server(best)
	if type(best) ~= 'table' or type(best.splits) ~= 'table' or #best.splits == 0 then return nil end
	local splits, names = {}, {}
	for i, sp in ipairs(best.splits) do
		if type(sp) ~= 'table' or type(sp.time) ~= 'number' then return nil end
		splits[i], names[i] = sp.time, sp.name
	end
	return { total = splits[#splits], splits = splits, names = names }
end

-- The faster of two PB records (either may be nil).
function Splits.better(a, b)
	local ta = type(a) == 'table' and type(a.total) == 'number' and a.total or nil
	local tb = type(b) == 'table' and type(b.total) == 'number' and b.total or nil
	if not ta then return tb and b or nil end
	if not tb then return a end
	return tb < ta and b or a
end

-- The run is cleared at race time t: the last split, and whether it beat the PB.
function Splits:clear(t)
	local split = self:record(t)
	self.cleared = true
	local best = self.pb and self.pb.total
	split.new_pb = type(best) ~= 'number' or t < best
	split.total_delta = type(best) == 'number' and (t - best) or nil
	return split
end

-- What to keep as this route's PB after a clear (nil if it isn't one).
function Splits:pb_record()
	if not (self.cleared and self.last and self.last.new_pb) then return nil end
	local splits = {}
	for i, t in ipairs(self.times) do splits[i] = t end
	return { total = self.times[#self.times], splits = splits, names = self.names }
end

-- "-0:05.31" / "+1:02.00" for a delta in seconds.
function Splits.fmt_delta(d)
	local sign = d < 0 and '-' or '+'
	d = math.abs(d)
	local m = math.floor(d / 60)
	return string.format('%s%d:%05.2f', sign, m, d - m * 60)
end

return Splits
