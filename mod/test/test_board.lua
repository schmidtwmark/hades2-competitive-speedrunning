local T = require('test.lib')
local json = T.load('json.lua')
local Client = T.load('client.lua')
local Board = T.load('board.lua')

-- A connected client over a fake transport (as in test_client.lua).
local function make()
	local f = { sent = {}, inbox = {}, status = 'connecting', t = 0 }
	local transport = {
		connect = function() return true end,
		send = function(line) f.sent[#f.sent + 1] = json.decode(line); return true end,
		poll = function() local l = f.inbox; f.inbox = {}; return l, f.status end,
		close = function() end,
	}
	local c = Client.new({ json = json, transport = transport, now = function() return f.t end, name = 'Mel' })
	c:connect('h', 1)
	f.status = 'connected'
	c:update()
	function f.push(m) f.inbox[#f.inbox + 1] = json.encode(m); c:update() end
	function f.last() return f.sent[#f.sent] end
	f.push({ type = 'welcome', id = 'p1', token = 't', resumed = false })
	local b = Board.new({ client = c, log = function() end, now = function() return f.t end })
	return c, f, b
end

local function view(c, b) return Board.view(c, b.ui, 0) end
local function keys(list)
	local out = {}
	for _, x in ipairs(list or {}) do out[#out + 1] = x.key end
	return table.concat(out, ',')
end
local players = {
	{ id = 'p1', name = 'Mel', connected = true, ready = false },
	{ id = 'p2', name = 'Zag', connected = true, ready = false },
}

T.case('board: offline until the server welcomes us', function()
	local c = Client.new({ json = json, transport = { connect = function() return true end, poll = function() return {}, 'connecting' end,
		send = function() return true end, close = function() end }, now = function() return 0 end })
	c:connect('h', 1)
	c:update()
	local d = Board.view(c, { code = '' }, 0)
	T.eq(d.id, 'offline')
	T.eq(#d.buttons, 0)
	T.eq(d.cancel.action, 'close')
end)

T.case('board: home offers Find Match, Create and Join', function()
	local c, f, b = make()
	local d = view(c, b)
	T.eq(d.id, 'home')
	T.eq(keys(d.buttons), 'find,create,join_page,about')
	T.truthy(d.lines[1].text:find('Mel'))
end)

T.case('board: Find Match queues, Cancel (B) leaves the queue', function()
	local c, f, b = make()
	b.desc = view(c, b)
	T.truthy(b:press('find'))
	T.eq(f.last().type, 'find_match')
	b.desc = view(c, b)
	T.eq(b.desc.id, 'queue')
	T.eq(b.desc.cancel.action, 'cancel_queue')
	b:press('cancel')
	T.eq(f.last().type, 'cancel_match')
	T.eq(view(c, b).id, 'home')
end)

T.case('board: code entry with the on-screen keys, B deletes then backs out', function()
	local c, f, b = make()
	b.desc = view(c, b)
	b:press('join_page')
	b.desc = view(c, b)
	T.eq(b.desc.id, 'code')
	T.eq(#b.desc.grid.items, 32)
	T.eq(b.desc.focus, 'key_A')
	for _, ch in ipairs({ 'W', 'X', 'Y', 'Q' }) do
		b:press('key_' .. ch)
		b.desc = view(c, b)
	end
	b:press('key_Z') -- a fifth key is ignored
	b.desc = view(c, b)
	T.eq(b.ui.code, 'WXYQ')
	T.eq(b.desc.lines[1].text, 'W X Y Q')
	T.eq(b.desc.focus, 'join')
	b:press('cancel')
	T.eq(b.ui.code, 'WXY')
	b.desc = view(c, b)
	T.eq(b.desc.cancel.label, '{CN} Delete')
	b:press('key_Z')
	b.desc = view(c, b)
	b:press('join')
	T.eq(f.last().type, 'join_lobby')
	T.eq(f.last().code, 'WXYZ')
	T.eq(f.last().create, true, 'an unused code opens a lobby under it')
	T.eq(b.ui.page, nil)
	b:press('join_page')
	b.desc = view(c, b)
	b:press('cancel')
	T.eq(b.ui.page, nil, 'B on an empty code goes back home')
end)

T.case('board: private lobby shows the code to share', function()
	local c, f, b = make()
	local host = { id = 'p1', name = 'Mel', connected = true, host = true }
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'waiting', you = 'p1', players = { host }, max_players = 5 })
	local d = view(c, b)
	T.eq(d.id, 'waiting:1:true')
	T.eq(d.lines[1].text, 'Code  A B 2 C')
	T.truthy(d.lines[2].text:find('up to 5 racers'))
	T.eq(d.lines[3].text, 'Mel  (you, host)')
	T.eq(keys(d.buttons), 'leave', 'nothing to start alone')
	T.eq(Board.wants_attention(d.id), false)
end)

T.case('board: the host starts a private race once rivals are in; the others wait', function()
	local c, f, b = make()
	local three = { { id = 'p1', name = 'Mel', host = true }, { id = 'p2', name = 'Zag' }, { id = 'p3', name = 'Nemesis', connected = false } }
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'waiting', you = 'p1', players = three, max_players = 5 })
	b.desc = view(c, b)
	T.eq(b.desc.id, 'waiting:3:true')
	T.eq(keys(b.desc.buttons), 'start,chat,leave')
	T.eq(b.desc.lines[4].text, 'Zag')
	T.eq(b.desc.lines[5].color, Board.colors.GREY, 'a disconnected racer is greyed out')
	T.truthy(Board.wants_attention(b.desc.id), 'the board opens for the host when someone joins')
	b:press('start')
	T.eq(f.last().type, 'start_race')
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'waiting', you = 'p2', players = three, max_players = 5 })
	local d = view(c, b)
	T.eq(d.id, 'waiting:3:false')
	T.eq(keys(d.buttons), 'chat,leave')
	T.eq(d.lines[#d.lines].text, 'Waiting for Mel to start the race...')
	T.eq(Board.wants_attention(d.id), false)
end)

T.case('board: Find Match gathers racers and counts down; B cancels', function()
	local c, f, b = make()
	f.t = 10
	c:find_match()
	f.push({ type = 'lobby_joined', code = 'QQQQ', opponent = nil })
	f.push({ type = 'lobby_state', code = 'QQQQ', phase = 'waiting', you = 'p1', public = true, max_players = 5,
		starts_in = nil, players = { players[1] } })
	f.t = 25
	b.desc = Board.view(c, b.ui, f.t)
	T.eq(b.desc.id, 'waiting:public:1')
	T.eq(b.desc.title, 'Finding Rivals')
	T.eq(b.desc.lines[1].text, 'Searching for other racers...')
	T.eq(b.desc.lines[3].text, 'Waiting 0:15')
	T.eq(b.desc.cancel.action, 'cancel_queue')
	local three = { players[1], players[2], { id = 'p3', name = 'Nemesis', connected = true } }
	f.push({ type = 'lobby_state', code = 'QQQQ', phase = 'waiting', you = 'p1', public = true, max_players = 5,
		starts_in = 15, players = three })
	f.t = 29.2
	local d = Board.view(c, b.ui, f.t)
	T.eq(d.id, 'waiting:public:3')
	T.eq(d.lines[1].text, '3 racers found (up to 5).')
	T.eq(d.lines[2].text, 'Mel  (you)', 'no host in a Find Match lobby')
	T.eq(d.lines[5].text, 'The race setup starts in 11s.')
	T.eq(keys(d.buttons), 'cancel_search,chat')
	b:press('cancel')
	T.eq(f.last().type, 'cancel_match')
end)

T.case('board: votes, ready and the hub race page with several rivals', function()
	local c, f, b = make()
	local four = { { id = 'p1', name = 'Mel' }, { id = 'p2', name = 'Zag' }, { id = 'p3', name = 'Nemesis' }, { id = 'p4', name = 'Hecate' } }
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'voting_weapon', you = 'p1', players = four })
	f.push({ type = 'vote_phase', phase = 'weapon', timer = 15, options = { { id = 'WeaponAxe', name = 'Axe' } } })
	f.push({ type = 'vote_cast', phase = 'weapon', by = 'opponent', id = 'p3', name = 'Nemesis', voted = 1, of = 4 })
	local d = view(c, b)
	T.eq(d.lines[1].text, '4 racers   -   15s left')
	T.eq(d.lines[2].text, '1 of 4 have voted. Most votes wins.')
	four[1].ready, four[3].ready = true, true
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = four })
	d = view(c, b)
	T.eq(d.id, 'ready:true')
	T.eq(d.lines[3].text, 'Waiting for Zag and Hecate...')
	four[2].ready, four[4].ready = true, true
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = four })
	T.eq(view(c, b).lines[3].text, 'Everyone else is ready.')
	-- Back in the hub after falling: Hecate cleared, two still running.
	f.push({ type = 'race_start', race_id = 1, seed = 5, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'racing', you = 'p1', players = four })
	f.push({ type = 'opponent_progress', id = 'p2', name = 'Zag', room = 'G_Combat01', depth = 14, hp = 9, time = 1 })
	f.push({ type = 'opponent_finished', id = 'p4', name = 'Hecate', victory = true, time = 900, outcome = 'cleared' })
	f.push({ type = 'race_decided', race_id = 1, winner = 'p4', winner_name = 'Hecate', draw = false, you_won = false,
		reason = 'completed_first' })
	d = view(c, b)
	T.eq(d.title, 'Defeat')
	T.eq(d.lines[1].text, 'Hecate cleared first.')
	T.eq(d.lines[2].text, 'Zag:  depth 14   9/9 HP')
	T.eq(d.lines[3].text, 'Nemesis:  starting')
	T.eq(d.lines[4].text, 'The full results appear when everyone finishes.')
	T.eq(Board.wants_attention(d.id), false, 'still racing: the board stays closed')
	-- We fall at depth 9: the board says so and opens itself.
	c:report_progress({ room = 'F_Combat03', depth = 9, hp = 0 }, true)
	f.t = 754.5
	c:report_complete(false)
	local out = view(c, b)
	T.eq(out.lines[1].text, 'You fell at depth 9   12:34.50')
	T.truthy(Board.wants_attention(out.id), out.id)
	f.push({ type = 'opponent_finished', id = 'p3', name = 'Nemesis', victory = false, time = 950, outcome = 'died' })
	local d2 = view(c, b)
	T.truthy(d2.id ~= d.id, 'a rival finishing rebuilds the page (one line fewer)')
	b:prompt('forfeit')
	T.eq(view(c, b).lines[2].text, 'Hecate has already won the race.')
