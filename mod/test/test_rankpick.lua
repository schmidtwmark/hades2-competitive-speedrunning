local T = require('test.lib')
local Game = T.load('game.lua')

-- Just enough of the game's random helpers for Game:rank_scope.
local function fake_game(seed)
	local G = { NextSeeds = { 1 }, draws = 0 }
	function G.RandomInit() end
	function G.RandomInt(a) G.draws = G.draws + 1; return a end
	function G.TableLength(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
	function G.CollapseTableOrdered(t)
		local keys, out = {}, {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do out[#out + 1] = t[k] end
		return out
	end
	function G.OverwriteAndCollapseTable(t)
		local vals = {}
		for _, v in pairs(t) do vals[#vals + 1] = v end
		for k in pairs(t) do t[k] = nil end
		for i, v in ipairs(vals) do t[i] = v end
		return t
	end
	G.GetRandomValue = function(t) G.draws = G.draws + 1; return G.CollapseTableOrdered(t)[1] end
	G.RemoveRandomValue = function() error('original RemoveRandomValue called') end
	G.GetRandomValueFromWeightedList = function() error('original weighted pick called') end
	local g = Game.new({ rom = { game = G }, log = function() end, now = function() return 0 end })
	g.launching = { seed = seed or 12345 }
	return g, G
end

local function pick(g, G, list, tags)
	return g:rank_scope(tags or { 'test', 3 }, nil, function() return G.GetRandomValue(list) end)
end

T.case('rank pick: equal lists pick alike; a losing option missing changes nothing', function()
	local g, G = fake_game()
	local full = { 'ArtemisCombatF2', 'GeneratedF', 'GeneratedF', 'NemesisRandomEvent', 'ArachneCombatF' }
	local win = pick(g, G, full)
	T.truthy(win)
	T.eq(pick(g, G, { 'NemesisRandomEvent', 'GeneratedF', 'ArachneCombatF', 'GeneratedF', 'ArtemisCombatF2' }), win,
		'order does not matter')
	-- Drop one option that did not win (keep the winner): same pick.
	local loser
	for _, v in ipairs(full) do if v ~= win then loser = v end end
	local short = {}
	for _, v in ipairs(full) do if v ~= loser then short[#short + 1] = v end end
	T.eq(pick(g, G, short), win)
	-- Drop the winner: something else.
	local no_win = {}
	for _, v in ipairs(full) do if v ~= win then no_win[#no_win + 1] = v end end
	T.truthy(pick(g, G, no_win) ~= win)
	T.eq(G.GetRandomValue == nil, false, 'original restored')
	T.eq(G.draws, 0, 'no draws from the game RNG inside the scope')
end)

T.case('rank pick: other tags or seeds pick independently; tables use their Name', function()
	local names = {}
	for i = 1, 20 do names[i] = 'Option' .. i end
	local seen = {}
	for depth = 1, 30 do
		local g, G = fake_game()
		seen[pick(g, G, names, { 'test', depth })] = true
	end
	local distinct = 0
	for _ in pairs(seen) do distinct = distinct + 1 end
	T.truthy(distinct >= 8, 'picks spread over options: ' .. distinct)
	local g, G = fake_game()
	local a = pick(g, G, { { Name = 'Hydralite' }, { Name = 'DustParcel' }, { Name = 'YarnOfAriadne' } })
	local b = pick(g, G, { { Name = 'YarnOfAriadne' }, { Name = 'Hydralite' }, { Name = 'DustParcel' } })
	T.eq(a.Name, b.Name)
end)

T.case('rank pick: prunes keep the best ranks whatever the order; weights count', function()
	local g, G = fake_game()
	local function prune(list, keep)
		return g:rank_scope({ 'stock', 9 }, nil, function()
			while G.TableLength(list) > keep do G.RemoveRandomValue(list) end
			local out = {}
			for _, v in pairs(list) do out[#out + 1] = v end
			table.sort(out)
			return table.concat(out, ',')
		end)
	end
	local a = prune({ 'A', 'B', 'C', 'D', 'E', 'F' }, 3)
	local b = prune({ 'F', 'E', 'D', 'C', 'B', 'A' }, 3)
	T.eq(a, b)
	-- One racer lacks an option that didn't survive: same survivors.
	local survivors = {}
	for v in a:gmatch('[^,]+') do survivors[v] = true end
	local lacking, dropped = {}, false
	for _, v in ipairs({ 'A', 'B', 'C', 'D', 'E', 'F' }) do
		if not survivors[v] and not dropped then dropped = true else lacking[#lacking + 1] = v end
	end
	T.eq(#lacking, 5)
	T.eq(prune(lacking, 3), a)
	local heavy = g:rank_scope({ 'heal', 2 }, nil, function()
		return G.GetRandomValueFromWeightedList({ Big = 1000000, Small = 0.000001 })
	end)
	T.eq(heavy, 'Big')
	local zero = g:rank_scope({ 'heal', 2 }, nil, function()
		return G.GetRandomValueFromWeightedList({ Never = 0, Only = 1 })
	end)
	T.eq(zero, 'Only')
end)

T.case('rank pick: limit leaves later picks to the game; no race, no change', function()
	local g, G = fake_game()
	local first, second = g:rank_scope({ 'encounter', 4 }, { limit = 1 }, function()
		return G.GetRandomValue({ 'X', 'Y', 'Z' }), G.GetRandomValue({ 'Q', 'R' })
	end)
	T.truthy(first)
	T.eq(second, 'Q', 'second pick went to the original (fake: first sorted)')
	g.launching = nil
	T.eq(g:rank_scope({ 'x' }, nil, function() return G.GetRandomValue({ 'M', 'N' }) end), 'M', 'not racing: game picks')
end)
