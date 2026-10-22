-- Race announcements in the game's own style: a big 3-2-1-GO in the hub
-- (driven by the server's start time, so both racers see the same count)
-- and the game's info banner (DisplayInfoBanner, the "biome cleared"
-- banner) for the result. Text ids live in MapState like the rival plate's,
-- because map loads destroy objects and the engine reuses their ids.

local Banner = {}
Banner.__index = Banner

local LAYER = 'Combat_Menu_TraitTray_Overlay'
-- The countdown's font: fonts are bitmaps, and P22UndergroundSCHeavy (35 in
-- Fonts.sjson) drawn at 150 was blocky. SpectralSCLightTitling's glyphs stay
-- sharp at twice its nominal 64, also on a 4K screen (scripts/e2e-reenter.sh
-- screenshots).
local COUNT_FONT, COUNT_SIZE = 'SpectralSCLightTitling', 128
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
			Y = (G.ScreenCenterY or 540) - 250 })
		G.CreateTextBox({ Id = id, Text = ' ', Font = self.count_font or COUNT_FONT, FontSize = self.count_size or COUNT_SIZE, Justification = 'Center',
			Color = { 254, 255, 255, 255 }, ShadowColor = { 0, 0, 0, 240 }, ShadowOffset = { 0, 4 }, ShadowBlur = 0,
			OutlineThickness = 2, OutlineColor = { 0, 0, 0, 255 } })
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
	-- preview: test bots show a count by hand (screenshots of the font).
	local text = self.preview or Banner.count_text(race, c:countdown_remaining(), self.go_at and (now - self.go_at))
	if text ~= self.shown then
		self.shown = text
		local ms = G.MapState
		if text then
			local id = self:count_id()
			G.ModifyTextBox({ Id = id, Text = text, Color = text == 'GO' and { 255, 202, 110, 255 } or { 254, 255, 255, 255 } })
			pcall(G.PulseText, { Id = id, ScaleTarget = 1.1, ScaleDuration = 0.15, HoldDuration = 0, PulseBias = 0.02 })
			pcall(G.PlaySound, { Name = BELL })
			self.stats.counts = self.stats.counts + 1
		elseif ms and ms.RankedRaceCount then
			G.ModifyTextBox({ Id = ms.RankedRaceCount, Text = ' ' })
		end
	end

	-- One banner per race: when the winner is decided (possibly mid-run for the
	-- other racer), or at the final result if nothing was decided before.
	local decided, result = c.state.decided, c.state.result
	local race_id = (decided and decided.race_id) or (result and result.race_id)
	if (decided or result) and race_id ~= self.announced_race then
		self.announced_race = race_id
		self:announce(decided or result, result == nil)
	end
end

-- What the banner says. still_running: the race is decided but not over,
-- so the loser is told they can keep going.
function Banner.texts(r, still_running, self_running)
	local name = r.winner_name and tostring(r.winner_name):gsub('[{}@]', '') or nil
	if r.draw then return 'DRAW', 'Nobody finished the run' end
	if r.you_won then return 'VICTORY', still_running and 'First to clear the run' or ((name or 'You') .. ' wins the race') end
	if still_running and self_running then return 'DEFEAT', (name or 'Your rival') .. ' cleared first - finish for your time' end
	return 'DEFEAT', (name or 'Your rival') .. ' wins the race'
end

function Banner:announce(r, still_running)
	local G = self.G
	local completed = self.client.state.race and self.client.state.race.completed
	local title, subtitle = Banner.texts(r, still_running, not completed)
	local win = r.you_won and not r.draw
	self.stats.results = self.stats.results + 1
	self.log('banner: ' .. title .. ' / ' .. subtitle)
	G.thread(G.DisplayInfoBanner, nil, {
		Text = title,
		SubtitleText = subtitle,
		Delay = 0.5, Duration = 4,
		Layer = 'Overlay', FontScale = 1.0,
		TextColor = { 254, 255, 255, 255 }, TextFadeColor = win and { 64, 230, 255, 255 } or { 235, 70, 60, 255 },
		AnimationName = win and 'InfoBannerBossKillIn' or 'LocationBackingIrisDeathIn',
		AnimationOutName = win and 'InfoBannerBossKillOut' or 'LocationBackingIrisDeathOut',
		SubtitleFont = 'SpectralSCMedium', SubtitleDelay = 0.6, SubtitleOffsetY = 10,
	})
end

-- A short in-world message (e.g. "Ready" at a run door).
function Banner:notice(title, subtitle, good)
	local G = self.G
	if not (G.thread and G.DisplayInfoBanner) then return end
	self.log('banner: ' .. tostring(title) .. ' / ' .. tostring(subtitle))
	G.thread(G.DisplayInfoBanner, nil, {
		Text = title, SubtitleText = subtitle, Delay = 0, Duration = 2.5, Layer = 'Overlay', FontScale = 0.8,
		TextColor = { 254, 255, 255, 255 }, TextFadeColor = good and { 64, 230, 255, 255 } or { 235, 70, 60, 255 },
		AnimationName = 'LocationBackingIrisGenericIn', AnimationOutName = 'LocationBackingIrisGenericOut',
		SubtitleFont = 'SpectralSCMedium', SubtitleDelay = 0.2, SubtitleOffsetY = 10,
	})
end

function Banner:update()
	if self.disabled or not self.G.MapState then return end
	local ok, err = pcall(self.tick, self)
	if not ok then self:fail('updating', err) end
end

return Banner
