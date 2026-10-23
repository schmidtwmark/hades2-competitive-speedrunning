-- Builds the competitive profile: a fresh GameState (no save file involved)
-- with every unlock maxed, identical for every player. Called instead of the
-- game's StartNewGame when the title-screen entry loads a map without a profile.
--
-- Field names and rules come from the game's own scripts (build 25481925):
-- StartNewGame (RunLogic.lua:312), WeaponUpgradeLogic rank = 1 + unlocked
-- <Aspect>N shop items, KeepsakeLogic levels from KeepsakeChambers with
-- thresholds {25, 50}, FamiliarShopLogic levels from FamiliarUpgrades,
-- MetaUpgradeLogic card levels and MetaUpgradeLimitLevel (Grasp). See NOTES.md.

local Profile = {}

-- The game revision saves of the tested build carry (Profile1.sav: 143476).
Profile.REVISION = 143476

-- Incantations left out: randomness (bonus weapon, next-run reroll) and resets.
local EXCLUDED_WORLD_UPGRADES = {
	WorldUpgradeUnusedWeaponBonus = true,
	WorldUpgradeUnusedWeaponBonusT2 = true,
	WorldUpgradeChangeNextRunRNG = true,
	WorldUpgradeStoryReset = true,
}

-- Data tables whose dialogue and voice lines count as already heard: the
-- competitive profile has seen every story beat, so no first-meeting lines,
-- discovery barks or arrival cutscenes play, and nothing story-gated (Hermes,
-- Selene, hammers, Nectar, Dream Dive) stays locked.
local STORY_TABLES = { 'EnemyData', 'LootData', 'NPCVariantData', 'ConsumableData', 'RoomData', 'HubRoomData',
	'EncounterData', 'ObstacleData', 'GlobalVoiceLines', 'HeroVoiceLines', 'HeroRepeatableTextLines', 'PresetEventArgs',
	'TraitData', 'WeaponData', 'FamiliarData', 'ResourceData', 'WorldUpgradeData', 'QuestData', 'BountyData',
	'ScreenData', 'StoreData', 'RewardData' }
-- Keys whose values are named text line sets.
local SET_KEYS = { InteractTextLineSets = true, GiftTextLineSets = true, BossIntroTextLineSets = true,
	BossOutroTextLineSets = true, BossPhaseChangeTextLineSets = true, DeathPresentationTextLineSets = true,
	CombatIntroTextLineSets = true, OnHitTextLineSets = true, RejectionTextLines = true, MakeUpTextLines = true,
	BoughtTextLines = true, DuoPickupTextLines = true, PostPortraitTextLines = true, TextLineSet = true }
-- One-time tutorials and hints (GameState.Flags).
local TUTORIAL_FLAGS = { 'SeenElementalIcons', 'SeenUnityBoons', 'HasPinnedAnyBoon', 'HasUpgradedCards',
	'InspectedMetaUpgrade', 'SecondUpgradeReminder', 'MetaUpgradeExpandPsycheHint', 'HasUsedSaveFirstSystem',
	'HasUsedWeaponShopNavigation', 'HasMultiPlanted', 'HasShuffledMusicPlayer' }

-- Every resource's lifetime total (see mark_story_seen): above the game's
-- highest lifetime threshold (10000, cosmetics).
Profile.LIFETIME_TOTAL = 100000

-- Completed runs recorded in history; feeds GetCompletedRuns-based eligibility.
local STUB_RUNS = 50

-- Times every encounter counts as won and seen, like a veteran's file. Rooms and
-- boss attacks can unlock only after repeat wins: Erebus's other two minibosses
-- need two Root-Stalker wins, Hecate's meteor hex ten. At 1, every Erebus run met
-- the Root-Stalker and bosses fought with their first-encounter movesets.
Profile.ENCOUNTER_COUNT = 10

