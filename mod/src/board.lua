-- The Race Board: a native, controller-first screen for everything before
-- and after a race (Find Match, private lobby codes, votes, ready, results),
-- for races of two up to five racers.
-- It is built like the game's own menus (OnScreenOpened, CreateScreenFromData,
-- interactable screen components, NotifyOnInteractOrControlPressed), so the
-- gamepad cursor, Confirm and Cancel work exactly as in the Keepsake rack.
-- The Pitch-Black Stone in the competitive hub opens it ("{I} Race"), and it
-- opens by itself on arrival and whenever the race needs the player.
--
-- What the board shows is a pure function of the client state (Board.view,
-- unit tested offline); the engine half only renders that description.

local Board = {}
Board.__index = Board

Board.SCREEN = 'RankedRaceBoard'
Board.STONE_ID = 561146 -- Pitch-Black Stone in Hub_PreRun
Board.USE_TEXT = 'RankedRace_UseBoard'
Board.KEYS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' -- the server's lobby code alphabet
Board.CODE_LENGTH = 4

-- ColorData.lua values (0-255) and the StoryReset prompt's text colours.
local TITLE_COLOR, BODY, GREY = { 221, 211, 211, 255 }, { 207, 225, 217, 255 }, { 160, 160, 170, 255 }
local GOLD, GREEN, RED = { 255, 202, 110, 255 }, { 115, 199, 69, 255 }, { 235, 70, 60, 255 }
Board.colors = { GOLD = GOLD, GREEN = GREEN, RED = RED, GREY = GREY }

local REASONS = {
	completed_first = 'First to clear the run.',
	survivor_finished = 'The only racer to finish.',
	no_finishers = 'Nobody finished the run.',
	time_limit = 'The race hit its time limit.',
}

function Board.ordinal(n)
	local tail = n % 100
	local suffix = (tail >= 11 and tail <= 13) and 'th' or (({ 'st', 'nd', 'rd' })[n % 10] or 'th')
	return n .. suffix
end