end)

T.case('board: results for three or more are a standings table', function()
	local t = Board.standings({
		{ id = 'p1', name = 'Mel', outcome = 'died', victory = false, time = 600, depth = 20, place = 3, stats = { Kills = 90, DamageTaken = 50 } },
		{ id = 'p2', name = 'Zag', outcome = 'cleared', victory = true, time = 1500.25, depth = 41, place = 1,
			stats = { Kills = 300, DamageTaken = 200 }, build = { { name = 'A' } } },
		{ id = 'p3', name = 'Nemesis', outcome = 'cleared', victory = true, time = 1600, depth = 41, place = 2, stats = { Kills = 300 } },
	}, 'p1')
	T.eq(t.cols[1].name, 'Zag')
	T.eq(t.cols[1].place, '1st')
	T.truthy(t.cols[1].winner)
	T.eq(t.cols[1].time, '25:00.25')
	T.eq(t.cols[3].place, '3rd')
	T.eq(t.cols[3].result, 'Fell')
	T.truthy(t.cols[3].me)
	local by = {}
	for _, r in ipairs(t.rows) do by[r.label] = r end
	T.eq(by['Foes Slain'].cells[3], '90')
	T.eq(by['Foes Slain'].best[1] and by['Foes Slain'].best[2] and not by['Foes Slain'].best[3], true, 'ties share gold')
	T.eq(by['Damage Taken'].cells[2], '-')
	T.truthy(by['Damage Taken'].best[3], 'least damage taken')
	T.eq(Board.ordinal(1) .. Board.ordinal(2) .. Board.ordinal(3) .. Board.ordinal(4) .. Board.ordinal(11) .. Board.ordinal(22),
		'1st2nd3rd4th11th22nd')
	T.eq(Board.join_names({ 'A', 'B', 'C' }), 'A, B and C')
end)

