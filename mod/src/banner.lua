-- Race announcements in the game's own style: a big 3-2-1-GO in the hub
-- (driven by the server's start time, so both racers see the same count)
-- and the game's info banner (DisplayInfoBanner, the "biome cleared"
-- banner) for the result. Text ids live in MapState like the rival plate's,
-- because map loads destroy objects and the engine reuses their ids.

local Banner = {}
Banner.__index = Banner

local LAYER = 'Combat_Menu_TraitTray_Overlay'
local GO_SHOWN_FOR = 1.0
local BELL = '/SFX/ThanatosAttackBell'

function Banner.new(deps)
	local b = setmetatable({}, Banner)
	b.G, b.log, b.client, b.game, b.now = deps.G, deps.log, deps.client, deps.game, deps.now
	b.disabled = false
	b.stats = { counts = 0, results = 0 }
	return b
end

function Banner:fail(what, err)
	self.disabled = true
	self.log('banner: disabled after ' .. what .. ' failed: ' .. tostring(err))
end

-- What the countdown should say now: '3', '2', '1', 'GO', or nil.
function Banner.count_text(race, remaining, since_go)
	if not race then return nil end
	if not race.started then
		local n = math.ceil(remaining or 0)
		if n >= 1 then return tostring(n) end
		return nil
	end
	if since_go and since_go < GO_SHOWN_FOR then return 'GO' end
	return nil
end

function Banner:count_id()
	local G = self.G
	local ms = G.MapState
	if not ms then return nil end
	if not ms.RankedRaceCount then
		local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = LAYER, X = G.ScreenCenterX or 960,
			Y = (G.ScreenCenterY or 540) - 160 })
		G.CreateTextBox({ Id = id, Text = ' ', Font = 'P22UndergroundSCHeavy', FontSize = 150, Justification = 'Center',
			Color = { 254, 255, 255, 255 }, ShadowColor = { 0, 0, 0, 240 }, ShadowOffset = { 0, 4 }, ShadowBlur = 0,
			OutlineThickness = 3, OutlineColor = { 0, 0, 0, 255 } })
		ms.RankedRaceCount = id
	end
	return ms.RankedRaceCount
end

function Banner:tick()
	local G, c = self.G, self.client
	local race = c.state.race
	local now = self.now()
	if race ~= self.race then self.race, self.go_at = race, nil end -- new race (or rematch)
	if race and race.started and not self.go_at then self.go_at = race.resumed and -math.huge or now end
	local text = Banner.count_text(race, c:countdown_remaining(), self.go_at and (now - self.go_at))
	if text ~= self.shown then
		self.shown = text
		local ms = G.MapState
		if text then
			local id = self:count_id()
			G.ModifyTextBox({ Id = id, Text = text, Color = text == 'GO' and { 255, 202, 110, 255 } or { 254, 255, 255, 255 } })
			pcall(G.PulseText, { Id = id, ScaleTarget = 1.25, ScaleDuration = 0.15, HoldDuration = 0, PulseBias = 0.02 })
			pcall(G.PlaySound, { Name = BELL })
			self.stats.counts = self.stats.counts + 1
		elseif ms and ms.RankedRaceCount then
			G.ModifyTextBox({ Id = ms.RankedRaceCount, Text = ' ' })
		end
	end

	local result = c.state.result
	if result and result ~= self.result_shown then
		self.result_shown = result
		self:announce(result)
	end
end

function Banner:announce(r)
	local G = self.G
	local title = r.draw and 'DRAW' or (r.you_won and 'VICTORY' or 'DEFEAT')
	local win = r.you_won and not r.draw
	self.stats.results = self.stats.results + 1
	self.log('banner: result ' .. title)
	G.thread(G.DisplayInfoBanner, nil, {
		Text = title,
		SubtitleText = r.winner_name and not r.draw and (tostring(r.winner_name):gsub('[{}@]', '') .. ' wins the race') or ' ',
		Delay = 0.5, Duration = 4,
		Layer = 'Overlay', FontScale = 1.0,
		TextColor = { 254, 255, 255, 255 }, TextFadeColor = win and { 64, 230, 255, 255 } or { 235, 70, 60, 255 },
		AnimationName = win and 'InfoBannerBossKillIn' or 'LocationBackingIrisDeathIn',
		AnimationOutName = win and 'InfoBannerBossKillOut' or 'LocationBackingIrisDeathOut',
		SubtitleFont = 'SpectralSCMedium', SubtitleDelay = 0.6, SubtitleOffsetY = 10,
	})
end

function Banner:update()
	if self.disabled or not self.G.MapState then return end
	local ok, err = pcall(self.tick, self)
	if not ok then self:fail('updating', err) end
end

return Banner
