-- Tiny test framework for running mod modules outside the game.
local T = { cases = {}, src = 'src/' }

function T.load(file, env)
	local path = T.src .. file
	local chunk, err
	if env then
		chunk, err = loadfile(path, 't', env)
	else
		chunk, err = loadfile(path)
	end
	assert(chunk, err)
	return chunk()
end

function T.case(name, fn)
	T.cases[#T.cases + 1] = { name = name, fn = fn, file = T.current_file }
end

function T.eq(a, b, msg)
	if a ~= b then
		error(string.format('%sexpected %s, got %s', msg and (msg .. ': ') or '', tostring(b), tostring(a)), 2)
	end
end

function T.truthy(v, msg)
	if not v then error((msg or 'expected truthy') .. ', got ' .. tostring(v), 2) end
end

function T.raises(fn, pattern)
	local ok, err = pcall(fn)
	if ok then error('expected an error', 2) end
	if pattern and not tostring(err):find(pattern) then
		error('error ' .. tostring(err) .. ' does not match ' .. pattern, 2)
	end
end

function T.run(files)
	for _, f in ipairs(files) do
		T.current_file = f
		dofile(f)
	end
	local pass, fail = 0, 0
	for _, c in ipairs(T.cases) do
		local ok, err = xpcall(c.fn, debug.traceback)
		if ok then
			pass = pass + 1
			print('  ok   ' .. c.file .. ': ' .. c.name)
		else
			fail = fail + 1
			print('  FAIL ' .. c.file .. ': ' .. c.name .. '\n' .. tostring(err))
		end
	end
	print(string.format('lua tests: %d passed, %d failed', pass, fail))
	return fail == 0 and pass > 0
end

return T