T.case('board: votes are an icon grid; the pick is highlighted and focused', function()
	local c, f, b = make()
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'voting_weapon', you = 'p1', players = players })
	f.push({ type = 'vote_phase', phase = 'weapon', timer = 15, options = {
		{ id = 'WeaponStaffSwing', name = "Witch's Staff" }, { id = 'WeaponAxe', name = 'Moonstone Axe' } } })
	b.desc = view(c, b)
	T.eq(b.desc.grid.kind, 'weapon')
	T.eq(keys(b.desc.grid.items), 'opt_WeaponStaffSwing,opt_WeaponAxe')
	T.eq(b.desc.focus, 'opt_WeaponStaffSwing')
	T.truthy(Board.wants_attention(b.desc.id))
	local before = b.desc.id
	b:press('opt_WeaponAxe')
	T.eq(f.last().type, 'vote_weapon')
	T.eq(f.last().weapon, 'WeaponAxe')
	b.desc = view(c, b)
	T.truthy(b.desc.id ~= before, 'voting rebuilds the page')
	T.eq(b.desc.focus, 'opt_WeaponAxe')
	T.truthy(b.desc.grid.items[2].selected)
	T.eq(view(c, b).lines[2].text, 'Zag is choosing...')
	f.push({ type = 'vote_cast', phase = 'weapon', by = 'opponent', id = 'p2', name = 'Zag', voted = 2, of = 2 })
	T.eq(view(c, b).lines[2].text, 'Zag has voted.')
