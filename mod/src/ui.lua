-- ImGui overlay: the Ranked Race window (lobby, votes, ready, result) and the
-- opponent HUD shown during a race. Draws only from client state; every button
-- maps to one client action.

local UI = {}
UI.__index = UI

local GREEN = { 0.35, 1.0, 0.45, 1.0 }
local RED = { 1.0, 0.35, 0.35, 1.0 }
local GOLD = { 1.0, 0.85, 0.3, 1.0 }
local GREY = { 0.65, 0.65, 0.65, 1.0 }

local function fmt_time(t)
	if type(t) ~= 'number' then return '--:--' end
	if t < 0 then t = 0 end
	local m = math.floor(t / 60)
	return string.format('%d:%05.2f', m, t - m * 60)
end
UI.fmt_time = fmt_time

-- deps: { ImGui, ImGuiCond, ImGuiWindowFlags, client, config, names = fn(id)->display, status = fn()->string|nil }
function UI.new(deps)
	local u = setmetatable({}, UI)
	u.ImGui = deps.ImGui
	u.Cond = deps.ImGuiCond or {}
	u.Flags = deps.ImGuiWindowFlags or {}
	u.client = deps.client
	u.config = deps.config
	u.names = deps.names or function(id) return id end
	u.status = deps.status or function() return nil end
	u.on_connect = deps.on_connect
	u.log = deps.log or function() end
	u.logged_errors = {}
	u.visible = false
	u.code_input = ''
	u.host_input = deps.config.server_host or '127.0.0.1'
	u.port_input = tostring(deps.config.server_port or 7777)
	u.name_input = deps.config.player_name or 'Melinoe'
	u.confirm_forfeit = false
	return u
end

function UI:toggle() self.visible = not self.visible end

function UI:report(where, err)
	local msg = where .. ' error: ' .. tostring(err)
	if not self.logged_errors[msg] then
		self.logged_errors[msg] = true
		self.log('ui: ' .. msg)
	end
	self:colored(RED, msg)
end

function UI:colored(color, text)
	self.ImGui.TextColored(color[1], color[2], color[3], color[4], text)
end

function UI:input(label, value, size)
	local text = self.ImGui.InputText(label, value, size or 64)
	if type(text) == 'string' then return text end
	return value
end

-- main window -----------------------------------------------------------------

function UI:draw_window()
	if not self.visible then return end
	local ImGui = self.ImGui
	ImGui.SetNextWindowPos(self.config.window_x or 300, self.config.window_y or 40, self.Cond.FirstUseEver)
	ImGui.SetNextWindowSize(420, 360, self.Cond.FirstUseEver)
	local shown = ImGui.Begin('Ranked Race (F8)')
	if shown then
		local ok, err = pcall(self.draw_body, self)
		if not ok then self:report('UI', err) end
	end
	ImGui.End()
end

