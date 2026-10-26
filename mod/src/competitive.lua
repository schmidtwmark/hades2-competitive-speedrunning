-- Competitive mode entry point on the title screen.
--
-- The main menu is engine C++ (MainMenuScreen); its buttons are SJSON
-- components bound to C++ callbacks by name. The build ships a hidden
-- "AnnouncementButton" whose only callback is MainMenuScreen::OpenPatchNotes
-- (rva 0x16cda0 on build 25481925, no other callers). We:
--   1. rewrite MainMenuScreen.sjson so that button shows under PLAY as
--      "Play Competitive Speedrun (Beta)" (ShellText gets the new string), and
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
-- Native saving that bypasses the game's Lua save gate: the pause menu's Undo
-- Night and Quit (and a few script actions) call these C++ functions directly,
-- so IllegalConversationModification and the RequestSave hook don't stop them.
-- Callers ignore the SaveResult. Relative operands are wildcarded.
local SAVE_PROFILE_SIG = '48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 48 8B 1D ?? ?? ?? ?? 4C 8D 0D ?? ?? ?? ?? 41 0F B6 F0 0F B6 FA 48 8B E9'
local SAVE_CHECKPOINT_SIG = '48 89 5C 24 18 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 D0 FD FF FF 48 81 EC 30 03 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4'
-- sgg::PauseScreen: the "Undo Night" and "Quit" buttons' targets, and Resume
-- (what Continue calls). Resume shares its prologue with another function, so
-- its signature keeps the string offset (this build only; without it the
-- pause menu just stays open until the player closes it).
local PAUSE_GIVE_UP_SIG = '48 8B C4 48 89 58 10 48 89 70 18 48 89 78 20 55 41 54 41 55 41 56 41 57 48 8D 68 A1 48 81 EC C0 00 00 00 0F 29 70 C8 4C'
local PAUSE_QUIT_SIG = '48 89 5C 24 10 48 89 74 24 18 48 89 7C 24 20 55 41 54 41 55 41 56 41 57 48 8D 6C 24 C9 48 81 EC 90 00 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 45 27 4C 8B E9 E8 ?? ??'
local PAUSE_RESUME_SIG = '48 89 5C 24 10 48 89 6C 24 18 48 89 74 24 20 57 48 83 EC 40 48 8B F9 C6 44 24 20 00 C6 44 24 37 17 48 8D 2D B8 E3 35 00'
-- The title music's sound id, sgg::MainMenuScreen::mMusicId (static): the
-- menu's constructor stores it right after starting the music
-- (mov r9d,-1; lea rdx,[rbp-49]; lea rcx,[rbp-29]; call; mov [rip+disp],eax).
-- Loading a save stops that music; the competitive entry has to stop it.
local MENU_MUSIC_STORE_SIG = '41 B9 FF FF FF FF 48 8D 55 B7 48 8D 4D D7 E8 ?? ?? ?? ?? 89 05 ?? ?? ?? ??'
local TEXT_ID = 'MainMenuScreen_CompetitiveSpeedrun'
local LABEL = 'Play Competitive Speedrun (Beta)'
local FORFEIT_LABEL = 'Race Menu'
local FORFEIT_HINT = 'end your run? your rival still has to finish to win'

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

