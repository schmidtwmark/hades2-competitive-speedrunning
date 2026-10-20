-- Non-blocking TCP transport over LuaSocket (`require('socket')` in Hell2Modding).
-- Implements the transport interface client.lua expects. Never blocks: every
-- socket call uses timeout 0 and is polled once per frame.
--
-- Hostname lookups do block, so connect() resolves the host once per attempt
-- (localhost and IP literals resolve instantly).

local Net = {}

local CONNECT_TIMEOUT = 5.0
local MAX_BUFFER = 64 * 1024

function Net.new(socket, log)
	log = log or function() end
	local t = {}
	local sock, status, inbuf, outbuf, started = nil, 'closed', '', '', 0

	local function shutdown(reason)
		if sock then sock:close() end
		sock = nil
		if status ~= 'closed' then log('net: closed (' .. tostring(reason) .. ')') end
		status = 'closed'
		inbuf, outbuf = '', ''
	end

	function t.connect(host, port)
		shutdown('reconnect')
		local addr = host
		if not host:find('^%d+%.%d+%.%d+%.%d+$') then
			local ip = socket.dns.toip(host)
			if not ip then return false, 'cannot resolve ' .. host end
			addr = ip
		end
		local s, err = socket.tcp()
		if not s then return false, err end
		s:settimeout(0)
		s:setoption('tcp-nodelay', true)
		local ok, cerr = s:connect(addr, port)
		sock, started = s, socket.gettime()
		if ok then
			status = 'connected'
		elseif cerr == 'timeout' or cerr == 'Operation already in progress' then
			status = 'connecting'
		else
			sock = nil
			s:close()
			return false, cerr
		end
		return true
	end

	local function flush()
		while #outbuf > 0 do
			local sent, err, last = sock:send(outbuf)
			local n = sent or last or 0
			if n > 0 then outbuf = outbuf:sub(n + 1) end
			if not sent then
				if err ~= 'timeout' then shutdown('send: ' .. tostring(err)) end
				return
			end
		end
	end

	function t.send(line)
		if status ~= 'connected' then return false, 'not connected' end
		if #outbuf > MAX_BUFFER then return false, 'send buffer full' end
		outbuf = outbuf .. line .. '\n'
		flush()
		return status == 'connected'
	end

	local function check_connected()
		local _, writable = socket.select(nil, { sock }, 0)
		if writable and #writable > 0 then
			if sock:getpeername() then
				status = 'connected'
				log('net: connected')
			else
				shutdown('connect refused')
			end
		elseif socket.gettime() - started > CONNECT_TIMEOUT then
			shutdown('connect timeout')
		end
	end

	function t.poll()
		local lines = {}
		if status == 'connecting' then check_connected() end
		if status ~= 'connected' then return lines, status end
		if #outbuf > 0 then flush() end
		if status ~= 'connected' then return lines, status end
		local data, err, partial = sock:receive('*a')
		local chunk = data or partial
		if chunk and #chunk > 0 then inbuf = inbuf .. chunk end
		-- '*a' returns the data with no error when the peer closed the connection.
		local closed = (data ~= nil) or (err ~= nil and err ~= 'timeout')
		while true do
			local nl = inbuf:find('\n', 1, true)
			if not nl then break end
			local line = inbuf:sub(1, nl - 1):gsub('\r$', '')
			inbuf = inbuf:sub(nl + 1)
			if #line > 0 then lines[#lines + 1] = line end
		end
		if #inbuf > MAX_BUFFER then closed, err = true, 'line too long' end
		if closed then shutdown(err or 'peer closed') end
		return lines, status
	end

	function t.close()
		shutdown('local close')
	end

	function t.now()
		return socket.gettime()
	end

	return t
end

return Net
