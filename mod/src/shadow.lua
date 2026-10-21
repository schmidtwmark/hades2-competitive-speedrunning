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
-- Same order as Hud.RIVAL_COLORS (violet, teal, gold, coral).
local TINTS = { { 0.55, 0.35, 1.0, 1.0 }, { 0.3, 0.9, 0.8, 1.0 }, { 1.0, 0.78, 0.35, 1.0 }, { 1.0, 0.45, 0.4, 1.0 } }
local STALE_AFTER = 1.5   -- seconds without updates before hiding
local SNAP_DISTANCE = 600 -- teleport instead of gliding beyond this

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
	self.client:report_ghost({
		room = game:current_map(), depth = game:race_depth(),
		x = loc.X, y = loc.Y, angle = type(angle) == 'number' and angle or nil,
		anim = moving == true and 'run' or 'idle',
	})
end

function Shadow:should_show(r, now)
	local g = r.ghost
	return g ~= nil and not r.finished and g.room == self.game:current_map()
		and now - (g.received or -math.huge) < STALE_AFTER
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
	self.stats.spawns = self.stats.spawns + 1
	self.log('shadow: spawned for ' .. tostring(g.room) .. ' at ' .. math.floor(g.x) .. ',' .. math.floor(g.y))
	return { id = id, x = g.x, y = g.y }
end

function Shadow:hide(list, rid)
	local sh = list[rid]
	if sh then
		pcall(self.G.Destroy, { Id = sh.id })
		list[rid] = nil
	end
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
	local anim = ANIM[g.anim] or ANIM.idle
	if anim ~= sh.anim then
		pcall(G.SetAnimation, { Name = anim, DestinationId = sh.id })
		sh.anim = anim
	end
	-- Test stats: the engine really put the shadow where we asked.
	self.stats.frames_visible = self.stats.frames_visible + 1
	local lok, loc = pcall(G.GetLocation, { Id = sh.id })
	if lok and loc and loc.X then
		local err_dist = math.sqrt((loc.X - sh.x) ^ 2 + (loc.Y - sh.y) ^ 2)
		self.stats.samples = self.stats.samples + 1
		if err_dist > self.stats.max_error and self.stats.samples > 10 then self.stats.max_error = err_dist end
	end
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
	for i, r in ipairs(self.client:rivals()) do
		if live and self:should_show(r, now) then
			wanted[r.id] = true
			if not list[r.id] then
				ok, err = pcall(self.spawn, self, r.ghost, TINTS[i] or TINTS[1])
				if not ok then return self:fail('spawning', err) end
				list[r.id] = err
			end
			ok, err = pcall(self.move, self, list[r.id], r.ghost, dt)
			if not ok then return self:fail('moving', err) end
		end
	end
	for rid in pairs(list) do
		if not wanted[rid] then self:hide(list, rid) end
	end
end

return Shadow
