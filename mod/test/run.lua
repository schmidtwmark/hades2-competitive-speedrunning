-- Run from mod/:  lua test/run.lua
package.path = './?.lua;' .. package.path
local T = require('test.lib')
local files = { 'test/test_json.lua', 'test/test_client.lua', 'test/test_ui.lua', 'test/test_competitive.lua', 'test/test_board.lua', 'test/test_racelog.lua', 'test/test_rankpick.lua' }
for _, f in ipairs(arg or {}) do files[#files + 1] = f end
os.exit(T.run(files) and 0 or 1)
