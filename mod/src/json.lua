-- Minimal JSON encode/decode for the wire protocol. Pure Lua, 5.1 through 5.5.
-- JSON null decodes to nil. Empty tables encode as {} (objects).

local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode_string(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format('\\u%04x', c:byte())
	end) .. '"'
end

local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then return false end
		if k > n then n = k end
	end
	if n == 0 then return false end
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true, n
end

local encode_value

local function encode_table(t, seen)
	if seen[t] then error('json: cycle in table') end
	seen[t] = true
	local out = {}
	local arr, n = is_array(t)
	if arr then
		for i = 1, n do out[i] = encode_value(t[i], seen) end
		seen[t] = nil
		return '[' .. table.concat(out, ',') .. ']'
	end
	local keys = {}
	for k in pairs(t) do
		if type(k) ~= 'string' then error('json: object key must be a string, got ' .. type(k)) end
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for i, k in ipairs(keys) do
		out[i] = encode_string(k) .. ':' .. encode_value(t[k], seen)
	end
	seen[t] = nil
	return '{' .. table.concat(out, ',') .. '}'
end

encode_value = function(v, seen)
	local tv = type(v)
	if tv == 'nil' then return 'null' end
	if tv == 'boolean' then return v and 'true' or 'false' end
	if tv == 'number' then
		if v ~= v or v == math.huge or v == -math.huge then error('json: cannot encode ' .. tostring(v)) end
		if math.floor(v) == v and math.abs(v) < 2 ^ 53 then return string.format('%d', v) end
		return string.format('%.17g', v)
	end
	if tv == 'string' then return encode_string(v) end
	if tv == 'table' then return encode_table(v, seen) end
	error('json: cannot encode type ' .. tv)
end

function json.encode(v)
	return encode_value(v, {})
end

-- decoding ------------------------------------------------------------------

local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decode_error(str, i, msg)
	error(string.format('json: %s at position %d near %q', msg, i, str:sub(i, i + 10)), 0)
end

local function skip_ws(str, i)
	local _, e = str:find('^[ \t\r\n]*', i)
	return e + 1
end

local decode_value

local function decode_string(str, i)
	-- i points at the opening quote
	local out = {}
	local j = i + 1
	while true do
		local c = str:sub(j, j)
		if c == '' then decode_error(str, i, 'unterminated string') end
		if c == '"' then return table.concat(out), j + 1 end
		if c == '\\' then
			local e = str:sub(j + 1, j + 1)
			local simple = ({ ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[e]
			if simple then
				out[#out + 1] = simple
				j = j + 2
			elseif e == 'u' then
				local hex = str:sub(j + 2, j + 5)
				if not hex:find('^%x%x%x%x$') then decode_error(str, j, 'bad unicode escape') end
				local cp = tonumber(hex, 16)
				j = j + 6
				if cp >= 0xD800 and cp <= 0xDBFF and str:sub(j, j + 1) == '\\u' then
					local lo = tonumber(str:sub(j + 2, j + 5), 16)
					if lo and lo >= 0xDC00 and lo <= 0xDFFF then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
						j = j + 6
					end
				end
				out[#out + 1] = utf8_char(cp)
			else
				decode_error(str, j, 'bad escape')
			end
		else
			local s, e = str:find('^[^"\\]+', j)
			out[#out + 1] = str:sub(s, e)
			j = e + 1
		end
	end
end

local function decode_number(str, i)
	local s, e = str:find('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
	if not s then decode_error(str, i, 'bad number') end
	local n = tonumber(str:sub(s, e))
	if n == nil then decode_error(str, i, 'bad number') end
	return n, e + 1
end

local function decode_array(str, i)
	local arr, n = {}, 0
	i = skip_ws(str, i + 1)
	if str:sub(i, i) == ']' then return arr, i + 1 end
	while true do
		local v
		v, i = decode_value(str, i)
		n = n + 1
		arr[n] = v
		i = skip_ws(str, i)
		local c = str:sub(i, i)
		if c == ']' then return arr, i + 1 end
		if c ~= ',' then decode_error(str, i, "expected ',' or ']'") end
		i = skip_ws(str, i + 1)
	end
end

local function decode_object(str, i)
	local obj = {}
	i = skip_ws(str, i + 1)
	if str:sub(i, i) == '}' then return obj, i + 1 end
	while true do
		if str:sub(i, i) ~= '"' then decode_error(str, i, 'expected string key') end
		local k
		k, i = decode_string(str, i)
		i = skip_ws(str, i)
		if str:sub(i, i) ~= ':' then decode_error(str, i, "expected ':'") end
		local v
		v, i = decode_value(str, skip_ws(str, i + 1))
		obj[k] = v
		i = skip_ws(str, i)
		local c = str:sub(i, i)
		if c == '}' then return obj, i + 1 end
		if c ~= ',' then decode_error(str, i, "expected ',' or '}'") end
		i = skip_ws(str, i + 1)
	end
end

decode_value = function(str, i)
	i = skip_ws(str, i)
	local c = str:sub(i, i)
	if c == '{' then return decode_object(str, i) end
	if c == '[' then return decode_array(str, i) end
	if c == '"' then return decode_string(str, i) end
	if c == '-' or c:find('%d') then return decode_number(str, i) end
	if str:sub(i, i + 3) == 'true' then return true, i + 4 end
	if str:sub(i, i + 4) == 'false' then return false, i + 5 end
	if str:sub(i, i + 3) == 'null' then return nil, i + 4 end
	decode_error(str, i, 'unexpected character')
end

function json.decode(str)
	if type(str) ~= 'string' then error('json: expected string, got ' .. type(str)) end
	local v, i = decode_value(str, 1)
	i = skip_ws(str, i)
	if i <= #str then decode_error(str, i, 'trailing garbage') end
	return v
end

return json
