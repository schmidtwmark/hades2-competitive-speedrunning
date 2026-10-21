-- Native rival plate during a race, top right: the opponent's name and
-- status, where they are (biome, depth, ahead/behind you), their HP on the
-- game's own HP bar art, both times, and their boons as icons with rarity
-- frames. Built from the same calls and styles as the game's HUD
-- (HUDData.lua) and faded with it whenever combat UI is hidden (dialogue,
-- boon choices, menus).
--
-- Every component lives in MapState: a map load destroys the objects and
-- the engine reuses their ids, so ids from an older MapState must never be
-- touched again. Any engine error disables the plate (the ImGui HUD then
-- takes over).

local Hud = {}
Hud.__index = Hud

local BIOMES = {
	F = 'Erebus', G = 'Oceanus', H = 'Fields of Mourning', I = 'Tartarus',
	N = 'Ephyra', O = 'Thessaly', P = 'Olympus', Q = 'Summit', Chaos = 'Chaos',
}
-- ColorData.lua values (0-255).
local WHITE, TITLE, GREY = { 254, 255, 255, 255 }, { 255, 202, 110, 255 }, { 190, 190, 200, 255 }
local GREEN, RED, GOLD = { 115, 199, 69, 255 }, { 235, 70, 60, 255 }, { 255, 214, 49, 255 }
local SHADOW = {
	ShadowRed = 0.1, ShadowBlue = 0.1, ShadowGreen = 0.1,
	OutlineColor = { 0.113, 0.113, 0.113, 1 }, OutlineThickness = 2,
	ShadowAlpha = 1.0, ShadowBlur = 1, ShadowOffset = { 0, 4 },
}
local GROUP = 'Combat_UI'
local CLOCK_GROUP = 'Combat_Menu_TraitTray_Overlay' -- above menus: the clock never hides
local MARGIN = 48         -- from the right edge
local CLOCK_Y = 34
local TOP = 92            -- rival plate, under the race clock
local BAR_SCALE = 0.32    -- HPBarFill is the player's bar, ~1050 px wide at 1.0
local BAR_WIDTH = 1050 * BAR_SCALE
local ICON_SCALE, ICON_STEP, ICONS_PER_ROW = 0.3, 44, 7
local FADE = 0.2

function Hud.biome_name(room)
	if type(room) ~= 'string' then return '?' end
	local key = room:match('^(Chaos)') or room:match('^(%a)_')
	return BIOMES[key or ''] or room
end

local function fmt_time(t)
	if type(t) ~= 'number' then return '--:--' end
	if t < 0 then t = 0 end
	local m = math.floor(t / 60)
	return string.format('%d:%05.2f', m, t - m * 60)
end
Hud.fmt_time = fmt_time

-- "1 room ahead of you" / "2 rooms behind you", from the opponent's side.
function Hud.depth_delta(mine, theirs)
	local d = (theirs or 0) - (mine or 0)
	if d == 0 then return 'level with you', GREY end
	local n = math.abs(d)
	local rooms = n == 1 and '1 room' or (n .. ' rooms')
	if d > 0 then return rooms .. ' ahead of you', RED end
	return rooms .. ' behind you', GREEN
end

-- Status line and colour for the opponent.
local DNF_TEXT = { died = 'FALLEN', forfeit = 'FORFEITED', disconnect = 'DISCONNECTED', timeout = 'OUT OF TIME' }

-- Status line for the rival. A rival who clears first has won, but you may
-- keep going to post your time; a rival who drops out (dies, forfeits,
-- disconnects) has not lost yet: you still have to finish.
function Hud.status(st)
	local r = st.result
	if r then
		if r.draw then return 'DRAW', GOLD end
		return r.you_won and 'YOU WIN' or 'YOU LOSE', r.you_won and GREEN or RED
	end
	local fin = st.opponent_finished
	if fin then
		if fin.victory then
			if st.decided and not st.decided.you_won then return 'WON THE RACE - FINISH FOR YOUR TIME', GOLD end
			return 'CLEARED', GOLD
		end
		return (DNF_TEXT[fin.outcome] or 'FALLEN') .. ' - FINISH TO WIN', RED
	end
	if st.opponent_connected == false then return 'DISCONNECTED', RED end
	return 'RIVAL', GREY
end

-- Both racers share one clock, so show it once; after the rival finishes,
-- their final time.
function Hud.clock_line(st, race_time)
	local fin = st.opponent_finished
	if fin and type(fin.time) == 'number' then
		return (fin.victory and 'Cleared at ' or 'Fell at ') .. fmt_time(fin.time)
	end
	return fmt_time(race_time)