end)

T.case('board: ready check, then the board closes for the countdown', function()
	local c, f, b = make()
	f.push({ type = 'vote_result', phase = 'weapon', selected = 'WeaponAxe', votes = {} })
	f.push({ type = 'vote_result', phase = 'keepsake', selected = 'LowHealthCritKeepsake', votes = {} })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = players })
	b.desc = view(c, b)
	T.eq(b.desc.id, 'ready:false')
	T.eq(keys(b.desc.buttons), 'setup,ready,chat,leave')
	T.eq(b.desc.focus, 'setup', 'a stray confirm press closes the board, it does not ready you')
	T.eq(b.desc.show[1].id, 'WeaponAxe')
	b:press('ready')
	T.eq(f.last().type, 'ready')
	local ready = { { id = 'p1', name = 'Mel', ready = true }, { id = 'p2', name = 'Zag', ready = true } }
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = ready })
	T.eq(keys(view(c, b).buttons), 'setup,chat,leave')
	T.truthy(view(c, b).lines[#view(c, b).lines].text:find('Zag is ready'))
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'countdown', you = 'p1', players = ready })
	T.truthy(view(c, b).close)
end)

T.case('board: results compare both racers like the clear screen', function()
	local cmp = Board.compare(
		{ name = 'Mel', outcome = 'cleared', victory = true, time = 754.5, depth = 41, build = { { name = 'A' } },
			stats = { DamageDealt = 90000, DamageTaken = 120, Kills = 300, DeathDefiancesUsed = 1 } },
		{ name = 'Zag', outcome = 'forfeit', victory = false, time = 300, depth = 12, build = {},
			stats = { DamageDealt = 20000, DamageTaken = 80, Kills = 90, DeathDefiancesUsed = 1 } })
	T.eq(cmp.me.result, 'Cleared 12:34.50')
	T.eq(cmp.them.result, 'Forfeited at 5:00.00')
	T.eq(cmp.them.depth, 'Depth 12')
	local by = {}
	for _, r in ipairs(cmp.rows) do by[r.label] = r end
	T.eq(by['Damage Dealt'].win, 'me')
	T.eq(by['Damage Taken'].win, 'them', 'less damage taken is better')
	T.eq(by['Death Defiances Used'].win, nil, 'ties have no winner')
	T.eq(by['Gold Earned'], nil, 'rows without data are left out')
	T.eq((Board.result_line({ outcome = 'disconnect', victory = false })), 'Disconnected')
end)

