local T = require('test.lib')
local json = T.load('json.lua')

T.case('round trips scalars, arrays and nested objects', function()
	local v = { type = 'x', n = 3, f = 1.5, neg = -2, b = true, arr = { 1, 'two', { k = false } }, s = 'a"b\\c\n' }
	local back = json.decode(json.encode(v))
	T.eq(back.type, 'x'); T.eq(back.n, 3); T.eq(back.f, 1.5); T.eq(back.neg, -2); T.eq(back.b, true)
	T.eq(back.arr[2], 'two'); T.eq(back.arr[3].k, false); T.eq(back.s, 'a"b\\c\n')
end)

T.case('encodes integers without exponent and sorts keys', function()
	T.eq(json.encode({ b = 1, a = 2147483646 }), '{"a":2147483646,"b":1}')
	T.eq(json.encode(12.0), '12')
end)

T.case('escapes control characters', function()
	T.eq(json.encode('\1'), '"\\u0001"')
end)

T.case('decodes null as nil, unicode escapes and surrogate pairs', function()
	local v = json.decode('{"a":null,"b":"\\u00e9\\ud83d\\ude00","c":[1,2]}')
	T.eq(v.a, nil)
	T.eq(v.b, '\195\169\240\159\152\128')
	T.eq(#v.c, 2)
end)

T.case('decodes numbers with exponents and whitespace', function()
	local v = json.decode(' { "x" : -1.25e2 , "y":[ ] } ')
	T.eq(v.x, -125)
	T.eq(next(v.y), nil)
end)

T.case('rejects garbage', function()
	T.raises(function() json.decode('{"a":1') end)
	T.raises(function() json.decode('{"a":1} x') end)
	T.raises(function() json.decode('{a:1}') end)
	T.raises(function() json.encode({ [true] = 1 }) end)
	T.raises(function() json.encode(0 / 0) end)
end)

T.case('matches what Node JSON.stringify produces for server messages', function()
	local m = json.decode('{"type":"race_start","race_id":1,"seed":123457,"weapon":"WeaponAxe","keepsake":"","countdown":3,"countdown_ms":3000}')
	T.eq(m.seed, 123457); T.eq(m.keepsake, ''); T.eq(m.countdown_ms, 3000)
end)
