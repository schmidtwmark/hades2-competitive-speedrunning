-- Hell2Modding entry point for Ranked Race.
-- Loaded once per game launch (and again on hot reload) inside this plugin's
-- private environment. Game globals (CurrentRun, ...) live on rom.game.

local guid = _PLUGIN.guid
local plugin_dir = _PLUGIN.plugins_mod_folder_path
local data_dir = _PLUGIN.plugins_data_mod_folder_path
local env = _ENV

local VERSION = '0.1.0'

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

local config_path = _PLUGIN.config_mod_folder_path .. '/config.json'
local config = { server_host = '127.0.0.1', server_port = 7777, player_name = 'Melinoe', hud_x = 20, hud_y = 80, autoconnect = false }
do
	local f = io.open(config_path, 'r')
	if f then
		local ok, saved = pcall(json.decode, f:read('*a'))
		f:close()
		if ok and type(saved) == 'table' then
			for k, v in pairs(saved) do config[k] = v end
		end
	end
end
local function save_config()
	local f = io.open(config_path, 'w')
	if f then
		f:write(json.encode(config))
		f:close()
	end
end
save_config()

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

local ui = UI.new({
	ImGui = rom.ImGui, ImGuiCond = rom.ImGuiCond, ImGuiWindowFlags = rom.ImGuiWindowFlags,
	client = client, config = config, log = log,
	names = function(id) return game:display_name(id) end,
	status = function() return game:status_line() end,
	on_connect = function(host, port, name)
		config.server_host, config.server_port, config.player_name = host, port, name
		save_config()
	end,
})

local bot = Bot.new({ dir = data_dir, json = json, client = client, game = game, log = log, now = socket.gettime })

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
if menu_ok and bot.active and bot.cfg.press_competitive_after then
	local ok, err = pcall(competitive.install_test_press, competitive, bot.cfg.press_competitive_after, socket.gettime)
	if not ok then log('competitive: test press install failed: ' .. tostring(err)) end
end
if config.autoconnect or (bot.active and bot.step ~= 'idle') then client:connect() end

-- per frame -----------------------------------------------------------------------
-- always_draw callbacks run on the game's script thread every frame (unless a
-- frame is skipped), with the Lua state locked, so touching game state is safe.

local function frame()
	if ui.visible and bot.active and bot.cfg.show_ui and not rom.gui.is_open() then rom.gui.toggle() end
	if rom.ImGui.IsKeyPressed(rom.ImGuiKey.F8, false) then
		ui:toggle()
		-- Text boxes only get keyboard focus while the H2M overlay is open.
		if ui.visible and not rom.gui.is_open() then rom.gui.toggle() end
	end
	client:update()
	game:update()
	bot:update()
	ui:draw_hud()
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
