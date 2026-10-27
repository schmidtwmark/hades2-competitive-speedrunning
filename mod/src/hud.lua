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
-- The clock's font has proportional digits, so a single right-aligned text
-- shifts every time a digit changes. Each character gets its own fixed cell.
local CLOCK_CELLS = 9       -- up to "180:00.00" (the race time limit)
local CLOCK_DIGIT_W = 23
local CLOCK_PUNCT_W = 11
local SPLIT_Y = 70        -- the latest region split, under the race clock
local TOP = 104           -- rival plate, under the split
local BAR_SCALE = 0.32    -- HPBarFill is the player's bar, ~1050 px wide at 1.0
local BAR_WIDTH = 1050 * BAR_SCALE
local SMALL_BAR_SCALE = 0.2
local SMALL_BAR_WIDTH = 1050 * SMALL_BAR_SCALE
local ROW_H = 96          -- one compact row per rival when racing more than one

-- One colour per rival, shared with their shadow (shadow.lua uses the same order).
Hud.RIVAL_COLORS = {
	{ 190, 150, 255, 255 }, -- violet
	{ 110, 230, 210, 255 }, -- teal
	{ 255, 202, 110, 255 }, -- gold
	{ 255, 130, 120, 255 }, -- coral
}
local ICON_SCALE, ICON_STEP, ICONS_PER_ROW = 0.3, 44, 7
local FADE = 0.2

-- Names go into text boxes, which parse {tokens} and @icons: keep them literal.
local function safe_name(name)
	return (tostring(name or '?'):gsub('[{}@]', ''))
end

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

local DNF_TEXT = { died = 'FALLEN', forfeit = 'FORFEITED', disconnect = 'DISCONNECTED', timeout = 'OUT OF TIME' }
local PLACE = { '1ST', '2ND', '3RD', '4TH', '5TH' }

-- Status line for one rival (r = client rival record). A rival who clears
-- first has won, but you may keep going for your time and place; a rival who
-- drops out (dies, forfeits, disconnects) hasn't lost to you yet: you still
-- have to finish. `many`: racing more than one rival (shorter wording).
function Hud.status(st, r, many)
	local res = st.result
	if res then
		for _, e in ipairs(res.results or {}) do
			if e.id == r.id and e.place then return PLACE[e.place] or ('#' .. e.place), e.place == 1 and GOLD or GREY end
		end
		if res.draw then return 'DRAW', GOLD end
		return res.you_won and 'YOU WIN' or 'YOU LOSE', res.you_won and GREEN or RED
	end
	local fin = r.finished
	if fin then
		if fin.victory then
			if st.decided and st.decided.winner == r.id and not st.decided.you_won then
				return many and 'WON THE RACE' or 'WON THE RACE - FINISH FOR YOUR TIME', GOLD
			end
			return 'CLEARED', GOLD
		end
		return (DNF_TEXT[fin.outcome] or 'FALLEN') .. (many and '' or ' - FINISH TO WIN'), RED
	end
	if r.connected == false then return 'DISCONNECTED', RED end
	return many and 'RACING' or 'RIVAL', GREY
end

-- The rival's name, then their Fear when they took on the Oath of the Unseen:
-- the number and the game's own skull icon, as its texts write it.
Hud.FEAR_ICON = '{!Icons.ShrinePointNoTooltip}'
function Hud.name_line(r)
	local stats = r.progress and r.progress.stats
	local fear = math.floor(tonumber(stats and stats.Fear) or 0)
	if fear <= 0 then return safe_name(r.name) end
	return safe_name(r.name) .. '   ' .. fear .. Hud.FEAR_ICON
end

-- Everyone shares one clock (shown once, at the top); a finished rival's
-- line shows their final time.
function Hud.clock_line(r, race_time)
	local fin = r and r.finished
	if fin and type(fin.time) == 'number' then
		return (fin.victory and 'Cleared at ' or 'Fell at ') .. fmt_time(fin.time)
	end
	return fmt_time(race_time)
end

