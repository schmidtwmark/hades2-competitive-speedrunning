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
	'CreateRoom', 'ChooseRoomReward', 'GetNextSpawn', 'HandleNextSpawn', 'Load', 'CloseRunClearScreen',
	'HandleUpgradeChoiceSelection', 'HandleStorePurchase', 'UseEscapeDoor', 'UseDreamRunDoor', 'SelectNextDreamBiome',
	'UnlockAchievement', 'CheckProgressAchievements', 'CheckAchievement', 'ChooseLoot', 'FillInShopOptions',
	'SetTraitsOnLoot', 'HandleBreakableSwap', 'CheckMoneyDrop', 'ProcessObjectValueOptions',
	'CheckChallengeSwitchItemValidity', 'CheckPlayerOnFirePowers', 'ChooseSpell', 'CreateSpellButtons',
	'IsSecretDoorEligible', 'ChooseNextRewardStore', 'UseWeaponKit', 'UseKeepsakeRack', 'AddInputBlock', 'RemoveInputBlock' }

-- Shadow animations for hero actions whose fire graphic isn't the visible move.
local ACTION_ANIMS = { WeaponBlink = 'MelinoeDashStart', WeaponSprint = 'MelinoeSprint' }

-- Race routes (server/src/pools.ts ids): the Crossroads door that starts each
-- (DeathLoopData Hub_PreRun ObstacleData) and what it passes to StartOver.
local ROUTES = {
	underworld = { door = 420947, label = 'the stairs down', start = function() return { StartingBiome = 'F' } end },
	surface = { door = 555784, label = 'the path to the Surface',
		start = function() return { StartingBiome = 'N', RandomOffset = 1 } end },
	dream = { door = 780651, label = 'the Dream Dive', dream = true,
		start = function()
			return { StartingRoomName = 'Dream_Intro', RunOverrides = { IsDreamRun = true, BiomeDepthCache = 1 } }
		end },
}
Game.ROUTES = ROUTES

function Game.new(deps)
	local g = setmetatable({}, Game)
	g.rom = deps.rom
	g.G = deps.rom.game
	g.modutil = deps.modutil
	g.log = deps.log
	g.now = deps.now
	g.profile = deps.profile
	g.Splits = deps.splits
	g.pbs = {}            -- route -> personal best (splits.lua), from main.lua's pb.json
	g.input_blocks = {}   -- name -> count of the scripts' input blocks still held
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
-- The running Hades II build: the game executable's PE link time (Unix
-- seconds), read from its header in memory. Every Steam player on a build has
-- the same binary (Proton runs the Windows one), so equal values mean the same
-- game; a larger one is newer. nil if it can't be read (then nothing blocks).
function Game:game_build()
	local _ = _ENV -- rom.memory finds the calling mod through _ENV
	local mem = self.rom and self.rom.memory
	if not (mem and mem.get_module_base_address) then return nil end
	local ok, stamp = pcall(function()
		local _ = _ENV
		local base = mem.get_module_base_address()
		if not base or base:is_null() then return nil end
		local pe = base:add(base:add(0x3C):get_dword())
		if pe:get_dword() ~= 0x4550 then return nil end -- "PE\0\0"
		return pe:add(8):get_dword() -- IMAGE_FILE_HEADER.TimeDateStamp
	end)
	if ok and type(stamp) == 'number' and stamp > 0 then return stamp end
	self.log('game: could not read the game build: ' .. tostring(stamp))
	return nil
end

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

-- One line in this race's choice log (racelog.lua); never breaks the game.
function Game:rlog(ev, fields)
	local rl = self.racelog
	if not (rl and self.race and self.race.run == self.G.CurrentRun) then return end
	pcall(rl.event, rl, ev, fields)
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

-- Non-linear mixing mod 2^31-1 (squaring + Park-Miller multiply). mulmod
-- splits the multiplier into 16-bit halves so every product stays below 2^53
-- and is exact in Lua 5.2's doubles. Without mixing, consecutive depths got
-- seeds in arithmetic progression.
local MIX_MOD = 2147483647
local function mulmod(a, b)
	local hi, lo = math.floor(b / 65536), b % 65536
	return ((a * hi % MIX_MOD) * 65536 + a * lo) % MIX_MOD
end
local function mix(h)
	for round = 1, 3 do
		h = (mulmod(h, h) + 0x2545F491 + round) % MIX_MOD
		h = mulmod(h, 48271)
	end
	return h
end

local function hash_seed(...)
	local h = 7
	for i = 1, select('#', ...) do
		local part = tostring((select(i, ...)))
		for j = 1, #part do h = (h * 31 + part:byte(j)) % MIX_MOD end
		h = mix(h + 1)
	end
	return mix(h + 1) % SEED_MOD + 1
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

-- Rank picks ------------------------------------------------------------------------
-- The game picks most things by drawing one random index into the list of
-- *eligible* options. If two racers' lists differ by one entry (a door reward
-- that bans an encounter, a god only one of them has unlocked), the same draw
-- lands on different options. Inside a rank-pick scope the game's
-- GetRandomValue / RemoveRandomValue / GetRandomValueFromWeightedList instead
-- score every option from (race seed, tags, pick #, option name, copy #) and
-- take the best eligible one (prunes drop the worst). Equal lists give equal
-- picks, a missing option only changes the picks it would have won, and the
-- result doesn't depend on table order (pairs order differs between game
-- processes).

local RANK_FNS = { 'GetRandomValue', 'RemoveRandomValue', 'GetRandomValueFromWeightedList' }

local function option_key(v)
	if type(v) == 'table' then
		local k = rawget(v, 'Name') or rawget(v, 'ItemName') or rawget(v, 'Type')
		return k ~= nil and tostring(k) or 'table'
	end
	return tostring(v)
end
Game.option_key = option_key

