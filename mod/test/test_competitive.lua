local T = require('test.lib')
local Competitive = T.load('competitive.lua')

local function read(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local s = f:read('*a')
	f:close()
	return s
end

-- Real game files are only on the dev machine (local/ is git-ignored).
local menu = read('../local/game-data/GUI/MainMenuScreen.sjson')
local shell = read('../local/game-data/ShellText.en.sjson')

T.case('main menu: announcement button becomes our entry under PLAY, Options moves down a row', function()
	if not menu then return end
	local out = assert(Competitive.patch_main_menu(menu))
	local ann = out:match('AnnouncementButton%s*=%s*(%b{})')
	T.truthy(ann:find('HelpTextId = "MainMenuScreen_CompetitiveSpeedrun"', 1, true), 'label')
	T.truthy(ann:find('AttachTo = "PlayGameButton"', 1, true), 'under play')
	T.truthy(not ann:find('Scale = 0', 1, true), 'visible')
	local settings = out:match('SettingsButton%s*=%s*(%b{})')
	T.truthy(settings:find('AttachTo = "PlayGameButton"', 1, true), 'settings still attached to play (creation order)')
	T.truthy(settings:find('OffsetY = 170', 1, true), 'settings moved down a row')
	-- Everything else untouched.
	T.eq(select(2, out:gsub('ExitButton%s*=', '')), select(2, menu:gsub('ExitButton%s*=', '')))
	T.eq(out:match('PlayGameButton%s*=%s*(%b{})'), menu:match('PlayGameButton%s*=%s*(%b{})'))
end)

T.case('shell text: adds the label once, before Play', function()
	if not shell then return end
	local out = assert(Competitive.patch_shell_text(shell))
	local a = out:find('MainMenuScreen_CompetitiveSpeedrun', 1, true)
	local b = out:find('"MainMenuScreen_PlayGame"', 1, true)
	T.truthy(a and b and a < b)
	T.truthy(out:find('DisplayName = "Play Competitive Speedrun"', 1, true))
	T.eq(Competitive.patch_shell_text(out), nil)
end)

T.case('patchers refuse unexpected layouts', function()
	T.eq(Competitive.patch_main_menu('{ Foo = {} }'), nil)
	T.eq(Competitive.patch_shell_text('{ Texts = [] }'), nil)
end)
