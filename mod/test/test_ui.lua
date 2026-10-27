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
	f.push({ type = 'opponent_progress', id = 'p2', name = 'Zag', room = 'F_Combat03', depth = 4, hp = 20, max_hp = 30, time = 40, alive = true })
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

T.case('hud: a rival\'s Fear follows their name', function()
	T.eq(Hud.name_line({ name = 'Zag' }), 'Zag')
	T.eq(Hud.name_line({ name = 'Zag', progress = { stats = { Fear = 0 } } }), 'Zag')
	T.eq(Hud.name_line({ name = 'Z{a}g', progress = { stats = { Fear = 12 } } }),
		'Zag   12{!Icons.ShrinePointNoTooltip} Fear', 'the name stays literal, the icon is the game\'s')
end)

T.case('hud: status line follows the race state', function()
	local st = {}
	T.eq((Hud.status(st, { id = 'p2', connected = true })), 'RIVAL')
	T.eq((Hud.status(st, { id = 'p2', connected = true }, true)), 'RACING')
	T.eq((Hud.status(st, { id = 'p2', connected = false })), 'DISCONNECTED')
	T.eq((Hud.status(st, { id = 'p2', finished = { victory = false, outcome = 'died' } })), 'FALLEN - FINISH TO WIN')
	T.eq((Hud.status(st, { id = 'p2', finished = { victory = false, outcome = 'died' } }, true)), 'FALLEN')
	T.eq((Hud.status(st, { id = 'p2', finished = { victory = false, outcome = 'forfeit' } })), 'FORFEITED - FINISH TO WIN')
	local dec = { decided = { winner = 'p2', you_won = false } }
	T.eq((Hud.status(dec, { id = 'p2', finished = { victory = true } })), 'WON THE RACE - FINISH FOR YOUR TIME')
	T.eq((Hud.status(dec, { id = 'p3', finished = { victory = true } }, true)), 'CLEARED', 'cleared after the winner')
	T.eq((Hud.status(st, { id = 'p2', finished = { victory = true } })), 'CLEARED')
	T.eq((Hud.status({ result = { you_won = true } }, { id = 'p2' })), 'YOU WIN')
	T.eq((Hud.status({ result = { draw = true } }, { id = 'p2' })), 'DRAW')
	local res = { result = { results = { { id = 'p1', place = 1 }, { id = 'p3', place = 2 }, { id = 'p2', place = 3 } } } }
	T.eq((Hud.status(res, { id = 'p2' }, true)), '3RD')
	T.eq((Hud.status(res, { id = 'p1' }, true)), '1ST')
end)

T.case('hud: one race clock, then the rival final time', function()
	T.eq(Hud.clock_line({}, 75.5), '1:15.50')
	T.eq(Hud.clock_line({ finished = { victory = false, time = 27.82 } }, 40), 'Fell at 0:27.82')
	T.eq(Hud.clock_line({ finished = { victory = true, time = 34.11 } }, 40), 'Cleared at 0:34.11')
	T.eq((Hud.delta_short(4, 6)), '2 ahead')
	T.eq((Hud.delta_short(4, 3)), '1 behind')
end)

T.case('hud: the race clock keeps every character in a fixed cell', function()
	local a = Hud.clock_cells('1:05.30', 1872)
	local b = Hud.clock_cells('1:15.39', 1872)
	for i = 1, 7 do T.eq(a[i], b[i], 'cell ' .. i) end
	T.eq(a[7], 1872 - 23 / 2, 'last digit hugs the right margin')
	T.truthy(a[5] - a[4] < a[3] - a[2] + 0.001, 'punctuation cells are narrower')
	local long = Hud.clock_cells('10:05.30', 1872)
	T.eq(long[8], a[7], 'a new leading digit does not move the others')
end)

T.case('hud: prep panel counts down the prep time and shows who is ready', function()
	local st = { lobby = { phase = 'ready_check', you = 'p1', prep_ends_in = 90, received = 100, players = {
		{ id = 'p1', name = 'Mark', ready = false, connected = true },
		{ id = 'p2', name = 'Blah{guy}', ready = true, connected = true },
		{ id = 'p3', name = 'Gone', ready = false, connected = false } } } }
	local v = Hud.prep_view(st, 125.4)
	T.eq(v.title, 'Race starts in 1:05')
	T.eq(v.rows[1].text, 'You - setting up')
	T.eq(v.rows[2].text, 'Blahguy - ready', 'names stay literal')
	T.eq(v.rows[3].text, 'Gone - away')
	T.eq(Hud.prep_view(st, 500).title, 'Race starts in 0:00')
	st.lobby.prep_ends_in = nil
	T.eq(Hud.prep_view(st, 100).title, 'Race starts when everyone is ready')
	st.lobby.phase = 'racing'
	T.eq(Hud.prep_view(st, 100), nil, 'only during the prep time')
end)

T.case('hud: the split line shows the region\'s best split, and a split\'s result for 10 s', function()
	local SplitsM = T.load('splits.lua')
	local sp = SplitsM.new('underworld', { total = 1500, splits = { 400, 800, 1150, 1500 } })
	T.eq(Hud.split_line(sp, 0, SplitsM.fmt_delta), nil, 'nothing before the first room')
	sp:room('F_Opening01', 1)
	local text, color = Hud.split_line(sp, 30, SplitsM.fmt_delta)
	T.eq(text, 'Erebus  best 6:40.00')
	T.truthy(color[1] == 255 and color[2] == 214, 'gold')
	sp:room('G_Intro01', 390)
	text = Hud.split_line(sp, 395, SplitsM.fmt_delta)
	T.truthy(text:find('^Erebus  6:30%.00  %-0:10'), text)
	T.eq(Hud.split_line(sp, 401, SplitsM.fmt_delta), 'Oceanus  best 13:20.00', 'then the next target')
	local none = SplitsM.new('underworld', nil)
	none:room('F_Opening01', 1)
	T.eq(Hud.split_line(none, 30, SplitsM.fmt_delta), nil, 'no PB: nothing to aim at')
	none:room('G_Intro01', 400)
	T.eq(Hud.split_line(none, 900, SplitsM.fmt_delta), 'Erebus  6:40.00', 'its splits stay up')
end)