-- Run fn(...) with rank picks keyed on `tags`. opts.limit: only the first N
-- picks are ranked (later ones use the game's own functions on the reseeded
-- RNG); opts.key(v): the option's name when the list holds indices.
function Game:rank_scope(tags, opts, fn, ...)
	local G = self.G
	local seed = self:race_seed()
	if not seed or (self.mutations and (self.mutations.no_depth_seed or self.mutations.no_rank_pick)) then return fn(...) end
	opts = opts or {}
	local keyfn = opts.key or option_key
	local saved = {}
	for _, name in ipairs(RANK_FNS) do saved[name] = G[name] end
	local calls = 0
	local unpack_ = table.unpack or unpack
	local function next_pick()
		calls = calls + 1
		return opts.limit == nil or calls <= opts.limit
	end
	local function score(pick, key, copy)
		local parts = { unpack_(tags) }
		parts[#parts + 1] = pick
		parts[#parts + 1] = key
		parts[#parts + 1] = copy
		return hash_seed(seed, unpack_(parts))
	end
	G.GetRandomValue = function(t, rng)
		if t == nil or not next_pick() then return saved.GetRandomValue(t, rng) end
		local pick, best, best_score, copies = calls, nil, nil, {}
		for _, v in ipairs(G.CollapseTableOrdered(t)) do
			local key = keyfn(v)
			copies[key] = (copies[key] or 0) + 1
			local sc = score(pick, key, copies[key])
			if best_score == nil or sc < best_score then best, best_score = v, sc end
		end
		return best
	end
	-- Prunes keep the best ranks: one ranking for every prune in the scope.
	G.RemoveRandomValue = function(t, rng)
		if t == nil or G.TableLength(t) <= 0 or not next_pick() then return saved.RemoveRandomValue(t, rng) end
		t = G.OverwriteAndCollapseTable(t)
		if G.cmp_multitype then table.sort(t, G.cmp_multitype) end
		local worst, worst_score, copies = nil, nil, {}
		for i, v in ipairs(t) do
			local key = keyfn(v)
			copies[key] = (copies[key] or 0) + 1
			local sc = score('prune', key, copies[key])
			if worst_score == nil or sc > worst_score then worst, worst_score = i, sc end
		end
		local v = t[worst]
		t[worst] = nil
		return v
	end
	-- Weighted: the smallest -ln(u)/weight wins, which picks in proportion to weight.
	G.GetRandomValueFromWeightedList = function(t, rng)
		if t == nil or not next_pick() then return saved.GetRandomValueFromWeightedList(t, rng) end
		local pick, best, best_score = calls, nil, nil
		for value, weight in pairs(t) do
			if type(weight) == 'number' and weight > 0 then
				local u = (score(pick, keyfn(value), 1) % 1000000 + 0.5) / 1000000
				local sc = -math.log(u) / weight
				if best_score == nil or sc < best_score or (sc == best_score and tostring(value) < tostring(best)) then
					best, best_score = value, sc
				end
			end
		end
		return best
	end
	self:reseed('rank', unpack_(tags))
	local results = { pcall(fn, ...) }
	for _, name in ipairs(RANK_FNS) do G[name] = saved[name] end
	if not results[1] then error(results[2], 0) end
	return unpack_results(results)
end

-- Random rolls made on the shared combat RNG at unpredictable moments (urns,
-- gold drops): decide them from the seed, then resume the combat stream from a
-- value drawn before, so combat rolls don't become predictable.
function Game:seeded_call(base, tags, ...)
	if not self:race_seed() or (self.mutations and self.mutations.no_depth_seed) then return base(...) end
	local G = self.G
	local resume = G.RandomInt(1, 1000000000)
	self:reseed((table.unpack or unpack)(tags))
	local results = { pcall(base, ...) }
	self:reseed('resume', resume)
	if not results[1] then error(results[2], 0) end
	return unpack_results(results)
end

-- How many times `tag` happened in the current room (for per-room keys).
function Game:room_count(tag)
	local room = self.G.CurrentRun and self.G.CurrentRun.CurrentRoom
	if not room then return 0 end
	room.RaceCounts = room.RaceCounts or {}
	room.RaceCounts[tag] = (room.RaceCounts[tag] or 0) + 1
	return room.RaceCounts[tag]
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
		self:rlog('take_door', { room = next_room.Name, reward = next_room.ChosenRewardType, loot = next_room.ForceLootName,
			encounter = next_room.Encounter and next_room.Encounter.Name })
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

-- The rewards on every door into `room` (the room we're leaving offers them).
function Game:door_rewards_into(run, room)
	local cur = run and run.CurrentRoom
	if not (cur and room and cur ~= room and type(cur.OfferedRewards) == 'table') then return {} end
	local types, seen = {}, {}
	for id, reward in pairs(cur.OfferedRewards) do
		local leads = cur.ExitDoorRooms and cur.ExitDoorRooms[id]
		local t = type(reward) == 'table' and reward.Type or nil
		if t and not seen[t] and (leads == nil or leads == room or (type(leads) == 'table' and leads.Name == room.Name)) then
			seen[t] = true
			types[#types + 1] = t
		end
	end
	table.sort(types)
	return types
end

-- An encounter counts as eligible for the room only if it is for every door's
-- reward: otherwise the door you took decides whether Artemis or Nemesis is
-- there (both ban some rewards). Then one ranked pick.
function Game:choose_encounter(base, run, room, args, union)
	local G = self.G
	local tags = { 'encounter', self:race_depth(), room and room.Name, args and args.LegalEncounters and 'cage' or 'main' }
	local types = union and self:door_rewards_into(run, room) or {}
	local orig = G.IsEncounterEligible
	if #types > 1 and orig then
		G.IsEncounterEligible = function(r, rm, data, a)
			if rm ~= room then return orig(r, rm, data, a) end
			local chosen = rm.ChosenRewardType
			for _, t in ipairs(types) do
				rm.ChosenRewardType = t
				if not orig(r, rm, data, a) then
					rm.ChosenRewardType = chosen
					return false
				end
			end
			rm.ChosenRewardType = chosen
			return true
		end
	end
	local results = { pcall(self.rank_scope, self, tags, { limit = 1 }, base, run, room, args) }
	G.IsEncounterEligible = orig
	if not results[1] then error(results[2], 0) end
	return results[2]
end

function Game:hook_ChooseEncounter(base, run, room, args)
	self:reseed('encounter', self:race_depth(), room and room.Name, args and args.LegalEncounters and 'cage' or 'main')
	local encounter
	if self:race_seed() then
		local ok, res = pcall(self.choose_encounter, self, base, run, room, args, args == nil)
		if ok and res ~= nil then
			encounter = res
		else
			-- Nothing fits every door's reward: this door's reward decides.
			self.log('game: encounter for every door failed (' .. tostring(res) .. '); per door')
			encounter = self:choose_encounter(base, run, room, args, false)
		end
	else
		encounter = base(run, room, args)
	end
	self:rlog('encounter', { room = room and room.Name, encounter = type(encounter) == 'table' and encounter.Name or nil,
		kind = args and args.LegalEncounters and 'cage' or 'main', for_door = self.unlock_ctx ~= nil })
	return encounter
end

function Game:hook_RunShopGeneration(base, room)
	self:reseed('shop', self:race_depth(), room and room.Name)
	local res = base(room)
	local store = room and room.Store
	if store and store.StoreOptions then
		local items = {}
		for _, item in ipairs(store.StoreOptions) do items[#items + 1] = tostring(item.Name) end
		self:rlog('store', { room = room.Name, store = room.StoreDataName, items = items })
	end
	return res
end

function Game:hook_HandleStorePurchase(base, screen, button)
	local item = button and button.Data and button.Data.Name
	local res = base(screen, button)
	self:rlog('buy', { item = item })
	return res
end

-- Boon (and other upgrade) choices: everything offered, and the pick.
function Game:hook_HandleUpgradeChoiceSelection(base, screen, button, args)
	local loot = button and button.LootData
	if loot and self.race then
		local offered = {}
		for _, o in pairs(loot.UpgradeOptions or {}) do
			offered[#offered + 1] = { name = tostring(o.ItemName), rarity = o.Rarity }
		end
		table.sort(offered, function(a, b) return a.name < b.name end)
		self:rlog('boon', { source = loot.Name, offered = offered, picked = button.Data and button.Data.Name })
	end
	return base(screen, button, args)
end

-- Which reward pool a room's doors draw from (RunProgress: boons, hammers, max
-- health...; MetaProgress: Ashes, Bones, Nectar...). The game rolls a chance
-- nudged toward a target ratio by the rewards already in your history, and a
-- Chaos room can carry its own ratio, so racers who picked differently or took
-- a Chaos detour drew from different pools at the same depth. In a race the
-- roll uses the plain target ratio, on the depth's room seed (the game
-- resynchronises the RNG first), so every racer gets the same pool.
function Game:hook_ChooseNextRewardStore(base, run)
	if not (run and self:race_run_live()) or (self.mutations and self.mutations.no_depth_seed) then return base(run) end
	local G, room = self.G, run.CurrentRoom
	local calc, room_ratio = G.CalcMetaProgressRatio, room and room.TargetMetaRewardsRatio
	G.CalcMetaProgressRatio = function() return nil end
	if room then room.TargetMetaRewardsRatio = nil end
	local ok, res = pcall(base, run)
	G.CalcMetaProgressRatio = calc
	if room then room.TargetMetaRewardsRatio = room_ratio end
	if not ok then error(res, 0) end
	return res
end

-- Which god a boon door (or other loot) offers: one ranked pick.
function Game:hook_ChooseLoot(base, exclude, force)
	if not self:race_seed() then return base(exclude, force) end
	local ctx = self.unlock_ctx
	local n
	if ctx then
		ctx.loot = (ctx.loot or 0) + 1
		n = ctx.loot
	else
		n = 'room' .. self:room_count('loot')
	end
	return self:rank_scope({ 'loot', self:race_depth(), n }, { limit = 1 }, base, exclude, force)
end

-- Shop and Well of Charon stock: ranked picks and prunes.
function Game:hook_FillInShopOptions(base, args)
	if not self:race_seed() then return base(args) end
	return self:rank_scope({ 'stock', self:race_depth(), args and args.RoomName, self:room_count('stock') }, nil, base, args)
end

-- A god's boon offer: the same options (and rarity rolls) for every racer who
-- opens that god's boon at this depth, as far as their boons allow.
function Game:hook_SetTraitsOnLoot(base, loot, args)
	if not (self:race_seed() and type(loot) == 'table') then return base(loot, args) end
	local tags = { 'boons', self:race_depth(), tostring(loot.Name), self:room_count('boons_' .. tostring(loot.Name)) }
	return self:rank_scope(tags, nil, base, loot, args)
end

-- Every weapon the hero fires (attacks, specials, casts, dashes): tell our
-- shadow on the rivals' screens to play the same animation.
function Game:hook_CheckPlayerOnFirePowers(base, args, ...)
	pcall(self.note_fire, self, args)
	return base(args, ...)
end

function Game:note_fire(args)
	local shadow, G = self.shadow, self.G
	if not (shadow and args and (self:race_run_live() or shadow.mirror)) then return end
	local weapon = args.name
	local anim = ACTION_ANIMS[weapon]
	if not anim and G.GetWeaponDataValue and G.CurrentRun and G.CurrentRun.Hero then
		anim = G.GetWeaponDataValue({ Id = G.CurrentRun.Hero.ObjectId, WeaponName = weapon, Property = 'FireGraphic' })
	end
	shadow:note_action(anim)
end

-- What a field NPC offers (Nemesis's trade, Echo, Arachne, Narcissus, Medea,
-- Circe, Icarus): ranked per depth, like every other offer.
local NPC_CHOICES = { 'EchoChoice', 'ArachneCostumeChoice', 'NarcissusBenefitChoice', 'MedeaCurseChoice',
	'CirceBlessingChoice', 'IcarusBenefitChoice', 'NemesisTradeChoice' }
for _, name in ipairs(NPC_CHOICES) do
	HOOKS[#HOOKS + 1] = name
	Game['hook_' .. name] = function(self, base, ...)
		if not self:race_seed() then return base(...) end
		return self:rank_scope({ 'npc', self:race_depth(), name }, nil, base, ...)
	end
end

-- Test bot option (bot.json "force_chaos_door"): a Chaos gate in every room
-- that can have one, to test what a detour does to depth tracking.
function Game:hook_IsSecretDoorEligible(base, ...)
	if self.bot_cfg and self.bot_cfg.force_chaos_door and self:race_run_live() then return true end
	return base(...)
end

-- Selene: which hex a moon reward is, and the three hexes her screen offers.
function Game:hook_ChooseSpell(base, room, args)
	if not self:race_seed() then return base(room, args) end
	return self:rank_scope({ 'spell', self:race_depth() }, { limit = 1 }, base, room, args)
end

function Game:hook_CreateSpellButtons(base, screen)
	if not self:race_seed() then return base(screen) end
	return self:rank_scope({ 'hexes', self:race_depth(), self:room_count('hexes') }, nil, base, screen)
end

function Game:hook_HandleBreakableSwap(base, room, args)
	return self:seeded_call(base, { 'urns', self:race_depth(), room and room.Name }, room, args)
end

function Game:hook_CheckMoneyDrop(base, enemy, data, attacker)
	local name = type(enemy) == 'table' and tostring(enemy.Name) or '?'
	return self:seeded_call(base, { 'money', self:race_depth(), name, self:room_count('money_' .. name) }, enemy, data, attacker)
end

function Game:hook_ProcessObjectValueOptions(base, object)
	local name = type(object) == 'table' and tostring(object.Name) or '?'
	return self:seeded_call(base, { 'value', self:race_depth(), name, self:room_count('value_' .. name) }, object)
end

function Game:hook_CheckChallengeSwitchItemValidity(base, run)
	return self:seeded_call(base, { 'switch', self:race_depth() }, run)
end

-- A racer who takes a side room (a Chaos gate) skips that depth's main room,
-- so the game still counts it as unvisited and may offer it later, where the
-- others can't get it (they've been in it; rooms don't repeat), and the racers
-- end up on different rooms until a fixed room (miniboss, shop, boss) lines
-- them up again. For room choice, count every main-path room as visited.
function Game:with_main_path_visited(run, fn)
	local path = self.race and self.race.main_path
	if not (path and run and run.RoomCountCache and run.BiomeRoomCountCache) then return fn() end
	local visited = {}
	for _, room in ipairs(run.RoomHistory or {}) do visited[room.Name] = true end
	if run.CurrentRoom then visited[run.CurrentRoom.Name] = true end
	local added = {}
	for _, name in pairs(path) do
		if not visited[name] then added[name] = true end
	end
	for name in pairs(added) do
		run.RoomCountCache[name] = (run.RoomCountCache[name] or 0) + 1
		run.BiomeRoomCountCache[name] = (run.BiomeRoomCountCache[name] or 0) + 1
	end
	local results = { pcall(fn) }
	for name in pairs(added) do
		run.RoomCountCache[name] = run.RoomCountCache[name] - 1
		run.BiomeRoomCountCache[name] = run.BiomeRoomCountCache[name] - 1
		if run.RoomCountCache[name] <= 0 then run.RoomCountCache[name] = nil end
		if run.BiomeRoomCountCache[name] <= 0 then run.BiomeRoomCountCache[name] = nil end
	end
	if not results[1] then error(results[2], 0) end
	return results[2]
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
	ctx.room_data = self:with_main_path_visited(run, function()
		return self:rank_scope({ 'route', ctx.depth }, nil, base, run, args, other_doors)
	end)
	-- The main path: the room every generic door at this depth leads to.
	if self.race and ctx.room_data then
		self.race.main_path = self.race.main_path or {}
		self.race.main_path[ctx.depth + 1] = ctx.room_data.Name
	end
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
		local ctx = self.unlock_ctx or {}
		ctx.rewards = (ctx.rewards or 0) + 1
		local entries = run.RewardStores and run.RewardStores[store] or {}
		local tags = { 'reward', self:race_depth(), tostring(store), self.unlock_ctx and ctx.rewards or self:room_count('reward') }
		local ok, res = pcall(self.rank_scope, self, tags, { key = function(k)
			local e = entries[k]
			return type(e) == 'table' and tostring(e.Name) or tostring(k)
		end }, base, run, room, store, previous, args)
		run.NumRerolls = saved
		if not ok then error(res, 0) end
		self:rlog('reward', { room = room and room.Name, reward = res, store = store })
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
			base_rerolls = self.G.CurrentRun and self.G.CurrentRun.NumRerolls,
			splits = self.Splits and self.Splits.new(race.route, self.pbs[race.route]) }
		self.dream_biomes = 0
		self.log('game: race run created for race ' .. tostring(race.race_id))
		if self.racelog then
			pcall(self.racelog.start, self.racelog, { race_id = race.race_id, seed = race.seed, weapon = race.weapon,
				keepsake = race.keepsake, name = self.client and self.client.name, version = self.client and self.client.version,
				game_build = self.client and self.client.game_build })
		end
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
	-- Mid-run starts (each Dream Dive biome): seeded and ranked per depth.
	if not self.launching and self:race_run_live() then
		return self:rank_scope({ 'start', self:race_depth(), args and args.StartingBiome }, nil, base, run, args)
	end
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
	if self.racelog then self.racelog:set_depth(entry.depth) end
	self:rlog('room', entry)
	self.log(string.format('game: room %d %s biome=%s seed=%s encounter=%s reward=%s', entry.depth, tostring(entry.name),
		tostring(entry.biome), tostring(entry.seed), tostring(entry.encounter), tostring(entry.reward)))
	if self.client then self.client:report_progress(self:progress(), true) end
	local sp = self.race.splits and self.client and self.race.splits:room(entry.name, self.client:race_time())
	if sp then
		self.log(string.format('game: split %d %s %.2f delta=%s', sp.index, sp.name, sp.time, tostring(sp.delta)))
		self:rlog('split', { index = sp.index, name = sp.name, time = sp.time, delta = sp.delta })
	end
end

-- The run is cleared: the last split, the PB kept if this beat it, and a line
-- for the results page.
function Game:finish_splits()
	local sp = self.race and self.race.splits
	if not (sp and self.client and not sp.cleared) then return end
	local last = sp:clear(self.client:race_time())
	self.log(string.format('game: split %d %s %.2f (cleared) new_pb=%s', last.index, last.name, last.time, tostring(last.new_pb)))
	self:rlog('split', { index = last.index, name = last.name, time = last.time, delta = last.delta, new_pb = last.new_pb })
	local record = sp:pb_record()
	if record and self.save_pb then
		local ok, err = pcall(self.save_pb, self.race.race.route, record)
		if not ok then self.log('game: saving the PB failed: ' .. tostring(err)) end
	end
	local line
	if last.new_pb and last.total_delta then
		line = 'New personal best! ' .. self.Splits.fmt_delta(last.total_delta) .. ' on your old one'
	elseif last.new_pb then
		line = 'Your first clear on this route: that is your personal best'
	else
		line = 'This run: ' .. self.Splits.fmt_delta(last.total_delta) .. ' on your personal best'
	end
	if self.board and self.board.ui then self.board.ui.pb_line = line end
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
	local offered = {}
	for i, d in ipairs(doors) do offered[i] = { room = d.room, reward = d.reward, loot = d.loot } end
	self:rlog('doors', { doors = offered })
end

function Game:hook_KillHero(base, victim, triggerArgs)
	-- Competitive mode, already on the way back to the Crossroads: no death
	-- sequence. A cleared Dream Dive kills the hero after its clear screen.
	if self.going_home or (self.race and self.race.cleared and self:competitive_active()) then return end
	if self:race_run_live() then
		self:rlog('died', { room = self.G.CurrentRun.CurrentRoom and self.G.CurrentRun.CurrentRoom.Name })
		self.race.finished = true
		self.log('game: hero died in race run')
		if self.client then
			self.client:report_progress(self:progress(false), true)
			self.client:report_complete(false, nil, self:run_stats(), self:build_list())
		end
		-- The game's death animation, then straight home: the full death
		-- sequence would play story scenes in Hub_Main and wait for input
		-- before the results.
		if self:competitive_active() and self:die_and_go_home(triggerArgs) then return end
	end
	return base(victim, triggerArgs)
end

function Game:hook_RecordRunCleared(base, ...)
	local run = self.G.CurrentRun
	-- The clear screen shows CurrentRun.GameplayTime, the game's paused-in-menus
	-- clock; in a race it shows the one real-time race clock instead.
	if self:race_run_live() and run and self.client then run.GameplayTime = self.client:race_time() end
	local res = base(...)
	local dream_race = self.race and self.race.race and self.race.race.route == 'dream'
	if self:race_run_live() and run and run.Cleared and not run.ActiveBounty and (dream_race or not run.IsDreamRun) then
		self:rlog('cleared', { time = self.client and self.client:race_time() })
		self.race.finished = true
		self.race.cleared = true
		self.log('game: race run cleared')
		pcall(self.finish_splits, self)
		if self.client then self.client:report_complete(true, nil, self:run_stats(), self:build_list()) end
	end
	return res
end

-- After the clear screen the competitive profile would walk into the story
-- rooms; go back to the Crossroads instead, where the results are shown.
function Game:hook_CloseRunClearScreen(base, ...)
	local res = base(...)
	if self.race and self.race.cleared and self:competitive_active() and not self.race.sent_home then
		self.race.sent_home = true
		self:go_home('run cleared')
	end
	return res
end

-- Back to the competitive Crossroads the way competitive mode first arrives
-- (run over, walk in from the Crossroads door), not through a death: the
-- death sequence plays story events and waits for input between the race
-- and its results.
function Game:go_home(why)
	local G = self.G
	local run = G.CurrentRun
	if not (run and run.Hero and G.LoadMap) then return false end
	self.log('game: returning to the Crossroads (' .. tostring(why) .. ')')
	self.going_home = true
	run.Hero.IsDead = true
	run.NextHeroStartPoint, run.NextHeroEndPoint = 40009, 40012
	self:spawn(function()
		if G.wait then G.wait(0.5) end
		self:clear_run_upgrades()
		G.LoadMap({ Name = 'Hub_PreRun' })
	end)
	return true
end

-- What KillHero does before the death map: the run's boons, hammers and
-- other traits go (the Arcana that work while dead come back). Without it
-- the hero walks into the Crossroads with the whole build.
function Game:clear_run_upgrades()
	local f = self:fn('ClearUpgrades')
	if not f then return end
	local ok, err = pcall(f)
	if not ok then self.log('game: clearing the run\'s upgrades failed: ' .. tostring(err)) end
end

-- What KillHero does up to its death presentation (spawns stopped, music and
-- ambience ended, Melinoe's death animation and the death banner), minus the
-- run bookkeeping and the death map; then home to the competitive hub.
function Game:die_and_go_home(triggerArgs)
	local G = self.G
	local run = G.CurrentRun
	if not (run and run.Hero and G.LoadMap) then return false end
	self.going_home = true
	self.death_cleanup = true
	local args = triggerArgs or {}
	local killer = args.AttackerTable or { Name = args.AttackerName, ObjectId = args.AttackerId }
	self:spawn(function()
		local ok, err = pcall(function()
			for _, name in pairs(run.CurrentRoom and run.CurrentRoom.SpawnThreads or {}) do G.killTaggedThreads(name) end
			if G.MapState then G.MapState.BlockSpawns = true end
			if run.CurrentRoom then run.CurrentRoom.SpawnThreads = {} end
			if G.EndAmbience then G.EndAmbience(0.5) end
			local audio = G.AudioState
			if G.EndMusic and audio then G.EndMusic(audio.MusicId, audio.MusicName, 0.0) end
			run.Hero.IsDead = true
			if G.SessionMapState then G.SessionMapState.HandlingDeath = true end
			G.DeathPresentation(run, killer, args)
		end)
		if not ok then self.log('game: death presentation failed: ' .. tostring(err)) end
		self.log('game: returning to the Crossroads (died)')
		run.Hero.IsDead = true
		run.NextHeroStartPoint, run.NextHeroEndPoint = 40009, 40012
		if G.SessionMapState then G.SessionMapState.HandlingDeath = false end
		self:clear_run_upgrades()
		G.LoadMap({ Name = 'Hub_PreRun' })
	end)
	return true
end

function Game:in_hub_now()
	if self.going_home and self:in_hub() then
		self.going_home = false
		-- Undo what the death presentation locked (a real death undoes these
		-- in the death area's arrival presentation, which we skip).
		if self.death_cleanup then
			self.death_cleanup = false
			local G = self.G
			for _, f in ipairs({
				function() G.RemoveInputBlock({ Name = 'DeathPresentation' }) end,
				function() G.UnzeroMouseTether('DeathPresentation') end,
				function() G.UnlockCameraMotion('DeathPresentation') end,
				function() G.ToggleCombatControl(G.CombatControlsDefaults, true, 'DeathPresentation') end,
				function() G.ShowCombatUI('Death') end,
			}) do pcall(f) end
		end
	end
end

-- competitive mode ------------------------------------------------------------------

-- Called from the title-screen hook. Drops whatever profile state is loaded so
-- the next map load builds a fresh GameState (no real save involved).
function Game:enter_competitive()
	local G = self.G
	G.RankedRaceCompetitive = { requested = true }
	G.GameState = nil
	G.CurrentRun = nil
	-- Quitting to the title screen leaves the screen faded to black; a save's
	-- own load fades it back in, this one doesn't (fade_in_hub, in update).
	self.fade_in_pending = true
	self:release_input_blocks()
	self:restart_script_clock()
	if self.stop_menu_music then pcall(self.stop_menu_music) end
	self.log('game: entering competitive mode; loading Hub_PreRun without a profile')
	-- LoadMap is a Lua wrapper that wait()s; on the title screen there is no
	-- game coroutine (and no threads to kill), so call the engine directly.
	self:call('LoadMapInternal', { Name = 'Hub_PreRun' })
end

-- The scripts' input blocks (AddInputBlock/RemoveInputBlock { Name }), so the
-- ones a quit to the title screen leaves behind can be released (below).
function Game:hook_AddInputBlock(base, args, ...)
	local name = type(args) == 'table' and args.Name
	if name then self.input_blocks[name] = (self.input_blocks[name] or 0) + 1 end
	return base(args, ...)
end

function Game:hook_RemoveInputBlock(base, args, ...)
	local name = type(args) == 'table' and args.Name
	if name and self.input_blocks[name] then
		self.input_blocks[name] = self.input_blocks[name] > 1 and self.input_blocks[name] - 1 or nil
	end
	return base(args, ...)
end

-- The scripts' clock (_worldTime, which wait() schedules against) is set by
-- the engine each frame, and a new session's engine clock starts at 0. A save
-- load restores it from the save; this entry doesn't, so after a quit to the
-- title screen it still held the last session's time while the Crossroads
-- arrival scheduled its waits, and those waited that long: no controls for as
-- long as you had played. Start it at 0, keeping what threads have left.
function Game:restart_script_clock()
	local G = self.G
	local now, now_u = tonumber(G._worldTime) or 0, tonumber(G._worldTimeUnmodified) or 0
	if now == 0 and now_u == 0 then return end
	for _, list in ipairs({ G._threads or {}, G._workingThreads or {} }) do
		for _, t in pairs(list) do
			if type(t) == 'table' and type(t.resumeTime) == 'number' then
				t.resumeTime = math.max(0, t.resumeTime - (t.unmodifiedTime and now_u or now))
			end
		end
	end
	G._worldTime, G._worldTimeUnmodified = 0, 0
	self.log(string.format('game: script clock restarted (was %.1f s)', now))
end

-- Quitting to the title screen drops the scene with its input blocks still
-- held (the pause menu's, a presentation's); loading a save clears them in
-- the engine, the competitive entry doesn't. Release whatever is left.
function Game:release_input_blocks()
	local names = {}
	for name, n in pairs(self.input_blocks) do
		for _ = 1, n do self:call('RemoveInputBlock', { Name = name }) end
		names[#names + 1] = name
	end
	self.input_blocks = {}
	if #names > 0 then
		table.sort(names)
		self.log('game: released input blocks left from before: ' .. table.concat(names, ', '))
	end
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
	-- Active while building too: unlocking everything must not save or earn achievements.
	c.active = true
	local loadout = self.saved_loadout
	if self.read_save_loadout then
		local rok, from_save, err = pcall(self.read_save_loadout)
		if rok and from_save then
			local slots = 0
			for _ in pairs(from_save.layouts or {}) do slots = slots + 1 end
			self.log(string.format('game: save file 1: %d Arcana equipped, %d layouts', #(from_save.arcana or {}), slots))
			loadout = self.profile.merge_loadouts(loadout, from_save)
		else
			self.log('game: save file 1 not used: ' .. tostring(rok and err or from_save))
		end
	end
	local ok, summary = pcall(self.profile.build, self.G, loadout)
	if not ok then
		c.active = false
		self.log('game: competitive profile build FAILED: ' .. tostring(summary))
		return
	end
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

-- The competitive profile has everything; it must not earn the player's real
-- Steam achievements.
function Game:hook_UnlockAchievement(base, ...)
	if self:competitive_active() then return end
	return base(...)
end

function Game:hook_CheckProgressAchievements(base, ...)
	if self:competitive_active() then return end
	return base(...)
end

function Game:hook_CheckAchievement(base, ...)
	if self:competitive_active() then return end
	return base(...)
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
	check('arcana layouts ready', type(GS.MetaUpgradeLayoutsArt) == 'table' and type(GS.SavedMetaUpgradeLayouts) == 'table')
	check('game revision set', (tonumber(G.Revision) or 0) >= self.profile.REVISION, 'Revision=' .. tostring(G.Revision))
	local room = G.CurrentRun and G.CurrentRun.CurrentRoom
	check('the last room has an encounter', room ~= nil and type(room.Encounter) == 'table', room and tostring(room.Name))
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
	if self.board and self.board.ui then self.board.ui.pb_line = nil end
	if race.weapon ~= '' and G.WeaponData and G.WeaponData[race.weapon] then
		self:call('EquipPlayerWeapon', G.WeaponData[race.weapon], { SkipPresentation = true })
		-- In competitive mode the player picked their aspect in the hub; otherwise use the base aspect.
		if not self:competitive_active() and GS.LastWeaponUpgradeName and BASE_ASPECT[race.weapon] then
			GS.LastWeaponUpgradeName[race.weapon] = BASE_ASPECT[race.weapon]
		end
	end
	if race.keepsake ~= '' then GS.LastAwardTrait = race.keepsake end
	-- Remember this racer's Arcana, familiar and aspects for the next session.
	if self:competitive_active() and self.save_loadout then
		local ok, err = pcall(function() self.save_loadout(self.profile.capture_loadout(GS)) end)
		if not ok then self.log('game: saving the loadout failed: ' .. tostring(err)) end
	end
	self.launching = race
	self.status = nil
	local start_over = self:fn('StartOver')
	if not start_over then
		self.status = 'StartOver missing: cannot start runs on this game version.'
		self.log('game: ' .. self.status)
		return
	end
	local route = ROUTES[race.route] or ROUTES.underworld
	if route.dream then
		-- What UseDreamRunDoor does before StartOver.
		GS.StoredActiveShrineBounty = GS.ActiveShrineBounty
		GS.ActiveShrineBounty = nil
	end
	self:restore_door_prompts()
	self.log(string.format('game: launching race %s seed=%s route=%s', tostring(race.race_id), tostring(race.seed),
		tostring(race.route)))
	self:spawn(start_over, route.start())
end

-- Run doors in the competitive Crossroads ------------------------------------------
-- During the prep time after the votes, the voted route's door marks you ready
-- (everyone then starts together after the countdown). While a race is being
-- set up or run, the doors don't start runs of their own. Outside races they
-- work as usual (practice runs).

function Game:notice(title, subtitle, good)
	if self.banner then pcall(self.banner.notice, self.banner, title, subtitle, good) end
end

function Game:race_door(route)
	if not self:competitive_active() then return false end
	local c = self.client
	local phase = c and c:phase()
	if not phase or phase == 'waiting' or phase == 'finished' then return false end
	if phase == 'ready_check' then
		local vote = c.state.vote_results.route
		local voted = vote and vote.selected
		if voted and voted ~= '' and voted ~= route and ROUTES[voted] then
			self:notice('Wrong Way', 'This race starts at ' .. ROUTES[voted].label)
		else
			if c:ready() then self:notice('Ready', 'The race starts when everyone is ready', true) end
		end
	else
		self:notice('Not Yet', 'The race starts from the Race Board')
	end
	return true
end

function Game:hook_UseEscapeDoor(base, usee, args, ...)
	if self:race_door(args and args.StartingBiome == 'N' and 'surface' or 'underworld') then return end
	return base(usee, args, ...)
end

function Game:hook_UseDreamRunDoor(base, usee, args, ...)
	if self:race_door('dream') then return end
	return base(usee, args, ...)
end

-- The race's loadout in the Crossroads ----------------------------------------------
-- Once voted, the weapon racks hand out only the race's weapon (its aspects
-- stay free) and the keepsake rack is closed: every racer starts with the
-- voted keepsake. Keepsake racks between regions work as usual.

-- The voted weapon and keepsake while a race is being set up or run (nil
-- before each vote and outside races).
function Game:voted_loadout()
	local c = self.client
	local phase = c and c:phase()
	if not phase or phase == 'waiting' or phase == 'finished' then return nil, nil end
	local function pick(kind)
		local v = c.state.vote_results[kind]
		local id = v and v.selected
		if id and id ~= '' then return id end
		return nil
	end
	return pick('weapon'), pick('keepsake')
end

function Game:hook_UseWeaponKit(base, kit, args, user)
	local weapon = self:in_hub() and self:voted_loadout()
	if weapon and kit and kit.Name ~= weapon then
		self:notice('Locked', 'This race uses the ' .. self:display_name(weapon))
		return
	end
	return base(kit, args, user)
end

function Game:hook_UseKeepsakeRack(base, rack, user)
	local _, keepsake = self:voted_loadout()
	if keepsake and self:in_hub() then
		if self:fn('CannotUseKeepsakeRackPresentation') and rack then
			self:spawn(self.G.CannotUseKeepsakeRackPresentation, rack.ObjectId)
		end
		self:notice('Locked', 'This race starts with ' .. self:display_name(keepsake))
		return
	end
	return base(rack, user)
end

-- Competitive Crossroads: put the voted weapon and keepsake in the racer's
-- hands as the votes land, the way the racks would (PickupWeaponKit,
-- KeepsakeScreenClose), so the aspect they pick is for the race's weapon.
function Game:equip_voted_loadout()
	if not (self:competitive_active() and self:in_hub()) then
		self.equipping = nil
		return
	end
	local weapon, keepsake = self:voted_loadout()
	local G = self.G
	local hero, GS = G.CurrentRun and G.CurrentRun.Hero, G.GameState
	if not (hero and GS) then return end
	if not weapon then self.equipping = nil end
	if weapon and hero.Weapons and hero.Weapons[weapon] == nil and self.equipping ~= weapon then
		local kit = self:call('GetWeaponKit', weapon)
		if kit and self:fn('PickupWeaponKit') then
			self.equipping = weapon
			self.log('game: equipping the race weapon ' .. weapon)
			self:spawn(G.PickupWeaponKit, kit, {})
		end
	end
	if keepsake and GS.LastAwardTrait ~= keepsake and self:fn('EquipKeepsake') then
		self.log('game: equipping the race keepsake ' .. keepsake)
		local old = GS.LastAwardTrait
		local readd = old and self:call('UnequipKeepsake', hero, old)
		GS.LastAwardTrait = keepsake
		self:call('EquipKeepsake', hero, keepsake, { FromLoot = true })
		if readd ~= nil then self:call('TraitUIAdd', readd) end
	end
end

-- The prep time's prompt on the voted route's door: "{I} Ready to Race".
function Game:update_door_prompts()
	local c, G = self.client, self.G
	if not (c and G.MapState and G.MapState.ActiveObstacles and self:competitive_active() and self:in_hub()) then return end
	local want
	if c:phase() == 'ready_check' then
		local vote = c.state.vote_results.route
		want = (ROUTES[vote and vote.selected or ''] or ROUTES.underworld).door
	end
	if want == self.ready_door then return end
	self:restore_door_prompts()
	local door = want and G.MapState.ActiveObstacles[want]
	if door then
		self.ready_door = want
		self.ready_door_text = door.UseText
		door.UseText = 'RankedRace_ReadyDoor'
		if G.RefreshUseButton then pcall(G.RefreshUseButton, door.ObjectId, door) end
	end
end

function Game:restore_door_prompts()
	local G = self.G
	local door = self.ready_door and G.MapState and G.MapState.ActiveObstacles and G.MapState.ActiveObstacles[self.ready_door]
	if door and self.ready_door_text then
		door.UseText = self.ready_door_text
		if G.RefreshUseButton then pcall(G.RefreshUseButton, door.ObjectId, door) end
	end
	self.ready_door, self.ready_door_text = nil, nil
end

-- Dream Dive: the next dream biome is a random pick that also avoids the last
-- dive's start (a save-dependent record); decide it from the race seed.
function Game:hook_SelectNextDreamBiome(base, ...)
	if not self:race_run_live() or (self.mutations and self.mutations.no_depth_seed) then return base(...) end
	local GS = self.G.GameState
	self.dream_biomes = (self.dream_biomes or 0) + 1
	local saved = GS and GS.LastDreamStartingBiome
	if GS then GS.LastDreamStartingBiome = nil end
	self:reseed('dreambiome', self.dream_biomes)
	local results = { pcall(base, ...) }
	if GS and GS.LastDreamStartingBiome == nil then GS.LastDreamStartingBiome = saved end
	if not results[1] then error(results[2], 0) end
	return unpack_results(results)
end

function Game:race_over(result)
	if self.race then self.race.finished = true end
	if self.racelog then pcall(self.racelog.stop, self.racelog, { reason = result and result.reason, you_won = result and result.you_won }) end
	self:restore_loadout()
end

function Game:cancel_race()
	self.launching = nil
	self:restore_loadout()
end

-- progress -------------------------------------------------------------------------

-- The opponent-visible build: traits that came from loot (god boons, Chaos,
-- hammers), not the keepsake/aspect/Arcana everyone in competitive shares.
function Game:build_list()
	local G = self.G
	local hero = G.CurrentRun and G.CurrentRun.Hero
	local source_of = self:fn('GetLootSourceName')
	local list = {}
	if not (hero and source_of) then return list end
	for _, trait in ipairs(hero.Traits or {}) do
		local ok, source = pcall(source_of, trait.Name, { ForBoonInfo = true })
		if ok and source then
			list[#list + 1] = { name = trait.Name, rarity = trait.Rarity, source = source, level = trait.StackNum }
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

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
		build = self:build_list(),
		stats = self:run_stats(),
	}
end

local function sum(t)
	local n = 0
	for _, v in pairs(type(t) == 'table' and t or {}) do
		if type(v) == 'number' then n = n + v end
	end
	return n
end

-- This run's numbers for the race results (all from CurrentRun, as the game's
-- own run clear screen reads them).
function Game:run_stats()
	local run = self.G.CurrentRun
	if not run then return {} end
	local hero = run.Hero or {}
	local function int(v) return math.floor((tonumber(v) or 0) + 0.5) end
	local gained = type(run.ResourcesGained) == 'table' and run.ResourcesGained or {}
	return {
		DamageDealt = int(sum(run.DamageDealtByHeroRecord) + sum(run.DamageDealtByCharmedEnemiesRecord)),
		DamageTaken = int(run.TotalDamageTaken or sum(run.DamageTakenFromRecord)),
		Kills = int(sum(run.EnemyKills)),
		Healed = int(sum(run.ActualHealthRecord)),
		GoldEarned = int(gained.Money),
		Rooms = #(run.RoomHistory or {}),
		DeathDefiancesUsed = int(hero.LastStandsUsed),
		Hammers = int(hero.HammerCount),
		Boons = #self:build_list(),
		MaxHealth = int(hero.MaxHealth),
	}
end

-- Pause menu "Race Menu" (or Quit) during a live race: the Race Board shows
-- the race menu (chat, forfeit) or the forfeit prompt, controller-first.
-- See competitive.lua.
function Game:forfeit_available()
	return self:race_run_live() and self.client ~= nil
end

function Game:request_forfeit(page)
	if not self:forfeit_available() then return false end
	self.log('game: ' .. (page == 'race' and 'race menu' or 'forfeit') .. ' requested')
	if self.board then self.board:prompt(page or 'forfeit') end
	return true
end

-- Give up: a DNF like dying. Report first, then end the run: straight home in
-- competitive mode, a normal death otherwise (the KillHero hook sees the race
-- as finished already).
function Game:forfeit_now()
	if not self:forfeit_available() then return false end
	local G = self.G
	self:rlog('forfeit', {})
	self.race.finished = true
	self.race.forfeited = true
	self.log('game: forfeiting the race')
	self.client:report_progress(self:progress(false), true)
	self.client:forfeit(self:run_stats(), self:build_list())
	if self:competitive_active() then return self:go_home('forfeit') end
	local hero = G.CurrentRun and G.CurrentRun.Hero
	if hero and not hero.IsDead and G.Kill then
		self:spawn(function()
			if G.wait then G.wait(0.5) end
			G.Kill(hero, { AttackerName = 'RankedRaceForfeit' })
		end)
	end
	return true
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

-- Once the competitive Crossroads is up after the title-screen entry.
function Game:fade_in_hub()
	if not (self.fade_in_pending and self:competitive_active() and self:in_hub()) then return end
	self.fade_in_pending = false
	self:call('FadeIn', { Duration = 0.5 })
	self.log('game: fading the Crossroads in')
end

-- Competitive Crossroads: remember the racer's Arcana, layouts, familiar and
-- aspects as they change them (not only at a race start), so quitting to the
-- title screen keeps them. save_loadout writes only when something changed.
function Game:remember_loadout()
	if not (self.save_loadout and self:competitive_active() and self:in_hub() and self.G.GameState) then return end
	local now = self.now()
	if now - (self.last_remember or 0) < 2 then return end
	self.last_remember = now
	self.save_loadout(self.profile.capture_loadout(self.G.GameState))
end

function Game:update()
	pcall(self.diagnose, self, self.now())
	-- Frames that stopped coming for a while: a pause or a load (diagnostics;
	-- the frame callback rides the game's script update, which pauses too).
	local t = self.now()
	if self.last_frame and t - self.last_frame > 1 then
		self.log(string.format('game: no frames for %.1f s', t - self.last_frame))
	end
	self.last_frame = t
	pcall(self.fade_in_hub, self)
	pcall(self.remember_loadout, self)
	self:in_hub_now()
	pcall(self.update_door_prompts, self)
	local ok, err = pcall(self.equip_voted_loadout, self)
	if not ok and self.now() - (self.last_equip_error or 0) >= 10 then
		self.last_equip_error = self.now()
		self.log('game: equipping the race loadout failed: ' .. tostring(err))
	end
	-- One timer: the game's own run timer pauses for menus and boon choices,
	-- so in competitive mode it is hidden and the race clock is the only one.
	if self:competitive_active() and self.G.SetConfigOption and self.now() - (self.last_timer_block or 0) >= 1 then
		self.last_timer_block = self.now()
		pcall(self.G.SetConfigOption, { Name = 'BlockGameplayTimer', Value = true })
	end
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
	-- Dream Dive: the intro room has no doors; talking to Hypnos sends you on.
	if a.phase == 'engage' and a.room and a.room.Name == 'Dream_Intro' and G.EnterNextDreamBiome then
		if not a.room.RaceBotEntered then
			a.room.RaceBotEntered = true
			self.log('game: bot entering the first dream biome')
			self:spawn(G.EnterNextDreamBiome, nil, {})
		end
		a.phase = 'wait_room'
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
			-- Walk onto the fight's start trigger; again every few seconds while it
			-- hasn't started (a reward picked up after the first visit gates it).
			if encounter and not encounter.StartTime and now - (a.teleported or -math.huge) > 4 then
				local ids = self:call('GetIdsByType', { Name = 'EncounterStartPoint' })
				if ids and ids[1] then
					a.teleported = now
					a.trigger_visits = (a.trigger_visits or 0) + 1
					-- Alternate on and off the point, so each visit is a fresh entry.
					local away = a.trigger_visits % 2 == 0
					self.log('game: bot walking ' .. (away and 'away from' or 'to') .. ' encounter start ' .. tostring(ids[1]))
					self:call('Teleport', { Id = run.Hero.ObjectId, DestinationId = ids[1], OffsetX = away and 600 or 0 })
				end
			end
			if not a.killing and G.RequiredKillEnemies and next(G.RequiredKillEnemies) then
				a.killing = true
				self:spawn(function()
					G.DestroyRequiredKills({ BlockLoot = true })
					a.killing = false
				end)
			elseif not a.killing and now - a.t0 > 12 and G.ActiveEnemies and next(G.ActiveEnemies)
				and ((encounter and not encounter.Completed) or self:bot_pylon_left()) then
				-- Fights won by breaking things rather than killing required
				-- enemies (Arachne's cocoons, the Surface's Soul Pylons), or delayed
				-- starts that wait for an enemy to notice you: clear everything left.
				a.killing = true
				self.log('game: bot clearing every active enemy (' .. tostring(encounter.Name) .. ')')
				self:spawn(function()
					for _, enemy in pairs(G.ShallowCopyTable(G.ActiveEnemies)) do
						if type(enemy) == 'table' and not enemy.IsDead then
							enemy.MoneyDropOnDeath, enemy.MetaPointDropOnDeath = nil, nil
							G.thread(G.Kill, enemy, { BlockRespawns = true, SkipDeathWeapons = true })
						end
					end
					G.wait(1)
					a.killing = false
				end)
			end
			-- Rewards can gate the fight (opening room: boon first) or follow it.
			-- A gating reward isn't always a required object (Selene's moon in
			-- the opening room): use the room's reward if the fight won't start.
			if encounter and not encounter.StartTime and now - a.t0 > 6 and not a.used_room_reward
				and not next(a.used or {}) then
				local name = room.ForceLootName or room.ChosenRewardType
				local ids = name and self:call('GetIdsByType', { Name = name })
				local obj = ids and ids[1] and G.MapState.ActiveObstacles and G.MapState.ActiveObstacles[ids[1]]
				if obj and obj.OnUsedFunctionName then
					a.used_room_reward = true
					self.log('game: bot using the room reward ' .. tostring(name))
					local hero = run.Hero
					self:spawn(G.CallFunctionName, obj.OnUsedFunctionName, obj, obj.OnUsedFunctionArgs, hero)
				end
			end
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
		local chaos_first = self.bot_cfg and self.bot_cfg.door_pick == 'chaos'
		local best
		-- Chaos gates are optional side rooms (their own room, a Chaos trial the
		-- bot can't take): only use one when it is the sole exit.
		local regular = 0
		for _, door in pairs(doors or {}) do
			if type(door) == 'table' and door.Room and not tostring(door.Room.Name):match('^Chaos') then regular = regular + 1 end
		end
		-- door_pick "chaos": take a Chaos gate whenever one is offered (tests depth tracking).
		if chaos_first then
			for id, door in pairs(doors or {}) do
				if type(door) == 'table' and door.Room and tostring(door.Room.Name):match('^Chaos') then
					best = door
					best.ObjectId = door.ObjectId or id
				end
			end
		end
		for id, door in pairs(best and {} or doors or {}) do
			if type(door) == 'table' and door.Room and (regular == 0 or not tostring(door.Room.Name):match('^Chaos')) then
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

-- A Surface room's Soul Pylon still standing (the exits wait for it).
function Game:bot_pylon_left()
	for _, enemy in pairs(self.G.ActiveEnemies or {}) do
		if type(enemy) == 'table' and enemy.Name == 'SoulPylon' and not enemy.IsDead then return true end
	end
	return false
end

-- Use each object the room requires (boon, max-health drop, ...) once, the
-- way the game's OnUsed handler does when the player presses interact.
function Game:bot_collect_rewards(a)
	local G = self.G
	local now = self.now()
	-- UseLoot and friends refuse while any screen (dialogue, menus) is open.
	if G.AreScreensActive and G.AreScreensActive() then
		if now - (a.screens_logged or 0) > 10 and next((G.MapState and G.MapState.RoomRequiredObjects) or {}) then
			a.screens_logged = now
			self.log('game: bot waiting for screens to close before using rewards')
		end
		return
	end
	a.used = a.used or {}
	local enc = a.room and a.room.Encounter
	for id, required in pairs((G.MapState and G.MapState.RoomRequiredObjects) or {}) do
		-- The live object (what OnUsed would receive) may be a different table:
		-- loot is the LootObjects entry (the map object can be bare, e.g. Chaos's
		-- boon); consumables default to UseConsumableItem (CreateConsumableItemFromData).
		local obj = (G.LootObjects and G.LootObjects[id]) or (G.MapState.ActiveObstacles and G.MapState.ActiveObstacles[id])
			or required
		-- Field NPCs (Artemis...) fight alongside you and give their boon after
		-- the encounter; talking to them first leaves the room stuck.
		if type(obj) == 'table' and tostring(obj.Name):match('^NPC_') and enc and not enc.Completed then obj = nil end
		if type(obj) == 'table' and not obj.OnUsedFunctionName and G.ConsumableData and G.ConsumableData[obj.Name] then
			obj.OnUsedFunctionName = 'UseConsumableItem'
		end
		if type(obj) == 'table' and not obj.OnUsedFunctionName and now - (a.skip_logged or 0) > 10 then
			a.skip_logged = now
			self.log('game: bot cannot use ' .. tostring(obj.Name) .. ' (no OnUsedFunctionName; live object '
				.. tostring(G.MapState.ActiveObstacles and G.MapState.ActiveObstacles[id] ~= nil) .. ')')
		end
		if now - (a.used[id] or -math.huge) > 8 and type(obj) == 'table' and obj.OnUsedFunctionName then
			a.used[id] = now
			self.log('game: bot using ' .. tostring(obj.Name) .. ' via ' .. obj.OnUsedFunctionName)
			local hero = G.CurrentRun.Hero
			self:spawn(function()
				if obj.OnUseEvents and G.RunEventsGeneric then G.RunEventsGeneric(obj.OnUseEvents, obj) end
				G.CallFunctionName(obj.OnUsedFunctionName, obj, obj.OnUsedFunctionArgs, hero)
				-- What the game's OnUsed handler does after the use function: wake
				-- whatever waits on this object. SpawnRoomReward sets NotifyName
				-- ("OnUsed<id>": the opening fight waits for it) on the table it
				-- returned, the RoomRequiredObjects entry, which for a hex drop is
				-- not the LootObjects one.
				local live = G.MapState and G.MapState.ActiveObstacles and G.MapState.ActiveObstacles[id]
				local woken = {}
				for _, t in ipairs({ obj, live or false, required }) do
					local name = type(t) == 'table' and t.NotifyName
					if name and not woken[name] and G.notifyExistingWaiters then
						woken[name] = true
						G.notifyExistingWaiters(name)
					end
				end
			end)
		end
	end
end

-- Press a screen button the way a player's input does: through the screen's
-- input loop (HandleScreenInput waits on "ScreenInput<name>"), which runs the
-- button's handler and then sees the screen closed and returns. Calling the
-- handler directly leaves the loop waiting, and whatever opened the screen
-- never resumes (Selene's hex: the opening fight waits on its OnUsed).
function Game:bot_press(screen, button)
	local G = self.G
	local event = 'ScreenInput' .. tostring(screen.Name or '')
	local waiting = type(G._eventListeners) == 'table' and G._eventListeners[event] ~= nil
	if waiting and type(G.NotifyResultsTable) == 'table' and G.notifyExistingWaiters then
		G.NotifyResultsTable[event] = button.Id
		G.notifyExistingWaiters(event)
	else
		self:spawn(G.CallFunctionName, button.OnPressedFunctionName, screen, button)
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

-- Back home after a death, the game waits for any input before giving the
-- player control (StartDeathLoop); a player would press something.
function Game:bot_wake_death_loop()
	local G = self.G
	local now = self.now()
	if self:in_hub() and G.notifyExistingWaiters and now - (self.last_death_wake or 0) >= 2 then
		self.last_death_wake = now
		G.notifyExistingWaiters('ReattachCameraOnInput')
	end
end

-- An open boon/upgrade choice: take the first option, like clicking it.
function Game:bot_choose_upgrade()
	local G = self.G
	-- Nemesis's trade: decline it (the room then plays out normally).
	local trade = G.ActiveScreens and G.ActiveScreens.TradeScreen
	if trade and not trade.bot_declined and G.TradeScreenDecline then
		trade.bot_declined = true
		self.log('game: bot declining a trade')
		self:spawn(G.TradeScreenDecline, trade, nil)
		return
	end
	-- Selene's hex choice is its own screen.
	local spell = G.ActiveScreens and G.ActiveScreens.SpellScreen
	if spell and spell.Components and not spell.bot_chose then
		local button = spell.Components.PurchaseButton1
		if button and G.AcceptAndCloseSpellScreen then
			spell.bot_chose = true
			self.log('game: bot choosing the first hex')
			self:bot_press(spell, button)
		end
		return
	end
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
	local screens, open = {}, {}
	for name, screen in pairs(G.ActiveScreens or {}) do
		open[#open + 1] = tostring(name)
		if screen.BlockExitsReady then screens[#screens + 1] = tostring(name) end
	end
	parts[#parts + 1] = 'blocking_screens=' .. table.concat(screens, ',')
	parts[#parts + 1] = 'open_screens=' .. table.concat(open, ',')
	parts[#parts + 1] = 'unlocked=' .. tostring(room and room.ExitsUnlocked)
	-- What the room's scripts are waiting for (waitUntil's event names).
	local waits = {}
	for event in pairs(type(G._eventListeners) == 'table' and G._eventListeners or {}) do waits[#waits + 1] = tostring(event) end
	table.sort(waits)
	parts[#parts + 1] = 'waits=' .. table.concat(waits, ','):sub(1, 300)
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
	local G = self.G
	local cfg = self.bot_cfg or {}
	-- clear_screen: go through the game's own run clear screen (as after the
	-- final boss), then close it like a player would.
	if cfg.clear_screen and self:fn('OpenRunClearScreen') and self:fn('CloseRunClearScreen') then
		self.log('game: bot clearing the run through the run clear screen')
		self:spawn(G.OpenRunClearScreen)
		self:spawn(function()
			G.waitUnmodified(cfg.clear_screen_seconds or 6)
			local screen = G.ActiveScreens and G.ActiveScreens.RunClear
			if screen then G.CloseRunClearScreen(screen) end
		end)
		return
	end
	self.log('game: bot recording run clear')
	self:call('RecordRunCleared')
end

function Game:quit()
	self.log('game: bot quitting')
	os.exit(0)
end

return Game
