-- Competitive mode entry point on the title screen.
--
-- The main menu is engine C++ (MainMenuScreen); its buttons are SJSON
-- components bound to C++ callbacks by name. The build ships a hidden
-- "AnnouncementButton" whose only callback is MainMenuScreen::OpenPatchNotes
-- (rva 0x16cda0 on build 25481925, no other callers). We:
--   1. rewrite MainMenuScreen.sjson so that button shows under PLAY as
--      "Play Competitive Speedrun" (ShellText gets the new string), and
--   2. hook OpenPatchNotes natively (found by a unique byte signature) so the
--      press starts competitive mode instead of opening patch notes.
-- If the signature isn't found (different game build) nothing is changed.

local Competitive = {}
Competitive.__index = Competitive

-- First 32 bytes of sgg::MainMenuScreen::OpenPatchNotes (unique in .text).
local OPEN_PATCH_NOTES_SIG = '48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55 41 56 41 57 48 8D 6C 24 B0 48 81 EC 50 01 00 00'
-- First 32 bytes of sgg::MainMenuScreen::Update(float, const vector<InputHandler*>&) (unique).
local MAIN_MENU_UPDATE_SIG = '48 89 5C 24 18 48 89 74 24 20 55 57 41 54 41 56 41 57 48 8B EC 48 83 EC 60 0F 29 74 24 50 4D 8B'
-- First 32 bytes of sgg::MenuScreen::ExitScreen() (unique): closes a menu screen.
local MENU_EXIT_SCREEN_SIG = '40 53 48 83 EC 50 48 8B D9 33 C0 0F 57 C9 F3 0F 7F 4C 24 20 48 89 44 24 30 0F 10 89 10 02 00 00'
local TEXT_ID = 'MainMenuScreen_CompetitiveSpeedrun'
local LABEL = 'Play Competitive Speedrun'

function Competitive.new(deps)
	local c = setmetatable({}, Competitive)
	c.rom, c.log = deps.rom, deps.log
	c.on_start = deps.on_start -- called (in the menu hook) when the button is pressed
	c.menu_ready = false
	return c
end

-- MainMenuScreen.sjson: show AnnouncementButton under PLAY with our label and
-- push Options/Quit down one row.
local function patch_main_menu(text)
	local ann_start, ann_end = text:find('AnnouncementButton%s*=%s*%b{}')
	local settings_attach = text:find('SettingsButton%s*=%s*{')
	if not ann_start or not settings_attach then return nil end
	local button = table.concat({
		'AnnouncementButton =',
		'    {',
		'      InheritFrom = "PlayGameButton"',
		'      AttachTo = "PlayGameButton"',
		'      OffsetY = 85',
		'      HelpTextId = "' .. TEXT_ID .. '"',
		'      FontSize = 34',
		'      FadeDelayMin = 1.6',
		'      FadeDelayMax = 1.61',
		'      TextJustification = "Center"',
		'    }',
	}, '\n')
	text = text:sub(1, ann_start - 1) .. button .. text:sub(ann_end + 1)
	-- Settings sits under PlayGameButton at +85; push it one row further down.
	-- (It can't attach to our button: components are created in a fixed order
	-- and AnnouncementButton is created after SettingsButton.)
	local s_start, s_end = text:find('SettingsButton%s*=%s*%b{}')
	local block = text:sub(s_start, s_end)
	local moved, n = block:gsub('OffsetY%s*=%s*85', 'OffsetY = 170', 1)
	if n ~= 1 then return nil end
	return text:sub(1, s_start - 1) .. moved .. text:sub(s_end + 1)
end

-- ShellText.<lang>.sjson: add our string next to "Play".
local function patch_shell_text(text)
	if text:find(TEXT_ID, 1, true) then return nil end
	local entry = '{\n      Id = "' .. TEXT_ID .. '"\n      DisplayName = "' .. LABEL .. '"\n    }\n    '
	local at = text:find('{%s*Id%s*=%s*"MainMenuScreen_PlayGame"')
	if not at then return nil end
	return text:sub(1, at - 1) .. entry .. text:sub(at)
end

