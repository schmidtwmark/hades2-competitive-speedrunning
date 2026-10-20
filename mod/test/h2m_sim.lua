-- Offline stand-in for Hell2Modding + a toy Hades II, enough to load the real
-- src/main.lua and let the bot play. It checks our wiring and control flow;
-- it says nothing about the real game's behaviour (that's the bazzite suite).
--
-- The fake game follows the call graph reported from the real scripts:
--   StartOver -> StartNewRun (EquipKeepsake) -> LoadMap -> RandomInit -> StartRoom
--   DestroyRequiredKills -> DoUnlockRoomExits;  LeaveRoom -> RandomSetNextInitSeed -> LoadMap
--   Kill(hero) -> KillHero;  RecordRunCleared sets CurrentRun.Cleared
-- Game code always calls through G.<name> so ModUtil-style wraps apply.

local Sim = {}
Sim.__index = Sim

local function lcg(seed)
	local s = seed % 2147483647
	if s <= 0 then s = s + 2147483646 end
	return function(n)
		s = (s * 48271) % 2147483647
		return s % n
	end
end

local function fake_game(sim, opts)
	local G = {}
	G.thread = function(fn, ...)
		sim.threads[#sim.threads + 1] = { co = coroutine.create(fn), args = { ... } }
	end
	G.wait = function() coroutine.yield() end
	G.GameState = { LastAwardTrait = 'OriginalKeepsake', LastWeaponUpgradeName = { WeaponAxe = 'AxeArmCastAspect' },
		Progress = opts.progress or 0 }
	G.WeaponData = {}
	for _, w in ipairs({ 'WeaponStaffSwing', 'WeaponDagger', 'WeaponTorch', 'WeaponAxe', 'WeaponLob', 'WeaponSuit' }) do
		G.WeaponData[w] = { Name = w }
	end
	G.MapState = { OfferedExitDoors = {} }
	G.CurrentRun = { CurrentRoom = { Name = 'F_Opening01' }, Hero = { Health = 30, MaxHealth = 30, traits = {}, IsDead = true }, RoomHistory = {} }
	G.CurrentHubRoom = { Name = 'Hub_Main' }
	G.NextSeeds = {}
	local rng = lcg(os.time())
	local rng_seed = 0
	local equipped = 'WeaponStaffSwing'

	function G.RandomSetNextInitSeed(args) G.NextSeeds[(args and args.Id) or 1] = (args and args.Seed) or (rng(2147483646) + 1) end
	function G.RandomInit()
		rng_seed = G.NextSeeds[1] or (os.time() + math.random(1000000))
		rng = lcg(rng_seed)
	end
	function G.RandomSynchronize() G.RandomInit() end
	function G.GetGlobalRng() return { seed = rng_seed } end
	function G.GetRarityKey(level) return ({ 'Common', 'Rare', 'Epic' })[level] end
	function G.EquipPlayerWeapon(data) equipped = data.Name end
	function G.GetEquippedWeapon() return equipped end
	function G.HeroHasTrait(name) return G.CurrentRun.Hero.traits[name] ~= nil end
	function G.EquipKeepsake(hero, name, args) hero.traits[name] = (args and args.ForceRarity) or 'Common' end
	function G.GetDisplayName(args) return args.Text end

	function G.StartNewRun(prevRun, args)
		local run = { Hero = { Health = 30, MaxHealth = 30, traits = {} }, RoomHistory = {}, Cleared = false }
		G.CurrentRun = run
		G.EquipKeepsake(run.Hero, G.GameState.LastAwardTrait, {})
		-- Save-dependent RNG draws before the room choice, like GetRandomUnequippedWeapon(prevRun).
		for _ = 1, G.GameState.Progress do rng(100) end
		G.InitializeRewardStores(run)
		run.CurrentRoom = G.ChooseStartingRoom(run, args)
		return run
	end
	function G.InitializeRewardStores(run) run.RewardStores = { first = rng(1000) } end
	function G.ChooseStartingRoom() return { Name = 'F_Opening0' .. (1 + rng(3)) } end
	function G.StartOver(args)
		G.CurrentHubRoom = nil
		local run = G.StartNewRun(G.CurrentRun, args)
		G.wait(0.1)
		G.LoadMap({ Name = run.CurrentRoom.Name, Room = run.CurrentRoom })
	end
	function G.LoadMap(args)
		G.RandomInit()
		local room = args.Room or { Name = args.Name }
		room.Encounter = { Name = 'Generated' .. rng(1000) }
		room.ChosenRewardType = ({ 'Boon', 'MaxHealthDrop', 'RoomMoneyDrop' })[1 + rng(3)]
		G.StartRoom(G.CurrentRun, room)
	end
	function G.StartRoom(run, room)
		run.CurrentRoom = room
		run.RunDepthCache = 1 + #run.RoomHistory
		G.MapState = { OfferedExitDoors = {} }
		for i = 1, 2 do
			local id = 1000 + rng(9000)
			G.MapState.OfferedExitDoors[id] = { ObjectId = id, Room = { Name = 'F_Combat' .. string.format('%02d', rng(20)) } }
		end
		sim.room_starts = sim.room_starts + 1
	end
	-- Encounters start only once the hero reaches the start point (StartTriggerDistance).
	function G.GetIdsByType(args) if args.Name == 'EncounterStartPoint' then return { 4242 } end return {} end
	function G.Teleport(args)
		local room = G.CurrentRun.CurrentRoom
		if args.DestinationId == 4242 and room.Encounter and not room.Encounter.StartTime then
			room.Encounter.StartTime = 1
			G.RequiredKillEnemies = { [1] = { Name = 'Grunt' }, [2] = { Name = 'Grunt' } }
		end
	end
	function G.DestroyRequiredKills()
		G.wait(0.1)
		G.RequiredKillEnemies = {}
		local room = G.CurrentRun.CurrentRoom
		room.Encounter.Completed = true
		room.ExitsUnlocked = true
		G.DoUnlockRoomExits(G.CurrentRun, room)
	end
	function G.DoUnlockRoomExits() end
	function G.LeaveRoom(run, door)
		table.insert(run.RoomHistory, run.CurrentRoom)
		G.RandomSetNextInitSeed()
		G.wait(0.1)
		G.LoadMap({ Name = door.Room.Name, Room = door.Room })
	end
	function G.Kill(victim) if victim == G.CurrentRun.Hero then G.KillHero(victim, {}) end end
	function G.KillHero(victim)
		victim.IsDead = true
		G.wait(0.1)
		G.CurrentHubRoom = { Name = 'Hub_Main' } -- CurrentRun.CurrentRoom keeps the last run room, as in the game
	end
	function G.RecordRunCleared() G.CurrentRun.Cleared = true end
	return G
end

local function fake_modutil(G, sim)
	local loaded_cbs = {}
	local mu = { once_loaded = {}, mod = { Path = {} } }
	function mu.once_loaded.game(cb) loaded_cbs[#loaded_cbs + 1] = cb end
	function mu.mod.Path.Wrap(name, wrapper)
		local base = assert(G[name], 'wrap of missing ' .. name)
		G[name] = function(...) return wrapper(base, ...) end
		sim.wraps[name] = (sim.wraps[name] or 0) + 1
	end
	function mu.fire_game_loaded()
		for _, cb in ipairs(loaded_cbs) do cb() end
		loaded_cbs = {}
	end
	return mu
end

local function imgui_stub()
	local noop = function() end
	local I = setmetatable({}, { __index = function() return noop end })
	I.Begin = function() return true end
	I.Button = function() return false end
	I.MenuItem = function() return false end
	I.IsKeyPressed = function() return false end
	I.InputText = function(_, v) return v, false end
	return I
end

-- opts: { name, data_dir, config_dir, bot = table|nil, game = 'fake'|'empty', progress = n }
function Sim.new(opts)
	local sim = setmetatable({ threads = {}, wraps = {}, room_starts = 0, logs = {}, always = {}, imgui = {}, menu = {} }, Sim)
	sim.name = opts.name
	local G = opts.game == 'empty' and {} or fake_game(sim, opts)
	sim.G = G
	local mu = fake_modutil(G, sim)
	sim.modutil = mu
	local log = function(level) return function(...)
		local parts = {}
		for i, v in ipairs({ ... }) do parts[i] = tostring(v) end
		sim.logs[#sim.logs + 1] = level .. ' ' .. table.concat(parts, ' ')
		if opts.echo then print('[' .. sim.name .. '] ' .. sim.logs[#sim.logs]) end
	end end
	sim.rom = {
		game = G,
		mods = { ['SGG_Modding-ModUtil'] = mu },
		log = { info = log('INFO'), warning = log('WARN'), error = log('ERROR') },
		gui = {
			add_always_draw_imgui = function(fn) sim.always[#sim.always + 1] = fn end,
			add_imgui = function(fn) sim.imgui[#sim.imgui + 1] = fn end,
			add_to_menu_bar = function(fn) sim.menu[#sim.menu + 1] = fn end,
			is_open = function() return false end,
			toggle = function() end,
		},
		ImGui = imgui_stub(),
		ImGuiKey = { F8 = 'F8' },
		ImGuiCond = { FirstUseEver = 4, Always = 1 },
		ImGuiWindowFlags = { NoTitleBar = 1, AlwaysAutoResize = 64, NoFocusOnAppearing = 4096 },
	}
	if opts.bot then
		local f = assert(io.open(opts.data_dir .. '/bot.json', 'w'))
		f:write(opts.json.encode(opts.bot))
		f:close()
	end
	-- Plugin environment: like H2M, lowercase globals are copied, game globals are not.
	local env = {}
	for k, v in pairs(_G) do
		if type(k) == 'string' and k:sub(1, 1):lower() == k:sub(1, 1) then env[k] = v end
	end
	env.rom = sim.rom
	env._PLUGIN = { guid = 'Test-RankedRace', plugins_mod_folder_path = opts.src_dir, plugins_data_mod_folder_path = opts.data_dir,
		config_mod_folder_path = opts.config_dir }
	env._G = env
	sim.env = env
	local chunk = assert(loadfile(opts.src_dir .. '/main.lua', 't', env))
	chunk()
	mu.fire_game_loaded()
	return sim
end

function Sim:frame()
	for _, fn in ipairs(self.always) do fn() end
	for _, fn in ipairs(self.imgui) do fn() end
	local pending = self.threads
	self.threads = {}
	for _, t in ipairs(pending) do
		local ok, err = coroutine.resume(t.co, table.unpack(t.args))
		if not ok then error('[' .. self.name .. '] game thread error: ' .. tostring(err)) end
		if coroutine.status(t.co) ~= 'dead' then
			t.args = {}
			self.threads[#self.threads + 1] = t
		end
	end
end

function Sim:saw(pattern)
	for _, l in ipairs(self.logs) do
		if l:find(pattern) then return true end
	end
	return false
end

return Sim