-- "2 ahead" / "1 behind" / "level", for the compact rows.
function Hud.delta_short(mine, theirs)
	local d = (theirs or 0) - (mine or 0)
	if d == 0 then return 'level', GREY end
	if d > 0 then return d .. ' ahead', RED end
	return (-d) .. ' behind', GREEN
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
	local rivals = self.client:rivals()
	local p = { all = {}, boons = {}, visible = true, right = right, count = #rivals, rows = {} }
	if #rivals <= 1 then
		-- One rival: the full plate, boons included.
		local row = {}
		row.name = self:text(p, right, TOP, 'P22UndergroundSCMedium', 30, 'Right', TITLE)
		row.status = self:text(p, right, TOP + 34, 'P22UndergroundSCMedium', 18, 'Right', GREY)
		row.where = self:text(p, right, TOP + 66, 'P22UndergroundSCMedium', 24, 'Right', WHITE)
		row.delta = self:text(p, right, TOP + 96, 'P22UndergroundSCMedium', 20, 'Right', GREY)
		-- HP: the player's bar fill art; its fraction is the *missing* part.
		local bar_cx = right - BAR_WIDTH / 2
		row.hp_fill = self:obstacle(p, bar_cx, TOP + 140, 'HPBarFill', BAR_SCALE)
		row.hp_text = self:text(p, bar_cx, TOP + 140, 'NumericP22UndergroundSCHeavy', 22, 'Center', WHITE)
		row.times = self:text(p, right, TOP + 172, 'NumericP22UndergroundSCMedium', 20, 'Right', GREY)
		p.boon_top = TOP + 222
		p.rows[1] = row
	else
		-- Several rivals: a compact row each, in their shadow's colour.
		for i = 1, #rivals do
			local y, row = TOP + (i - 1) * ROW_H, {}
			row.name = self:text(p, right, y, 'P22UndergroundSCMedium', 24, 'Right', Hud.RIVAL_COLORS[i] or TITLE)
			row.status = self:text(p, right, y + 26, 'P22UndergroundSCMedium', 15, 'Right', GREY)
			row.where = self:text(p, right, y + 48, 'P22UndergroundSCMedium', 18, 'Right', WHITE)
			local bar_cx = right - SMALL_BAR_WIDTH / 2
			row.hp_fill = self:obstacle(p, bar_cx, y + 74, 'HPBarFill', SMALL_BAR_SCALE)
			row.hp_text = self:text(p, bar_cx, y + 74, 'NumericP22UndergroundSCHeavy', 15, 'Center', WHITE)
			p.rows[i] = row
		end
	end
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

function Hud:set_hp(row, prog, small)
	local hp, max = prog.hp or 0, prog.max_hp or prog.hp or 1
	local frac = math.max(0, math.min(1, hp / math.max(1, max)))
	self.G.SetAnimationFrameTarget({ Name = 'HPBarFill', Fraction = 1 - frac, DestinationId = row.hp_fill, Instant = true })
	self:set(row.hp_text, string.format('%d/%d', math.ceil(hp), math.ceil(max)))
end

-- Returns false when the plate no longer fits the racers (rebuild it).
function Hud:refresh(p)
	local st, c = self.client.state, self.client
	local rivals = c:rivals()
	if #rivals ~= p.count then return false end
	local many = #rivals > 1
	local mine = self.game:race_depth()
	for i, r in ipairs(rivals) do
		local row, prog = p.rows[i], r.progress
		self:set(row.name, Hud.name_line(r))
		self:set(row.status, Hud.status(st, r, many))
		if many then
			if prog then
				local d = Hud.delta_short(mine, prog.depth)
				self:set(row.where, string.format('Depth %d %s - %s', prog.depth or 0, Hud.biome_name(prog.room), d))
				self:set_hp(row, prog, true)
			else
				self:set(row.where, 'Entering Erebus')
				self:set(row.hp_text, ' ')
			end
		else
			if prog then
				self:set(row.where, string.format('Depth %d  %s', prog.depth or 0, Hud.biome_name(prog.room)))
				self:set(row.delta, Hud.depth_delta(mine, prog.depth))
				self:set_hp(row, prog)
				local key = ''
				for _, e in ipairs(prog.build or {}) do key = key .. e.name .. (e.rarity or '') .. ',' end
				if key ~= p.build_key then
					p.build_key = key
					self:show_build(p, prog.build)
				end
			else
				self:set(row.where, 'Entering Erebus')
				self:set(row.delta, ' ')
				self:set(row.hp_text, ' ')
			end
			-- The clock itself is the separate race timer; this line only shows
			-- the rival's final time once they are done.
			local fin = r.finished
			self:set(row.times, (fin and type(fin.time) == 'number') and Hud.clock_line(r, c:race_time()) or ' ')
		end
	end
	self.stats.refreshes = self.stats.refreshes + 1
	return true
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
		pcall(self.G.Destroy, { Ids = ms.RankedRaceClock.ids })
		ms.RankedRaceClock = nil
	end
end

-- Cell centres for a clock string, right to left from the right margin, so
-- digits never move: "12:34.56" -> one x per character.
function Hud.clock_cells(text, right)
	local xs, x = {}, right
	for i = #text, 1, -1 do
		local w = text:sub(i, i):match('%d') and CLOCK_DIGIT_W or CLOCK_PUNCT_W
		xs[i] = x - w / 2
		x = x - w
	end
	return xs
end

-- The one race timer: real time since the start (the server's clock is the
-- official one), never paused for menus or boon choices, always on top.
function Hud:update_clock()
	local G, ms = self.G, self.G.MapState
	local clock = ms.RankedRaceClock
	local now = self.now()
	if clock and now - (self.last_clock or 0) < 0.05 then return end
	self.last_clock = now
	local text = fmt_time(self.client:race_time())
	if #text > CLOCK_CELLS then text = text:sub(-CLOCK_CELLS) end
	-- Rebuild when the layout changes (e.g. 9:59.99 -> 10:00.00); otherwise
	-- only touch the characters that changed.
	if clock and clock.len ~= #text then
		self:destroy_clock()
		clock = nil
	end
	if not clock then
		clock = { ids = {}, chars = {}, len = #text }
		local xs = Hud.clock_cells(text, (G.ScreenWidth or 1920) - MARGIN)
		for i = 1, #text do
			local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = CLOCK_GROUP, X = xs[i], Y = CLOCK_Y })
			local a = text_args(id, 'NumericP22UndergroundSCHeavy', 36, 'Center', WHITE)
			a.DataProperties = nil
			G.CreateTextBox(a)
			clock.ids[i] = id
		end
		ms.RankedRaceClock = clock
		self.stats.clocks = (self.stats.clocks or 0) + 1
	end
	for i = 1, #text do
		local ch = text:sub(i, i)
		if clock.chars[i] ~= ch then
			clock.chars[i] = ch
			G.ModifyTextBox({ Id = clock.ids[i], Text = ch, AutoSetDataProperties = false })
		end
	end
