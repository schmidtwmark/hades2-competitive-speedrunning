-- Hell2Modding entry point for Ranked Race.
-- Loaded once per game launch (and again on hot reload) inside this plugin's
-- private environment. Game globals (CurrentRun, ...) live on rom.game.

local guid = _PLUGIN.guid
local plugin_dir = _PLUGIN.plugins_mod_folder_path
local data_dir = _PLUGIN.plugins_data_mod_folder_path
local env = _ENV

local VERSION = '0.3.0'

local function import(name)
	local chunk = assert(loadfile(plugin_dir .. '/' .. name, 't', env))
	return chunk()
end

-- H2M doesn't create the per-plugin data/config folders.
for _, dir in ipairs({ data_dir, _PLUGIN.config_mod_folder_path }) do
	if rom.path and rom.path.create_directory then pcall(rom.path.create_directory, dir) end
end

local socket = require('socket')
local json = import('json.lua')
local Client = import('client.lua')
local Net = import('net.lua')
local UI = import('ui.lua')
local Game = import('game.lua')
local Bot = import('bot.lua')
local Competitive = import('competitive.lua')
local Profile = import('profile.lua')
local Shadow = import('shadow.lua')
local Hud = import('hud.lua')
local Board = import('board.lua')
local Banner = import('banner.lua')

-- logging: H2M's log plus our own file, flushed per line -----------------------

local log_file = io.open(data_dir .. '/ranked.log', 'a')
local function log(line)
	local stamped = string.format('%.3f %s', socket.gettime(), line)
	rom.log.info(line)
	if log_file then
		log_file:write(stamped, '\n')
		log_file:flush()
	end
end
log('=== Ranked Race ' .. VERSION .. ' loading (' .. guid .. ')')

-- config: a Lua table file in the plugin's config folder ------------------------

-- The file holds only what the player changed, so new defaults (e.g. a moved
-- public server) still reach everyone who never edited them.
local DEFAULT_SERVER_HOST = 'hopper.proxy.rlwy.net' -- Railway TCP proxy (scripts/railway-deploy.sh)
local DEFAULT_SERVER_PORT = 16303
local config_path = _PLUGIN.config_mod_folder_path .. '/config.json'
local config = { server_host = DEFAULT_SERVER_HOST, server_port = DEFAULT_SERVER_PORT, player_name = nil,
	hud_x = 20, hud_y = 80, autoconnect = false }
local overrides = {}
do
	local f = io.open(config_path, 'r')
	if f then
		local ok, saved = pcall(json.decode, f:read('*a'))
		f:close()
		if ok and type(saved) == 'table' then
			for k, v in pairs(saved) do
				config[k] = v
				overrides[k] = v
			end
		end
	end
end
local function save_config(changes)
	for k, v in pairs(changes) do
		config[k] = v
		overrides[k] = v
	end
	local f = io.open(config_path, 'w')
	if f then
		f:write(json.encode(overrides))
		f:close()
	end
end

-- Controller-only players never type a name: give each install its own.
if not config.player_name then
	save_config({ player_name = 'Melinoe ' .. (100 + math.floor(socket.gettime() * 1000) % 900) })
end

-- wiring ------------------------------------------------------------------------

local game = Game.new({ rom = rom, modutil = rom.mods['SGG_Modding-ModUtil'], log = log, now = socket.gettime, profile = Profile })

local client = Client.new({
	json = json, transport = Net.new(socket, log), now = socket.gettime, log = log,
	host = config.server_host, port = config.server_port, name = config.player_name, version = VERSION,
	on = {
		race_start = function(race) game:prepare_race(race) end,
		go = function(race) game:start_race(race) end,
		race_result = function(result) game:race_over(result) end,
		lobby_left = function() game:cancel_race() end,
	},
})
game.client = client
-- Sent with hello: the server only pairs racers on the same Hades II build.
client.game_build = game:game_build()
local build_day = client.game_build and os and os.date and os.date('!%Y-%m-%d', client.game_build)
log('game build ' .. tostring(client.game_build) .. (build_day and (' (' .. build_day .. ')') or ''))

-- In-run opponent display: the shadow Melinoë and the native rival plate.
local shadow = Shadow.new({ G = rom.game, log = log, client = client, game = game, now = socket.gettime })
local hud = Hud.new({ G = rom.game, log = log, client = client, game = game, now = socket.gettime })
game.shadow, game.hud = shadow, hud

-- Before/after a race: the native Race Board (controller-first) and banners.
local board = Board.new({ G = rom.game, log = log, client = client, game = game, now = socket.gettime,
	names = function(id) return game:display_name(id) end })
board:install()
local banner = Banner.new({ G = rom.game, log = log, client = client, game = game, now = socket.gettime })
game.board = board