-- ShellText.<lang>.sjson: add our string next to "Play", and relabel the
-- pause menu's "Undo Night" (it forfeits during a race; see install_pause_hooks).
local function patch_shell_text(text)
	if text:find(TEXT_ID, 1, true) then return nil end
	local entry = '{\n      Id = "' .. TEXT_ID .. '"\n      DisplayName = "' .. LABEL .. '"\n    }\n    '
	local at = text:find('{%s*Id%s*=%s*"MainMenuScreen_PlayGame"')
	if not at then return nil end
	text = text:sub(1, at - 1) .. entry .. text:sub(at)
	text = text:gsub('(Id%s*=%s*"PauseScreen_Abandon"%s*DisplayName%s*=%s*")[^"]*(")', '%1' .. FORFEIT_LABEL .. '%2', 1)
	-- ...and its hint line under the menu (lower case, like the game's own).
	text = text:gsub('(Id%s*=%s*"PauseScreen_GiveUp_ValidCheckpoint"%s*DisplayName%s*=%s*")[^"]*(")', '%1' .. FORFEIT_HINT .. '%2', 1)
	return text
end

-- ScreenText.<lang>.sjson: in-world prompts (the Race Board's "{I} Race").
local SCREEN_TEXTS = { { 'RankedRace_UseBoard', '{I} Race' }, { 'RankedRace_ReadyDoor', '{I} Ready to Race' } }
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

-- In competitive mode the in-memory profile must never reach the disk: skip
-- the native save calls while active() is true.
function Competitive:install_save_guard(active)
	local _ = _ENV
	local mem = self.rom.memory
	if not (mem and mem.scan_pattern and mem.dynamic_hook) then return false end
	local log, guarded = self.log, 0
	for _, h in ipairs({
		{ 'RankedRace_SaveProfile', SAVE_PROFILE_SIG, { 'uint64_t', 'bool', 'bool' }, 'ProfileManager::SaveProfile' },
		{ 'RankedRace_SaveValidCheckpoint', SAVE_CHECKPOINT_SIG, { 'uint64_t', 'bool' }, 'ProgressManager::SaveValidCheckpoint' },
	}) do
		local name, sig, params, what = h[1], h[2], h[3], h[4]
		local ptr = mem.scan_pattern(sig)
		if ptr and not ptr:is_null() then
			mem.dynamic_hook(name, 'int', params, ptr, {
				function(ret)
					local ok, on = pcall(active)
					if not (ok and on) then return true end
					log('competitive: blocked native ' .. what .. ' (the competitive profile is never saved)')
					pcall(function() ret:set(0) end)
					return false
				end,
				nil,
			})
			guarded = guarded + 1
		else
			log('competitive: ' .. what .. ' signature not found; that native save is not guarded')
		end
	end
	self.log('competitive: native save guard on ' .. guarded .. '/2 functions')
	return guarded == 2
end

-- Pause menu during a race: "Undo Night" (relabelled "Race Menu": chat,
-- forfeit) and Quit open the mod's prompts instead of their normal action when
-- h.give_up() / h.quit() say so; the pause menu is closed like Continue does.
function Competitive:install_pause_hooks(h)
	local _ = _ENV
	local mem = self.rom.memory
	if not (mem and mem.scan_pattern and mem.dynamic_hook and mem.dynamic_call) then return false end
	local log, game = self.log, self.rom.game
	local resume
	local rptr = mem.scan_pattern(PAUSE_RESUME_SIG)
	if rptr and not rptr:is_null() then
		resume = game[mem.dynamic_call('void', { 'uint64_t' }, rptr)]
	else
		log('competitive: PauseScreen::Resume signature not found; the pause menu stays open after Forfeit')
	end
	local hooked = 0
	for _, b in ipairs({ { 'RankedRace_PauseGiveUp', PAUSE_GIVE_UP_SIG, 'Undo Night', h.give_up },
		{ 'RankedRace_PauseQuit', PAUSE_QUIT_SIG, 'Quit', h.quit } }) do
		local name, sig, what, take = b[1], b[2], b[3], b[4]
		local ptr = mem.scan_pattern(sig)
		if ptr and not ptr:is_null() then
			mem.dynamic_hook(name, 'void', { 'uint64_t' }, ptr, {
				function(_, screen)
					local ok, yes = pcall(take)
					if not (ok and yes) then return true end
					log('competitive: pause menu ' .. what .. ' -> race prompt')
					local rok, rerr = pcall(h.forfeit_prompt, what)
					if not rok then log('competitive: forfeit prompt failed: ' .. tostring(rerr)) end
					if resume then pcall(resume, screen:get()) end
					return false
				end,
				nil,
			})
			hooked = hooked + 1
		else
			log('competitive: PauseScreen ' .. what .. ' signature not found; not hooked')
		end
	end
	return hooked == 2
end

-- Stops the title music (fades it out). Returns true if it was found.
function Competitive:stop_menu_music(fade)
	local _ = _ENV
	local mem = self.rom.memory
	if not (mem and mem.scan_pattern) then return false end
	if self.menu_music_id_ptr == nil then
		local ptr = mem.scan_pattern(MENU_MUSIC_STORE_SIG)
		if not ptr or ptr:is_null() then
			self.menu_music_id_ptr = false
			self.log('competitive: title music id not found (different game build); the music may keep playing')
		else
			-- mov [rip+disp32], eax at +19: the target is the next instruction (+25) plus disp32.
			local disp = ptr:add(21):get_dword()
			if disp >= 2 ^ 31 then disp = disp - 2 ^ 32 end
			self.menu_music_id_ptr = ptr:add(25 + disp)
		end
	end
	if not self.menu_music_id_ptr then return false end
	local id = self.menu_music_id_ptr:get_dword()
	if not id or id == 0 then return false end
	local stop = self.rom.game.StopSound
	if stop then stop({ Id = id, Duration = fade or 1.0 }) end
	self.log('competitive: title music stopped (sound ' .. tostring(id) .. ')')
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
-- again: also press it each later time the title screen comes back (quit to menu).
function Competitive:install_test_press(after_seconds, now, again)
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
	local first, done, last, log = nil, false, nil, self.log
	mem.dynamic_hook('RankedRace_MainMenuUpdate', 'void', { 'uint64_t', 'float', 'uint64_t' }, upd, {
		function(_, this_screen)
			-- A gap in the menu's updates: it closed and has come back.
			if again and last and now() - last > 2 then first, done = nil, false end
			last = now()
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
