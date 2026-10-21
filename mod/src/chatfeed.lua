-- Race chat on screen: the last few lines (client.state.chat) at the top left,
-- each for a few seconds, in runs and in the Crossroads, above menus.
-- Text box ids live in MapState (map loads reuse ids).

local ChatFeed = {}
ChatFeed.__index = ChatFeed

local LINES, SHOW_FOR = 4, 10
local X, Y, STEP = 40, 104, 32
local WHITE, GREY = { 245, 245, 245, 255 }, { 175, 175, 185, 255 }

function ChatFeed.new(deps)
	local f = setmetatable({}, ChatFeed)
	f.G, f.log, f.client, f.now = deps.G, deps.log, deps.client, deps.now
	f.disabled = false
	return f
end

-- The lines to show now, oldest first: { text, color }.
function ChatFeed.visible(chat, now)
	local out = {}
	for i = #chat, 1, -1 do
		local m = chat[i]
		if now - (m.at or 0) > SHOW_FOR or #out >= LINES then break end
		local name = tostring(m.name or '?'):gsub('[{}@]', '')
		local text = tostring(m.text or ''):gsub('[{}@]', '')
		table.insert(out, 1, { text = (m.mine and 'You' or name) .. ':  ' .. text, color = m.mine and GREY or WHITE })
	end
	return out
end

function ChatFeed:update()
	if self.disabled or not self.G.MapState then return end
	local ok, err = pcall(self.tick, self)
	if not ok then
		self.disabled = true
		self.log('chat: feed disabled: ' .. tostring(err))
	end
end

function ChatFeed:tick()
	local G, ms = self.G, self.G.MapState
	local now = self.now()
	if now - (self.last or 0) < 0.2 then return end
	self.last = now
	local lines = ChatFeed.visible(self.client.state.chat or {}, now)
	local feed = ms.RankedRaceChat
	if not feed then
		if #lines == 0 then return end
		feed = { ids = {}, shown = {} }
		for i = 1, LINES do
			local id = G.CreateScreenObstacle({ Name = 'BlankObstacle', Group = 'Combat_Menu_TraitTray_Overlay', X = X,
				Y = Y + (i - 1) * STEP })
			G.CreateTextBox({ Id = id, Text = ' ', Font = 'LatoMedium', FontSize = 22, Color = WHITE, Justification = 'Left',
				OutlineColor = { 0, 0, 0, 255 }, OutlineThickness = 2, ShadowColor = { 0, 0, 0, 200 }, ShadowOffset = { 0, 2 },
				Width = 760 })
			feed.ids[i] = id
		end
		ms.RankedRaceChat = feed
	end
	for i = 1, LINES do
		local l = lines[i]
		local key = l and (l.text .. tostring(l.color == GREY)) or ''
		if feed.shown[i] ~= key then
			feed.shown[i] = key
			G.ModifyTextBox({ Id = feed.ids[i], Text = l and l.text or ' ', Color = l and l.color or WHITE })
		end
	end
end

return ChatFeed