local ui = UI.new({
	ImGui = rom.ImGui, ImGuiCond = rom.ImGuiCond, ImGuiWindowFlags = rom.ImGuiWindowFlags,
	client = client, config = config, log = log,
	names = function(id) return game:display_name(id) end,
	status = function() return game:status_line() end,
	on_connect = function(host, port, name)
		local changes = { player_name = name }
		-- Only remember a server the player actually typed in.
		if host ~= DEFAULT_SERVER_HOST or port ~= DEFAULT_SERVER_PORT then
			changes.server_host, changes.server_port = host, port
		end
		save_config(changes)
	end,
})

local bot = Bot.new({ dir = data_dir, json = json, client = client, game = game, board = board, log = log, now = socket.gettime })

-- Test runs can ask for the lobby window to be open so its draw code runs in-game.
if bot.active and bot.cfg.show_ui then ui.visible = true end

game:install_hooks()
if bot.active and bot.cfg.trace_functions then game:install_tracers(bot.cfg.trace_functions) end
if bot.active and bot.cfg.probe_doors then game.probe_doors = true end

-- Title screen entry "Play Competitive Speedrun" (native hook; see competitive.lua).
-- Never let it take the rest of the mod down.
local competitive = Competitive.new({ rom = rom, log = log, on_start = function() game:enter_competitive() end })
local menu_ok, menu_err = pcall(competitive.install, competitive)
if not menu_ok then log('competitive: install failed: ' .. tostring(menu_err)) end
-- The in-memory competitive profile must never be saved, including by native
-- code that skips the game's Lua save gate (pause menu Undo Night / Quit).
local guard_ok, guard_err = pcall(competitive.install_save_guard, competitive, function() return game:competitive_active() end)
if not guard_ok then log('competitive: save guard failed: ' .. tostring(guard_err)) end
-- Pause menu: "Forfeit Race" (the relabelled Undo Night) and Quit mid-race ask
-- to forfeit; in competitive mode Undo Night never runs.
local pause_ok, pause_err = pcall(competitive.install_pause_hooks, competitive, {
	give_up = function() return game:competitive_active() or game:forfeit_available() end,
	quit = function() return game:forfeit_available() end,
	forfeit_prompt = function() game:request_forfeit() end,
})
if not pause_ok then log('competitive: pause hooks failed: ' .. tostring(pause_err)) end
if menu_ok and bot.active and bot.cfg.press_competitive_after then
	local ok, err = pcall(competitive.install_test_press, competitive, bot.cfg.press_competitive_after, socket.gettime)
	if not ok then log('competitive: test press install failed: ' .. tostring(err)) end
end
if config.autoconnect or (bot.active and bot.step ~= 'idle') then client:connect() end

-- per frame -----------------------------------------------------------------------
-- always_draw callbacks run on the game's script thread every frame (unless a
-- frame is skipped), with the Lua state locked, so touching game state is safe.

-- First arrival in the competitive hub: connect and open the Race Board.
local competitive_arrived = false
local function competitive_arrival()
	if competitive_arrived or not game:competitive_active() or not game:in_hub() then return end
	competitive_arrived = true
	log('competitive: in the hub; opening the race board')
	board:open_soon(1.5)
	if client.state.conn == 'disconnected' and not client.want_connected then client:connect() end
end

local function frame()
	-- show_ui = "lobby": like a player, keep the lobby window open until the race
	-- starts, then close the overlay so only the in-run HUD shows.
	if bot.active and bot.cfg.show_ui then
		local want_open = ui.visible and not (bot.cfg.show_ui == 'lobby' and client:racing())
		if want_open ~= rom.gui.is_open() then rom.gui.toggle() end
	end
	if rom.ImGui.IsKeyPressed(rom.ImGuiKey.F8, false) then
		ui:toggle()
		-- Text boxes only get keyboard focus while the H2M overlay is open.
		if ui.visible and not rom.gui.is_open() then rom.gui.toggle() end
	end
	competitive_arrival()
	client:update()
	game:update()
	shadow:update()
	hud:update()
	board:update(game:competitive_active() and game:in_hub())
	banner:update()
	bot:update()
	-- Competitive mode is all native UI; the ImGui HUD is for races from your own save.
	if not hud:active() and not game:competitive_active() then ui:draw_hud() end
end

local function guarded(fn)
	local failures = 0
	return function()
		local ok, err = xpcall(fn, debug.traceback)
		if not ok then
			failures = failures + 1
			if failures <= 20 then log('frame error: ' .. tostring(err)) end
		end
	end
end

rom.gui.add_always_draw_imgui(guarded(frame))
rom.gui.add_imgui(guarded(function() ui:draw_window() end))
rom.gui.add_to_menu_bar(function()
	if rom.ImGui.MenuItem('Ranked Race (F8)') then ui:toggle() end
end)

log('loaded; bot=' .. tostring(bot.active))
