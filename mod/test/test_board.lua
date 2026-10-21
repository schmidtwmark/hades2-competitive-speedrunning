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
	T.eq(keys(d.buttons), 'find,create,join_page')
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
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'waiting', you = 'p1', players = { players[1] } })
	local d = view(c, b)
	T.eq(d.id, 'waiting')
	T.eq(d.lines[1].text, 'Code  A B 2 C')
	T.eq(keys(d.buttons), 'leave')
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
	f.push({ type = 'vote_cast', phase = 'weapon', by = 'opponent' })
	T.truthy(view(c, b).lines[2].text:find('has voted'))
end)

T.case('board: ready check, then the board closes for the countdown', function()
	local c, f, b = make()
	f.push({ type = 'vote_result', phase = 'weapon', selected = 'WeaponAxe', votes = {} })
	f.push({ type = 'vote_result', phase = 'keepsake', selected = 'LowHealthCritKeepsake', votes = {} })
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = players })
	b.desc = view(c, b)
	T.eq(b.desc.id, 'ready:false')
	T.eq(keys(b.desc.buttons), 'ready,leave')
	T.eq(b.desc.show[1].id, 'WeaponAxe')
	b:press('ready')
	T.eq(f.last().type, 'ready')
	local ready = { { id = 'p1', name = 'Mel', ready = true }, { id = 'p2', name = 'Zag', ready = true } }
	f.push({ type = 'lobby_state', code = 'AB2C', phase = 'ready_check', you = 'p1', players = ready })
	T.eq(keys(view(c, b).buttons), 'leave')
	T.truthy(view(c, b).lines[3].text:find('Zag is ready'))
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
	T.eq(keys(view(c, b).buttons), 'leave')
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