end

-- Prep time (after the votes, in the Crossroads): time left and who is
-- ready, top right and above menus, so it stays in view on the Arcana and
-- aspect screens while racers set up. The Arcana screen keeps its Grasp meter
-- and layout decks in the top right corner: there the panel sits left of them.
local PREP_ROW_H = 30
local PREP_Y = 44
local PREP_ARCANA_RIGHT = 400 -- from the right edge, clear of the Grasp meter

-- The panel's title and one row per racer, or nil outside the prep time.
function Hud.prep_view(st, now)
	local lobby = st.lobby
	if not (lobby and lobby.phase == 'ready_check') then return nil end
	local title = 'Race starts when everyone is ready'
	if type(lobby.prep_ends_in) == 'number' then
		local left = math.max(0, math.ceil(lobby.prep_ends_in - (now - (lobby.received or now))))
		title = string.format('Race starts in %d:%02d', math.floor(left / 60), left % 60)
	end
	local rows = {}
	for _, p in ipairs(lobby.players or {}) do
		local state, color = 'setting up', GREY
		if p.ready then
			state, color = 'ready', GREEN
		elseif p.connected == false then
			state, color = 'away', RED
		end
		rows[#rows + 1] = { text = (p.id == lobby.you and 'You' or safe_name(p.name)) .. ' - ' .. state, color = color }
	end
	return { title = title, rows = rows }
end

function Hud:update_prep()
	local G, ms = self.G, self.G.MapState
	local now = self.now()
	if now - (self.last_prep or 0) < 0.2 then return end
	self.last_prep = now
	local view = self.game:in_hub() and Hud.prep_view(self.client.state, now) or nil
	local screens = G.ActiveScreens or {}
	local right = (G.ScreenWidth or 1920) - (screens.MetaUpgradeCardLayout and PREP_ARCANA_RIGHT or MARGIN)
	local panel = ms.RankedRacePrep
	if panel and (not view or panel.n ~= #view.rows or panel.right ~= right) then
		pcall(G.Destroy, { Ids = panel.ids })
		ms.RankedRacePrep, panel = nil, nil
	end
	if not view then return end
	if not panel then
		panel = { ids = {}, rows = {}, shown = {}, n = #view.rows, right = right }
		local function text(y, size, color)
			local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = CLOCK_GROUP, X = right, Y = y })
			local a = text_args(id, 'P22UndergroundSCMedium', size, 'Right', color)
			a.DataProperties = nil
			G.CreateTextBox(a)
			panel.ids[#panel.ids + 1] = id
			return id
		end
		panel.title = text(PREP_Y, 28, TITLE)
		for i = 1, panel.n do panel.rows[i] = text(PREP_Y + 12 + i * PREP_ROW_H, 20, GREY) end
		ms.RankedRacePrep = panel
		self.stats.prep_panels = (self.stats.prep_panels or 0) + 1
	end
	local function show(key, id, text, color)
		local shown = text .. ':' .. tostring(color and color[1])
		if panel.shown[key] ~= shown then
			panel.shown[key] = shown
			self:set(id, text, color)
		end
	end
	show('title', panel.title, view.title)
	for i, row in ipairs(view.rows) do show(i, panel.rows[i], row.text, row.color) end
end

-- Under the clock: the region being run and its PB split ("Erebus  best
-- 6:32.10", gold), and for SPLIT_HOLD seconds after each split its result
-- ("Erebus  5:12.30  -0:05.31", green ahead of the PB's split, red behind,
-- white without a PB).
local SPLIT_HOLD = 10
function Hud.split_line(sp, now, fmt_delta)
	if not sp then return nil end
	local last, target = sp.last, sp:target()
	if last and not (target and type(now) == 'number' and now - last.time >= SPLIT_HOLD) then
		local text, color = last.name .. '  ' .. fmt_time(last.time), WHITE
		if last.delta and fmt_delta then
			text = text .. '  ' .. fmt_delta(last.delta)
			color = last.delta < 0 and GREEN or RED
		end
		return text, color
	end
	if target then return target.name .. '  best ' .. fmt_time(target.time), GOLD end
	return nil
end

function Hud:update_split()
	local G, ms = self.G, self.G.MapState
	local race = self.game.race
	local now = self.client and self.client:race_time()
	local text, color = Hud.split_line(race and race.splits, now, self.game.Splits and self.game.Splits.fmt_delta)
	if not text then return end
	if not ms.RankedRaceSplit then
		local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = CLOCK_GROUP, X = (G.ScreenWidth or 1920) - MARGIN,
			Y = SPLIT_Y })
		local a = text_args(id, 'P22UndergroundSCMedium', 20, 'Right', color)
		a.DataProperties = nil
		G.CreateTextBox(a)
		ms.RankedRaceSplit = { id = id }
	end
	local split = ms.RankedRaceSplit
	if split.text ~= text then
		split.text = text
		self:set(split.id, text, color)
	end
end

function Hud:destroy_split()
	local ms = self.G.MapState
	if ms and ms.RankedRaceSplit then
		pcall(self.G.Destroy, { Id = ms.RankedRaceSplit.id })
		ms.RankedRaceSplit = nil
	end
end

function Hud:update()
	if self.disabled or not self.G.MapState then return end
	if not self.prep_failed then
		local ok, err = pcall(self.update_prep, self)
		if not ok then
			self.prep_failed = true
			self.log('hud: prep panel disabled: ' .. tostring(err))
		end
	end
	if not self:wanted() then
		self:destroy()
		self:destroy_clock()
		self:destroy_split()
		return
	end
	local cok, cerr = pcall(self.update_clock, self)
	if not cok then return self:fail('drawing the race clock', cerr) end
	local sok, serr = pcall(self.update_split, self)
	if not sok then return self:fail('drawing the split', serr) end
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
		local fits
		ok, fits = pcall(self.refresh, self, p)
		if not ok then return self:fail('refreshing', fits) end
		if fits == false then
			self:destroy()
			self.last_refresh = nil
		end
	end
end

return Hud
