-- Read-only reader for a Hades II save (ProfileN.sav), so the competitive
-- profile can start from the racer's own Arcana loadouts. Nothing here ever
-- opens a save for writing.
--
-- Format (build 25481925, save version 18): "SGB1", checksum u32, version
-- u32, timestamp u64, location string, five u32 and two u8, a count of
-- strings, two map names, then a u32 length and an LZ4 block holding the Lua
-- state in luabins form (one table: GameState, CurrentRun, MapState, ...).
-- Strings are a u32 length and bytes; numbers are little endian.

local SaveFile = {}

local byte, char, concat = string.byte, string.char, table.concat
local unpack = table.unpack or unpack

local function u32(s, p)
	local a, b, c, d = byte(s, p, p + 3)
	if not d then error('save truncated at ' .. p, 0) end
	return a + b * 256 + c * 65536 + d * 16777216
end

-- The compressed Lua state's offset and length in a save file's contents.
function SaveFile.block(s)
	if s:sub(1, 4) ~= 'SGB1' then return nil, 'not a Hades II save' end
	local version = u32(s, 9)
	if version ~= 18 then return nil, 'unknown save version ' .. version end
	local p = 21
	local function skip_string() p = p + 4 + u32(s, p) end
	skip_string() -- location
	p = p + 5 * 4 + 2
	local n = u32(s, p)
	p = p + 4
	for _ = 1, n do skip_string() end
	skip_string() -- current map
	skip_string() -- next map
	local len = u32(s, p)
	if p + 4 + len - 1 > #s then return nil, 'save truncated' end
	return p + 4, len
end

-- LZ4 block decompression of s[from .. from + len - 1] into a string.
function SaveFile.lz4(s, from, len)
	local out, n = {}, 0
	local i, stop = from, from + len
	while i < stop do
		local token = byte(s, i)
		i = i + 1
		local lit = math.floor(token / 16)
		if lit == 15 then
			repeat
				local b = byte(s, i)
				i = i + 1
				lit = lit + b
			until b ~= 255
		end
		-- Literals, a few thousand bytes at a time (unpack's stack limit).
		local j = i
		while j < i + lit do
			local k = math.min(j + 4095, i + lit - 1)
			local bytes = { byte(s, j, k) }
			for x = 1, #bytes do out[n + x] = bytes[x] end
			n = n + #bytes
			j = k + 1
		end
		i = i + lit
		if i >= stop then break end
		local lo, hi = byte(s, i, i + 1)
		local offset = lo + hi * 256
		i = i + 2
		local ml = token % 16
		if ml == 15 then
			repeat
				local b = byte(s, i)
				i = i + 1
				ml = ml + b
			until b ~= 255
		end
		ml = ml + 4
		if offset == 0 or offset > n then error('bad LZ4 offset at ' .. i, 0) end
		local from_n = n - offset
		for x = 1, ml do out[n + x] = out[from_n + x] end
		n = n + ml
	end
	local parts = {}
	for x = 1, n, 4096 do parts[#parts + 1] = char(unpack(out, x, math.min(x + 4095, n))) end
	return concat(parts)
end

-- IEEE 754 double from 8 little-endian bytes.
local function double(s, p)
	local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, p, p + 7)
	local sign = b8 >= 128 and -1 or 1
	local exp = (b8 % 128) * 16 + math.floor(b7 / 16)
	local mant = ((((((b7 % 16) * 256 + b6) * 256 + b5) * 256 + b4) * 256 + b3) * 256 + b2) * 256 + b1
	if exp == 0 then
		if mant == 0 then return sign * 0 end
		return sign * mant * 2 ^ -1074
	elseif exp == 2047 then
		return mant == 0 and sign * math.huge or 0 / 0
	end
	return sign * (1 + mant / 2 ^ 52) * 2 ^ (exp - 1023)
end

-- Decodes luabins data. want(path) says whether to build the value at a key
-- path (a list of keys from the top table); everything else is only skipped.
-- Returns the decoded values as a list.
function SaveFile.luabins(s, want)
	local p = 1
	local path = {}
	local value
	local function key_string(k) return type(k) == 'number' and k or tostring(k) end
	function value(build)
		local tag = s:sub(p, p)
		p = p + 1
		if tag == '-' then return nil
		elseif tag == '0' then return false
		elseif tag == '1' then return true
		elseif tag == 'N' then
			p = p + 8
			return build and double(s, p - 8) or 0
		elseif tag == 'S' then
			local len = u32(s, p)
			p = p + 4 + len
			return build and s:sub(p - len, p - 1) or ''
		elseif tag == 'T' then
			local count = u32(s, p) + u32(s, p + 4)
			p = p + 8
			local t = build and {} or nil
			for _ = 1, count do
				local k = value(true)
				path[#path + 1] = key_string(k)
				local keep = build and (want == nil or want(path))
				local v = value(keep)
				path[#path] = nil
				if keep and k ~= nil then t[k] = v end
			end
			return t
		end
		error('bad luabins tag ' .. string.format('%q', tag) .. ' at ' .. (p - 1), 0)
	end
	local n = byte(s, 1)
	p = 2
	local out = {}
	for i = 1, n do out[i] = value(true) end
	return out
end

-- The parts of GameState the competitive profile takes from a save.
SaveFile.LOADOUT_KEYS = { MetaUpgradeState = true, SavedMetaUpgradeLayouts = true, MetaUpgradeLayoutsArt = true,
	CurrentMetaUpgradeLayout = true, EquippedFamiliar = true, LastWeaponUpgradeName = true }

-- Only the top table, its GameState, and the loadout keys under it.
local function want_loadout(path)
	if path[1] ~= 'GameState' then return false end
	return path[2] == nil or SaveFile.LOADOUT_KEYS[path[2]] == true
end

-- The racer's loadout from a save file's contents, in Profile.capture_loadout's
-- form, or nil and why. layouts_out: Profile.layouts_out.
function SaveFile.loadout(contents, layouts_out)
	local from, len = SaveFile.block(contents)
	if not from then return nil, len end
	local state = SaveFile.luabins(SaveFile.lz4(contents, from, len), want_loadout)[1]
	local GS = type(state) == 'table' and state.GameState
	if type(GS) ~= 'table' then return nil, 'no GameState in the save' end
	local out = { arcana = {}, aspects = {}, familiar = GS.EquippedFamiliar }
	for name, st in pairs(GS.MetaUpgradeState or {}) do
		if type(st) == 'table' and st.Equipped then out.arcana[#out.arcana + 1] = name end
	end
	table.sort(out.arcana)
	for weapon, aspect in pairs(GS.LastWeaponUpgradeName or {}) do out.aspects[weapon] = aspect end
	out.layouts, out.layout_art = layouts_out(GS.SavedMetaUpgradeLayouts, GS.MetaUpgradeLayoutsArt)
	out.layout = GS.CurrentMetaUpgradeLayout
	return out
end

-- Reads one save file (read-only). Returns the loadout, or nil and why.
function SaveFile.read_loadout(path, layouts_out)
	local f = io.open(path, 'rb')
	if not f then return nil, 'no save at ' .. tostring(path) end
	local contents = f:read('*a')
	f:close()
	local ok, res, err = pcall(SaveFile.loadout, contents, layouts_out)
	if not ok then return nil, res end
	return res, err
end

return SaveFile
