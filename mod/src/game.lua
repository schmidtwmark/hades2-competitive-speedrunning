-- Game layer: everything that touches Hades II's own Lua. Hooks are installed
-- once per game launch through ModUtil and dispatch to the current Game object,
-- so a hot reload swaps behaviour without double-wrapping.
--
-- Function names come from the game's Content/Scripts (RunLogic, RoomLogic,
-- DeathLoopLogic, RandomLogic, BountyLogic). See NOTES.md for sources. Every
-- name is checked before use: a game patch that renames one disables that
-- feature and logs it instead of crashing.

local Game = {}
Game.__index = Game

local HUB_MAPS = { Hub_Main = true, Hub_PreRun = true }

-- Default (first) aspect per weapon, WeaponUpgradeData ScreenData order.
local BASE_ASPECT = {
	WeaponStaffSwing = 'BaseStaffAspect',
	WeaponDagger = 'DaggerBackstabAspect',
	WeaponTorch = 'TorchSpecialDurationAspect',
	WeaponAxe = 'AxeRecoveryAspect',
	WeaponLob = 'LobAmmoBoostAspect',
	WeaponSuit = 'BaseSuitAspect',
}

-- Both racers get the same keepsake rank regardless of their save.
local KEEPSAKE_LEVEL = 3

local HOOKS = { 'StartNewRun', 'InitializeRewardStores', 'ChooseStartingRoom', 'StartRoom', 'KillHero', 'RecordRunCleared',
	'EquipKeepsake', 'DoUnlockRoomExits', 'StartNewGame', 'RequestSave', 'DeathAreaSwitchRoom', 'ValidateCheckpoint',
	'InvalidateCheckpoint', 'LeaveRoom', 'RandomSetNextInitSeed', 'ChooseEncounter', 'RunShopGeneration', 'ChooseNextRoomData',
	'CreateRoom', 'ChooseRoomReward', 'GetNextSpawn', 'HandleNextSpawn', 'Load' }

function Game.new(deps)
	local g = setmetatable({}, Game)
	g.rom = deps.rom
	g.G = deps.rom.game
	g.modutil = deps.modutil
	g.log = deps.log
	g.now = deps.now
	g.profile = deps.profile
	g.client = nil
	g.race = nil          -- race whose run is (or was) live: { race, run, rooms = {} }
	g.launching = nil     -- race being launched (between GO and StartNewRun)
	g.status = nil
	g.last_progress = 0
	g.adv = nil           -- bot room-advance state
	return g
end

-- helpers ----------------------------------------------------------------------

function Game:fn(name)
	local f = self.G and self.G[name]
	if type(f) == 'function' then return f end
	return nil
end

-- Call a game function if it exists; log and return nil if it doesn't or errors.
function Game:call(name, ...)
	local f = self:fn(name)
	if not f then
		self.log('game: missing function ' .. name)
		return nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		self.log('game: ' .. name .. ' failed: ' .. tostring(res))
		return nil
	end
	return res
end

-- Run fn inside a game coroutine (needed for anything that calls wait()).
function Game:spawn(fn, ...)
	local thread = self:fn('thread')
	if not thread then
		self.log('game: no thread() function')
		return false
	end
	thread(fn, ...)
	return true
end

-- In the hub, CurrentRun.CurrentRoom still names the last run room; the hub
-- map lives in CurrentHubRoom (set on arrival, cleared by StartOver).
function Game:current_map()
	local hub = self.G.CurrentHubRoom
	if hub and hub.Name then return hub.Name end
	local run = self.G.CurrentRun
	return run and run.CurrentRoom and run.CurrentRoom.Name or nil
end

function Game:in_hub()
	return HUB_MAPS[self:current_map() or ''] == true
end

-- In the hub the previous run's hero stays IsDead = true (nothing resets it),
-- so "ready" only means: a save is loaded and we're standing in the hub.
function Game:ready_for_race()
	return self.G.GameState ~= nil and self.G.CurrentRun ~= nil and self:in_hub()
end

-- In a live run (not hub, hero alive): somewhere the bot can die to get home.
function Game:in_live_run()
	local run = self.G.CurrentRun
	return run ~= nil and not self:in_hub() and run.Hero ~= nil and not run.Hero.IsDead and self:current_map() ~= nil
end

function Game:race_run_live()
	local r = self.race
	return r ~= nil and r.run ~= nil and r.run == self.G.CurrentRun and not r.finished
end

function Game:display_name(id)
	if not id or id == '' then return '-' end
	local f = self:fn('GetDisplayName')
	if f then
		local ok, name = pcall(f, { Text = id })
		if ok and type(name) == 'string' and name ~= '' and name ~= id then return name end
	end
	return id
end

function Game:status_line()
	if self.status then return self.status end
	if self.client and self.client:phase() == 'ready_check' then
		if not self:in_hub() then return 'Go to the Crossroads: races start from the hub.' end
		if self:competitive_active() then
			local w = self.client.state.vote_results.weapon
			return 'Set your Arcana, familiar and ' .. self:display_name(w and w.selected or '') .. ' aspect, then press Ready.'
		end
	end
	return nil
end

-- hooks ------------------------------------------------------------------------------