T.case('board: forfeit prompt defaults to Keep Racing; B keeps racing', function()
	local c, f, b0 = make()
	local forfeits = 0
	local b = Board.new({ client = c, log = function() end, now = function() return f.t end,
		game = { forfeit_now = function() forfeits = forfeits + 1 end, forfeit_available = function() return true end } })
	b:prompt('forfeit')
	b.desc = view(c, b)
	T.eq(b.desc.id, 'prompt:forfeit')
	T.eq(b.desc.focus, 'keep')
	T.eq(keys(b.desc.buttons), 'forfeit,keep')
	b:press('cancel')
	T.eq(b.ui.prompt, nil)
	T.eq(forfeits, 0)
	b:prompt('forfeit')
	b.desc = view(c, b)
	b:press('forfeit')
	T.eq(forfeits, 1)
	T.eq(b.ui.prompt, nil)
end)

T.case('board: result page offers a rematch once', function()
	local c, f, b = make()
	f.push({ type = 'race_start', race_id = 1, seed = 5, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	f.push({ type = 'race_result', race_id = 1, winner = 'p1', winner_name = 'Mel', draw = false, you_won = true,
		reason = 'survivor_finished', results = {
			{ id = 'p1', name = 'Mel', finished = true, victory = true, outcome = 'cleared', time = 300.5, stats = { Kills = 5 } },
			{ id = 'p2', name = 'Zag{CN}', finished = true, victory = false, outcome = 'died', time = 120, stats = { Kills = 2 } } } })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'finished', you = 'p1', players = players })
	b.desc = view(c, b)
	T.eq(b.desc.title, 'Victory')
	T.eq(b.desc.lines[1].text, 'The only racer to finish.')
	T.eq(b.desc.compare.me.result, 'Cleared 5:00.50')
	T.eq(b.desc.compare.them.result, 'Fell at 2:00.00')
	T.eq(b.desc.compare.them.name, 'ZagCN', 'names cannot inject text tokens')
	T.eq(b.desc.compare.rows[1].label, 'Foes Slain')
	T.truthy(Board.wants_attention(b.desc.id))
	b:press('rematch')
	T.eq(f.last().type, 'rematch')
	T.eq(keys(view(c, b).buttons), 'chat,leave')
end)

