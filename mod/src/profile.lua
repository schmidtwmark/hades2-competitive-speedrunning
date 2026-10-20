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

-- Incantations left out: randomness (bonus weapon, next-run reroll) and resets.
local EXCLUDED_WORLD_UPGRADES = {
	WorldUpgradeUnusedWeaponBonus = true,
	WorldUpgradeUnusedWeaponBonusT2 = true,
	WorldUpgradeChangeNextRunRNG = true,
	WorldUpgradeStoryReset = true,
}

-- Story records that would otherwise force the prologue / intro rooms.
local STORY_RECORDS = { 'HecateHideAndSeekIntro01', 'ChronosNightmare01', 'ApolloFirstPickUp', 'ZeusFirstPickUp' }

-- Completed runs recorded in history; feeds GetCompletedRuns-based eligibility.
local STUB_RUNS = 50

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

-- Returns a summary table (counts per category) for logs and tests.
function Profile.build(G)
	local summary = {}

	-- Mirror StartNewGame, but start the bookkeeping run in a real room so
	-- CreateRoom has RoomData (the hub maps have none).
	G.GameState = {}
	G.GameStateInit()
	G.InitializeMetaUpgradeState()
	G.CurrentRun = nil
	G.StartNewRun(nil, { RoomName = 'F_Opening01', StartingBiome = 'F', SkipChooseEncounter = true, SkipChooseReward = true })
	G.CurrentRun.Hero.IsDead = true -- we are in the hub; that run is over
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
	for _, familiar in ipairs(G.FamiliarOrderData or {}) do
		GS.FamiliarsUnlocked[familiar] = true
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

	-- Skip the prologue and the forced intro encounters.
	for _, record in ipairs(STORY_RECORDS) do GS.TextLinesRecord[record] = true end
	GS.UseRecord.HermesUpgrade = 1
	GS.UseRecord.ApolloUpgrade = 1
	for _, encounter in ipairs(sorted_keys(G.EncounterData)) do
		GS.EncountersCompletedCache[encounter] = 1
		GS.EncountersOccurredCache[encounter] = 1
	end

	-- Identical run history for everyone.
	GS.RunHistory = {}
	for _ = 1, STUB_RUNS do
		local saved = G.CurrentRun
		G.CurrentRun = {}
		G.RunStateInit()
		G.CurrentRun.Hero = {}
		table.insert(GS.RunHistory, G.CurrentRun)
		G.CurrentRun = saved
	end
	summary.completed_runs = G.GetCompletedRuns()
	GS.GamePhase = 5
	GS.GamePhaseRunsRemaining = 2
	GS.NextBiomeStateName = nil
	return summary
end

return Profile
