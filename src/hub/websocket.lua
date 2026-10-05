--[[=============================================================================
    DirectorLink UniFi Protect - WebSocket client (RFC 6455)
    Runs over a Control4 network connection with SSL (C4:CreateNetworkConnection,
    C4:NetPortOptions, C4:NetConnect), so nothing waits on Director's thread:
    Director calls ReceivedFromNetwork and OnConnectionStatusChanged, which the
    driver passes to WsReceived and WsStatus.

    The console's certificate is self-signed: NetPortOptions VERIFY_MODE "none"
    (also Director's default) accepts it. The connection only ever goes to the host
    the socket was made for.

    ws = WsNew({ name, binding, host, port, path, headers = function() return { "Name: value" } end,
                 onOpen = function(ws) end, onMessage = function(ws, text) end,
                 onClose = function(ws, reason, httpStatus) end })
    WsOpen(ws)  WsClose(ws)

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_CONNECT_TIMEOUT_MS = 15000
WS_PING_INTERVAL_MS = 30000
WS_SILENCE_LIMIT_S = 90
WS_MAX_MESSAGE = 2 * 1024 * 1024

gSockets = {} -- binding -> socket

local function Xor(a, b)
	if bit and bit.bxor then return bit.bxor(a, b) end
	local r, v = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + v end
		a, b, v = (a - x) / 2, (b - y) / 2, v * 2
	end
	return r
end

local function Mask(data, key)
	local out, k = {}, { string.byte(key, 1, 4) }
	for i = 1, #data do
		out[i] = string.char(Xor(string.byte(data, i), k[(i - 1) % 4 + 1]))
	end
	return table.concat(out)
end

local function RandomBytes(n)
	local t = {}
	for i = 1, n do t[i] = string.char(math.random(0, 255)) end
	return table.concat(t)
end

-- A client frame (always masked, as RFC 6455 requires)
function WsFrame(opcode, payload)
	payload = payload or ""
	local len = #payload
	local head
	if len <= 125 then
		head = string.char(0x80 + opcode, 0x80 + len)
	elseif len <= 65535 then
		head = string.char(0x80 + opcode, 0x80 + 126, math.floor(len / 256), len % 256)
	else
		local b = {}
		local n = len
		for i = 8, 1, -1 do
			b[i] = n % 256
			n = math.floor(n / 256)
		end
		head = string.char(0x80 + opcode, 0x80 + 127, unpack(b))
	end
	local key = RandomBytes(4)
	return head .. key .. Mask(payload, key)
end

local function Send(ws, data)
	local ok, err = pcall(function() C4:SendToNetwork(ws.binding, ws.port, data) end)
	if not ok then LogDebug("WebSocket %s: send failed: %s", ws.name, err) end
end

local function TimerName(ws, what)
	return "WS_" .. ws.name .. "_" .. what
end

local function Disconnect(ws)
	KillTimer(TimerName(ws, "CONNECT"))
	KillTimer(TimerName(ws, "PING"))
	pcall(function() C4:NetDisconnect(ws.binding, ws.port) end)
end

-- The connection ended without being asked to
local function Fail(ws, reason, httpStatus)
	if ws.state == "closed" then return end
	local was = ws.state
	ws.state = "closed"
	ws.closedAt = os.time()
	ws.lastReason = reason
	Disconnect(ws)
	LogDebug("WebSocket %s: closed (%s) after %s", ws.name, reason, was)
	if ws.onClose then
		local ok, err = pcall(ws.onClose, ws, reason, httpStatus)
		if not ok then LogError("WebSocket %s close handler failed: %s", ws.name, err) end
	end
end

function WsNew(opts)
	local ws = {
		name = opts.name, binding = opts.binding, host = opts.host, port = opts.port or 443, path = opts.path,
		headers = opts.headers, onOpen = opts.onOpen, onMessage = opts.onMessage, onClose = opts.onClose,
		state = "closed", buf = "", messages = 0, gen = 0,
	}
	gSockets[ws.binding] = ws
	return ws
end

local Connect -- forward

function WsOpen(ws)
	if ws.state ~= "closed" then
		-- Let the old connection's OFFLINE arrive before the new one starts
		ws.state = "closed"
		Disconnect(ws)
		ws.gen = ws.gen + 1
		ws.state = "reopening"
		SetTimer(TimerName(ws, "REOPEN"), 1000, function() Connect(ws) end)
		return
	end
	Connect(ws)
end

Connect = function(ws)
	if not ValidAddress(ws.host) then
		ws.state = "connecting"
		return Fail(ws, "no console address")
	end
	ws.gen = ws.gen + 1
	ws.state = "connecting"
	ws.buf, ws.fragments, ws.fragmentLen = "", nil, 0
	ws.startedMs = NowMs()
	ws.lastData = os.time()
	LogDebug("WebSocket %s: connecting to %s:%d%s", ws.name, ws.host, ws.port, ws.path)
	local ok, err = pcall(function()
		C4:CreateNetworkConnection(ws.binding, ws.host, "SSL")
		C4:NetPortOptions(ws.binding, ws.port, "SSL", {
			AUTO_CONNECT = false, MONITOR_CONNECTION = false, KEEP_CONNECTION = false, KEEP_ALIVE = true,
			VERIFY_MODE = "none", -- the console's certificate is self-signed (also Director's default)
		})
		C4:NetConnect(ws.binding, ws.port)
	end)
	if not ok then return Fail(ws, "cannot open a connection: " .. tostring(err)) end
	local gen = ws.gen
	SetTimer(TimerName(ws, "CONNECT"), WS_CONNECT_TIMEOUT_MS, function()
		if ws.gen == gen and ws.state ~= "open" and ws.state ~= "closed" then
			Fail(ws, ws.state == "connecting" and "no connection to the console (timeout)" or "no answer to the WebSocket request (timeout)")
		end
	end)
end

function WsClose(ws)
	KillTimer(TimerName(ws, "REOPEN"))
	if ws.state == "closed" then return end
	if ws.state == "open" then Send(ws, WsFrame(8, string.char(3, 232))) end -- 1000 normal closure
	ws.state = "closed"
	ws.closedAt = os.time()
	ws.lastReason = "closed by the driver"
	Disconnect(ws)
	LogDebug("WebSocket %s: closed by the driver", ws.name)
end

local function SendHandshake(ws)
	ws.key = Base64Encode(RandomBytes(16))
	local lines = {
		"GET " .. ws.path .. " HTTP/1.1",
		"Host: " .. HostPort(ws.host, ws.port, 443),
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Key: " .. ws.key,
		"Sec-WebSocket-Version: 13",
		"User-Agent: " .. UserAgent(),
	}
	if ws.headers then
		for _, h in ipairs(ws.headers() or {}) do lines[#lines + 1] = h end
	end
	ws.state = "handshake"
	Send(ws, table.concat(lines, "\r\n") .. "\r\n\r\n")
end

-- Director: OnConnectionStatusChanged(binding, port, "ONLINE" / "OFFLINE")
function WsStatus(binding, status)
	local ws = gSockets[binding]
	if not ws then return false end
	status = string.upper(tostring(status or ""))
	if status == "ONLINE" then
		if ws.state == "connecting" then
			LogDebug("WebSocket %s: TLS connection up (%d ms), sending the upgrade request", ws.name, NowMs() - ws.startedMs)
			SendHandshake(ws)
		end
	elseif status == "OFFLINE" then
		if ws.state == "connecting" or ws.state == "handshake" or ws.state == "open" then
			Fail(ws, ws.state == "connecting" and "the console refused the connection" or "the connection dropped")
		end
	end
	return true
end

local function ExpectedAccept(key)
	local ok, res = pcall(function() return C4:Hash("SHA1", key .. WS_GUID, { return_encoding = "BASE64", data_encoding = "NONE" }) end)
	return ok and type(res) == "string" and res ~= "" and res or nil
end

local function ParseHandshake(ws)
	local e = string.find(ws.buf, "\r\n\r\n", 1, true)
	if not e then
		if #ws.buf > 16384 then Fail(ws, "the answer to the WebSocket request is too long") end
		return false
	end
	local head = string.sub(ws.buf, 1, e - 1)
	ws.buf = string.sub(ws.buf, e + 4)
	local status = tonumber(string.match(head, "^HTTP/%d%.%d%s+(%d+)") or "")
	local headers = {}
	for k, v in string.gmatch(head, "\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do headers[string.lower(k)] = trim(v) end
	if status ~= 101 then
		Fail(ws, "the console answered HTTP " .. tostring(status or "?"), status)
		return false
	end
	if string.lower(headers["upgrade"] or "") ~= "websocket" then
		Fail(ws, "the console did not switch to WebSocket")
		return false
	end
	local want = ExpectedAccept(ws.key)
	if want and headers["sec-websocket-accept"] ~= want then
		Fail(ws, "the console's WebSocket answer has a wrong Sec-WebSocket-Accept")
		return false
	end
	KillTimer(TimerName(ws, "CONNECT"))
	ws.state = "open"
	ws.openedAt = os.time()
	ws.lastReason = nil
	LogDebug("WebSocket %s: open (%d ms)", ws.name, NowMs() - ws.startedMs)
	SetTimer(TimerName(ws, "PING"), WS_PING_INTERVAL_MS, function()
		if ws.state ~= "open" then return end
		if os.time() - ws.lastData > WS_SILENCE_LIMIT_S then
			return Fail(ws, "no data from the console for " .. WS_SILENCE_LIMIT_S .. " s")
		end
		Send(ws, WsFrame(9, "dl"))
	end, true)
	if ws.onOpen then
		local ok, err = pcall(ws.onOpen, ws)
		if not ok then LogError("WebSocket %s open handler failed: %s", ws.name, err) end
	end
	return true
end

local function Deliver(ws, text)
	ws.messages = ws.messages + 1
	ws.lastMessageAt = os.time()
	LogTrace("WebSocket %s: message %d bytes: %s", ws.name, #text, string.sub(text, 1, 600))
	if ws.onMessage then
		local ok, err = pcall(ws.onMessage, ws, text)
		if not ok then LogError("WebSocket %s message handler failed: %s", ws.name, err) end
	end
end

-- One frame from ws.buf, or false when it is not complete yet
local function ParseFrame(ws)
	local buf = ws.buf
	if #buf < 2 then return false end
	local b1, b2 = string.byte(buf, 1, 2)
	local fin = b1 >= 128
	local opcode = b1 % 16
	local masked = b2 >= 128
	local len = b2 % 128
	local pos = 3
	if len == 126 then
		if #buf < 4 then return false end
		local h, l = string.byte(buf, 3, 4)
		len = h * 256 + l
		pos = 5
	elseif len == 127 then
		if #buf < 10 then return false end
		len = 0
		for i = 3, 10 do len = len * 256 + string.byte(buf, i) end
		pos = 11
	end
	if len > WS_MAX_MESSAGE then
		Fail(ws, "a message from the console is too large (" .. len .. " bytes)")
		return false
	end
	local key
	if masked then
		if #buf < pos + 3 then return false end
		key = string.sub(buf, pos, pos + 3)
		pos = pos + 4
	end
	if #buf < pos + len - 1 then return false end
	local payload = string.sub(buf, pos, pos + len - 1)
	ws.buf = string.sub(buf, pos + len)
	if key then payload = Mask(payload, key) end

	if opcode == 1 or opcode == 2 then
		if fin then
			Deliver(ws, payload)
		else
			ws.fragments, ws.fragmentLen = { payload }, #payload
		end
	elseif opcode == 0 then
		if not ws.fragments then
			Fail(ws, "the console sent a continuation frame out of order")
			return false
		end
		ws.fragments[#ws.fragments + 1] = payload
		ws.fragmentLen = ws.fragmentLen + #payload
		if ws.fragmentLen > WS_MAX_MESSAGE then
			Fail(ws, "a message from the console is too large")
			return false
		end
		if fin then
			local text = table.concat(ws.fragments)
			ws.fragments, ws.fragmentLen = nil, 0
			Deliver(ws, text)
		end
	elseif opcode == 8 then
		local code = #payload >= 2 and (string.byte(payload, 1) * 256 + string.byte(payload, 2)) or nil
		Send(ws, WsFrame(8, string.sub(payload, 1, 2)))
		Fail(ws, "closed by the console" .. (code and (" (code " .. code .. ")") or ""))
		return false
	elseif opcode == 9 then
		Send(ws, WsFrame(10, payload))
	elseif opcode == 10 then
		ws.lastPong = os.time()
	end
	return true
end

-- Director: ReceivedFromNetwork(binding, port, data)
function WsReceived(binding, data)
	local ws = gSockets[binding]
	if not ws then return false end
	if ws.state ~= "handshake" and ws.state ~= "open" then return true end
	ws.lastData = os.time()
	ws.buf = ws.buf .. (data or "")
	if ws.state == "handshake" and not ParseHandshake(ws) then return true end
	while ws.state == "open" and ParseFrame(ws) do end
	return true
end
