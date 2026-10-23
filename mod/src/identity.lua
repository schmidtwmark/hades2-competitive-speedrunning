-- Who the racer is on their store, for their name and a player key that
-- survives reinstalling: Steam (SteamID64 and persona name, from the game's
-- own steam_api64.dll) or Epic (account id and display name, from the Epic
-- launcher's command line). Read-only calls; nothing is changed.
--
-- Steam: the flat API's SteamAPI_SteamUser_v0xx / SteamAPI_SteamFriends_v0xx
-- give the interfaces (exports found through the DLL's PE export table, so no
-- game-build signatures); ISteamUser::GetSteamID is vtable slot 2 and returns
-- its CSteamID through a hidden pointer (as Hades2.exe's own
-- SteamWrapper::GetSteamId calls it), so the 64 bits land in memory and are read
-- as two exact 32-bit words (Lua 5.2 numbers are doubles).
-- Pure helpers (u64_decimal, parse_epic, clean_name) are unit tested offline.

local Identity = {}

-- A 64-bit unsigned number given as two 32-bit words, in decimal, exactly.
function Identity.u64_decimal(hi, lo)
	local limbs = { math.floor(hi / 65536), hi % 65536, math.floor(lo / 65536), lo % 65536 }
	local digits = {}
	repeat
		local rem, left = 0, false
		for i = 1, 4 do
			local cur = rem * 65536 + limbs[i]
			limbs[i] = math.floor(cur / 10)
			rem = cur % 10
			if limbs[i] ~= 0 then left = true end
		end
		digits[#digits + 1] = string.char(48 + rem)
	until not left
	return table.concat(digits):reverse()
end

-- The Epic launcher passes -epicuserid=<hex> and -epicusername=<name>.
function Identity.parse_epic(cmdline)
	if type(cmdline) ~= 'string' then return nil end
	local id = cmdline:match('%-epicuserid=(%x+)')
	local name = cmdline:match('%-epicusername="([^"]*)"') or cmdline:match('%-epicusername=([^%s"]+)')
	if not id then return nil end
	return id:lower(), name
end

-- A display name: no control characters or text-box markup, at most 24
-- characters, never cut inside a UTF-8 sequence. nil if nothing is left.
function Identity.clean_name(name)
	if type(name) ~= 'string' then return nil end
	name = name:gsub('[%c{}@]', ''):gsub('^%s+', ''):gsub('%s+$', '')
	local out, count = {}, 0
	for ch in name:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
		count = count + 1
		if count > 24 then break end
		out[#out + 1] = ch
	end
	name = table.concat(out)
	return name ~= '' and name or nil
end

-- The address of a loaded module's export whose name passes wanted(name).
function Identity.find_export(mem, module, wanted)
	local base = mem.get_module_base_address(module)
	if not base or base:is_null() then return nil end
	local pe = base:add(base:add(0x3C):get_dword())
	if pe:get_dword() ~= 0x4550 then return nil end -- "PE\0\0"
	local dir = pe:add(0x88):get_dword() -- PE32+ DataDirectory[EXPORT].VirtualAddress
	if dir == 0 then return nil end
	local exp = base:add(dir)
	local count = exp:add(0x18):get_dword()
	local funcs = base:add(exp:add(0x1C):get_dword())
	local names = base:add(exp:add(0x20):get_dword())
	local ords = base:add(exp:add(0x24):get_dword())
	for i = 0, count - 1 do
		local name = base:add(names:add(i * 4):get_dword()):get_string()
		if wanted(name) then
			local ord = ords:add(i * 2):get_word()
			return base:add(funcs:add(ord * 4):get_dword()), name
		end
	end
	return nil
end

-- A pointer object for an address (Hell2Modding's rom.memory.pointer; sol2's
-- usertype constructor is Type.new(addr)).
local function ptr(rom, addr)
	local P = rom.memory.pointer or rom.pointer
	local ok, p = pcall(P.new, addr)
	if ok and p and p.get_dword then return p end
	return P:new(addr)
end

local function versioned(prefix)
	return function(name) return name:match('^' .. prefix .. '%d+$') ~= nil end
end

-- { platform = 'steam', id = '7656...', name = 'persona' }, or nil and why.
function Identity.steam(rom)
	local _ = _ENV -- rom.memory finds the calling mod through _ENV
	local mem, G = rom.memory, rom.game
	local user_fn = Identity.find_export(mem, 'steam_api64.dll', versioned('SteamAPI_SteamUser_v'))
	if not user_fn then return nil, 'no SteamAPI_SteamUser export' end
	local user = G[mem.dynamic_call('uint64_t', {}, user_fn)]()
	if type(user) ~= 'number' or user == 0 then return nil, 'Steam is not running for this game' end
	local this = ptr(rom, user)
	local get_id = this:deref():add(0x10):deref() -- ISteamUser vtable slot 2: GetSteamID
	local buf = mem.allocate(16)
	buf:set_qword(0)
	G[mem.dynamic_call('uint64_t', { 'uint64_t', 'uint64_t' }, get_id)](user, buf:get_address())
	local lo, hi = buf:get_dword(), buf:add(4):get_dword()
	mem.free(buf)
	if lo == 0 then return nil, 'no Steam user logged in' end
	local out = { platform = 'steam', id = Identity.u64_decimal(hi, lo) }
	local friends_fn = Identity.find_export(mem, 'steam_api64.dll', versioned('SteamAPI_SteamFriends_v'))
	local name_fn = Identity.find_export(mem, 'steam_api64.dll',
		function(n) return n == 'SteamAPI_ISteamFriends_GetPersonaName' end)
	if friends_fn and name_fn then
		local friends = G[mem.dynamic_call('uint64_t', {}, friends_fn)]()
		if type(friends) == 'number' and friends ~= 0 then
			local str = G[mem.dynamic_call('uint64_t', { 'uint64_t' }, name_fn)](friends)
			if type(str) == 'number' and str ~= 0 then out.name = Identity.clean_name(ptr(rom, str):get_string()) end
		end
	end
	return out
end

-- { platform = 'epic', id = '<hex>', name = 'display name' }, or nil and why.
function Identity.epic(rom)
	local _ = _ENV
	local mem, G = rom.memory, rom.game
	local fn = Identity.find_export(mem, 'kernel32.dll', function(n) return n == 'GetCommandLineA' end)
	if not fn then return nil, 'no GetCommandLineA' end
	local addr = G[mem.dynamic_call('uint64_t', {}, fn)]()
	if type(addr) ~= 'number' or addr == 0 then return nil, 'no command line' end
	local id, name = Identity.parse_epic(ptr(rom, addr):get_string())
	if not id then return nil, 'not launched by Epic' end
	return { platform = 'epic', id = id, name = Identity.clean_name(name) }
end

-- The store identity, trying Steam then Epic; never throws.
function Identity.read(rom, log)
	log = log or function() end
	local mem = rom and rom.memory
	if not (mem and mem.get_module_base_address and mem.allocate and (mem.pointer or rom.pointer)) then
		log('identity: none (this Hell2Modding has no rom.memory pointers)')
		return nil
	end
	local why = {}
	for _, kind in ipairs({ 'steam', 'epic' }) do
		local ok, who, err = pcall(Identity[kind], rom)
		if ok and who then return who end
		why[#why + 1] = kind .. ': ' .. tostring(ok and err or who)
	end
	log('identity: none (' .. table.concat(why, '; ') .. ')')
	return nil
end

return Identity
