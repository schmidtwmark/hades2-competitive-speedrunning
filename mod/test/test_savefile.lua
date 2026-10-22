local T = require('test.lib')
local SaveFile = T.load('savefile.lua')
local Profile = T.load('profile.lua')

-- Writers for a synthetic save: luabins values, an LZ4 block, the SGB1 header.
local function u32(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function str(s) return u32(#s) .. s end
local function double(x)
	-- Little-endian IEEE 754 for the small integers and halves used here.
	if x == 0 then return string.rep('\0', 8) end
	local sign = x < 0 and 128 or 0
	x = math.abs(x)
	local e = math.floor(math.log(x) / math.log(2))
	local mant = (x / 2 ^ e - 1) * 2 ^ 52
	local bytes = {}
	for i = 1, 6 do bytes[i] = mant % 256; mant = math.floor(mant / 256) end
	local exp = e + 1023
	bytes[7] = mant % 16 + (exp % 16) * 16
	bytes[8] = math.floor(exp / 16) + sign
	return string.char((table.unpack or unpack)(bytes))
end
local function bins(v)
	if v == nil then return '-' end
	if v == true then return '1' end
	if v == false then return '0' end
	if type(v) == 'number' then return 'N' .. double(v) end
	if type(v) == 'string' then return 'S' .. str(v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out = { 'T', u32(0), u32(#keys) }
	for _, k in ipairs(keys) do out[#out + 1] = bins(k) .. bins(v[k]) end
	return table.concat(out)
end
-- LZ4 block: everything as literals, except a repeated tail as one match.
local function lz4(data)
	local function lenbytes(n)
		local out = {}
		while n >= 255 do out[#out + 1] = string.char(255); n = n - 255 end
		out[#out + 1] = string.char(n)
		return table.concat(out)
	end
	local lit = #data
	local token = (lit >= 15 and 15 or lit) * 16 + 15 -- match length 15+ follows
	local body = string.char(token) .. (lit >= 15 and lenbytes(lit - 15) or '') .. data
	-- Match: repeat the last 8 bytes 3 times (24 bytes, overlapping copy).
	body = body .. string.char(8, 0) .. lenbytes(24 - 4 - 15)
	-- Final literals: the last block must end in literals.
	return body .. string.char(0x10) .. 'Z', data .. string.rep(data:sub(-8), 3) .. 'Z'
end
local function save_file(state)
	local payload = string.char(1) .. bins(state)
	local block, plain = lz4(payload)
	local header = 'SGB1' .. u32(0) .. u32(18) .. string.rep('\0', 8) .. str('Location_Home')
		.. string.rep('\0', 22) .. u32(2) .. str('WeaponAxe') .. str('DevSaveName=test') .. str('I_Boss01') .. str('Hub_Main')
	return header .. u32(#block) .. block, plain
end

local STATE = {
	GameState = {
		MetaUpgradeState = { BonusHealth = { Equipped = true, Level = 4 }, CastBuff = { Equipped = true }, Dash = { Level = 2 } },
		SavedMetaUpgradeLayouts = { [1] = { BonusHealth = true, CastBuff = true }, [2] = { Dash = true }, [3] = {} },
		MetaUpgradeLayoutsArt = { [2] = 5 },
		CurrentMetaUpgradeLayout = 1,
		EquippedFamiliar = 'RavenFamiliar',
		LastWeaponUpgradeName = { WeaponAxe = 'AxeRallyAspect' },
		LastAwardTrait = 'TempHammerKeepsake',
		Unrelated = { Deep = { -2.5, 1e10 } },
	},
	CurrentRun = { Hero = { Health = 30 } },
}

T.case('save file: header, LZ4 (with an overlapping match) and luabins decode', function()
	local file, plain = save_file(STATE)
	local from, len = SaveFile.block(file)
	T.truthy(from, len)
	T.eq(SaveFile.lz4(file, from, len), plain)
	local all = SaveFile.luabins(plain:sub(1, -26)) -- without the LZ4 test tail
	T.eq(all[1].GameState.Unrelated.Deep[1], -2.5)
	T.eq(all[1].GameState.Unrelated.Deep[2], 1e10)
	T.eq(all[1].CurrentRun.Hero.Health, 30)
	T.eq(SaveFile.block('nope'), nil)
end)

T.case('save file: the loadout (Arcana, layouts, familiar, aspects), skipping the rest', function()
	local file = save_file(STATE)
	local l = assert(SaveFile.loadout(file, Profile.layouts_out))
	T.eq(table.concat(l.arcana, ','), 'BonusHealth,CastBuff')
	T.eq(l.familiar, 'RavenFamiliar')
	T.eq(l.aspects.WeaponAxe, 'AxeRallyAspect')
	T.eq(table.concat(l.layouts['1'], ','), 'BonusHealth,CastBuff')
	T.eq(#l.layouts['3'], 0)
	T.eq(l.layout_art['2'], 5)
	T.eq(l.layout, 1)
	local nope, why = SaveFile.loadout('SGB1' .. u32(0) .. u32(17), Profile.layouts_out)
	T.eq(nope, nil)
	T.truthy(tostring(why):find('version 17'))
end)

T.case('profile: Arcana come from the save until competitive remembers its own', function()
	local from_save = { arcana = { 'A' }, layouts = { ['1'] = { 'A' } }, layout = 1, familiar = 'Cat', aspects = { W = 'X' } }
	-- Remembered before 0.5.5 (no layouts): the save's Arcana, the remembered familiar.
	local m = Profile.merge_loadouts({ arcana = { 'B' }, familiar = 'Frog' }, from_save)
	T.eq(m.arcana[1], 'A')
	T.eq(m.familiar, 'Frog')
	T.eq(m.aspects.W, 'X')
	-- Remembered with layouts: all of competitive's Arcana.
	m = Profile.merge_loadouts({ arcana = { 'B' }, layouts = { ['2'] = { 'B' } }, layout = 2 }, from_save)
	T.eq(m.arcana[1], 'B')
	T.eq(m.layout, 2)
	T.eq(m.layouts['1'], nil)
	T.eq(Profile.merge_loadouts(nil, from_save), from_save)
	T.eq(Profile.merge_loadouts(from_save, nil), from_save)
end)

T.case('profile: layouts survive capture -> JSON-safe -> apply', function()
	local G = { MetaUpgradeCardData = { A = { Cost = 1 }, B = { Cost = 2 } } }
	function G.GetMaxMetaUpgradeCost() return 30 end
	local GS = { MetaUpgradeState = { A = { Unlocked = true, Equipped = true }, B = { Unlocked = true } },
		SavedMetaUpgradeLayouts = { [1] = { A = true }, [4] = { A = true, B = true } }, MetaUpgradeLayoutsArt = { [4] = 3 },
		CurrentMetaUpgradeLayout = 4, LastWeaponUpgradeName = {}, FamiliarsUnlocked = {} }
	local out = Profile.capture_loadout(GS)
	T.eq(table.concat(out.layouts['4'], ','), 'A,B')
	local GS2 = { MetaUpgradeState = { A = { Unlocked = true }, B = { Unlocked = true } }, LastWeaponUpgradeName = {},
		FamiliarsUnlocked = {} }
	Profile.apply_loadout(G, GS2, out)
	T.truthy(GS2.SavedMetaUpgradeLayouts[4].A and GS2.SavedMetaUpgradeLayouts[4].B)
	T.eq(GS2.MetaUpgradeLayoutsArt[4], 3)
	T.eq(GS2.CurrentMetaUpgradeLayout, 4)
	T.truthy(GS2.MetaUpgradeState.A.Equipped)
end)