end

function Hud.new(deps)
	local h = setmetatable({}, Hud)
	h.G, h.log, h.client, h.game, h.now = deps.G, deps.log, deps.client, deps.game, deps.now
	h.disabled = false
	h.stats = { builds = 0, refreshes = 0, hidden_frames = 0 }
	return h
end

-- The plate for the current map, or nil.
function Hud:plate()
	local ms = self.G.MapState
	return ms and ms.RankedRaceHud or nil
end

function Hud:active()
	return not self.disabled and self:plate() ~= nil
end

function Hud:wanted()
	local st = self.client.state
	return st.race ~= nil and st.race.started and self.game:race_run_live()
end

function Hud:fail(what, err)
	self.disabled = true
	self.log('hud: disabled after ' .. what .. ' failed: ' .. tostring(err))
	local ms = self.G.MapState
	if ms then ms.RankedRaceHud = nil end
end

local function text_args(id, font, size, justify, color)
	local a = { Id = id, Text = ' ', Font = font, FontSize = size, Justification = justify or 'Right',
		Color = color or WHITE, DataProperties = { OpacityWithOwner = true } }
	for k, v in pairs(SHADOW) do a[k] = v end
	return a
end

function Hud:obstacle(p, x, y, anim, scale)
	local G = self.G
	local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = GROUP, X = x, Y = y, Scale = scale or 1 })
	if anim then G.SetAnimation({ Name = anim, DestinationId = id }) end
	p.all[#p.all + 1] = id
	return id
end

function Hud:text(p, x, y, font, size, justify, color)
	local id = self:obstacle(p, x, y)
	self.G.CreateTextBox(text_args(id, font, size, justify, color))
	return id
end

function Hud:create()
	local G = self.G
	local right = (G.ScreenWidth or 1920) - MARGIN
	local p = { all = {}, boons = {}, visible = true }
	p.name = self:text(p, right, TOP, 'P22UndergroundSCMedium', 30, 'Right', TITLE)
	p.status = self:text(p, right, TOP + 34, 'P22UndergroundSCMedium', 18, 'Right', GREY)
	p.where = self:text(p, right, TOP + 66, 'P22UndergroundSCMedium', 24, 'Right', WHITE)
	p.delta = self:text(p, right, TOP + 96, 'P22UndergroundSCMedium', 20, 'Right', GREY)
	-- HP: the player's bar fill art; its fraction is the *missing* part.
	local bar_cx = right - BAR_WIDTH / 2
	p.hp_fill = self:obstacle(p, bar_cx, TOP + 140, 'HPBarFill', BAR_SCALE)
	p.hp_text = self:text(p, bar_cx, TOP + 140, 'NumericP22UndergroundSCHeavy', 22, 'Center', WHITE)
	p.times = self:text(p, right, TOP + 172, 'NumericP22UndergroundSCMedium', 20, 'Right', GREY)
	p.boon_top, p.right = TOP + 222, right
	G.MapState.RankedRaceHud = p
	self.stats.builds = self.stats.builds + 1
end

function Hud:set(id, text, color)
	local args = { Id = id, Text = text, AutoSetDataProperties = false }
	if color then args.Color = color end
	self.G.ModifyTextBox(args)
end

function Hud:show_build(p, build)
	local G = self.G
	if #p.boons > 0 then pcall(G.Destroy, { Ids = p.boons }) end
	p.boons = {}
	local shown = 0
	for _, entry in ipairs(build or {}) do
		local trait = G.TraitData and G.TraitData[entry.name]
		local icon = trait and trait.Icon
		if icon then
			-- Rows start under the left end of the HP bar, in the order taken.
			local col, row = shown % ICONS_PER_ROW, math.floor(shown / ICONS_PER_ROW)
			local x = p.right - BAR_WIDTH + 22 + col * ICON_STEP
			local y = p.boon_top + row * ICON_STEP
			local frame = entry.rarity and ('Frame_Boon_Menu_' .. entry.rarity) or 'BoonIcon_Frame_Common'
			for _, anim in ipairs({ icon, frame }) do
				local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = GROUP, X = x, Y = y, Scale = ICON_SCALE })
				G.SetAnimation({ Name = anim, DestinationId = id })
				if not p.visible then G.SetAlpha({ Id = id, Fraction = 0 }) end
				p.boons[#p.boons + 1] = id
			end
			shown = shown + 1
		end
	end
end

-- Follow the game's own HUD: hidden while anything blocks combat UI.
function Hud:combat_ui_hidden()
	local ms = self.G.MapState
	return ms ~= nil and type(ms.CombatUIHide) == 'table' and next(ms.CombatUIHide) ~= nil
end

function Hud:set_visible(p, visible)
	if p.visible == visible then return end
	p.visible = visible
	local ids = {}
	for _, id in ipairs(p.all) do ids[#ids + 1] = id end
	for _, id in ipairs(p.boons) do ids[#ids + 1] = id end
	self.G.SetAlpha({ Ids = ids, Fraction = visible and 1 or 0, Duration = FADE })
end

function Hud:refresh(p)
	local st, c, G = self.client.state, self.client, self.G
	local opp = st.opponent
	local name = c:opponent_name() or 'Rival'
	self:set(p.name, name)
	self:set(p.status, Hud.status(st))
	if opp then
		self:set(p.where, string.format('Depth %d  %s', opp.depth or 0, Hud.biome_name(opp.room)))
		self:set(p.delta, Hud.depth_delta(self.game:race_depth(), opp.depth))
		local hp, max = opp.hp or 0, opp.max_hp or opp.hp or 1
		local frac = math.max(0, math.min(1, hp / math.max(1, max)))
		G.SetAnimationFrameTarget({ Name = 'HPBarFill', Fraction = 1 - frac, DestinationId = p.hp_fill, Instant = true })
		self:set(p.hp_text, string.format('%d/%d', math.ceil(hp), math.ceil(max)))
		local key = ''
		for _, e in ipairs(opp.build or {}) do key = key .. e.name .. (e.rarity or '') .. ',' end
		if key ~= p.build_key then
			p.build_key = key
			self:show_build(p, opp.build)
		end
	else
		self:set(p.where, 'Entering Erebus')
		self:set(p.delta, ' ')
		self:set(p.hp_text, ' ')
	end
	-- The clock itself is the separate race timer; this line is only for the
	-- rival's final time once they are done.
	local fin = st.opponent_finished
	self:set(p.times, (fin and type(fin.time) == 'number') and Hud.clock_line(st, c:race_time()) or ' ')
	self.stats.refreshes = self.stats.refreshes + 1
end

function Hud:destroy()
	local p = self:plate()
	if not p then return end
	local ids = {}
	for _, id in ipairs(p.all) do ids[#ids + 1] = id end
	for _, id in ipairs(p.boons) do ids[#ids + 1] = id end
	pcall(self.G.Destroy, { Ids = ids })
	self.G.MapState.RankedRaceHud = nil
end

function Hud:destroy_clock()
	local ms = self.G.MapState
	if ms and ms.RankedRaceClock then
		pcall(self.G.Destroy, { Id = ms.RankedRaceClock })
		ms.RankedRaceClock = nil
	end
end

-- The one race timer: real time since the start (the server's clock is the
-- official one), never paused for menus or boon choices, always on top.
function Hud:update_clock()
	local G, ms = self.G, self.G.MapState
	local id = ms.RankedRaceClock
	if not id then
		id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = CLOCK_GROUP, X = (G.ScreenWidth or 1920) - MARGIN, Y = CLOCK_Y })
		local a = text_args(id, 'NumericP22UndergroundSCHeavy', 36, 'Right', WHITE)
		a.DataProperties = nil
		G.CreateTextBox(a)
		ms.RankedRaceClock = id
		self.stats.clocks = (self.stats.clocks or 0) + 1
	end
	local now = self.now()
	if now - (self.last_clock or 0) >= 0.05 then
		self.last_clock = now
		G.ModifyTextBox({ Id = id, Text = fmt_time(self.client:race_time()), AutoSetDataProperties = false })
	end
end

function Hud:update()
	if self.disabled or not self.G.MapState then return end
	if not self:wanted() then
		self:destroy()
		self:destroy_clock()
		return
	end
	local cok, cerr = pcall(self.update_clock, self)
	if not cok then return self:fail('drawing the race clock', cerr) end
	local p = self:plate()
	if not p then
		local ok, err = pcall(self.create, self)
		if not ok then return self:fail('creating the plate', err) end
		p = self:plate()
		self.last_refresh = nil
	end
	local ok, err = pcall(self.set_visible, self, p, not self:combat_ui_hidden())
	if not ok then return self:fail('fading', err) end
	if not p.visible then self.stats.hidden_frames = self.stats.hidden_frames + 1 end
	local now = self.now()
	if now - (self.last_refresh or 0) >= 0.25 then
		self.last_refresh = now
		ok, err = pcall(self.refresh, self, p)
		if not ok then return self:fail('refreshing', err) end
	end
end

return Hud
