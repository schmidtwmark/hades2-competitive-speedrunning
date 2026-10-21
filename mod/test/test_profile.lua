local T = require('test.lib')
local Profile = T.load('profile.lua')

T.case('profile: every lifetime resource total starts past the game\'s thresholds', function()
	local G = { ResourceData = { MetaCardPointsCommon = {}, MetaCurrency = {}, CosmeticsPoints = {} },
		LootData = { ZeusUpgrade = {} }, ConsumableData = {}, RoomData = {}, TraitData = {} }
	local GS = { LifetimeResourcesGained = { MetaCurrency = 250000 } }
	Profile.mark_story_seen(G, GS)
	local life = GS.LifetimeResourcesGained
	T.eq(life.MetaCardPointsCommon, Profile.LIFETIME_TOTAL, 'Ashes: Bones are offered from the start')
	T.eq(life.CosmeticsPoints, Profile.LIFETIME_TOTAL)
	T.eq(life.MetaCurrency, 250000, 'never lowered')
	T.truthy(Profile.LIFETIME_TOTAL > 10000, 'above the highest threshold in the game data')
	-- A race pickup can't cross a threshold any more.
	life.MetaCardPointsCommon = life.MetaCardPointsCommon + 30
	T.truthy(life.MetaCardPointsCommon >= 5 and not (life.MetaCardPointsCommon < 800))
	T.eq(GS.ReachedTrueEnding, true)
	T.eq(GS.UseRecord.ZeusUpgrade, 4)
end)