local function satisfy(G, reqs)
	for _, r in ipairs(reqs or {}) do
		local p = r.PathTrue
		if p and p[1] == 'GameState' and #p == 3 then
			G.GameState[p[2]] = G.GameState[p[2]] or {}
			G.GameState[p[2]][p[3]] = true
		end
	end
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t or {}) do
		if type(k) == 'string' then keys[#keys + 1] = k end
	end
	table.sort(keys)
	return keys
end

-- Mark every text line set and voice cue the game knows as already played,
-- plus first pickups, tutorials, first screens, objectives and quests. The
-- true ending counts as reached (every 100% save is in that state): without
-- it the fully-heard story leaves Hecate "missing" (no Erebus boss fight) and
-- a Typhon kill would lock the Surface route. Returns the line-set count.
function Profile.mark_story_seen(G, GS)
	GS.TextLinesRecord = GS.TextLinesRecord or {}
	GS.SpeechRecord = GS.SpeechRecord or {}
	GS.SpeechRecordContexts = GS.SpeechRecordContexts or {}
	local seen, sets = {}, 0
	local function mark_set(name)
		if not GS.TextLinesRecord[name] then sets = sets + 1 end
		GS.TextLinesRecord[name] = true
	end
	local function walk(t, ctx)
		if seen[t] then return end
		seen[t] = true
		if type(rawget(t, 'PlayOnceContext')) == 'string' then ctx = rawget(t, 'PlayOnceContext') end
		local cue = rawget(t, 'Cue')
		if type(cue) == 'string' and cue:sub(1, 4) == '/VO/' then
			GS.SpeechRecord[cue] = GS.SpeechRecord[cue] or 1
			if ctx then
				GS.SpeechRecordContexts[ctx] = GS.SpeechRecordContexts[ctx] or {}
				GS.SpeechRecordContexts[ctx][cue] = true
			end
		end
		for k, v in pairs(t) do
			if type(v) == 'table' then
				if SET_KEYS[k] then
					for name, set in pairs(v) do
						if type(name) == 'string' and type(set) == 'table' then mark_set(name) end
					end
				end
				walk(v, ctx)
			end
		end
	end
	for name in pairs(G.TextLinesCache or {}) do
		if type(name) == 'string' then mark_set(name) end
	end
	for _, name in ipairs(STORY_TABLES) do
		if type(G[name]) == 'table' then walk(G[name]) end
	end
	GS.ReachedTrueEnding = true
	GS.UseRecord = GS.UseRecord or {}
	GS.LootPickups = GS.LootPickups or {}
	for name in pairs(G.LootData or {}) do
		GS.UseRecord[name] = math.max(GS.UseRecord[name] or 0, 4)
		GS.LootPickups[name] = math.max(GS.LootPickups[name] or 0, 10)
	end
	for name in pairs(G.ConsumableData or {}) do GS.UseRecord[name] = math.max(GS.UseRecord[name] or 0, 4) end
	GS.Flags = GS.Flags or {}
	for _, flag in ipairs(TUTORIAL_FLAGS) do GS.Flags[flag] = true end
	GS.ScreensViewed = GS.ScreensViewed or {}
	for name in pairs(G.ScreenData or {}) do GS.ScreensViewed[name] = true end
	GS.CompletedObjectiveSets = GS.CompletedObjectiveSets or {}
	for name in pairs(G.ObjectiveSetData or {}) do GS.CompletedObjectiveSets[name] = true end
	GS.QuestStatus, GS.QuestsCompleted, GS.QuestsViewed = GS.QuestStatus or {}, GS.QuestsCompleted or {}, GS.QuestsViewed or {}
	for _, quest in ipairs(G.QuestOrderData or {}) do
		GS.QuestStatus[quest] = 'CashedOut'
		GS.QuestsCompleted[quest] = true
		GS.QuestsViewed[quest] = true
	end
	GS.RoomsEntered = GS.RoomsEntered or {}
	for name in pairs(G.RoomData or {}) do GS.RoomsEntered[name] = math.max(GS.RoomsEntered[name] or 0, 10) end
	GS.TraitsSeen = GS.TraitsSeen or {}
	for name in pairs(G.TraitData or {}) do GS.TraitsSeen[name] = true end
	-- Lifetime totals of every resource, past every threshold the game checks
	-- (the highest is 10000). ~150 reward, room and shop rules read them, e.g.
	-- Bones are only offered after 5 lifetime Ashes: started at 0, a racer who
	-- picked up Ashes unlocked Bones for themselves only, mid-race.
	GS.LifetimeResourcesGained = GS.LifetimeResourcesGained or {}
	for name in pairs(G.ResourceData or {}) do
		if type(name) == 'string' then
			GS.LifetimeResourcesGained[name] = math.max(GS.LifetimeResourcesGained[name] or 0, Profile.LIFETIME_TOTAL)
		end
	end
	-- A Dream Dive's first biome avoids the last dive's: no last dive.
	GS.LastDreamStartingBiome = nil
	return sets
end

-- Arcana layouts (the Arcana screen's saved card sets) in a JSON-safe form:
-- { ["1"] = { card names, sorted } }, art { ["1"] = texture }, the current one.
function Profile.layouts_out(saved_layouts, art)
	local layouts, out_art = {}, {}
	for slot, set in pairs(type(saved_layouts) == 'table' and saved_layouts or {}) do
		if tonumber(slot) and type(set) == 'table' then
			local names = {}
			for name, on in pairs(set) do
				if on then names[#names + 1] = name end
			end
			table.sort(names)
			layouts[string.format('%d', tonumber(slot))] = names
		end
	end
	for slot, num in pairs(type(art) == 'table' and art or {}) do
		if tonumber(slot) and tonumber(num) then out_art[string.format('%d', tonumber(slot))] = tonumber(num) end
	end
	return layouts, out_art
end

local function apply_layouts(G, GS, saved)
	if type(saved.layouts) == 'table' then
		GS.SavedMetaUpgradeLayouts = {}
		for slot, names in pairs(saved.layouts) do
			if tonumber(slot) and type(names) == 'table' then
				local set = {}
				for _, name in ipairs(names) do
					if G.MetaUpgradeCardData[name] then set[name] = true end
				end
				GS.SavedMetaUpgradeLayouts[tonumber(slot)] = set
			end
		end
	end
	if type(saved.layout_art) == 'table' then
		GS.MetaUpgradeLayoutsArt = {}
		for slot, num in pairs(saved.layout_art) do
			if tonumber(slot) and tonumber(num) then GS.MetaUpgradeLayoutsArt[tonumber(slot)] = tonumber(num) end
		end
	end
	if tonumber(saved.layout) then GS.CurrentMetaUpgradeLayout = tonumber(saved.layout) end
end

-- The racer's own picks: from earlier competitive sessions (main.lua keeps
-- them in the mod's data folder), else from save file 1 (savefile.lua):
-- equipped Arcana within the Grasp limit, the Arcana layouts, the familiar
-- and each weapon's aspect. Returns how many Arcana were equipped.
function Profile.apply_loadout(G, GS, saved)
	if type(saved) ~= 'table' then return 0 end
	apply_layouts(G, GS, saved)
	local budget, n = G.GetMaxMetaUpgradeCost and G.GetMaxMetaUpgradeCost() or 0, 0
	for _, name in ipairs(type(saved.arcana) == 'table' and saved.arcana or {}) do
		local data, state = G.MetaUpgradeCardData[name], GS.MetaUpgradeState[name]
		local cost = type(data) == 'table' and (data.Cost or 0) or nil
		if state and state.Unlocked and cost and cost <= budget then
			state.Equipped = true
			budget = budget - cost
			n = n + 1
		end
	end
	if G.UpdateMetaUpgradeCardAdjacencyBonuses then pcall(G.UpdateMetaUpgradeCardAdjacencyBonuses) end
	if type(saved.familiar) == 'string' and GS.FamiliarsUnlocked[saved.familiar] then GS.EquippedFamiliar = saved.familiar end
	for weapon, aspect in pairs(type(saved.aspects) == 'table' and saved.aspects or {}) do
		if type(aspect) == 'string' and G.TraitData and G.TraitData[aspect] then GS.LastWeaponUpgradeName[weapon] = aspect end
	end
	return n
end

-- What apply_loadout restores, read from the current profile.
function Profile.capture_loadout(GS)
	local out = { arcana = {}, aspects = {}, familiar = GS.EquippedFamiliar }
	for name, state in pairs(GS.MetaUpgradeState or {}) do
		if type(state) == 'table' and state.Equipped then out.arcana[#out.arcana + 1] = name end
	end
	table.sort(out.arcana)
	for weapon, aspect in pairs(GS.LastWeaponUpgradeName or {}) do out.aspects[weapon] = aspect end
	out.layouts, out.layout_art = Profile.layouts_out(GS.SavedMetaUpgradeLayouts, GS.MetaUpgradeLayoutsArt)
	out.layout = GS.CurrentMetaUpgradeLayout
	return out
end

-- The remembered competitive loadout over save file 1's: what the racer set
-- in competitive mode wins and the save fills in the rest. The Arcana (cards,
-- layouts, current layout) move as one: the game rewrites the current layout
-- from the equipped cards, so they must agree. Loadouts remembered before
-- layouts were (0.5.4 and older) take the save's Arcana.
local ARCANA_KEYS = { arcana = true, layouts = true, layout_art = true, layout = true }
function Profile.merge_loadouts(mine, from_save)
	if type(from_save) ~= 'table' then return mine end
	if type(mine) ~= 'table' then return from_save end
	local out = {}
	for k, v in pairs(from_save) do out[k] = v end
	for k, v in pairs(mine) do
		if not ARCANA_KEYS[k] or mine.layouts ~= nil then out[k] = v end
	end
	return out
end

-- Returns a summary table (counts per category) for logs and tests.
-- `saved`: the racer's loadout from an earlier session (optional).
function Profile.build(G, saved)
	local summary = {}

	-- Mirror StartNewGame, but start the bookkeeping run in a real room so
	-- CreateRoom has RoomData (the hub maps have none).
	G.GameState = {}
	G.GameStateInit()
	-- Which game revision this profile belongs to. A loaded save sets the global;
	-- left at 0, DoPatches (every map load) would treat every trait as coming from
	-- an old save and remove and re-add ~30 of them in every room (among them
	-- HeraSpecialBoon and AphroditeSprintBoon, whose HUD icons then drew under the
	-- empty-slot art). A newer save file 1 raises it for newer builds.
	G.Revision = math.max(tonumber(G.Revision) or 0, Profile.REVISION, tonumber(type(saved) == 'table' and saved.revision) or 0)
	G.RevisionFirstSave = G.RevisionFirstSave or G.Revision
	summary.revision = G.Revision
	G.InitializeMetaUpgradeState()
	G.CurrentRun = nil
	G.StartNewRun(nil, { RoomName = 'F_Opening01', StartingBiome = 'F', SkipChooseEncounter = true, SkipChooseReward = true })
	G.CurrentRun.Hero.IsDead = true -- we are in the hub; that run is over
	-- The Crossroads' scripts read the last run's room encounter (ManaLogic's
	-- regen loop: "attempt to index local 'encounter'" once Magick dropped, e.g.
	-- on an aspect change); this bookkeeping room skipped choosing one.
	local room = G.CurrentRun.CurrentRoom
	if room and room.Encounter == nil and G.SetupEncounter and G.EncounterData and G.EncounterData.Empty then
		room.Encounter = G.SetupEncounter(G.EncounterData.Empty, room)
	end
	local GS = G.GameState
	-- The game's own guard: RequestSave skips every save while this is set.
	GS.IllegalConversationModification = true

	-- Weapons, aspects (all ranks), tools.
	local n = 0
	for _, name in ipairs(sorted_keys(G.WeaponShopItemData)) do
		if name ~= 'BaseWeaponUpgrade' then
			GS.WeaponsUnlocked[name] = true
			G.UnlockWorldUpgrade(name)
			n = n + 1
		end
	end
	local free = G.ScreenData and G.ScreenData.WeaponUpgradeScreen and G.ScreenData.WeaponUpgradeScreen.FreeUnlocks
	for _, aspect in pairs(free or {}) do
		GS.WeaponsUnlocked[aspect] = true
		G.UnlockWorldUpgrade(aspect)
	end
	summary.weapon_shop_items = n

	-- Incantations (main category), minus the excluded ones.
	n = 0
	local cats = G.ScreenData and G.ScreenData.GhostAdmin and G.ScreenData.GhostAdmin.ItemCategories
	for _, name in ipairs((cats and cats[1]) or {}) do
		if type(name) == 'string' and not EXCLUDED_WORLD_UPGRADES[name] then
			G.UnlockWorldUpgrade(name)
			n = n + 1
		end
	end
	summary.incantations = n

	-- Keepsakes: unlocked and at 75 chambers (rank 3 = Epic).
	n = 0
	for _, npc in ipairs(sorted_keys(G.GiftData)) do
		local gift = G.GiftData[npc]
		if type(gift) == 'table' then
			for _, level in ipairs(gift) do
				satisfy(G, level.GameStateRequirements)
				if level.Gift then
					GS.KeepsakeChambers[level.Gift] = 75
					n = n + 1
				end
			end
		end
	end
	GS.LifetimeResourcesGained.GiftPoints = math.max(GS.LifetimeResourcesGained.GiftPoints or 0, 1)
	summary.keepsakes = n

	-- Familiars and all their upgrades.
	n = 0
	GS.TraitsTaken = GS.TraitsTaken or {}
	for _, familiar in ipairs(G.FamiliarOrderData or {}) do
		GS.FamiliarsUnlocked[familiar] = true
		-- Their traits count as taken: an untaken one puts a "!" over the familiar.
		local data = G.FamiliarData and G.FamiliarData[familiar]
		for _, trait in ipairs(type(data) == 'table' and data.TraitNames or {}) do GS.TraitsTaken[trait] = true end
		n = n + 1
	end
	local shop = G.ScreenData and G.ScreenData.FamiliarShop
	for _, upgrade in ipairs((shop and shop.ItemOrder) or {}) do
		if type(upgrade) == 'string' then
			GS.FamiliarUpgrades[upgrade] = true
			G.UnlockWorldUpgrade(upgrade)
		end
	end
	summary.familiars = n

	-- Arcana: every card unlocked at max rank, none equipped (players choose), max Grasp.
	n = 0
	for _, name in ipairs(sorted_keys(G.MetaUpgradeCardData)) do
		local data = G.MetaUpgradeCardData[name]
		local state = GS.MetaUpgradeState[name]
		if type(data) == 'table' and not data.DebugOnly and state then
			state.Unlocked = true
			state.Level = #(data.UpgradeResourceCost or {}) + 1
			state.Equipped = nil
			n = n + 1
		end
	end
	GS.MetaUpgradeLimitLevel = #G.MetaUpgradeCostData.MetaUpgradeLevelData
	summary.arcana = n
	summary.grasp = G.GetMaxMetaUpgradeCost()
	if G.UpdateMetaUpgradeUnlockedCountCache then G.UpdateMetaUpgradeUnlockedCountCache() end

	-- No Fear, no God Mode scaling.
	GS.ShrineUpgrades = {}
	GS.SpentShrinePointsCache = 0
	GS.EasyModeLevel = 0

	-- Every aspect equipped as the weapon's base aspect (at rank V) until the
	-- player picks another; with nothing set, runs use a bonus-less dummy.
	for weapon, aspect in pairs(free or {}) do GS.LastWeaponUpgradeName[weapon] = aspect end

	-- Seen everything: story, dialogue, voice lines, tutorials, first pickups.
	summary.story_lines = Profile.mark_story_seen(G, GS)
	-- Weapon and cast tutorials (the controls list that otherwise shows after
	-- each weapon pickup or aspect change). Not the in-run challenge objectives.
	GS.CompletedObjectiveSets = GS.CompletedObjectiveSets or {}
	for name in pairs(G.ObjectiveSetData or {}) do
		if type(name) == 'string' and name:find('Tutorial') then GS.CompletedObjectiveSets[name] = true end
	end
	for _, encounter in ipairs(sorted_keys(G.EncounterData)) do
		GS.EncountersCompletedCache[encounter] = Profile.ENCOUNTER_COUNT
		GS.EncountersOccurredCache[encounter] = Profile.ENCOUNTER_COUNT
	end

	-- Identical run history for everyone.
	GS.RunHistory = {}
	for _ = 1, STUB_RUNS do
		local saved = G.CurrentRun
		G.CurrentRun = {}
		G.RunStateInit()
		G.CurrentRun.Hero = {}
		-- Story rooms forced until seen within N runs: seen in every run.
		G.CurrentRun.RoomsEntered = G.CurrentRun.RoomsEntered or {}
		for name, room in pairs(G.RoomData or {}) do
			if type(room) == 'table' and room.ForceIfUnseenForRuns then G.CurrentRun.RoomsEntered[name] = 1 end
		end
		table.insert(GS.RunHistory, G.CurrentRun)
		G.CurrentRun = saved
	end
	summary.completed_runs = G.GetCompletedRuns()
	GS.GamePhase = 5
	GS.GamePhaseRunsRemaining = 2
	GS.NextBiomeStateName = nil
	summary.saved_arcana = Profile.apply_loadout(G, GS, saved)
	-- What loading a save adds: DoPatches runs on every map load, but on this
	-- first one it ran before the profile existed. Without it the Arcana
	-- screen's layout slots have no art table and the screen errors on open.
	GS.CurrentMetaUpgradeLayout = GS.CurrentMetaUpgradeLayout or 1
	GS.SavedMetaUpgradeLayouts = GS.SavedMetaUpgradeLayouts or {}
	GS.MetaUpgradeLayoutsArt = GS.MetaUpgradeLayoutsArt or {}
	if G.DoPatches then
		local ok, err = pcall(G.DoPatches)
		summary.patched = ok or tostring(err)
	end
	return summary
end

return Profile