function Game:install_hooks()
	local G = self.G
	local reg = G.RankedRaceHooks
	if reg then
		-- Hot reload: hooks already wrap the game functions; point them at us.
		reg.game = self
		return
	end
	reg = { game = self, installed = {} }
	G.RankedRaceHooks = reg
	local mu = self.modutil
	if not (mu and mu.once_loaded and mu.once_loaded.game) then
		self.log('game: ModUtil not available; race hooks disabled')
		return
	end
	local log = self.log
	mu.once_loaded.game(function()
		-- The plugin table exposes `mod` in current ModUtil; the game global is the classic API.
		local api = (mu.mod and mu.mod.Path and mu.mod) or G.ModUtil
		if not (api and api.Path and api.Path.Wrap) then
			log('game: ModUtil.Path.Wrap not found; race hooks disabled')
			return
		end
		for _, name in ipairs(HOOKS) do
			if type(G[name]) ~= 'function' then
				log('game: hook target missing: ' .. name)
			else
				local method = 'hook_' .. name
				api.Path.Wrap(name, function(base, ...)
					local game = reg.game
					if game and game[method] then return game[method](game, base, ...) end
					return base(...)
				end)
				reg.installed[name] = true
			end
		end
		log('game: hooks installed')
	end)
end

-- Test diagnostics: log every call of the named game functions with a short
-- Lua traceback (bot.json "trace_functions"). Logging only.
function Game:install_tracers(names)
	local mu, G, log = self.modutil, self.G, self.log
	if not (mu and mu.once_loaded and type(names) == 'table') then return end
	mu.once_loaded.game(function()
		local api = (mu.mod and mu.mod.Path and mu.mod) or G.ModUtil
		for _, name in ipairs(names) do
			if type(G[name]) == 'function' then
				api.Path.Wrap(name, function(base, ...)
					local tb = debug.traceback('', 2):gsub('\n%s*', ' <- '):sub(1, 600)
					log('trace: ' .. name .. tb)
					return base(...)
				end)
			else
				log('trace: no function ' .. tostring(name))
			end
		end
	end)
end

function Game:hooks_installed()
	local reg = self.G.RankedRaceHooks
	return reg and reg.installed or {}
end

