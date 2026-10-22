local T = require('test.lib')
local Game = T.load('game.lua')
local Profile = T.load('profile.lua')

-- A competitive Crossroads with weapon kits and a keepsake rack, and a client
-- in the given lobby phase with these vote results.
local function fake_hub(phase, results)
	local G = { CurrentHubRoom = { Name = 'Hub_PreRun' }, RankedRaceCompetitive = { active = true }, calls = {} }
	G.GameState = { LastAwardTrait = 'OldKeepsake' }
	G.CurrentRun = { Hero = { Weapons = { WeaponStaffSwing = {} } } }
	G.MapState = { WeaponKits = { [1] = { Name = 'WeaponAxe' }, [2] = { Name = 'WeaponStaffSwing' } } }
	local function log(name) return function(...) G.calls[#G.calls + 1] = { name, ... } end end
	G.thread = function(fn, ...) fn(...) end
	G.GetWeaponKit = function(name)
		for _, kit in pairs(G.MapState.WeaponKits) do if kit.Name == name then return kit end end
	end
	G.PickupWeaponKit = function(kit) G.calls[#G.calls + 1] = { 'PickupWeaponKit', kit.Name }; G.CurrentRun.Hero.Weapons = { [kit.Name] = {} } end
	G.EquipKeepsake = log('EquipKeepsake')
	G.UnequipKeepsake = log('UnequipKeepsake')
	G.CannotUseKeepsakeRackPresentation = log('locked rack')
	local g = Game.new({ rom = { game = G }, log = function() end, now = function() return 0 end })
	local vote_results = {}
	for kind, id in pairs(results or {}) do vote_results[kind] = { phase = kind, selected = id } end
	g.client = { state = { vote_results = vote_results }, phase = function() return phase end }
	g.notices = {}
	g.notice = function(self, title, sub) self.notices[#self.notices + 1] = title .. ': ' .. sub end
	return g, G
end

local function called(G, name)
	for _, c in ipairs(G.calls) do if c[1] == name then return c end end
	return nil
end

T.case('race loadout: only the voted weapon\'s rack works once voted (its aspects stay free)', function()
	local g, G = fake_hub('ready_check', { weapon = 'WeaponStaffSwing', keepsake = 'BossPreDamageKeepsake' })
	local used = {}
	local base = function(kit) used[#used + 1] = kit.Name end
	g:hook_UseWeaponKit(base, { Name = 'WeaponAxe' })
	T.eq(#used, 0, 'another weapon is refused')
	T.truthy(g.notices[1] and g.notices[1]:find('^Locked'), 'and says why')
	g:hook_UseWeaponKit(base, { Name = 'WeaponStaffSwing' })
	T.eq(used[1], 'WeaponStaffSwing', 'the race weapon opens as usual (aspect screen)')
end)

T.case('race loadout: racks are free before the votes, after the race and away from the hub', function()
	for _, case in ipairs({ { 'voting_weapon', {} }, { 'waiting', { weapon = 'WeaponStaffSwing' } },
		{ 'finished', { weapon = 'WeaponStaffSwing', keepsake = 'BossPreDamageKeepsake' } } }) do
		local g = fake_hub(case[1], case[2])
		local used = 0
		g:hook_UseWeaponKit(function() used = used + 1 end, { Name = 'WeaponAxe' })
		g:hook_UseKeepsakeRack(function() used = used + 1 end, { ObjectId = 7 })
		T.eq(used, 2, case[1])
	end
	-- Mid-run (a region's keepsake rack): swapping keepsakes is allowed.
	local g, G = fake_hub('racing', { weapon = 'WeaponStaffSwing', keepsake = 'BossPreDamageKeepsake' })
	G.CurrentHubRoom = nil
	G.CurrentRun.CurrentRoom = { Name = 'F_PostBoss01' }
	local opened = false
	g:hook_UseKeepsakeRack(function() opened = true end, { ObjectId = 7 })
	T.truthy(opened, 'post-boss rack opens')
end)

T.case('race loadout: the Crossroads keepsake rack is closed once the keepsake is voted', function()
	local g, G = fake_hub('ready_check', { weapon = 'WeaponStaffSwing', keepsake = 'BossPreDamageKeepsake' })
	local opened = false
	g:hook_UseKeepsakeRack(function() opened = true end, { ObjectId = 7 })
	T.eq(opened, false)
	T.truthy(called(G, 'locked rack'), 'the game\'s locked-rack shake and sound')
end)

T.case('race loadout: competitive puts the voted weapon and keepsake in hand once', function()
	local g, G = fake_hub('ready_check', { weapon = 'WeaponAxe', keepsake = 'BossPreDamageKeepsake' })
	g:equip_voted_loadout()
	T.eq(called(G, 'PickupWeaponKit')[2], 'WeaponAxe')
	T.eq(G.GameState.LastAwardTrait, 'BossPreDamageKeepsake')
	T.eq(called(G, 'UnequipKeepsake')[3], 'OldKeepsake')
	T.eq(called(G, 'EquipKeepsake')[3], 'BossPreDamageKeepsake')
	local n = #G.calls
	g:equip_voted_loadout()
	T.eq(#G.calls, n, 'nothing more once equipped')
	-- Own save (not competitive): nothing is equipped early.
	local g2, G2 = fake_hub('ready_check', { weapon = 'WeaponAxe', keepsake = 'BossPreDamageKeepsake' })
	G2.RankedRaceCompetitive = nil
	g2:equip_voted_loadout()
	T.eq(#G2.calls, 0)
	T.eq(G2.GameState.LastAwardTrait, 'OldKeepsake')
end)

T.case('profile: the Arcana screen\'s layout tables exist and DoPatches runs once built', function()
	-- Only the tail of Profile.build matters here; build the minimum around it.
	local GS
	local G = { WeaponShopItemData = {}, GiftData = {}, MetaUpgradeCardData = {}, EncounterData = {},
		MetaUpgradeCostData = { MetaUpgradeLevelData = { 1, 2 } }, ResourceData = {}, LootData = {}, RoomData = {} }
	function G.GameStateInit()
		GS = { WeaponsUnlocked = {}, KeepsakeChambers = {}, LifetimeResourcesGained = {}, FamiliarsUnlocked = {},
			FamiliarUpgrades = {}, MetaUpgradeState = {}, LastWeaponUpgradeName = {}, EncountersCompletedCache = {},
			EncountersOccurredCache = {}, Flags = {}, UseRecord = {}, TextLinesRecord = {}, SpeechRecord = {} }
		G.GameState = GS
	end
	function G.InitializeMetaUpgradeState() end
	function G.StartNewRun() G.CurrentRun = { Hero = {} } end
	function G.UnlockWorldUpgrade() end
	function G.GetMaxMetaUpgradeCost() return 30 end
	function G.RunStateInit() end
	function G.GetCompletedRuns() return 50 end
	local patched = 0
	function G.DoPatches() patched = patched + 1; T.truthy(G.GameState.MetaUpgradeLayoutsArt ~= nil) end
	local ok, summary = pcall(Profile.build, G)
	T.truthy(ok, tostring(summary))
	T.eq(patched, 1)
	T.eq(type(GS.MetaUpgradeLayoutsArt), 'table')
	T.eq(type(GS.SavedMetaUpgradeLayouts), 'table')
	T.eq(GS.CurrentMetaUpgradeLayout, 1)
end)