-- ScreenText.<lang>.sjson: in-world prompts (the Race Board's "{I} Race").
local SCREEN_TEXTS = { { 'RankedRace_UseBoard', '{I} Race' } }
local function patch_screen_text(text)
	if text:find(SCREEN_TEXTS[1][1], 1, true) then return nil end
	local _, open_end = text:find('Texts%s*=%s*%[')
	if not open_end then return nil end
	local entries = {}
	for _, t in ipairs(SCREEN_TEXTS) do
		entries[#entries + 1] = '\n    {\n      Id = "' .. t[1] .. '"\n      DisplayName = "' .. t[2] .. '"\n    }'
	end
	return text:sub(1, open_end) .. table.concat(entries) .. text:sub(open_end + 1)
end

function Competitive:install_sjson()
	local data = self.rom.data
	if not (data and data.on_sjson_read_as_string) then
		self.log('competitive: rom.data.on_sjson_read_as_string missing; no menu entry')
		return false
	end
	local log = self.log
	data.on_sjson_read_as_string(function(path, text)
		local p = tostring(path):gsub('\\', '/')
		if p:find('GUI/MainMenuScreen%.sjson$') then
			local out = patch_main_menu(text)
			log('competitive: main menu sjson ' .. (out and 'patched' or 'NOT patched (layout changed?)'))
			return out
		elseif p:find('ShellText%.[%w_%-]+%.sjson$') then
			return patch_shell_text(text)
		elseif p:find('/ScreenText%.[%w_%-]+%.sjson$') then
			return patch_screen_text(text)
		end
	end)
	return true
end

-- rom.memory finds the calling mod through the caller's _ENV upvalue, which a
-- Lua 5.2 function only has if it touches a global; reference it explicitly.
function Competitive:install_hook()
	local _ = _ENV
	local mem = self.rom.memory
	if not (mem and mem.scan_pattern and mem.dynamic_hook) then
		self.log('competitive: rom.memory hooks unavailable; no menu entry')
		return false
	end
	local ptr = mem.scan_pattern(OPEN_PATCH_NOTES_SIG)
	if not ptr or ptr:is_null() then
		self.log('competitive: MainMenuScreen::OpenPatchNotes signature not found (different game build); no menu entry')
		return false
	end
	self.open_patch_notes_ptr = ptr
	-- Closing the title screen once the hub load is queued (otherwise the menu
	-- stays on top of the world and keeps eating input).
	local exit_ptr = mem.scan_pattern(MENU_EXIT_SCREEN_SIG)
	local exit_screen
	if exit_ptr and not exit_ptr:is_null() then
		exit_screen = self.rom.game[mem.dynamic_call('void', { 'uint64_t' }, exit_ptr)]
	else
		self.log('competitive: MenuScreen::ExitScreen signature not found; menu will stay open')
	end
	local this = self
	mem.dynamic_hook('RankedRace_OpenPatchNotes', 'void', { 'uint64_t' }, ptr, {
		function(_, menu)
			this.log('competitive: menu button pressed')
			local ok, err = pcall(this.on_start)
			if not ok then
				this.log('competitive: start failed: ' .. tostring(err))
			elseif exit_screen then
				exit_screen(menu:get())
			end
			return false -- never open patch notes
		end,
		nil,
	})
	self.log('competitive: hooked OpenPatchNotes at ' .. tostring(ptr:get_address()))
	return true
end

function Competitive:install()
	-- Text and layout changes only make sense if the press can be handled.
	if self:install_hook() then
		self.menu_ready = self:install_sjson()
	end
	return self.menu_ready
end

-- Test bot only: no Lua runs on the title screen and synthetic input doesn't
-- reach the window under gamescope, so the bot presses the entry from a
-- MainMenuScreen::Update hook by calling the button's callback target,
-- OpenPatchNotes(this) -- which goes through the hook above like a real click.
function Competitive:install_test_press(after_seconds, now)
	local _ = _ENV
	local mem = self.rom.memory
	if not self.open_patch_notes_ptr then return false end
	local upd = mem.scan_pattern(MAIN_MENU_UPDATE_SIG)
	if not upd or upd:is_null() then
		self.log('competitive: MainMenuScreen::Update signature not found; no test press')
		return false
	end
	local call_name = mem.dynamic_call('void', { 'uint64_t' }, self.open_patch_notes_ptr)
	local call = self.rom.game[call_name]
	local first, done, log = nil, false, self.log
	mem.dynamic_hook('RankedRace_MainMenuUpdate', 'void', { 'uint64_t', 'float', 'uint64_t' }, upd, {
		function(_, this_screen)
			if done then return true end
			first = first or now()
			if now() - first >= after_seconds then
				done = true
				log('competitive: test bot pressing the menu entry')
				call(this_screen:get())
			end
			return true
		end,
		nil,
	})
	return true
end

Competitive.patch_main_menu = patch_main_menu
Competitive.patch_shell_text = patch_shell_text
Competitive.patch_screen_text = patch_screen_text

return Competitive
