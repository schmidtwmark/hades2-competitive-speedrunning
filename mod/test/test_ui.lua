local T = require('test.lib')
local json = T.load('json.lua')
local Client = T.load('client.lua')
local UI = T.load('ui.lua')

-- Stub ImGui: records drawn text, clicks the button whose label matches `click`.
local function stub()
	local s = { texts = {}, buttons = {}, click = nil, depth = 0, inputs = {} }
	s.ImGui = {
		Begin = function() s.depth = s.depth + 1; return true end,
		End = function() s.depth = s.depth - 1 end,
		Text = function(t) s.texts[#s.texts + 1] = t end,
		TextColored = function(_, _, _, _, t) s.texts[#s.texts + 1] = t end,
		Button = function(label)
			s.buttons[#s.buttons + 1] = label
			if s.click and label:find(s.click, 1, true) then
				s.click = nil
				return true
			end
			return false
		end,
		InputText = function(label, value) return s.inputs[label] or value, false end,
		SameLine = function() end,
		Separator = function() end,
		SetNextWindowSize = function() end,
		SetNextWindowPos = function() end,
		SetNextWindowBgAlpha = function() end,
	}
	function s.frame(ui)
		s.texts, s.buttons = {}, {}
		ui:draw_window()
		ui:draw_hud()
		assert(s.depth == 0, 'unbalanced Begin/End')
	end
	function s.saw(pattern)
		for _, t in ipairs(s.texts) do if t:find(pattern) then return true end end
		return false
	end
	return s
end

local function setup()
	local f = { sent = {}, inbox = {}, status = 'connecting', t = 0 }
	local transport = {
		connect = function() return true end,
		send = function(line) f.sent[#f.sent + 1] = json.decode(line); return true end,
		poll = function() local l = f.inbox; f.inbox = {}; return l, f.status end,
		close = function() end,
	}
	local c = Client.new({ json = json, transport = transport, now = function() return f.t end })
	local s = stub()
	local ui = UI.new({ ImGui = s.ImGui, client = c, config = {} })
	ui.visible = true
	function f.push(m) f.inbox[#f.inbox + 1] = json.encode(m) end
	return c, f, s, ui
end

T.case('connect screen -> lobby buttons -> vote -> ready -> race HUD -> result', function()
	local c, f, s, ui = setup()
	s.frame(ui)
	s.inputs['Name'] = 'Mel'
	s.click = 'Connect'
	s.frame(ui)
	T.eq(c.name, 'Mel')
	f.status = 'connected'
	c:update()
	f.push({ type = 'welcome', id = 'p1', token = 't', resumed = false })
	c:update()
	s.click = 'Create Lobby'
	s.frame(ui)
	T.eq(f.sent[#f.sent].type, 'create_lobby')

	local players = { { id = 'p1', name = 'Mel', ready = false }, { id = 'p2', name = 'Zag', ready = false } }
	f.push({ type = 'lobby_state', code = 'WXYZ', phase = 'voting_weapon', you = 'p1', players = players })
	f.push({ type = 'vote_phase', phase = 'weapon', timer = 15, options = { { id = 'WeaponAxe', name = 'Moonstone Axe' } } })
	c:update()
	s.click = 'Moonstone Axe'
	s.frame(ui)
	T.eq(f.sent[#f.sent].weapon, 'WeaponAxe')
	T.truthy(s.saw('vs Zag'))

	f.push({ type = 'vote_result', phase = 'weapon', selected = 'WeaponAxe', votes = {} })
	f.push({ type = 'lobby_state', code = 'WXYZ', phase = 'ready_check', you = 'p1', players = players })
	c:update()
	s.click = 'Ready'
	s.frame(ui)
	T.eq(f.sent[#f.sent].type, 'ready')

	f.push({ type = 'race_start', race_id = 1, seed = 5, weapon = 'WeaponAxe', keepsake = 'K', countdown = 3, countdown_ms = 3000 })
	f.push({ type = 'lobby_state', code = 'WXYZ', phase = 'countdown', you = 'p1', players = players })
	c:update()
	s.frame(ui)
	T.truthy(s.saw('RACE STARTS IN 3'))
	f.t = 3
	c:update()
	f.push({ type = 'lobby_state', code = 'WXYZ', phase = 'racing', you = 'p1', players = players })
	f.push({ type = 'opponent_progress', room = 'F_Combat03', depth = 4, hp = 20, max_hp = 30, time = 40, alive = true })
	c:update()
	f.t = 63.5
	s.frame(ui)
	T.truthy(s.saw('Zag: ALIVE'))
	T.truthy(s.saw('Room F_Combat03'))
	T.truthy(s.saw('You  1:00.50'))
	s.click = 'Forfeit'
	s.frame(ui)
	s.click = 'Really forfeit'
	s.frame(ui)
	T.eq(f.sent[#f.sent].type, 'forfeit')

	f.push({ type = 'race_result', race_id = 1, winner = 'p2', winner_name = 'Zag', draw = false, you_won = false, reason = 'forfeit',
		results = { { id = 'p1', name = 'Mel', finished = true, victory = false }, { id = 'p2', name = 'Zag', finished = false, victory = false } } })
	f.push({ type = 'lobby_state', code = 'WXYZ', phase = 'finished', you = 'p1', players = players })
	c:update()
	s.click = 'Rematch'
	s.frame(ui)
	T.truthy(s.saw('YOU LOSE'))
	T.eq(f.sent[#f.sent].type, 'rematch')
end)

T.case('fmt_time', function()
	T.eq(UI.fmt_time(0), '0:00.00')
	T.eq(UI.fmt_time(75.5), '1:15.50')
	T.eq(UI.fmt_time(nil), '--:--')
end)

local Hud = T.load('hud.lua')

T.case('hud: biome names from room names', function()
	T.eq(Hud.biome_name('F_Combat07'), 'Erebus')
	T.eq(Hud.biome_name('G_Boss01'), 'Oceanus')
	T.eq(Hud.biome_name('Chaos_01'), 'Chaos')
	T.eq(Hud.biome_name('I_Boss01'), 'Tartarus')
	T.eq(Hud.biome_name(nil), '?')
end)

T.case('hud: ahead/behind wording is from your point of view', function()
	T.eq((Hud.depth_delta(5, 6)), '1 room ahead of you')
	T.eq((Hud.depth_delta(5, 3)), '2 rooms behind you')
	T.eq((Hud.depth_delta(4, 4)), 'level with you')
end)

T.case('hud: status line follows the race state', function()
	T.eq((Hud.status({ opponent_connected = true })), 'RIVAL')
	T.eq((Hud.status({ opponent_connected = false })), 'DISCONNECTED')
	T.eq((Hud.status({ opponent_finished = { victory = false } })), 'FALLEN - FINISH TO WIN')
	T.eq((Hud.status({ opponent_finished = { victory = true } })), 'CLEARED')
	T.eq((Hud.status({ result = { you_won = true } })), 'YOU WIN')
	T.eq((Hud.status({ result = { draw = true } })), 'DRAW')
end)

T.case('hud: one race clock, then the rival final time', function()
	T.eq(Hud.clock_line({}, 75.5), '1:15.50')
	T.eq(Hud.clock_line({ opponent_finished = { victory = false, time = 27.82 } }, 40), 'Fell at 0:27.82')
	T.eq(Hud.clock_line({ opponent_finished = { victory = true, time = 34.11 } }, 40), 'Cleared at 0:34.11')
end)
