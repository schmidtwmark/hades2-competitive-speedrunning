-- The opponent's shadow: a translucent Melinoë that mirrors the opponent's
-- position, facing and movement while both racers are in the same room
-- (rooms are identical per depth, so their coordinates line up).
--
-- It is a BlankObstacle3D with Melinoë's model, not a unit: units go through
-- SetupUnit and land in ActiveEnemies / RequiredKillEnemies. Its id lives in
-- MapState: a map load destroys every object and the engine reuses ids, so an
-- id from an older MapState must never be moved again. Any engine error
-- disables the feature for the session instead of breaking the run.

local Shadow = {}
Shadow.__index = Shadow

local MODEL = 'Melinoe_Mesh'
local FALLBACK_MODEL = 'MelMarker_Mesh'
local ALPHA = 0.45
local TINT = { 0.55, 0.35, 1.0, 1.0 }
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

function Shadow:fail(what, err)
	self.disabled = true
	self.log('shadow: disabled after ' .. what .. ' failed: ' .. tostring(err))
	self:set_id(nil)
end

-- The shadow's object id for the current map, or nil.
function Shadow:get_id()
	local ms = self.G.MapState
	return ms and ms.RankedRaceShadow or nil
end

function Shadow:set_id(id)
	local ms = self.G.MapState
	if ms then ms.RankedRaceShadow = id end
end

-- Our own state for the opponent (rate-limited by the client).
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

function Shadow:should_show(now)
	local g = self.client.state.ghost
	local fin = self.client.state.opponent_finished
	return self.game:race_run_live() and g ~= nil and g.room == self.game:current_map()
		and now - (g.received or -math.huge) < STALE_AFTER and not fin
end

function Shadow:spawn(g)
	local G = self.G
	local id = G.SpawnObstacle({ Name = 'BlankObstacle3D', Group = 'Standing', LocationX = g.x, LocationY = g.y,
		TriggerOnSpawn = false })
	if not id or id == 0 then error('SpawnObstacle returned ' .. tostring(id)) end
	local model_ok = pcall(G.SetThingProperty, { Property = 'GrannyModel', Value = MODEL, DestinationId = id })
	if not model_ok then G.SetThingProperty({ Property = 'GrannyModel', Value = FALLBACK_MODEL, DestinationId = id }) end
	pcall(G.SetThingProperty, { Property = 'StopsProjectiles', Value = false, DestinationId = id })
	pcall(G.SetThingProperty, { Property = 'StopsUnits', Value = false, DestinationId = id })
	pcall(G.SetThingProperty, { Property = 'AddColor', Value = true, DestinationId = id })
	pcall(G.SetColor, { Id = id, Color = TINT })
	pcall(G.SetAlpha, { Id = id, Fraction = ALPHA })
	self:set_id(id)
	self.x, self.y, self.anim, self.angle = g.x, g.y, nil, nil
	self.stats.spawns = self.stats.spawns + 1
	self.log('shadow: spawned for ' .. tostring(g.room) .. ' at ' .. math.floor(g.x) .. ',' .. math.floor(g.y))
end

function Shadow:hide()
	local id = self:get_id()
	if id then
		pcall(self.G.Destroy, { Id = id })
		self:set_id(nil)
	end
end

function Shadow:update()
	if self.disabled then return end
	local now = self.now()
	local ok, err = pcall(self.send_own, self)
	if not ok then return self:fail('sending own position', err) end

	if not self.G.MapState then return end
	if not self:should_show(now) then
		self:hide()
		return
	end
	local g = self.client.state.ghost
	if not self:get_id() then
		ok, err = pcall(self.spawn, self, g)
		if not ok then return self:fail('spawning', err) end
	end
	local id = self:get_id()

	-- Glide toward the latest report; snap after long jumps (dashes, teleports).
	local dt = math.min(0.1, now - (self.last_frame or now))
	self.last_frame = now
	local dx, dy = g.x - self.x, g.y - self.y
	if dx * dx + dy * dy > SNAP_DISTANCE * SNAP_DISTANCE then
		self.x, self.y = g.x, g.y
	else
		local k = math.min(1, dt * 14)
		self.x, self.y = self.x + dx * k, self.y + dy * k
	end
	local G = self.G
	ok, err = pcall(G.Teleport, { Id = id, OffsetX = self.x, OffsetY = self.y })
	if not ok then return self:fail('moving', err) end
	if g.angle and g.angle ~= self.angle then
		pcall(G.SetAngle, { Ids = { id }, Angle = g.angle })
		self.angle = g.angle
	end
	local anim = ANIM[g.anim] or ANIM.idle
	if anim ~= self.anim then
		pcall(G.SetAnimation, { Name = anim, DestinationId = id })
		self.anim = anim
	end

	-- Test stats: the engine really put the shadow where we asked.
	self.stats.frames_visible = self.stats.frames_visible + 1
	local lok, loc = pcall(G.GetLocation, { Id = id })
	if lok and loc and loc.X then
		local err_dist = math.sqrt((loc.X - self.x) ^ 2 + (loc.Y - self.y) ^ 2)
		self.stats.samples = self.stats.samples + 1
		if err_dist > self.stats.max_error and self.stats.samples > 10 then self.stats.max_error = err_dist end
	end
end

return Shadow