-- Engine stub: just enough of the game's screen API for open/close bookkeeping.
local function engine()
	local G = { ActiveScreens = {}, MapState = {}, ScreenCenterX = 960, ScreenCenterY = 540, UIData = {} }
	local next_id, threads = 100, {}
	local function id() next_id = next_id + 1; return next_id end
	function G.CreateScreenComponent(p) local c = {}; for k, v in pairs(p) do c[k] = v end; c.Id = id(); return c end
	function G.CreateScreenObstacle() return id() end
	for _, name in ipairs({ 'CreateTextBox', 'ModifyTextBox', 'SetAnimation', 'Destroy', 'AttachLua', 'TeleportCursor',
		'SetColor', 'SetAlpha', 'SetConfigOption', 'HideCombatUI', 'ShowCombatUI', 'PlaySound', 'UseableOn' }) do
		G[name] = function() end
	end
	function G.OnScreenOpened(s) G.ActiveScreens[s.Name] = s end
	function G.CreateScreenFromData(s, data)
		for _, k in ipairs(data.Order) do s.Components[k] = { Id = id() } end
	end
	function G.OnScreenCloseStarted() end
	function G.CloseScreen() coroutine.yield() end
	function G.OnScreenCloseFinished(s) G.ActiveScreens[s.Name] = nil end
	function G.GetAllIds() return {} end
	function G.IsInputAllowed() return true end
	function G.IsUseable() return true end
	function G.NotifyOnInteractOrControlPressed(a) G.pending = a.Notify end
	G.NotifyResultsTable = {}
	function G.waitUntil(name) G.waiting = name; coroutine.yield() end
	function G.wait() end
	function G.notifyExistingWaiters(name)
		if G.waiting == name then
			G.waiting = nil
			local co = threads[#threads]
			if co and coroutine.status(co) == 'suspended' then assert(coroutine.resume(co)) end
		end
	end
	function G.thread(fn)
		local co = coroutine.create(fn)
		threads[#threads + 1] = co
		assert(coroutine.resume(co))
	end
	function G.resume_last() local co = threads[#threads]; assert(coroutine.resume(co)) end
	return G
end

T.case('board: opens in the hub, B closes a vote page and it stays closed', function()
	local c, f, b0 = make()
	local G = engine()
	local logs = {}
	local b = Board.new({ G = G, client = c, log = function(l) logs[#logs + 1] = l end, now = function() return f.t end })
	b:install()
	b:open_soon(0)
	b:update(true)
	T.truthy(b:is_open(), 'opened on arrival')
	T.eq(b.desc.id, 'home')
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'voting_weapon', you = 'p1', players = players })
	f.push({ type = 'vote_phase', phase = 'weapon', timer = 15, options = { { id = 'WeaponAxe', name = 'Axe' } } })
	b:update(true)
	T.truthy(b.desc.id:find('^vote_weapon'), 'rebuilt for the vote')
	-- B (Cancel) arrives through the input loop.
	G.NotifyResultsTable[G.waiting] = 'Cancel'
	G.notifyExistingWaiters(G.waiting)
	G.resume_last() -- CloseScreen's fade
	T.eq(b:is_open(), false)
	T.eq(G.ActiveScreens.RankedRaceBoard, nil)
	b:update(true)
	T.eq(b:is_open(), false, 'a seen page does not reopen the board')
	f.push({ type = 'vote_result', phase = 'weapon', selected = 'WeaponAxe', votes = {} })
	f.push({ type = 'vote_phase', phase = 'keepsake', timer = 15, options = { { id = 'K1', name = 'K' } } })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'voting_keepsake', you = 'p1', players = players })
	b:update(true)
	T.truthy(b:is_open(), 'a new vote reopens it')
	b:update(false)
	T.eq(b:is_open(), false, 'leaving the hub closes it')
end)

T.case('board: a results page that cannot open yet (input blocked) opens later', function()
	local c, f = make()
	local G = engine()
	local allowed = false
	G.IsInputAllowed = function() return allowed end
	local b = Board.new({ G = G, client = c, log = function() end, now = function() return f.t end })
	b:install()
	f.push({ type = 'race_start', race_id = 1, seed = 5, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	f.push({ type = 'race_result', race_id = 1, winner = 'p2', winner_name = 'Zag', draw = false, you_won = false,
		reason = 'completed_first', results = {} })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'finished', you = 'p1', players = players })
	b:update(true)
	T.eq(b:is_open(), false, 'blocked during the walk-in')
	allowed = true
	b:update(true)
	T.truthy(b:is_open(), 'opens once the player has control')
	T.truthy(b.desc.id:find('^finished'))
end)

T.case('board: a version mismatch says who updates what, and opens the board', function()
	local c, f, b = make()
	f.push({ type = 'error', code = 'version_mismatch', who = 'you', what = 'game', rival = 'Zag', message = 'long' })
	local d = view(c, b)
	T.eq(d.id, 'home:mismatch')
	T.eq(d.lines[2].text, "Can't race Zag")
	T.eq(d.lines[3].text, 'Your Hades II is out of date.')
	T.truthy(d.lines[4].text:find('Steam'))
	T.truthy(Board.wants_attention(d.id))
	T.eq(keys(d.buttons), 'find,create,join_page,about', 'still can search again')
	local them = Board.mismatch_lines({ code = 'version_mismatch', who = 'rival', what = 'mod', rival = 'Zag' })
	T.eq(them[2].text, "Zag's Ranked Race is out of date.")
	local old = Board.mismatch_lines({ code = 'update_required', who = 'you', what = 'mod' })
	T.truthy(old[3].text:find('installer'))
	-- Find Match next to an incompatible searcher: our own lobby says why we're alone.
	c:find_match()
	f.push({ type = 'error', code = 'version_mismatch', who = 'rival', what = 'game', rival = 'Zag', message = 'long' })
	f.push({ type = 'lobby_joined', code = 'QQQQ', opponent = nil })
	f.push({ type = 'lobby_state', code = 'QQQQ', phase = 'waiting', you = 'p1', public = true, max_players = 5, players = { players[1] } })
	d = view(c, b)
	T.eq(d.id, 'waiting:public:1:mismatch')
	T.eq(d.lines[1].text, "Can't race Zag")
	T.truthy(Board.wants_attention(d.id))
	f.push({ type = 'lobby_state', code = 'QQQQ', phase = 'waiting', you = 'p1', public = true, max_players = 5, players = players })
	T.eq(view(c, b).id, 'waiting:public:2', 'gone once someone can race us')
end)

T.case('board: the standings page renders with the engine', function()
	local c, f = make()
	local G = engine()
	G.TraitData = { ZeusWeaponBoon = { Icon = 'BoonIcon_Zeus' } }
	local b = Board.new({ G = G, client = c, log = function() end, now = function() return f.t end })
	b:install()
	local three = { players[1], players[2], { id = 'p3', name = 'Nemesis', connected = true } }
	f.push({ type = 'race_start', race_id = 1, seed = 5, weapon = 'W', keepsake = 'K', countdown = 0, countdown_ms = 0 })
	f.push({ type = 'race_result', race_id = 1, winner = 'p2', winner_name = 'Zag', draw = false, you_won = false,
		reason = 'completed_first', results = {
			{ id = 'p2', name = 'Zag', outcome = 'cleared', victory = true, time = 900, depth = 41, place = 1,
				stats = { Kills = 5 }, build = { { name = 'ZeusWeaponBoon', rarity = 'Epic' }, { name = 'Unknown' } } },
			{ id = 'p1', name = 'Mel', outcome = 'died', victory = false, time = 500, depth = 20, place = 2, stats = { Kills = 3 } },
			{ id = 'p3', name = 'Nemesis', outcome = 'forfeit', victory = false, time = 100, depth = 3, place = 3, stats = {} } } })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'finished', you = 'p1', players = three })
	b:update(true)
	T.truthy(b:is_open())
	T.truthy(b.desc.table)
	local comps = b.screen.Components
	T.truthy(comps.Place1 and comps.Name3 and comps.Cell1_2 and comps.Boon1_1 and comps.Boon1_Frame1)
	T.eq(comps.Boon1_2, nil, 'boons without an icon are skipped')
	T.truthy(comps.Button_rematch)
end)