function UI:draw_body()
	local ImGui, c = self.ImGui, self.client
	local st = c.state
	local status = self.status()
	if status then self:colored(GOLD, status) end

	if st.conn ~= 'connected' then
		self.host_input = self:input('Server', self.host_input, 128)
		self.port_input = self:input('Port', self.port_input, 8)
		self.name_input = self:input('Name', self.name_input, 32)
		if st.conn == 'connecting' then
			self:colored(GREY, 'Connecting...')
		elseif ImGui.Button('Connect') then
			c.name = self.name_input
			if self.on_connect then self.on_connect(self.host_input, tonumber(self.port_input) or 7777, self.name_input) end
			c:connect(self.host_input, tonumber(self.port_input) or 7777)
		end
		if c.want_connected and st.conn == 'disconnected' then self:colored(RED, 'Disconnected, retrying...') end
		return
	end

	self:colored(GREEN, 'Connected as ' .. tostring(c.name))
	if st.last_error and c.now() - st.last_error.at < 8 then self:colored(RED, st.last_error.message or st.last_error.code) end
	ImGui.Separator()

	local lobby = st.lobby
	if not lobby then
		if ImGui.Button('Create Lobby') then c:create_lobby() end
		self.code_input = self:input('Code', self.code_input, 8)
		ImGui.SameLine()
		if ImGui.Button('Join') then c:join_lobby(self.code_input) end
		return
	end

	local names = {}
	for _, r in ipairs(c:rivals()) do
		names[#names + 1] = r.name
		if not r.connected then self:colored(RED, r.name .. ' disconnected, waiting for reconnect...') end
	end
	ImGui.Text('Lobby ' .. lobby.code .. '   vs ' .. (#names > 0 and table.concat(names, ', ') or '(waiting)'))
	local phase = lobby.phase
	if phase == 'waiting' then
		if lobby.public then
			local left = c:starts_in()
			ImGui.Text(left and string.format('Starting in %ds', math.ceil(left)) or 'Searching for racers...')
			if ImGui.Button('Cancel search') then c:cancel_match() end
		else
			ImGui.Text('Share the code ' .. lobby.code .. ' with your rivals.')
			if c:is_host() and #names > 0 and ImGui.Button('Start race') then c:start_race() end
		end
	elseif phase == 'voting_weapon' or phase == 'voting_keepsake' then
		self:draw_vote()
	elseif phase == 'ready_check' then
		self:draw_ready(lobby)
	elseif phase == 'countdown' then
		local left = c:countdown_remaining() or 0
		self:colored(GOLD, string.format('Starting in %d...', math.ceil(left)))
	elseif phase == 'racing' then
		ImGui.Text('Racing: ' .. fmt_time(c:race_time()))
		if not self.confirm_forfeit then
			if ImGui.Button('Forfeit') then self.confirm_forfeit = true end
		else
			if ImGui.Button('Really forfeit') then
				self.confirm_forfeit = false
				c:forfeit()
			end
			ImGui.SameLine()
			if ImGui.Button('Cancel') then self.confirm_forfeit = false end
		end
	elseif phase == 'finished' then
		self:draw_result()
		if st.rematch_requested then
			self:colored(GREY, 'Rematch requested, waiting for the others...')
		elseif ImGui.Button('Rematch') then
			c:rematch()
		end
	end
	ImGui.Separator()
	if ImGui.Button('Leave lobby') then c:leave_lobby() end
end

function UI:draw_vote()
	local ImGui, v = self.ImGui, self.client.state.vote
	if not v then return end
	local left = math.max(0, v.deadline - self.client.now())
	ImGui.Text(string.format('Vote %s (%ds)', v.phase, math.ceil(left)))
	for _, opt in ipairs(v.options) do
		local label = self.names(opt.id)
		if label == opt.id then label = opt.name or opt.id end
		if v.mine == opt.id then label = '> ' .. label .. ' <' end
		if ImGui.Button(label .. '##' .. opt.id) then self.client:vote(v.phase, opt.id) end
	end
	if v.of then self:colored(GREY, string.format('%d of %d voted.', v.voted or 0, v.of)) end
end

function UI:draw_ready(lobby)
	local ImGui, c = self.ImGui, self.client
	local w = c.state.vote_results.weapon
	local k = c.state.vote_results.keepsake
	ImGui.Text('Weapon:   ' .. (w and self.names(w.selected) or '?'))
	ImGui.Text('Keepsake: ' .. (k and self.names(k.selected) or '-'))
	local me_ready = false
	for _, p in ipairs(lobby.players) do
		local mark = p.ready and '[ready]' or '[...]'
		ImGui.Text(mark .. ' ' .. p.name)
		if p.id == lobby.you then me_ready = p.ready end
	end
	if not me_ready and ImGui.Button('Ready') then c:ready() end
end

function UI:draw_result()
	local r = self.client.state.result
	if not r then return end
	if r.draw then
		self:colored(GOLD, 'DRAW (' .. tostring(r.reason) .. ')')
	elseif r.you_won then
		self:colored(GREEN, 'YOU WIN (' .. tostring(r.reason) .. ')')
	else
		self:colored(RED, 'YOU LOSE (' .. tostring(r.reason) .. ')')
	end
	for _, e in ipairs(r.results or {}) do
		local what = not e.finished and 'did not finish' or (e.victory and 'cleared' or 'died')
		self.ImGui.Text(string.format('%s: %s %s', e.name, what, e.time and fmt_time(e.time) or ''))
	end
end

-- HUD ---------------------------------------------------------------------------

function UI:draw_hud()
	local c = self.client
	local race = c.state.race
	if not race then return end
	local ImGui = self.ImGui
	ImGui.SetNextWindowPos(self.config.hud_x or 20, self.config.hud_y or 80, self.Cond.FirstUseEver)
	ImGui.SetNextWindowBgAlpha(0.6)
	local flags = (self.Flags.NoTitleBar or 0) + (self.Flags.AlwaysAutoResize or 0) + (self.Flags.NoFocusOnAppearing or 0)
	local shown = ImGui.Begin('Ranked HUD', flags)
	if shown then
		local ok, err = pcall(self.draw_hud_body, self, race)
		if not ok then self:report('HUD', err) end
	end
	ImGui.End()
end

function UI:draw_hud_body(race)
	local ImGui, c = self.ImGui, self.client
	local st = c.state
	if not race.started then
		self:colored(GOLD, string.format('RACE STARTS IN %d', math.ceil(c:countdown_remaining() or 0)))
		ImGui.Text(self.names(race.weapon) .. ' / ' .. self.names(race.keepsake))
		return
	end
	ImGui.Text('You  ' .. fmt_time(st.result and (race.completed and race.completed.time) or c:race_time()))
	for _, r in ipairs(c:rivals()) do
		local fin = r.finished
		if fin then
			self:colored(fin.victory and GREEN or RED, r.name .. (fin.victory and ': CLEARED' or ': OUT'))
		elseif not r.connected then
			self:colored(RED, r.name .. ': DISCONNECTED')
		else
			self:colored(GREEN, r.name .. ': ALIVE')
		end
		local opp = r.progress
		if opp then
			ImGui.Text(string.format('  Room %s  depth %s', tostring(opp.room), tostring(opp.depth)))
			ImGui.Text(string.format('  HP %s/%s  time %s', tostring(opp.hp), tostring(opp.max_hp or '?'), fmt_time(opp.time)))
		end
	end
	if st.result then self:draw_result() end
end

return UI