-- Per-depth seeds -------------------------------------------------------------------
-- Inside a race run every random decision that shapes a room (which room, its
-- encounter and enemies, mirroring, shop stock, door rewards) is re-seeded
-- from (race seed, tag, depth, ...), so it can't depend on what the player did
-- earlier. Choices still matter where the game reads run state (e.g. which
-- gods you've taken), which is intended.

local SEED_MOD = 2147483629

local function unpack_results(results)
	return (table.unpack or unpack)(results, 2, #results)
end

local function hash_seed(...)
	local h = 7
	for i = 1, select('#', ...) do
		local part = tostring((select(i, ...)))
		for j = 1, #part do h = (h * 31 + part:byte(j)) % SEED_MOD end
		h = (h * 31 + 59) % SEED_MOD
	end
	return h + 1
end
Game.hash_seed = hash_seed

function Game:race_seed()
	if self.launching then return self.launching.seed end
	if self:race_run_live() then return self.race.race.seed end
	return nil
end

function Game:race_depth()
	local run = self.G.CurrentRun
	if not run then return 0 end
	return run.RunDepthCache or (1 + #(run.RoomHistory or {}))
end

-- Seed the global RNG from the race seed and tags; leave NextSeeds alone so the
-- game's own RandomSynchronize calls keep using the room seed.
function Game:reseed(...)
	local seed = self:race_seed()
	if not seed or (self.mutations and self.mutations.no_depth_seed) then return false end
	local G = self.G
	local s = hash_seed(seed, ...)
	local old = G.NextSeeds[1]
	G.NextSeeds[1] = s
	G.RandomInit(1)
	G.NextSeeds[1] = old
	return true
end

function Game:hook_LeaveRoom(base, run, door)
	if self:race_seed() and door and door.Room and run then
		local next_room, depth = door.Room, self:race_depth() + 1
		-- Mirroring: the game uses RandomChance on the current room's RNG unless
		-- the room geometry decides it. Decide it from the seed instead.
		local cur = run.CurrentRoom
		local geometric = cur and cur.ExitDirection ~= nil and next_room.EntranceDirection ~= nil
			and next_room.EntranceDirection ~= 'LeftRight'
		if next_room.Flipped == nil and not geometric and not (self.mutations and self.mutations.no_depth_seed) then
			local roll = (hash_seed(self:race_seed(), 'flip', depth) % 10000) / 10000
			next_room.Flipped = roll < (next_room.FlipHorizontalChance or 0.5)
		end
		self.leaving_depth = depth
	end
	return base(run, door)
end

-- LeaveRoom queues the next room's seed with a draw from the current RNG; use
-- a per-depth seed instead.
function Game:hook_RandomSetNextInitSeed(base, args)
	if args == nil and self.leaving_depth and self:race_seed() and not (self.mutations and self.mutations.no_depth_seed) then
		local depth = self.leaving_depth
		self.leaving_depth = nil
		return base({ Seed = hash_seed(self:race_seed(), 'room', depth) })
	end
	return base(args)
end

function Game:hook_ChooseEncounter(base, run, room, args)
	self:reseed('encounter', self:race_depth(), room and room.Name, args and args.LegalEncounters and 'cage' or 'main')
	return base(run, room, args)
end

function Game:hook_RunShopGeneration(base, room)
	self:reseed('shop', self:race_depth(), room and room.Name)
	return base(room)
end

-- Every generic exit door at a depth leads to the same next room; each door
-- keeps its own reward (chosen later per door).
function Game:hook_ChooseNextRoomData(base, run, args, other_doors)
	local ctx = self.unlock_ctx
	if not (ctx and self:race_seed()) or args ~= nil or (self.mutations and self.mutations.no_depth_seed) then
		return base(run, args, other_doors)
	end
	if ctx.room_data then return ctx.room_data end
	self:reseed('route', ctx.depth)
	ctx.room_data = base(run, args, other_doors)
	return ctx.room_data
end

function Game:hook_CreateRoom(base, room_data, args)
	if self.unlock_ctx and room_data then self:reseed('create', self.unlock_ctx.depth, room_data.Name) end
	return base(room_data, args)
end

-- Reward picks offset the RNG by the reroll count; spent rerolls must not shift
-- later rooms, so use the count the run started with.
function Game:hook_ChooseRoomReward(base, run, room, store, previous, args)
	if self:race_seed() and run and self.race and self.race.base_rerolls then
		local saved = run.NumRerolls
		run.NumRerolls = self.race.base_rerolls
		local ok, res = pcall(base, run, room, store, previous, args)
		run.NumRerolls = saved
		if not ok then error(res, 0) end
		return res
	end
	return base(run, room, store, previous, args)
end

-- Spawns happen mid-combat on the same RNG that crits and procs use. Make the
-- spawn decisions (which enemy next, enemy-set swaps, spawn point shuffle)
-- depend only on (depth, encounter, spawn #), then resume the combat stream
-- from a value drawn before, so combat rolls don't become predictable.
-- Spawn *points* still depend on where the hero stands (eligibility checks).
function Game:spawn_seeded(base, tag, encounter, ...)
	if not (self:race_seed() and type(encounter) == 'table') or (self.mutations and self.mutations.no_depth_seed) then
		return base(encounter, ...)
	end
	local G = self.G
	encounter.RaceSpawnCounts = encounter.RaceSpawnCounts or {}
	local n = (encounter.RaceSpawnCounts[tag] or 0) + 1
	encounter.RaceSpawnCounts[tag] = n
	local resume = G.RandomInt(1, 1000000000)
	self:reseed(tag, self:race_depth(), encounter.Name, n)
	local results = { pcall(base, encounter, ...) }
	self:reseed('resume', resume)
	if not results[1] then error(results[2], 0) end
	return unpack_results(results)
end

function Game:hook_GetNextSpawn(base, encounter)
	local spawn_info = self:spawn_seeded(base, 'next', encounter)
	pcall(self.record_spawn, self, spawn_info)
	return spawn_info
end

function Game:hook_HandleNextSpawn(base, encounter, ...)
	return self:spawn_seeded(base, 'spawn', encounter, ...)
end

-- Trace: the order enemies were picked to spawn in, per room.
function Game:record_spawn(spawn_info)
	if not (self.race and self.race.rooms and type(spawn_info) == 'table') then return end
	local entry = self.race.rooms[#self.race.rooms]
	if not entry then return end
	entry.spawns = entry.spawns or {}
	entry.spawns[#entry.spawns + 1] = tostring(spawn_info.Name)
end

-- Seed the global RNG now and queue the same seed for the next map load, so
-- both StartNewRun's choices and the first room's RandomInit are fixed.
function Game:apply_seed(seed)
	if self.mutations and self.mutations.no_seed then return end -- test-only mutation twin
	self:call('RandomSetNextInitSeed', { Seed = seed })
	self:call('RandomSynchronize')
	self:call('RandomSetNextInitSeed', { Seed = seed })
end

function Game:hook_StartNewRun(base, prevRun, args)
	local race = self.launching
	if race then
		local ok, err = pcall(self.apply_seed, self, race.seed)
		if not ok then self.log('game: seeding failed: ' .. tostring(err)) end
	end
	local run = base(prevRun, args)
	if race then
		self.launching = nil
		pcall(self.apply_seed, self, race.seed)
		self.race = { race = race, run = self.G.CurrentRun, rooms = {}, finished = false,
			base_rerolls = self.G.CurrentRun and self.G.CurrentRun.NumRerolls }
		self.log('game: race run created for race ' .. tostring(race.race_id))
	end
	return run
end

-- StartNewRun draws randomness that depends on the save (e.g. the unused-weapon
-- bonus from the previous run) before it builds reward stores and picks the
-- first room. Re-seed right before each of those so both racers match.
function Game:hook_InitializeRewardStores(base, run)
	if self.launching then pcall(self.apply_seed, self, self.launching.seed) end
	return base(run)
end

function Game:hook_ChooseStartingRoom(base, run, args)
	if self.launching then pcall(self.apply_seed, self, self.launching.seed) end
	return base(run, args)
end

function Game:hook_EquipKeepsake(base, hero, traitName, args)
	if self.launching and traitName == self.launching.keepsake then
		args = args or {}
		local rarity = self:call('GetRarityKey', KEEPSAKE_LEVEL)
		if rarity then args.ForceRarity = rarity end
	end
	return base(hero, traitName, args)
end

function Game:hook_StartRoom(base, run, room)
	pcall(self.on_room_start, self, run, room)
	return base(run, room)
end

function Game:on_room_start(run, room)
	if not (self.race and run == self.race.run) then return end
	local rng = self:call('GetGlobalRng')
	local entry = {
		name = room and room.Name,
		biome = room and room.RoomSetName,
		depth = 1 + #(run.RoomHistory or {}),
		seed = rng and rng.seed,
		encounter = room and room.Encounter and room.Encounter.Name,
		reward = room and room.ChosenRewardType,
		flipped = room and room.Flipped,
		enemies = self:encounter_digest(room and room.Encounter),
	}
	local rooms = self.race.rooms
	rooms[#rooms + 1] = entry
	self.log(string.format('game: room %d %s biome=%s seed=%s encounter=%s reward=%s', entry.depth, tostring(entry.name),
		tostring(entry.biome), tostring(entry.seed), tostring(entry.encounter), tostring(entry.reward)))
	if self.client then self.client:report_progress(self:progress(), true) end
end

-- "wave1: A x3, B x2 | wave2: ..." from the generated encounter.
function Game:encounter_digest(encounter)
	if type(encounter) ~= 'table' or type(encounter.SpawnWaves) ~= 'table' then return nil end
	local waves = {}
	for i, wave in ipairs(encounter.SpawnWaves) do
		local spawns = {}
		for _, sp in ipairs(wave.Spawns or {}) do
			spawns[#spawns + 1] = tostring(sp.Name) .. ' x' .. tostring(sp.TotalCount or sp.CountMax or '?')
		end
		table.sort(spawns)
		waves[#waves + 1] = 'w' .. i .. ': ' .. table.concat(spawns, ', ')
	end
	return table.concat(waves, ' | ')
end

function Game:hook_DoUnlockRoomExits(base, run, room)
	if self:race_seed() then self.unlock_ctx = { depth = self:race_depth() } end
	local ok, res = pcall(base, run, room)
	self.unlock_ctx = nil
	if not ok then error(res, 0) end
	self.exits_unlocked_for = room
	pcall(self.record_doors, self, room)
	return res
end

-- Trace: what each offered door leads to (room + reward), sorted by door id.
function Game:record_doors(room)
	if not (self.race and self.race.rooms) then return end
	local entry = self.race.rooms[#self.race.rooms]
	if not entry then return end
	local doors = {}
	for id, door in pairs((self.G.MapState and self.G.MapState.OfferedExitDoors) or {}) do
		if type(door) == 'table' and door.Room then
			doors[#doors + 1] = { id = door.ObjectId or id, room = door.Room.Name, reward = door.Room.ChosenRewardType,
				loot = door.Room.ForceLootName }
		end
	end
	table.sort(doors, function(a, b) return a.id < b.id end)
	entry.doors = doors
end

function Game:hook_KillHero(base, victim, triggerArgs)
	if self:race_run_live() then
		self.race.finished = true
		self.log('game: hero died in race run')
		if self.client then
			self.client:report_progress(self:progress(false), true)
			self.client:report_complete(false)
		end
	end
	return base(victim, triggerArgs)
end

function Game:hook_RecordRunCleared(base, ...)
	local res = base(...)
	local run = self.G.CurrentRun
	if self:race_run_live() and run and run.Cleared and not run.ActiveBounty and not run.IsDreamRun then
		self.race.finished = true
		self.log('game: race run cleared')
		if self.client then self.client:report_complete(true) end
	end
	return res
end

-- competitive mode ------------------------------------------------------------------

-- Called from the title-screen hook. Drops whatever profile state is loaded so
-- the next map load builds a fresh GameState (no real save involved).
function Game:enter_competitive()
	local G = self.G
	G.RankedRaceCompetitive = { requested = true }
	G.GameState = nil
	G.CurrentRun = nil
	self.log('game: entering competitive mode; loading Hub_PreRun without a profile')
	-- LoadMap is a Lua wrapper that wait()s; on the title screen there is no
	-- game coroutine (and no threads to kill), so call the engine directly.
	self:call('LoadMapInternal', { Name = 'Hub_PreRun' })
end

function Game:competitive_active()
	local c = self.G.RankedRaceCompetitive
	return c ~= nil and c.active == true
end

-- With no profile loaded, OnPreThingCreation calls StartNewGame(mapName). In
-- competitive mode build the maxed profile instead of a new save game.
function Game:hook_StartNewGame(base, mapName)
	local c = self.G.RankedRaceCompetitive
	if not (c and c.requested) then return base(mapName) end
	c.requested = false
	local ok, summary = pcall(self.profile.build, self.G)
	if not ok then
		self.log('game: competitive profile build FAILED: ' .. tostring(summary))
		return
	end
	c.active = true
	-- Arrive as if walking in from the Crossroads door (DeathLoopData PreRunExit:
	-- HeroStartPoint 40009 -> HeroEndPoint 40012). Without a walk-in the hero
	-- stands inside the auto-activating exit back to Hub_Main and bounces.
	if mapName == 'Hub_PreRun' and self.G.CurrentRun then
		self.G.CurrentRun.NextHeroStartPoint = 40009
		self.G.CurrentRun.NextHeroEndPoint = 40012
	end
	local parts = {}
	for k, v in pairs(summary) do parts[#parts + 1] = k .. '=' .. tostring(v) end
	table.sort(parts)
	self.log('game: competitive profile built for ' .. tostring(mapName) .. ': ' .. table.concat(parts, ' '))
end

-- The engine calls Load(data) when a real profile is loaded (e.g. PLAY after
-- leaving competitive mode). From then on saves must work normally again.
function Game:hook_Load(base, data)
	local c = self.G.RankedRaceCompetitive
	if c and (c.active or c.requested) then
		self.log('game: real profile loaded; leaving competitive mode')
		c.active, c.requested = false, false
	end
	return base(data)
end

-- Belt and braces on top of IllegalConversationModification: competitive mode never saves.
function Game:hook_RequestSave(base, args)
	if self:competitive_active() then
		if not self.logged_save_skip then
			self.logged_save_skip = true
			self.log('game: competitive mode: save request suppressed')
		end
		return
	end
	return base(args)
end

-- Asserts the competitive profile through the game's own level functions.
-- Returns a list of { name, ok, detail }.
function Game:verify_competitive_profile()
	local G = self.G
	local GS = G.GameState or {}
	local checks = {}
	local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
	check('competitive mode active', self:competitive_active())
	check('saving disabled', GS.IllegalConversationModification == true)
	-- Aspects: every aspect of every weapon at rank 5 (Legendary).
	local min_aspect, aspects = math.huge, 0
	local order = G.ScreenData and G.ScreenData.WeaponUpgradeScreen and G.ScreenData.WeaponUpgradeScreen.DisplayOrder or {}
	for weapon, list in pairs(order) do
		if type(list) == 'table' then
			check('weapon unlocked ' .. weapon, GS.WeaponsUnlocked and GS.WeaponsUnlocked[weapon])
			for _, aspect in ipairs(list) do
				aspects = aspects + 1
				min_aspect = math.min(min_aspect, G.GetWeaponUpgradeLevel(aspect))
			end
		end
	end
	check('all aspects at rank 5', aspects == 24 and min_aspect == 5, string.format('%d aspects, min rank %s', aspects, tostring(min_aspect)))
	-- Keepsakes: level 3 (Epic) for every gift.
	local min_keepsake, keepsakes = math.huge, 0
	for _, gift in pairs(G.GiftData or {}) do
		if type(gift) == 'table' then
			for _, level in ipairs(gift) do
				if level.Gift then
					keepsakes = keepsakes + 1
					min_keepsake = math.min(min_keepsake, G.GetKeepsakeLevel(level.Gift))
				end
			end
		end
	end
	check('all keepsakes at level 3', keepsakes >= 30 and min_keepsake == 3, string.format('%d keepsakes, min level %s', keepsakes, tostring(min_keepsake)))
	-- Familiars and their upgrades.
	local familiars = 0
	for _, f in ipairs(G.FamiliarOrderData or {}) do
		if GS.FamiliarsUnlocked and GS.FamiliarsUnlocked[f] then familiars = familiars + 1 end
	end
	local upgrades, owned = 0, 0
	for _, u in ipairs((G.ScreenData and G.ScreenData.FamiliarShop and G.ScreenData.FamiliarShop.ItemOrder) or {}) do
		if type(u) == 'string' then
			upgrades = upgrades + 1
			if GS.FamiliarUpgrades and GS.FamiliarUpgrades[u] then owned = owned + 1 end
		end
	end
	check('all familiars unlocked and upgraded', familiars == #(G.FamiliarOrderData or {}) and familiars > 0 and owned == upgrades,
		string.format('%d familiars, %d/%d upgrades', familiars, owned, upgrades))
	-- Arcana: every card unlocked at max rank; max Grasp.
	local cards, maxed = 0, 0
	for name, data in pairs(G.MetaUpgradeCardData or {}) do
		local st = GS.MetaUpgradeState and GS.MetaUpgradeState[name]
		if type(data) == 'table' and not data.DebugOnly and st then
			cards = cards + 1
			if st.Unlocked and st.Level == #(data.UpgradeResourceCost or {}) + 1 then maxed = maxed + 1 end
		end
	end
	check('all arcana at max rank', cards > 0 and maxed == cards, string.format('%d/%d cards', maxed, cards))
	local grasp = G.GetMaxMetaUpgradeCost and G.GetMaxMetaUpgradeCost()
	check('max grasp', grasp == 30, 'grasp=' .. tostring(grasp))
	check('no fear', next(GS.ShrineUpgrades or {}) == nil)
	return checks
end

-- The engine's checkpoint-valid flag lives in <Profile>.v.sav; StartOver and
-- many interactions flip it. In competitive mode leave the player's file alone.
function Game:hook_ValidateCheckpoint(base, ...)
	if self:competitive_active() then return end
	return base(...)
end

function Game:hook_InvalidateCheckpoint(base, ...)
	if self:competitive_active() then return end
	return base(...)
end

-- While Hell2Modding's overlay is open (our lobby window needs it for text
-- boxes) it bypasses Player::HandleInput and flips a jump in
-- PlayerManager::HandleInput; in that state the hub's AutoActivate doors fire
-- on their own if the hero stands in range, bouncing between Hub_Main and
-- Hub_PreRun. The player can't use anything while the overlay has input, so
-- ignore those uses.
function Game:hook_DeathAreaSwitchRoom(base, source, args)
	local gui = self.rom.gui
	if source and source.AutoActivate and gui and gui.is_open and gui.is_open() then
		if not self.logged_door_block then
			self.logged_door_block = true
			self.log('game: ignored hub door auto-use while the overlay is open')
		end
		return
	end
	return base(source, args)
end

-- race lifecycle (called from client callbacks) ----------------------------------

function Game:prepare_race(race)
	self.status = nil
	if not self:in_hub() then
		self.status = 'Not in the Crossroads: the race will try to start anyway.'
	end
end

function Game:backup_loadout(weapon)
	local GS = self.G.GameState
	if not GS then return end
	self.backup = {
		LastAwardTrait = GS.LastAwardTrait,
		weapon = weapon,
		aspect = GS.LastWeaponUpgradeName and GS.LastWeaponUpgradeName[weapon],
	}
end

function Game:restore_loadout()
	local b, GS = self.backup, self.G.GameState
	if not (b and GS) then return end
	GS.LastAwardTrait = b.LastAwardTrait
	if GS.LastWeaponUpgradeName and b.weapon then GS.LastWeaponUpgradeName[b.weapon] = b.aspect end
	self.backup = nil
end

function Game:start_race(race)
	local G = self.G
	local GS = G.GameState
	if not (GS and G.CurrentRun) then
		self.status = 'Game not ready (no save loaded); cannot start the race.'
		self.log('game: ' .. self.status)
		return
	end
	self:backup_loadout(race.weapon)
	if race.weapon ~= '' and G.WeaponData and G.WeaponData[race.weapon] then
		self:call('EquipPlayerWeapon', G.WeaponData[race.weapon], { SkipPresentation = true })
		-- In competitive mode the player picked their aspect in the hub; otherwise use the base aspect.
		if not self:competitive_active() and GS.LastWeaponUpgradeName and BASE_ASPECT[race.weapon] then
			GS.LastWeaponUpgradeName[race.weapon] = BASE_ASPECT[race.weapon]
		end
	end
	if race.keepsake ~= '' then GS.LastAwardTrait = race.keepsake end
	self.launching = race
	self.status = nil
	local start_over = self:fn('StartOver')
	if not start_over then
		self.status = 'StartOver missing: cannot start runs on this game version.'
		self.log('game: ' .. self.status)
		return
	end
	self.log(string.format('game: launching race %s seed=%s', tostring(race.race_id), tostring(race.seed)))
	self:spawn(start_over, { StartingBiome = 'F' })
end

function Game:race_over(result)
	if self.race then self.race.finished = true end
	self:restore_loadout()
end

function Game:cancel_race()
	self.launching = nil
	self:restore_loadout()
end

-- progress -------------------------------------------------------------------------

function Game:progress(alive)
	local run = self.G.CurrentRun
	local room = run and run.CurrentRoom
	local hero = run and run.Hero
	return {
		room = room and room.Name or '?',
		biome = room and room.RoomSetName or nil,
		depth = run and run.RunDepthCache or (run and 1 + #(run.RoomHistory or {})) or 0,
		hp = hero and hero.Health or 0,
		max_hp = hero and hero.MaxHealth or nil,
		alive = alive ~= false and not (hero and hero.IsDead),
	}
end

-- Diagnostics for the test logs: map changes immediately, a heartbeat every 15s.
function Game:diagnose(now)
	local map = self:current_map()
	if map ~= self.last_map then self.ticker_started = false end -- map loads kill game threads
	if not self.ticker_started and self:fn('thread') and self:fn('wait') then
		-- Proves game-time coroutines advance (they don't while the game is paused).
		self.ticker_started = true
		local G, log = self.G, self.log
		self:spawn(function()
			local n = 0
			while true do
				G.wait(5)
				n = n + 1
				log(string.format('game: thread tick %d focus_cfg=%s', n,
					tostring(G.GetConfigOptionValue and G.GetConfigOptionValue({ Name = 'RequireFocusToUpdate' }))))
			end
		end)
	end
	-- Test probe: hero distance to auto-activating hub doors for 10 s after arriving.
	if self.probe_doors and map ~= self.last_map then self.probe_until, self.next_probe = now + 10, now end
	if self.probe_doors and now < (self.probe_until or 0) and now >= (self.next_probe or 0) then
		self.next_probe = now + 1
		local hub = self.G.HubRoomData and self.G.HubRoomData[map or '']
		local hero = self.G.CurrentRun and self.G.CurrentRun.Hero
		local parts = {}
		for id, obstacle in pairs((hub and hub.ObstacleData) or {}) do
			if type(obstacle) == 'table' and obstacle.AutoActivate and hero and hero.ObjectId then
				local ok, d = pcall(self.G.GetDistance, { Id = hero.ObjectId, DestinationId = id })
				parts[#parts + 1] = string.format('%s=%s(r%s)', tostring(id), ok and tostring(math.floor(d or -1)) or 'err',
					tostring(obstacle.InteractDistance))
			end
		end
		self.log('probe: ' .. tostring(map) .. ' door distances ' .. table.concat(parts, ' '))
	end
	local GS = self.G.GameState
	if map ~= self.last_map or now - (self.last_beat or 0) >= 15 then
		self.last_beat = now
		self.log(string.format('game: state map=%s save=%s illegal=%s hub=%s dead=%s', tostring(map), tostring(GS ~= nil),
			tostring(GS and GS.IllegalConversationModification), tostring(self:in_hub()),
			tostring(self.G.CurrentRun and self.G.CurrentRun.Hero and self.G.CurrentRun.Hero.IsDead)))
		self.last_map = map
	end
end

function Game:update()
	pcall(self.diagnose, self, self.now())
	if self:race_run_live() and self.client then
		local now = self.now()
		if now - self.last_progress >= 0.5 then
			self.last_progress = now
			self.client:report_progress(self:progress())
		end
	end
end

-- introspection for the bot ----------------------------------------------------------

function Game:run_info()
	local G = self.G
	local run = G.CurrentRun
	if not (self.race and run == self.race.run and run) then return { in_run = false } end
	local first = self.race.rooms[1]
	local hero = run.Hero
	local weapon
	local get_weapon = self:fn('GetEquippedWeapon')
	if get_weapon then
		local ok, w = pcall(get_weapon)
		if ok then weapon = w end
	end
	local keepsake = G.GameState and G.GameState.LastAwardTrait
	local has_trait = self:fn('HeroHasTrait')
	if has_trait and keepsake then
		local ok, has = pcall(has_trait, keepsake)
		if ok and not has then keepsake = 'not-equipped:' .. keepsake end
	end
	return {
		in_run = first ~= nil and not (hero and hero.IsDead),
		seed = first and first.seed,
		weapon = weapon,
		keepsake = keepsake,
		room = run.CurrentRoom and run.CurrentRoom.Name,
	}
end

function Game:trace_details()
	return { rooms = self.race and self.race.rooms or {}, choices = self.race and self.race.choices or {} }
end

-- Drive one room transition the way a player would, minus the fighting:
-- walk (teleport) to the encounter trigger, kill required enemies until the
-- game itself unlocks the exits, then take the lowest-id offered door.
-- Returns 'working', 'advanced' or 'failed'. Called every frame by the bot.
function Game:bot_advance_room()
	local G = self.G
	local run = G.CurrentRun
	if not (run and self.race) then return 'failed' end
	local now = self.now()
	local a = self.adv
	if not a then
		a = { phase = 'engage', t0 = now, rooms_before = #self.race.rooms, room = run.CurrentRoom, next_act = 0, next_report = now + 10 }
		self.adv = a
	end
	if now - a.t0 > 120 then
		self.log('game: bot_advance_room timed out in phase ' .. a.phase .. '; ' .. self:exit_blockers(a.room))
		self.adv = nil
		return 'failed'
	end
	if a.phase == 'engage' then
		local room = a.room
		-- Wait for DoUnlockRoomExits to finish assigning rooms to every door:
		-- room.ExitsUnlocked is set before that runs (only pre-made doors, like
		-- a Chaos gate, have a room then). Fall back after 20 s.
		if self.exits_unlocked_for == room or (room.ExitsUnlocked and now - a.t0 > 20) then
			a.phase = 'pick_door'
		elseif now >= a.next_act then
			a.next_act = now + 1
			local encounter = room.Encounter
			if encounter and not encounter.StartTime and not a.teleported then
				local ids = self:call('GetIdsByType', { Name = 'EncounterStartPoint' })
				if ids and ids[1] then
					a.teleported = true
					self.log('game: bot walking to encounter start ' .. tostring(ids[1]))
					self:call('Teleport', { Id = run.Hero.ObjectId, DestinationId = ids[1] })
				end
			end
			if not a.killing and G.RequiredKillEnemies and next(G.RequiredKillEnemies) then
				a.killing = true
				self:spawn(function()
					G.DestroyRequiredKills({ BlockLoot = true })
					a.killing = false
				end)
			end
			-- Rewards can gate the fight (opening room: boon first) or follow it.
			self:bot_collect_rewards(a)
			self:bot_choose_upgrade()
		end
		if now >= a.next_report then
			a.next_report = now + 10
			self.log('game: bot waiting for exits; ' .. self:exit_blockers(room))
		end
	elseif a.phase == 'pick_door' then
		local doors = G.MapState and G.MapState.OfferedExitDoors
		local highest = self.bot_cfg and self.bot_cfg.door_pick == 'highest'
		local best
		for id, door in pairs(doors or {}) do
			if type(door) == 'table' and door.Room then
				local oid = door.ObjectId or id
				local better = not best or (highest and oid > best.ObjectId) or (not highest and oid < best.ObjectId)
				if better then best = door; best.ObjectId = oid end
			end
		end
		if best then
			a.door = best
			local entry = self.race.rooms[#self.race.rooms]
			if entry then entry.taken = { id = best.ObjectId, reward = best.Room and best.Room.ChosenRewardType } end
			self.log('game: bot leaving via door ' .. tostring(best.ObjectId) .. ' to ' .. tostring(best.Room and best.Room.Name))
			self:spawn(G.LeaveRoom, run, best)
			a.phase = 'wait_room'
		end
	elseif a.phase == 'wait_room' then
		if #self.race.rooms > a.rooms_before then
			self.adv = nil
			return 'advanced'
		end
	end
	return 'working'
end

-- Use each object the room requires (boon, max-health drop, ...) once, the
-- way the game's OnUsed handler does when the player presses interact.
function Game:bot_collect_rewards(a)
	local G = self.G
	-- UseLoot and friends refuse while any screen (dialogue, menus) is open.
	if G.AreScreensActive and G.AreScreensActive() then return end
	a.used = a.used or {}
	local now = self.now()
	for id, required in pairs((G.MapState and G.MapState.RoomRequiredObjects) or {}) do
		-- The live object (what OnUsed would receive) may be a different table;
		-- consumables default to UseConsumableItem (CreateConsumableItemFromData).
		local obj = (G.MapState.ActiveObstacles and G.MapState.ActiveObstacles[id]) or required
		if type(obj) == 'table' and not obj.OnUsedFunctionName and G.ConsumableData and G.ConsumableData[obj.Name] then
			obj.OnUsedFunctionName = 'UseConsumableItem'
		end
		if now - (a.used[id] or -math.huge) > 8 and type(obj) == 'table' and obj.OnUsedFunctionName then
			a.used[id] = now
			self.log('game: bot using ' .. tostring(obj.Name) .. ' via ' .. obj.OnUsedFunctionName)
			local hero = G.CurrentRun.Hero
			self:spawn(function()
				if obj.OnUseEvents and G.RunEventsGeneric then G.RunEventsGeneric(obj.OnUseEvents, obj) end
				G.CallFunctionName(obj.OnUsedFunctionName, obj, obj.OnUsedFunctionArgs, hero)
				if obj.NotifyName and G.notifyExistingWaiters then G.notifyExistingWaiters(obj.NotifyName) end
			end)
		end
	end
end

-- Dialogue waits for "NarrativeLineNextInput"; the game's own auto-advance
-- option sends exactly that notification. Lines with choices aren't handled.
function Game:bot_advance_dialogue()
	local G = self.G
	if G.ActiveScreens and G.ActiveScreens.Dialog and G.notifyExistingWaiters then
		local now = self.now()
		if now - (self.last_dialog_advance or 0) >= 0.75 then
			self.last_dialog_advance = now
			G.notifyExistingWaiters('NarrativeLineNextInput')
		end
	end
end

-- An open boon/upgrade choice: take the first option, like clicking it.
function Game:bot_choose_upgrade()
	local G = self.G
	local screen = G.ScreenAnchors and G.ScreenAnchors.ChoiceScreen
	if not (screen and screen.Components) or screen.ChoiceMade or screen.bot_chose then return end
	local button = screen.Components.PurchaseButton1
	if self.bot_cfg and self.bot_cfg.boon_pick == 'last' then
		for i = 4, 2, -1 do
			local b = screen.Components['PurchaseButton' .. i]
			if b and b.Data then button = b; break end
		end
	end
	if not (button and button.Data) then return end
	screen.bot_chose = true
	self.log('game: bot choosing ' .. tostring(button.Data.Name))
	if self.race then
		self.race.choices = self.race.choices or {}
		table.insert(self.race.choices, button.Data.Name)
	end
	self:spawn(G.HandleUpgradeChoiceSelection, screen, button)
end

-- What CheckRoomExitsReady would object to, for the logs.
function Game:exit_blockers(room)
	local G = self.G
	local parts = {}
	local enc = room and room.Encounter
	parts[#parts + 1] = string.format('encounter=%s started=%s completed=%s', tostring(enc and enc.Name),
		tostring(enc and enc.StartTime ~= nil), tostring(enc and enc.Completed))
	local n = 0
	for _ in pairs(G.RequiredKillEnemies or {}) do n = n + 1 end
	parts[#parts + 1] = 'required_kills=' .. n
	local req = {}
	for id, obj in pairs((G.MapState and G.MapState.RoomRequiredObjects) or {}) do req[#req + 1] = tostring(obj.Name or id) end
	parts[#parts + 1] = 'required_objects=' .. table.concat(req, ',')
	local screens = {}
	for name, screen in pairs(G.ActiveScreens or {}) do
		if screen.BlockExitsReady then screens[#screens + 1] = tostring(name) end
	end
	parts[#parts + 1] = 'blocking_screens=' .. table.concat(screens, ',')
	parts[#parts + 1] = 'unlocked=' .. tostring(room and room.ExitsUnlocked)
	return table.concat(parts, ' ')
end

function Game:bot_kill_hero()
	local G = self.G
	local hero = G.CurrentRun and G.CurrentRun.Hero
	if hero and not hero.IsDead and self:fn('Kill') then
		self.log('game: bot killing hero')
		self:spawn(G.Kill, hero, { AttackerName = 'RankedRaceBot' })
	end
end

-- Calls the game's own clear bookkeeping (what OpenRunClearScreen does after a
-- final boss), which our RecordRunCleared hook turns into a victory report.
function Game:bot_win()
	self.log('game: bot recording run clear')
	self:call('RecordRunCleared')
end

function Game:quit()
	self.log('game: bot quitting')
	os.exit(0)
end

return Game