T.case('board: race menu from the pause menu: chat a quick line, back to the run', function()
	local c, f, b0 = make()
	local closed = 0
	local b = Board.new({ client = c, log = function() end, now = function() return f.t end,
		game = { forfeit_now = function() end, forfeit_available = function() return true end } })
	b.close = function() closed = closed + 1 end
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'racing', you = 'p1', players = players })
	b:prompt('race')
	b.desc = view(c, b)
	T.eq(b.desc.id, 'prompt:race')
	T.eq(keys(b.desc.buttons), 'chat,forfeit,keep')
	T.eq(b.desc.focus, 'keep')
	b:press('forfeit')
	T.eq(view(c, b).id, 'prompt:forfeit', 'forfeit still asks to confirm')
	b:prompt('race')
	b.desc = view(c, b)
	b:press('chat')
	b.desc = view(c, b)
	T.eq(b.desc.id, 'prompt:chat:0')
	T.eq(b.desc.grid.kind, 'words')
	T.eq(b.desc.grid.items[1].label, 'GG')
	b:press('say_1')
	T.eq(f.last().type, 'chat')
	T.eq(f.last().text, 'GG')
	T.eq(b.ui.prompt, nil)
	T.eq(closed, 1, 'back to the run')
end)

T.case('board: typing a chat line on the keys; B deletes, Aa toggles case', function()
	local c, f, b = make()
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = players })
	b.desc = view(c, b)
	b:press('chat')
	b.desc = view(c, b)
	b:press('type')
	b.desc = view(c, b)
	T.eq(b.desc.grid.kind, 'keys')
	T.eq(#b.desc.grid.items, #Board.CHAT_KEYS + 2)
	b:press('chr_caps')
	b.desc = view(c, b)
	b:press('chr_g')
	b:press('chr_caps')
	b.desc = view(c, b)
	for _, k in ipairs({ 'chr_g', 'chr_x', 'chr_space', 'chr_!' }) do b:press(k) end
	b.desc = view(c, b)
	T.eq(b.desc.lines[1].text, 'Ggx !_')
	b:press('cancel')
	b:press('cancel')
	b.desc = view(c, b)
	T.eq(b.desc.lines[1].text, 'Ggx_')
	T.eq(keys(b.desc.buttons), 'send,back')
	b:press('send')
	T.eq(f.last().text, 'Ggx')
	T.eq(b.ui.prompt, nil, 'in the Crossroads: back to the ready page')
	T.eq(view(c, b).id, 'ready:false')
	-- Lines from the server show on the chat page and in the feed.
	f.push({ type = 'chat', id = 'p2', name = 'Zag{CN}', text = 'gl hf' })
	f.push({ type = 'chat', id = 'p1', name = 'Mel', text = 'Ggx' })
	b.desc = view(c, b)
	b:press('chat')
	local d = view(c, b)
	T.eq(d.lines[1].text, 'ZagCN:  gl hf')
	T.eq(d.lines[2].text, 'You:  Ggx')
	local ChatFeed = T.load('chatfeed.lua')
	local lines = ChatFeed.visible(c.state.chat, f.t)
	T.eq(#lines, 2)
	T.eq(lines[1].text, 'ZagCN:  gl hf')
	T.eq(#ChatFeed.visible(c.state.chat, f.t + 11), 0, 'gone after 10 seconds')
end)

T.case('board: first open shows the welcome (spoilers first, AI disclosure); About shows it again', function()
	local c, f, b = make()
	local seen = 0
	b.on_welcome_seen = function() seen = seen + 1 end
	b.ui.welcome = true
	b.desc = view(c, b)
	T.eq(b.desc.id, 'welcome')
	T.truthy(b.desc.lines[1].text:find('100%% completed save'), 'spoiler warning up top')
	T.eq(b.desc.lines[1].color, Board.colors.GOLD)
	local all = {}
	for _, l in ipairs(b.desc.lines) do all[#all + 1] = l.text end
	all = table.concat(all, ' | ')
	T.truthy(all:find('AI'), 'AI disclosure')
	T.truthy(all:find('open source'), 'open source')
	T.truthy(all:find('github.com/schmidtwmark/hades2-ranked-race', 1, true), 'repo link')
	T.truthy(Board.wants_attention(b.desc.id))
	b:press('continue')
	T.eq(seen, 1)
	b.desc = view(c, b)
	T.eq(b.desc.id, 'home')
	b:press('about')
	T.eq(view(c, b).id, 'welcome')
	b.desc = view(c, b)
	b:press('cancel')
	T.eq(view(c, b).id, 'home', 'B continues too')
	T.truthy(#Board.QUICK_LINES == 8 and Board.QUICK_LINES[7] == "I'm using tilt controls" and Board.QUICK_LINES[8] == "I'm a little nervous")
end)

T.case('board: presses are ignored for a moment after the page changes', function()
	T.eq(Board.page_kind('ready:false'), 'ready')
	T.eq(Board.page_kind('vote_keepsake:33:A:nil'), 'vote_keepsake')
	T.eq(Board.page_kind('prompt:chat_type:nil:true'), 'prompt:chat_type')
	local c, f = make()
	local G = engine()
	local b = Board.new({ G = G, client = c, log = function() end, now = function() return f.t end })
	b:install()
	f.t = 100
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'voting_keepsake', you = 'p1', players = players })
	f.push({ type = 'vote_phase', phase = 'keepsake', timer = 15, options = { { id = 'K1', name = 'K' } } })
	b:update(true)
	T.truthy(b:is_open())
	T.eq(b.settle_until, 100 + Board.SETTLE)
	f.t = 105
	b:press('opt_K1') -- voting rebuilds the same kind of page: no new pause
	b:update(true)
	T.eq(b.settle_until, 100 + Board.SETTLE)
	f.push({ type = 'vote_result', phase = 'keepsake', selected = 'K1', votes = {} })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = players })
	b:update(true)
	T.eq(b.desc.id, 'ready:false')
	T.eq(b.settle_until, 105 + Board.SETTLE, 'the ready page starts a new pause')
	-- A confirm press through the input loop inside the pause is dropped.
	local sent = #f.sent
	G.NotifyResultsTable[G.waiting] = b.screen.Components.Button_ready.Id
	G.notifyExistingWaiters(G.waiting)
	T.eq(#f.sent, sent, 'not readied')
end)