-- "A", "A and B", "A, B and C".
function Board.join_names(list)
	if #list <= 1 then return list[1] or '' end
	return table.concat(list, ', ', 1, #list - 1) .. ' and ' .. list[#list]
end

local function fmt_clock(t)
	if type(t) ~= 'number' then return '--:--' end
	if t < 0 then t = 0 end
	local m = math.floor(t / 60)
	return string.format('%d:%05.2f', m, t - m * 60)
end

-- Text is parsed for {tokens} and @icons: keep player names literal.
function Board.safe(name)
	return (tostring(name or '?'):gsub('[{}@]', ''))
end

function Board.code_slots(code)
	local out = {}
	for i = 1, Board.CODE_LENGTH do
		out[i] = code:sub(i, i) ~= '' and code:sub(i, i) or '_'
	end
	return table.concat(out, ' ')
end

-- Results screen rows (like the game's run clear screen): which way is better.
Board.STAT_ROWS = {
	{ key = 'DamageDealt', label = 'Damage Dealt', better = 'high' },
	{ key = 'DamageTaken', label = 'Damage Taken', better = 'low' },
	{ key = 'Kills', label = 'Foes Slain', better = 'high' },
	{ key = 'Healed', label = 'Health Restored' },
	{ key = 'GoldEarned', label = 'Gold Earned' },
	{ key = 'Rooms', label = 'Chambers Cleared', better = 'high' },
	{ key = 'DeathDefiancesUsed', label = 'Death Defiances Used', better = 'low' },
	{ key = 'Boons', label = 'Boons' },
	{ key = 'Hammers', label = 'Daedalus Hammers' },
}

local OUTCOME_TEXT = { cleared = 'Cleared', died = 'Fell', forfeit = 'Forfeited', disconnect = 'Disconnected', timeout = 'Out of Time' }

-- "Cleared 12:34.56" / "Fell at 8:12.30" for one racer's result entry.
function Board.result_line(e)
	local word = OUTCOME_TEXT[e.outcome] or (e.victory and 'Cleared' or 'Did Not Finish')
	if type(e.time) ~= 'number' then return word, e.victory and GREEN or RED end
	if e.victory then return word .. ' ' .. fmt_clock(e.time), GREEN end
	return word .. ' at ' .. fmt_clock(e.time), RED
end

-- Results table for three or more racers: a column per racer in finishing
-- order (place, name, result, depth, boons) and a row per stat, best in gold.
function Board.standings(results, my_id)
	local sorted = {}
	for i, e in ipairs(results) do sorted[i] = e end
	table.sort(sorted, function(a, b) return (a.place or 99) < (b.place or 99) end)
	local out = { cols = {}, rows = {} }
	for i, e in ipairs(sorted) do
		local word = OUTCOME_TEXT[e.outcome] or (e.victory and 'Cleared' or 'Did Not Finish')
		out.cols[i] = { place = e.place and Board.ordinal(e.place) or '-', name = Board.safe(e.name), result = word,
			time = type(e.time) == 'number' and fmt_clock(e.time) or nil, color = e.victory and GREEN or RED,
			depth = e.depth and ('Depth ' .. e.depth) or nil, build = e.build or {}, me = e.id == my_id,
			winner = e.victory and e.place == 1 }
	end
	for _, row in ipairs(Board.STAT_ROWS) do
		local vals, any = {}, false
		for i, e in ipairs(sorted) do
			vals[i] = (e.stats or {})[row.key]
			if vals[i] ~= nil then any = true end
		end
		if any then
			local best, all_same = nil, true
			for i = 1, #sorted do
				local v = vals[i]
				if type(v) == 'number' then
					if best ~= nil and v ~= best then all_same = false end
					if best == nil or (row.better == 'high' and v > best) or (row.better == 'low' and v < best) then best = v end
				end
			end
			local cells, gold = {}, {}
			for i = 1, #sorted do
				cells[i] = vals[i] ~= nil and tostring(vals[i]) or '-'
				gold[i] = row.better ~= nil and not all_same and vals[i] == best
			end
			out.rows[#out.rows + 1] = { label = row.label, cells = cells, best = gold }
		end
	end
	return out
end

function Board.compare(me, them)
	local function side(e)
		local text, color = Board.result_line(e)
		local depth = e.depth and ('Depth ' .. e.depth) or nil
		return { name = Board.safe(e.name), result = text, color = color, depth = depth, build = e.build or {} }
	end
	local out = { me = side(me), them = side(them), rows = {} }
	local ms, ts = me.stats or {}, them.stats or {}
	for _, row in ipairs(Board.STAT_ROWS) do
		local a, b = ms[row.key], ts[row.key]
		if a ~= nil or b ~= nil then
			local win
			if row.better and type(a) == 'number' and type(b) == 'number' and a ~= b then
				win = ((a > b) == (row.better == 'high')) and 'me' or 'them'
			end
			out.rows[#out.rows + 1] = { label = row.label, me = a ~= nil and tostring(a) or '-',
				them = b ~= nil and tostring(b) or '-', win = win }
		end
	end
	return out
end

-- Lines for "can't race": who has to update what, and how.
function Board.mismatch_lines(m)
	local rival = Board.safe(m.rival or 'your rival')
	local thing = m.what == 'game' and 'Hades II' or 'Ranked Race'
	local how = m.what == 'game' and 'Update it in Steam: Library -> Hades II -> Update.'
		or 'Update it: git pull in the mod folder, then run the installer again.'
	if m.code == 'update_required' then
		return { { text = 'This Ranked Race is out of date', color = RED },
			{ text = 'It can no longer race on this server.' }, { text = how, color = GREY } }
	end
	local head = { text = "Can't race " .. rival, color = RED }
	if m.who == 'you' then
		return { head, { text = 'Your ' .. thing .. ' is out of date.' }, { text = how, color = GREY } }
	elseif m.who == 'rival' then
		return { head, { text = rival .. "'s " .. thing .. ' is out of date.' },
			{ text = 'Search again once they have updated.', color = GREY } }
	end
	return { head, { text = 'Your ' .. thing .. ' versions differ.' }, { text = 'Both of you: update to the latest.', color = GREY } }
end

-- Page description for the current state. `ui` is the board's own state
-- (page, typed code); `names(id)` gives display names.
function Board.view(c, ui, now, names)
	local st = c.state
	names = names or function(id) return id end
	local d = { lines = {}, buttons = {}, cancel = { action = 'close', label = '{CN} Close' } }
	local function line(text, color) d.lines[#d.lines + 1] = { text = text, color = color } end
	local function button(key, label, action, arg)
		d.buttons[#d.buttons + 1] = { key = key, label = label, action = action or key, arg = arg }
	end

	-- In-run prompt from the pause menu's "Forfeit Race" (or Quit).
	if ui.prompt == 'forfeit' then
		local rivals = c:rivals()
		local dec = st.decided
		d.id, d.title, d.title_color = 'prompt:forfeit', 'Forfeit the Race?', RED
		line('Your run ends here and counts as a DNF.')
		if dec and not dec.you_won and not dec.draw then
			line(Board.safe(dec.winner_name or 'Your rival') .. ' has already won the race.', GREY)
		elseif #rivals == 1 then
			line(Board.safe(rivals[1].name) .. ' still has to finish to win.', GREY)
		else
			line('Your rivals still have to finish to win.', GREY)
		end
		button('forfeit', 'Forfeit', 'forfeit_confirm')
		button('keep', 'Keep Racing', 'prompt_cancel')
		d.focus = 'keep'
		d.cancel = { action = 'prompt_cancel', label = '{CN} Keep Racing' }
		return d
	end

	if st.conn ~= 'connected' or not st.id then
		d.id, d.title = 'offline', 'Competitive Speedrun'
		line(st.conn == 'connecting' and 'Reaching the race server...' or 'The race server is unreachable. Retrying...')
		return d
	end
	local lobby = st.lobby
	if not lobby then
		if st.queue then
			d.id, d.title = 'queue', 'Finding Rivals'
			if st.mismatch then
				for _, l in ipairs(Board.mismatch_lines(st.mismatch)) do line(l.text, l.color) end
				d.id = 'queue:mismatch'
			else
				line('Searching for other racers...')
			end
			line('Waiting ' .. fmt_clock(now - (st.queue.since or now)):gsub('%.%d+$', ''), GREY)
			button('cancel_search', 'Cancel Search', 'cancel_queue')
			d.cancel = { action = 'cancel_queue', label = '{CN} Cancel' }
			return d
		end
		if ui.page == 'code' then
			local full = #ui.code >= Board.CODE_LENGTH
			d.id, d.title = 'code', 'Race by Code'
			line(Board.code_slots(ui.code), GOLD)
			line("Enter your rival's code, or agree on any code and both enter it.", GREY)
			d.grid = { kind = 'keys', cols = 8, items = {} }
			for ch in Board.KEYS:gmatch('.') do
				d.grid.items[#d.grid.items + 1] = { key = 'key_' .. ch, label = ch, action = 'type', arg = ch }
			end
			if full then button('join', 'Join Race', 'join') end
			button('back', 'Back', 'home')
			d.cancel = { action = 'backspace', label = #ui.code > 0 and '{CN} Delete' or '{CN} Back' }
			d.focus = full and 'join' or ('key_' .. Board.KEYS:sub(1, 1))
			d.id = d.id .. (full and ':full' or '')
			return d
		end
		d.id, d.title = 'home', 'Competitive Speedrun'
		line('Racing as ' .. Board.safe(c.name))
		if st.mismatch then
			for _, l in ipairs(Board.mismatch_lines(st.mismatch)) do line(l.text, l.color) end
			d.id = 'home:mismatch'
		else
			line('Same seed, same rooms, same foes. First to clear wins.', GREY)
			local err = st.last_error
			if err and now - (err.at or 0) < 10 then line(err.message or err.code, RED) end
		end
		button('find', 'Find Match', 'find')
		button('create', 'Create Private Race', 'create')
		button('join_page', 'Race by Code', 'join_page')
		return d
	end

	local rivals = c:rivals()
	local opp = Board.safe(#rivals == 1 and rivals[1].name or 'your rivals')
	local players = lobby.players or {}
	local phase = lobby.phase
	-- Everyone in the lobby, one line each.
	local function roster()
		for _, p in ipairs(players) do
			local tags = {}
			if p.id == lobby.you then tags[#tags + 1] = 'you' end
			if p.host and not lobby.public then tags[#tags + 1] = 'host' end
			line(Board.safe(p.name) .. (#tags > 0 and ('  (' .. table.concat(tags, ', ') .. ')') or ''),
				p.connected == false and GREY or BODY)
		end
	end
	-- Names of the other players for whom pred(p) is false.
	local function waiting_on(pred)
		local out = {}
		for _, p in ipairs(players) do
			if p.id ~= lobby.you and not pred(p) then out[#out + 1] = Board.safe(p.name) end
		end
		return out
	end
	if phase == 'waiting' and lobby.public then
		-- Find Match: more racers can join until the setup starts by itself.
		local n, alone = #players, #players < 2
		d.id, d.title = 'waiting:public:' .. n, 'Finding Rivals'
		if alone and st.mismatch then
			for _, l in ipairs(Board.mismatch_lines(st.mismatch)) do line(l.text, l.color) end
			d.id = d.id .. ':mismatch'
		elseif alone then
			line('Searching for other racers...')
		else
			line(n .. ' racers found (up to ' .. (lobby.max_players or n) .. ').')
		end
		roster()
		local left = c:starts_in()
		if left then
			line('The race setup starts in ' .. math.ceil(left) .. 's.', GOLD)
		elseif alone then
			line('Waiting ' .. fmt_clock(now - (st.search_since or now)):gsub('%.%d+$', ''), GREY)
		end
		button('cancel_search', 'Cancel Search', 'cancel_queue')
		d.cancel = { action = 'cancel_queue', label = '{CN} Cancel' }
	elseif phase == 'waiting' then
		local n, host = #players, c:is_host()
		d.id, d.title = 'waiting:' .. n .. ':' .. tostring(host), 'Private Race'
		line('Code  ' .. (lobby.code or '????'):gsub('.', '%0 '):gsub(' $', ''), GOLD)
		line('Share this code with your rivals (up to ' .. (lobby.max_players or 2) .. ' racers).', GREY)
		roster()
		if not host then
			local host_name = 'the host'
			for _, p in ipairs(players) do
				if p.host then host_name = Board.safe(p.name) end
			end
			line('Waiting for ' .. host_name .. ' to start the race...', GREY)
		elseif n >= 2 then
			button('start', 'Start Race', 'start')
		else
			line('Waiting for a rival to join...')
		end
		button('leave', 'Leave Race', 'leave')
	elseif phase == 'voting_weapon' or phase == 'voting_keepsake' then
		local kind = phase == 'voting_weapon' and 'weapon' or 'keepsake'
		local v = st.vote or { options = {} }
		d.title = kind == 'weapon' and 'Vote: Weapon' or 'Vote: Keepsake'
		local left = math.max(0, math.ceil((v.deadline or now) - now))
		if #rivals == 1 then
			line('vs ' .. opp .. '   -   ' .. left .. 's left')
			line((v.voters or {})[rivals[1].id] and (opp .. ' has voted.') or (opp .. ' is choosing...'), GREY)
		else
			line((#rivals + 1) .. ' racers   -   ' .. left .. 's left')
			line((v.voted or 0) .. ' of ' .. (v.of or #rivals + 1) .. ' have voted. Most votes wins.', GREY)
		end
		d.grid = { kind = kind, cols = kind == 'weapon' and 6 or 11, items = {} }
		local keys = {}
		for _, o in ipairs(v.options or {}) do
			local shown = names(o.id)
			if shown == o.id then shown = o.name or o.id end
			d.grid.items[#d.grid.items + 1] = { key = 'opt_' .. o.id, label = shown, action = 'vote',
				arg = o.id, icon = o.id, selected = v.mine == o.id }
			keys[#keys + 1] = o.id
		end
		button('leave', 'Leave Race', 'leave')
		d.focus = v.mine and ('opt_' .. v.mine) or (d.grid.items[1] and d.grid.items[1].key)
		d.id = 'vote_' .. kind .. ':' .. #keys .. ':' .. tostring(keys[1]) .. ':' .. tostring(v.mine)
	elseif phase == 'ready_check' then
		local me_ready = false
		for _, p in ipairs(players) do
			if p.id == lobby.you then me_ready = p.ready end
		end
		local not_ready = waiting_on(function(p) return p.ready end)
		local w = st.vote_results.weapon and st.vote_results.weapon.selected
		local k = st.vote_results.keepsake and st.vote_results.keepsake.selected
		d.id, d.title = 'ready:' .. tostring(me_ready), 'Ready to Race'
		line((w and names(w) or '?') .. '   +   ' .. (k and names(k) or '?'), GOLD)
		line('Set your Arcana, familiar and aspect here first.', GREY)
		if #not_ready > 0 then
			line('Waiting for ' .. Board.join_names(not_ready) .. '...', GREY)
		else
			line(#rivals == 1 and (opp .. ' is ready.') or 'Everyone else is ready.', GREEN)
		end
		d.show = { { kind = 'weapon', id = w }, { kind = 'keepsake', id = k } }
		if not me_ready then button('ready', 'Ready', 'ready') end
		button('leave', 'Leave Race', 'leave')
	elseif phase == 'countdown' then
		d.id, d.title = 'countdown', 'Get Ready'
		line('The race is starting.')
		d.close = true
	elseif phase == 'racing' then
		-- Back in the hub while rivals are still running (after a clear or a DNF).
		local dec, mine = st.decided, st.race and st.race.completed
		d.title = dec and (dec.you_won and 'Victory' or 'Defeat') or 'Race in Progress'
		d.title_color = dec and (dec.you_won and GREEN or RED) or nil
		if dec and dec.you_won then
			line('You cleared first.', GREEN)
		elseif dec and not dec.draw and dec.winner_name then
			line(Board.safe(dec.winner_name) .. ' cleared first.', RED)
		end
		local running = 0
		for _, r in ipairs(rivals) do
			if not r.finished then
				running = running + 1
				local p = r.progress
				line(Board.safe(r.name) .. ' is still running' .. (p and p.depth and (': depth ' .. p.depth) or '') .. '.')
			end
		end
		line(running > 1 and 'The full results appear when everyone finishes.' or 'The full results appear when they finish.',
			GREY)
		d.id = 'racing:' .. tostring(dec and dec.you_won) .. ':' .. tostring(mine and mine.forfeit) .. ':' .. #d.lines
	elseif phase == 'finished' then
		local r = st.result or {}
		d.id = 'finished:' .. tostring(st.rematch_requested)
		d.title = r.draw and 'Draw' or (r.you_won and 'Victory' or 'Defeat')
		d.title_color = r.draw and GOLD or (r.you_won and GREEN or RED)
		line(REASONS[r.reason] or '', GREY)
		local results = r.results or {}
		if #results == 2 then
			local me, them
			for _, e in ipairs(results) do
				if e.id == lobby.you or e.id == st.id then me = e else them = e end
			end
			if me and them then d.compare = Board.compare(me, them) end
		elseif #results > 2 then
			d.table = Board.standings(results, lobby.you or st.id)
		end
		if st.rematch_requested then
			local others = waiting_on(function(p) return p.rematch end)
			line('Rematch requested. Waiting for ' .. (#others > 0 and Board.join_names(others) or 'the others') .. '...', GREY)
		else
			button('rematch', 'Rematch', 'rematch')
		end
		button('leave', 'Leave Race', 'leave')
	else
		d.id, d.title = 'phase:' .. tostring(phase), 'Competitive Speedrun'
	end
	return d
end

-- Pages that need the player: the board opens itself for these in the hub.
function Board.wants_attention(id)
	if id == nil then return false end
	-- A private lobby's host, once someone joins: Start Race is up to them.
	local joined = tonumber(id:match('^waiting:(%d+):true$'))
	return id:find('^vote_') ~= nil or id:find('^ready:false') ~= nil or id:find('^finished') ~= nil
		or id:find(':mismatch$') ~= nil or (joined ~= nil and joined >= 2)
end

-- actions (shared by controller presses and the test bot) ---------------------

function Board.new(deps)
	local b = setmetatable({}, Board)
	b.G, b.log, b.client, b.game, b.now = deps.G, deps.log, deps.client, deps.game, deps.now
	b.names = deps.names
	b.ui = { page = nil, code = '' }
	b.gen = 0
	b.disabled = false
	b.stats = { opens = 0, builds = 0, presses = 0 }
	return b
end

function Board:act(action, arg)
	local c, ui = self.client, self.ui
	self.stats.presses = self.stats.presses + 1
	self.log('board: ' .. tostring(action) .. (arg and (' ' .. tostring(arg)) or ''))
	if action == 'close' then
		self:close()
	elseif action == 'find' then
		c:find_match()
	elseif action == 'cancel_queue' then
		c:cancel_match()
	elseif action == 'start' then
		c:start_race()
	elseif action == 'create' then
		c:create_lobby()
	elseif action == 'join_page' then
		ui.page, ui.code = 'code', ''
	elseif action == 'home' then
		ui.page, ui.code = nil, ''
	elseif action == 'type' then
		if #ui.code < Board.CODE_LENGTH then ui.code = ui.code .. arg end
	elseif action == 'backspace' then
		if #ui.code > 0 then ui.code = ui.code:sub(1, -2) else ui.page = nil end
	elseif action == 'join' then
		if #ui.code == Board.CODE_LENGTH then
			c:join_lobby(ui.code, true)
			ui.page, ui.code = nil, ''
		end
	elseif action == 'vote' then
		local v = c.state.vote
		if v then c:vote(v.phase, arg) end
	elseif action == 'ready' then
		c:ready()
	elseif action == 'rematch' then
		c:rematch()
	elseif action == 'leave' then
		c:leave_lobby()
	elseif action == 'forfeit_confirm' then
		ui.prompt = nil
		if self.game and self.game.forfeit_now then self.game:forfeit_now() end
		self:close()
	elseif action == 'prompt_cancel' then
		ui.prompt = nil
		self:close()
	end
end

-- An in-run prompt (pause menu "Forfeit Race"): opens even outside the hub.
function Board:prompt(kind)
	self.ui.prompt = kind
	self.log('board: prompt ' .. tostring(kind))
end

-- Press a control on the current page by its key (what the test bot does;
-- the controller goes through the same act()).
function Board:press(key)
	local d = self.desc
	if not d then return false end
	if key == 'cancel' then
		self:act(d.cancel.action)
		return true
	end
	for _, list in ipairs({ d.buttons, d.grid and d.grid.items or {} }) do
		for _, item in ipairs(list) do
			if item.key == key then
				self:act(item.action, item.arg)
				return true
			end
		end
	end
	return false
end

-- engine half --------------------------------------------------------------------

local GROUP = 'Combat_Menu_TraitTray'
local BACK_GROUP = 'Combat_Menu_TraitTray_Backing'

local function text_args(id, text, font, size, color, extra)
	local a = {
		Id = id, Text = text, Font = font, FontSize = size, Color = color or BODY,
		Justification = 'Center', VerticalJustification = 'Center',
		OutlineColor = { 27, 26, 23, 255 }, OutlineThickness = 3,
		ShadowColor = { 12, 11, 10, 255 }, ShadowBlur = 0, ShadowOffset = { 0, 4 },
	}
	for k, v in pairs(extra or {}) do a[k] = v end
	return a
end

function Board:is_open()
	return self.screen ~= nil and self.screen.KeepOpen == true
end

function Board:fail(what, err)
	self.disabled = true
	self.log('board: disabled after ' .. what .. ' failed: ' .. tostring(err))
end

-- Each weapon's base aspect: its icon is boon-sized, like the keepsakes'.
local BASE_ASPECT = {
	WeaponStaffSwing = 'BaseStaffAspect', WeaponDagger = 'DaggerBackstabAspect', WeaponTorch = 'TorchSpecialDurationAspect',
	WeaponAxe = 'AxeRecoveryAspect', WeaponLob = 'LobAmmoBoostAspect', WeaponSuit = 'BaseSuitAspect',
}

function Board:icon_for(kind, id)
	local G = self.G
	if not id then return nil end
	if kind == 'weapon' then
		local aspect = G.TraitData and BASE_ASPECT[id] and G.TraitData[BASE_ASPECT[id]]
		if aspect and aspect.Icon then return aspect.Icon end
		local icons = G.ScreenData and G.ScreenData.Shrine and G.ScreenData.Shrine.BountyWeaponIcons
		return icons and icons[id]
	end
	local t = G.TraitData and G.TraitData[id]
	return t and (t.InRackIcon or t.Icon)
end

function Board:component(key, params)
	local G = self.G
	params.Group = params.Group or GROUP
	local comp = G.CreateScreenComponent(params)
	self.screen.Components[key] = comp
	self.dynamic[#self.dynamic + 1] = key
	return comp
end

function Board:label(key, x, y, text, font, size, color, extra)
	local comp = self:component(key, { Name = 'BlankObstacle', X = x, Y = y })
	self.G.CreateTextBox(text_args(comp.Id, text, font, size, color, extra))
	return comp
end

function Board:clear_dynamic()
	local ids = {}
	for _, key in ipairs(self.dynamic or {}) do
		local comp = self.screen.Components[key]
		if comp then ids[#ids + 1] = comp.Id end
		self.screen.Components[key] = nil
	end
	if #ids > 0 then self.G.Destroy({ Ids = ids }) end
	self.dynamic = {}
end

-- Build the page for description d. Never yields (runs from the frame callback).
function Board:render(d)
	local G = self.G
	local cx, cy = G.ScreenCenterX or 960, G.ScreenCenterY or 540
	self:clear_dynamic()
	self.gen = self.gen + 1
	self.desc, self.rendered = d, d.id
	self.last_attention = d.id -- seen: closing it with B keeps it closed
	self.stats.builds = self.stats.builds + 1
	self.log('board: page ' .. tostring(d.id))

	self:label('Title', cx, cy - 330, d.title, 'P22UndergroundSCMedium', 44, d.title_color or TITLE_COLOR,
		{ OutlineThickness = 4 })
	for i, l in ipairs(d.lines) do
		local big = i == 1 and l.color == GOLD
		self:label('Line' .. i, cx, cy - 262 + (i - 1) * 40 + (big and -6 or 0), l.text,
			big and 'P22UndergroundSCMedium' or 'LatoMedium', big and 34 or 24, l.color or BODY, { Width = 900 })
	end

	local focus_id
	local top = cy - 262 + #d.lines * 40 + 40
	if d.compare then
		top = self:render_compare(d.compare, cx, top)
	elseif d.table then
		top = self:render_table(d.table, cx, top)
	elseif d.grid then
		local g, n = d.grid, #d.grid.items
		local step_x = g.kind == 'weapon' and 150 or (g.kind == 'keys' and 96 or 104)
		local step_y = g.kind == 'keys' and 90 or 118
		local cols = math.min(g.cols, n)
		local x0 = cx - (cols - 1) * step_x / 2
		local y0 = top + (g.kind == 'weapon' and 60 or 50)
		-- Behind the buttons, like the Keepsake rack's cursor frame.
		self:component('HoverFrame', { Name = 'BlankObstacle', X = -1000, Y = -1000, Group = BACK_GROUP,
			Animation = 'AwardMenuCursorHighlight', Scale = g.kind == 'keys' and 0.7 or 1 })
		for i, item in ipairs(g.items) do
			local col, row = (i - 1) % g.cols, math.floor((i - 1) / g.cols)
			local x, y = x0 + col * step_x, y0 + row * step_y
			local scale = g.kind == 'weapon' and 0.85 or 0.55 -- aspect art is smaller than keepsake art
			local comp = self:component(item.key, { Name = 'ButtonKeepsakeItem', X = x, Y = y, Scale = scale })
			comp.Action, comp.Arg, comp.Label = item.action, item.arg, item.label
			comp.Sound = '/SFX/Menu Sounds/GeneralWhooshMENU'
			comp.OnMouseOverFunctionName, comp.OnMouseOffFunctionName = 'RankedRace_BoardHover', 'RankedRace_BoardUnhover'
			G.AttachLua({ Id = comp.Id, Table = comp })
			if g.kind == 'keys' then
				G.SetAnimation({ Name = 'Keepsake_BackingMenu', DestinationId = comp.Id })
				G.CreateTextBox(text_args(comp.Id, item.label, 'P22UndergroundSCMedium', 40, BODY))
			else
				local icon = self:icon_for(g.kind, item.icon)
				if icon then G.SetAnimation({ Name = icon, DestinationId = comp.Id }) end
			end
			if item.selected then
				self:component('Selected_' .. item.key, { Name = 'BlankObstacle', X = x, Y = y,
					Group = 'Combat_Menu_TraitTray_Overlay', Animation = 'AwardMenuItemEquippedIn' })
			end
			if item.key == d.focus then focus_id = comp.Id end
		end
		local rows = math.ceil(n / g.cols)
		self:label('HoverLabel', cx, y0 + rows * step_y - 10, ' ', 'P22UndergroundSCMedium', 28, GOLD)
		top = y0 + rows * step_y + 50
	elseif d.show then
		local x0 = cx - 90
		for i, s in ipairs(d.show) do
			local icon = self:icon_for(s.kind, s.id)
			if icon then
				self:component('Show' .. i, { Name = 'BlankObstacle', X = x0 + (i - 1) * 180, Y = top + 70,
					Animation = icon, Scale = s.kind == 'weapon' and 0.85 or 0.55 })
			end
		end
		top = top + 170
	end

	-- Action buttons: a column on list pages, a row under grids.
	local nb = #d.buttons
	for i, btn in ipairs(d.buttons) do
		local x, y
		if d.grid or d.compare or d.table then
			x, y = cx + (i - (nb + 1) / 2) * 440, math.max(top, cy + 200) + 40
		else
			x, y = cx, math.max(top + 30, cy - 60) + (i - 1) * 100
		end
		local comp = self:component('Button_' .. btn.key, { Name = 'ButtonDefault', X = x, Y = y, Scale = 1.2 })
		comp.Action, comp.Arg = btn.action, btn.arg
		comp.Sound = '/SFX/Menu Sounds/GeneralWhooshMENU'
		G.CreateTextBox(text_args(comp.Id, btn.label, 'P22UndergroundSCMedium', 26, { 254, 255, 255, 255 },
			{ Width = 600, OutlineThickness = 0, ShadowColor = { 0, 0, 0, 0 }, ShadowOffset = { 0, 3 } }))
		if btn.key == d.focus or (not d.focus and i == 1 and not d.grid) then focus_id = comp.Id end
	end

	-- Bottom-right contextual action, bound to Cancel (B / Esc).
	local ui_data = G.UIData or {}
	local back = self:component('Cancel', { Name = 'ContextualActionButton', X = ui_data.ContextualButtonXRight or 1875,
		Y = ui_data.ContextualButtonY or 1030 })
	back.Action = d.cancel.action
	back.ControlHotkeys = { 'Cancel' }
	back.OnMouseOverFunctionName, back.OnMouseOffFunctionName = 'MouseOverContextualAction', 'MouseOffContextualAction'
	local fmt = {}
	for k, v in pairs(ui_data.ContextualButtonFormatRight or {}) do fmt[k] = v end
	fmt.Id, fmt.Text = back.Id, d.cancel.label
	G.CreateTextBox(fmt)
	G.AttachLua({ Id = back.Id, Table = back })

	self.focus_id = focus_id
	if focus_id then G.TeleportCursor({ DestinationId = focus_id, ForceUseCheck = true }) end
end

-- In mouse mode TeleportCursor only moves the pointer; when the player picks up
-- the controller, the game starts its selection from wherever the pointer is.
-- Put it back on the page's focus so A does what the screen suggests.
function Board:follow_input_mode()
	local G = self.G
	if not G.GetConfigOptionValue then return end
	local mouse = G.GetConfigOptionValue({ Name = 'UseMouse' })
	if self.used_mouse and not mouse and self.focus_id then
		G.TeleportCursor({ DestinationId = self.focus_id, ForceUseCheck = true })
		self.log('board: controller picked up; cursor on the page focus')
	end
	self.used_mouse = mouse
end

-- Boon icons in rarity frames, per_row to a row, centred on x. Returns rows used.
function Board:boon_icons(prefix, build, x, y, per_row, step, scale)
	local G, icons = self.G, {}
	for _, entry in ipairs(build or {}) do
		local trait = G.TraitData and G.TraitData[entry.name]
		if trait and trait.Icon then icons[#icons + 1] = { icon = trait.Icon, rarity = entry.rarity } end
	end
	local n = math.min(#icons, per_row)
	for i, e in ipairs(icons) do
		local c, r = (i - 1) % per_row, math.floor((i - 1) / per_row)
		local ix, iy = x - (n - 1) * step / 2 + c * step, y + r * step
		self:component(prefix .. i, { Name = 'BlankObstacle', X = ix, Y = iy, Animation = e.icon, Scale = scale })
		local frame = e.rarity and ('Frame_Boon_Menu_' .. e.rarity) or 'BoonIcon_Frame_Common'
		self:component(prefix .. 'Frame' .. i, { Name = 'BlankObstacle', X = ix, Y = iy, Animation = frame, Scale = scale })
	end
	return math.ceil(#icons / per_row)
end

-- Results screen: both racers side by side like the run clear screen's stats
-- panel; the better value of each row in gold, boons with rarity frames below.
local ICON_STEP, ICONS_PER_ROW = 44, 8
function Board:render_compare(cmp, cx, top)
	local col = { me = cx - 250, them = cx + 250 }
	local y = top
	for _, who in ipairs({ 'me', 'them' }) do
		local side = cmp[who]
		self:label('Name_' .. who, col[who], y, side.name, 'P22UndergroundSCMedium', 30, GOLD)
		self:label('Result_' .. who, col[who], y + 36, side.result, 'P22UndergroundSCMedium', 24, side.color)
		if side.depth then self:label('Depth_' .. who, col[who], y + 66, side.depth, 'LatoMedium', 20, GREY) end
	end
	self:label('Versus', cx, y + 30, 'VS', 'P22UndergroundSCMedium', 26, GREY)
	y = y + 112
	for i, row in ipairs(cmp.rows) do
		local ry = y + (i - 1) * 32
		self:label('RowLabel' .. i, cx, ry, row.label, 'LatoMedium', 20, GREY)
		self:label('RowMe' .. i, col.me, ry, row.me, 'NumericP22UndergroundSCMedium', 24, row.win == 'me' and GOLD or BODY)
		self:label('RowThem' .. i, col.them, ry, row.them, 'NumericP22UndergroundSCMedium', 24, row.win == 'them' and GOLD or BODY)
	end
	y = y + #cmp.rows * 32 + 24
	local rows_used = 0
	for _, who in ipairs({ 'me', 'them' }) do
		rows_used = math.max(rows_used, self:boon_icons('Boon_' .. who, cmp[who].build, col[who], y, ICONS_PER_ROW, ICON_STEP, 0.3))
	end
	return y + rows_used * ICON_STEP
end

-- Results for three or more: stat labels on the left, a column per racer.
local MINI_STEP, MINI_PER_ROW = 34, 4
function Board:render_table(t, cx, top)
	local n = #t.cols
	local x_first, x_last = cx - 180, cx + 440
	local step = n > 1 and (x_last - x_first) / (n - 1) or 0
	local fit = math.max(6, math.floor(step / 12))
	local y = top
	for i, col in ipairs(t.cols) do
		local x = x_first + (i - 1) * step
		local name = #col.name > fit and (col.name:sub(1, fit - 1) .. '.') or col.name
		self:label('Place' .. i, x, y, col.place, 'P22UndergroundSCMedium', 30, col.winner and GOLD or TITLE_COLOR)
		self:label('Name' .. i, x, y + 34, name, 'P22UndergroundSCMedium', 22, col.me and GOLD or BODY)
		self:label('Result' .. i, x, y + 62, col.result, 'P22UndergroundSCMedium', 20, col.color)
		if col.time then self:label('Time' .. i, x, y + 86, col.time, 'NumericP22UndergroundSCMedium', 20, col.color) end
		if col.depth then self:label('Depth' .. i, x, y + 110, col.depth, 'LatoMedium', 18, GREY) end
	end
	y = y + 146
	for r, row in ipairs(t.rows) do
		local ry = y + (r - 1) * 28
		self:label('RowLabel' .. r, cx - 390, ry, row.label, 'LatoMedium', 18, GREY)
		for i, cell in ipairs(row.cells) do
			self:label('Cell' .. r .. '_' .. i, x_first + (i - 1) * step, ry, cell, 'NumericP22UndergroundSCMedium', 22,
				row.best[i] and GOLD or BODY)
		end
	end
	y = y + #t.rows * 28 + 16
	local rows_used = 0
	for i, col in ipairs(t.cols) do
		rows_used = math.max(rows_used, self:boon_icons('Boon' .. i .. '_', col.build, x_first + (i - 1) * step, y,
			MINI_PER_ROW, MINI_STEP, 0.22))
	end
	return y + rows_used * MINI_STEP
end

-- Update texts in place when the page is the same (timers, rival status).
function Board:refresh(d)
	local G, comps = self.G, self.screen.Components
	self.desc = d
	if comps.Title then G.ModifyTextBox({ Id = comps.Title.Id, Text = d.title }) end
	for i, l in ipairs(d.lines) do
		local comp = comps['Line' .. i]
		if comp then G.ModifyTextBox({ Id = comp.Id, Text = l.text, Color = l.color or BODY }) end
	end
end

function Board:hover(comp, on)
	local comps = self.screen and self.screen.Components
	if not comps then return end
	if comps.HoverFrame then
		if on then
			self.G.Teleport({ Id = comps.HoverFrame.Id, DestinationId = comp.Id })
		else
			self.G.Teleport({ Id = comps.HoverFrame.Id, OffsetX = -1000, OffsetY = -1000 })
		end
	end
	if comps.HoverLabel then self.G.ModifyTextBox({ Id = comps.HoverLabel.Id, Text = on and comp.Label or ' ' }) end
end

-- Coroutine body: open the screen and run its input loop until closed.
function Board:run()
	local G = self.G
	if self:is_open() then return end
	local cx, cy = G.ScreenCenterX or 960, G.ScreenCenterY or 540
	local screen = {
		Name = Board.SCREEN, Components = {}, BlockPause = true,
		OpenSound = '/SFX/Menu Sounds/HadesLocationTextAppear', CloseSound = '/SFX/Menu Sounds/IrisMenuBack',
		GamepadNavigation = {
			FreeFormSelectWrapY = false, FreeFormSelectGridLock = true, FreeFormSelectStepDistance = 8,
			FreeFormSelectSuccessDistanceStep = 4, FreeFormSelectRepeatDelay = 0.6, FreeFormSelectRepeatInterval = 0.1,
		},
		ComponentData = {
			DefaultGroup = BACK_GROUP,
			Order = { 'BackgroundTint', 'Box' },
			BackgroundTint = { Graphic = 'rectangle01', GroupName = BACK_GROUP, Scale = 10, X = cx, Y = cy },
			Box = { AnimationName = 'MythmakerBoxDefault', GroupName = BACK_GROUP, X = cx, Y = cy, ScaleX = 1.5, ScaleY = 1.25 },
		},
	}
	self.screen, self.dynamic = screen, {}
	self.stats.opens = self.stats.opens + 1
	G.OnScreenOpened(screen)
	G.HideCombatUI(screen.Name)
	G.CreateScreenFromData(screen, screen.ComponentData)
	G.SetColor({ Id = screen.Components.BackgroundTint.Id, Color = { 0, 0, 0, 1 } })
	G.SetAlpha({ Id = screen.Components.BackgroundTint.Id, Fraction = 0.85, Duration = 0.2 })
	G.SetConfigOption({ Name = 'ExclusiveInteractGroup', Value = GROUP })
	local d = Board.view(self.client, self.ui, self.now(), self.names)
	self:render(d)
	screen.KeepOpen = true
	self.log('board: opened (' .. tostring(d.id) .. ')')

	-- The game's HandleScreenInput, with a fresh notify name per page build so a
	-- press meant for a page that was rebuilt meanwhile is dropped, not replayed.
	while screen.KeepOpen do
		local gen = self.gen
		local notify = 'RankedRaceBoardInput' .. gen
		local ids, hotkeys = {}, {}
		for _, comp in pairs(screen.Components) do
			if comp.Action then ids[#ids + 1] = comp.Id end
			if comp.ControlHotkeys then
				for _, h in ipairs(comp.ControlHotkeys) do hotkeys[#hotkeys + 1] = h end
			end
		end
		self.waiting_on = notify
		G.NotifyOnInteractOrControlPressed({ Ids = ids, Names = hotkeys, Notify = notify })
		G.waitUntil(notify)
		self.waiting_on = nil
		local result = G.NotifyResultsTable and G.NotifyResultsTable[notify]
		local allowed = G.IsInputAllowed({})
		if result ~= nil then
			self.log('board: input ' .. tostring(result) .. (allowed and '' or ' (input blocked)')
				.. (gen ~= self.gen and ' (stale page)' or ''))
		end
		if screen.KeepOpen and gen == self.gen and result ~= nil and allowed then
			if type(result) == 'string' then
				if result == 'Cancel' then self:act(self.desc.cancel.action) end
			else
				for _, comp in pairs(screen.Components) do
					if comp.Id == result and comp.Action and G.IsUseable({ Id = comp.Id }) then
						if comp.Sound then G.PlaySound({ Name = comp.Sound }) end
						self:act(comp.Action, comp.Arg)
						break
					end
				end
			end
		end
		if G.NotifyResultsTable then G.NotifyResultsTable[notify] = nil end
		if screen.KeepOpen then G.wait(0.05) end
	end
	self:finish_close()
end

function Board:finish_close()
	local G, screen = self.G, self.screen
	if not screen or screen.closed then return end
	screen.closed = true
	G.SetConfigOption({ Name = 'ExclusiveInteractGroup', Value = nil })
	G.OnScreenCloseStarted(screen)
	G.CloseScreen(G.GetAllIds(screen.Components), 0.1, screen)
	G.OnScreenCloseFinished(screen)
	G.ShowCombatUI(screen.Name)
	self.log('board: closed')
end

-- Ask the input loop to end (it closes the screen on its own coroutine).
function Board:close()
	local screen = self.screen
	if not screen or not screen.KeepOpen then return end
	screen.KeepOpen = false
	self:wake()
end

function Board:wake()
	local G = self.G
	if self.waiting_on and G.notifyExistingWaiters then G.notifyExistingWaiters(self.waiting_on) end
end

function Board:open()
	if self.disabled or self:is_open() then return end
	local G = self.G
	G.thread(G.RankedRace_BoardRun)
end

-- Globals the engine calls by name (CallFunctionName / OnMouseOver).
function Board:install()
	local G = self.G
	G.RankedRaceBoardObj = self
	if G.RankedRace_BoardRun then return end -- hot reload: globals already point at RankedRaceBoardObj
	G.RankedRace_BoardRun = function()
		local b = G.RankedRaceBoardObj
		local ok, err = xpcall(function() b:run() end, debug.traceback)
		if not ok then
			b:fail('running the screen', err)
			pcall(b.finish_close, b)
		end
	end
	G.RankedRace_UseStone = function()
		G.RankedRace_BoardRun()
	end
	G.RankedRace_BoardHover = function(comp)
		local b = G.RankedRaceBoardObj
		if b then pcall(b.hover, b, comp, true) end
	end
	G.RankedRace_BoardUnhover = function(comp)
		local b = G.RankedRaceBoardObj
		if b then pcall(b.hover, b, comp, false) end
	end
end

-- Hub: turn the Pitch-Black Stone into the race board's entrance.
function Board:patch_stone()
	local G = self.G
	local ms = G.MapState
	if not ms or ms.RankedRaceStone then return end
	local stone = ms.ActiveObstacles and ms.ActiveObstacles[Board.STONE_ID]
	if not stone then return end
	ms.RankedRaceStone = true
	stone.OnUsedFunctionName = 'RankedRace_UseStone'
	stone.UseText = Board.USE_TEXT
	pcall(G.SetAnimation, { Name = 'Crossroads_BountyBoard_On01', DestinationId = Board.STONE_ID })
	G.UseableOn({ Id = Board.STONE_ID })
	self.log('board: Pitch-Black Stone is now the race board')
end

-- Every frame (not a coroutine: nothing here may yield).
function Board:update(in_hub)
	if self.disabled then return end
	local ok, err = pcall(self.tick, self, in_hub)
	if not ok then self:fail('updating', err) end
end

function Board:tick(in_hub)
	if in_hub then self:patch_stone() end
	if self.ui.prompt == 'forfeit' and self.game and self.game.forfeit_available and not self.game:forfeit_available() then
		self.ui.prompt = nil -- the run ended meanwhile
	end
	local d = Board.view(self.client, self.ui, self.now(), self.names)
	local here = in_hub or self.ui.prompt ~= nil
	if self:is_open() then
		if d.close or not here then
			self:close()
		elseif d.id ~= self.rendered then
			self:render(d)
			self:wake() -- the input loop re-registers the new buttons
		else
			self:refresh(d)
		end
		self:follow_input_mode()
	elseif self.ui.prompt then
		if not self:other_screen_open() and self:input_allowed() then self:open() end
	elseif in_hub and not d.close then
		-- Open by itself on arrival and when the race needs the player.
		-- A page counts as seen once it was rendered (render sets last_attention),
		-- so one that can't open yet (input blocked during the walk-in) waits.
		local attention = Board.wants_attention(d.id) and d.id ~= self.last_attention
		local now = self.now()
		if attention or (self.open_at and now >= self.open_at) then
			-- Not during the hub's arrival presentation: it blocks input, and a
			-- board that ignores the controller looks broken.
			if not self:other_screen_open() and self:input_allowed() then
				self.open_at = nil
				self:open()
			end
		end
	end
end

-- Open once the hero has settled in the hub (first arrival).
function Board:open_soon(delay)
	self.open_at = self.now() + (delay or 1.5)
end

function Board:input_allowed()
	local G = self.G
	if not G.IsInputAllowed then return true end
	local ok, allowed = pcall(G.IsInputAllowed, {})
	return not ok or allowed ~= false
end

function Board:other_screen_open()
	local screens = self.G.ActiveScreens
	return screens ~= nil and next(screens) ~= nil
end

return Board
