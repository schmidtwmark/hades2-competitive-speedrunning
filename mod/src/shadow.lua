-- Rivals' shadows: a translucent Melinoë per rival that mirrors their
-- position, facing and movement while you are in the same room (rooms are
-- identical per depth, so coordinates line up). Each rival keeps one colour,
-- shared with their row on the rival plate.
--
-- It is a BlankObstacle3D with Melinoë's model, not a unit: units go through
-- SetupUnit and land in ActiveEnemies / RequiredKillEnemies. Their ids live in
-- MapState: a map load destroys every object and the engine reuses ids, so an
-- id from an older MapState must never be moved again. Any engine error
-- disables the feature for the session instead of breaking the run.

local Shadow = {}
Shadow.__index = Shadow

local MODEL = 'Melinoe_Mesh'
local FALLBACK_MODEL = 'MelMarker_Mesh'
local ALPHA = 0.45
-- The 3D obstacle draws Melinoë's model larger than the hero unit does.
Shadow.SCALE = 0.75
-- Same order as Hud.RIVAL_COLORS (violet, teal, gold, coral).
local TINTS = { { 0.55, 0.35, 1.0, 1.0 }, { 0.3, 0.9, 0.8, 1.0 }, { 1.0, 0.78, 0.35, 1.0 }, { 1.0, 0.45, 0.4, 1.0 } }
-- No update for this long (or a pause report): the shadow stays put with
-- "PAUSED" above her head (an overhead text like the game's PopOverheadText).
-- It only goes away when the rival leaves the room, finishes or disconnects.
local FROZEN_AFTER = 0.6
local PAUSE_TEXT, PAUSE_OFFSET_Y = 'PAUSED', -170
local SNAP_DISTANCE = 600 -- teleport instead of gliding beyond this
-- How long an attack/dash animation is reported after it starts.
local ACTION_TIME = 0.35

local ANIM = { run = 'MelinoeRun', idle = 'MelinoeIdle' }

function Shadow.new(deps)
	local s = setmetatable({}, Shadow)
	s.G, s.log, s.client, s.game, s.now = deps.G, deps.log, deps.client, deps.game, deps.now
	s.disabled = false
	s.stats = { spawns = 0, frames_visible = 0, max_error = 0, samples = 0 }
	return s
end

-- This map's shadows by rival id: { id = object id, x, y, anim, angle }.
function Shadow:shadows()
	local ms = self.G.MapState
	if not ms then return nil end
	ms.RankedRaceShadows = ms.RankedRaceShadows or {}
	return ms.RankedRaceShadows
end

function Shadow:fail(what, err)
	self.disabled = true
	self.log('shadow: disabled after ' .. what .. ' failed: ' .. tostring(err))
	local ms = self.G.MapState
	if ms then ms.RankedRaceShadows = nil end
end

-- Our own position for the rivals (rate-limited by the client).
function Shadow:send_own()
	local G, game = self.G, self.game
	if not game:race_run_live() then return end
	local hero = G.CurrentRun and G.CurrentRun.Hero
	if not (hero and hero.ObjectId and not hero.IsDead) then return end
	local ok, loc = pcall(G.GetLocation, { Id = hero.ObjectId })
	if not (ok and loc and loc.X) then return end
	local angle = G.GetAngle and select(2, pcall(G.GetAngle, { Id = hero.ObjectId })) or nil
	local moving = G.IsMoving and select(2, pcall(G.IsMoving, { Id = hero.ObjectId })) or false
	local action = self.action and self.now() < self.action.ends and self.action.anim or nil
	self.client:report_ghost({
		room = game:current_map(), depth = game:race_depth(),
		x = loc.X, y = loc.Y, angle = type(angle) == 'number' and angle or nil,
		anim = action or (moving == true and 'run' or 'idle'), act = self.act,
		paused = (G.SessionMapState and G.SessionMapState.IsPaused) and true or nil,
	})
end

-- Our hero attacked, cast or dashed (game.lua's weapon-fire hook): the rival's
-- shadow of us plays the same animation.
function Shadow:note_action(anim)
	if type(anim) ~= 'string' or anim == '' then return end
	self.act = (self.act or 0) + 1
	self.action = { anim = anim, ends = self.now() + ACTION_TIME }
end

function Shadow:should_show(r)
	local g = r.ghost
	return g ~= nil and not r.finished and r.connected ~= false and g.room == self.game:current_map()
end

function Shadow:frozen(g, now)
	return g.paused == true or now - (g.received or -math.huge) > FROZEN_AFTER
end

function Shadow:spawn(g, tint)
	local G = self.G
	local id = G.SpawnObstacle({ Name = 'BlankObstacle3D', Group = 'Standing', LocationX = g.x, LocationY = g.y,
		TriggerOnSpawn = false })
	if not id or id == 0 then error('SpawnObstacle returned ' .. tostring(id)) end
	local model_ok = pcall(G.SetThingProperty, { Property = 'GrannyModel', Value = MODEL, DestinationId = id })
	if not model_ok then G.SetThingProperty({ Property = 'GrannyModel', Value = FALLBACK_MODEL, DestinationId = id }) end
	pcall(G.SetThingProperty, { Property = 'StopsProjectiles', Value = false, DestinationId = id })
	pcall(G.SetThingProperty, { Property = 'StopsUnits', Value = false, DestinationId = id })
	pcall(G.SetThingProperty, { Property = 'AddColor', Value = true, DestinationId = id })
	pcall(G.SetColor, { Id = id, Color = tint })
	pcall(G.SetAlpha, { Id = id, Fraction = ALPHA })
	pcall(G.SetScale, { Id = id, Fraction = self.SCALE_OVERRIDE or Shadow.SCALE })
	self.stats.spawns = self.stats.spawns + 1
	self.log('shadow: spawned for ' .. tostring(g.room) .. ' at ' .. math.floor(g.x) .. ',' .. math.floor(g.y))
	return { id = id, x = g.x, y = g.y }
end

function Shadow:hide(list, rid)
	local sh = list[rid]
	if sh then
		self:set_paused(sh, false)
		pcall(self.G.Destroy, { Id = sh.id })
		list[rid] = nil
	end
end

-- "PAUSED" above a frozen shadow's head.
function Shadow:set_paused(sh, paused)
	if (sh.paused or false) == paused then return end
	sh.paused = paused
	local G = self.G
	if sh.pause_id then
		pcall(G.Destroy, { Id = sh.pause_id })
		sh.pause_id = nil
	end
	if not paused then return end
	local ok, anchor = pcall(G.SpawnObstacle, { Name = 'BlankObstacleNoTimeModifier', DestinationId = sh.id,
		Group = 'Combat_Menu_Overlay', OffsetY = PAUSE_OFFSET_Y })
	if not (ok and anchor and anchor ~= 0) then return end
	sh.pause_id = anchor
	pcall(G.CreateTextBox, { Id = anchor, Text = PAUSE_TEXT, Justification = 'CENTER', Font = 'P22UndergroundSCMedium',
		FontSize = 64, Scale = 0.6, Color = { 235, 225, 255, 255 }, OutlineThickness = 3, OutlineColor = { 0, 0, 0, 1 },
		ShadowBlur = 0, ShadowColor = { 0, 0, 0, 1 }, ShadowOffset = { 0, 4 }, AutoSetDataProperties = false })
end

function Shadow:move(sh, g, dt)
	local G = self.G
	-- Glide toward the latest report; snap after long jumps (dashes, teleports).
	local dx, dy = g.x - sh.x, g.y - sh.y
	if dx * dx + dy * dy > SNAP_DISTANCE * SNAP_DISTANCE then
		sh.x, sh.y = g.x, g.y
	else
		local k = math.min(1, dt * 14)
		sh.x, sh.y = sh.x + dx * k, sh.y + dy * k
	end
	G.Teleport({ Id = sh.id, OffsetX = sh.x, OffsetY = sh.y })
	if g.angle and g.angle ~= sh.angle then
		pcall(G.SetAngle, { Ids = { sh.id }, Angle = g.angle })
		sh.angle = g.angle
	end
	-- Attacks and dashes replay on every new action (the same animation twice
	-- in a row too); otherwise run or idle.
	local anim = ANIM[g.anim] or g.anim or ANIM.idle
	if (g.act and g.act ~= sh.act and not ANIM[g.anim]) or anim ~= sh.anim then
		pcall(G.SetAnimation, { Name = anim, DestinationId = sh.id })
		sh.anim = anim
	end
	sh.act = g.act
	-- Test stats: the engine really put the shadow where we asked.
	self.stats.frames_visible = self.stats.frames_visible + 1
	local lok, loc = pcall(G.GetLocation, { Id = sh.id })
	if lok and loc and loc.X then
		local err_dist = math.sqrt((loc.X - sh.x) ^ 2 + (loc.Y - sh.y) ^ 2)
		self.stats.samples = self.stats.samples + 1
		if err_dist > self.stats.max_error and self.stats.samples > 10 then self.stats.max_error = err_dist end
	end
end

-- The rivals to draw. Test option (bot.json "shadow_mirror"): also mirror our
-- own hero, offset to the side, to compare the shadow with the real model.
function Shadow:shown_rivals()
	local rivals = self.client:rivals()
	local m = self.mirror
	if m then
		local G = self.G
		local hero = G.CurrentRun and G.CurrentRun.Hero
		local ok, loc = pcall(G.GetLocation, { Id = hero and hero.ObjectId })
		if ok and loc and loc.X then
			-- m.pause_cycle = N: frozen for the last third of every N seconds (pause icon check).
			local now = self.now()
			local paused = m.pause_cycle and (now % m.pause_cycle) > m.pause_cycle * 2 / 3 or nil
			local mirror = { id = 'mirror', name = 'mirror', connected = true,
				ghost = { room = self.game:current_map(), x = loc.X + (m.dx or 160), y = loc.Y + (m.dy or 0), anim = 'idle',
					act = self.act, received = now, paused = paused } }
			if self.action and self.now() < self.action.ends then mirror.ghost.anim = self.action.anim end
			local out = { mirror }
			for _, r in ipairs(rivals) do out[#out + 1] = r end
			return out
		end
	end
	return rivals
end

function Shadow:update()
	if self.disabled then return end
	local now = self.now()
	local ok, err = pcall(self.send_own, self)
	if not ok then return self:fail('sending own position', err) end
	local list = self:shadows()
	if not list then return end
	local dt = math.min(0.1, now - (self.last_frame or now))
	self.last_frame = now
	local live = self.game:race_run_live()
	local wanted = {}
	for i, r in ipairs(self:shown_rivals()) do
		if live and self:should_show(r) then
			wanted[r.id] = true
			if not list[r.id] then
				ok, err = pcall(self.spawn, self, r.ghost, TINTS[i] or TINTS[1])
				if not ok then return self:fail('spawning', err) end
				list[r.id] = err
			end
			local sh, frozen = list[r.id], self:frozen(r.ghost, now)
			if not frozen then
				ok, err = pcall(self.move, self, sh, r.ghost, dt)
				if not ok then return self:fail('moving', err) end
			end
			pcall(self.set_paused, self, sh, frozen)
		end
	end
	for rid in pairs(list) do
		if not wanted[rid] then self:hide(list, rid) end
	end
end

return Shadow
