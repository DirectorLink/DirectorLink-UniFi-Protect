--[[=============================================================================
    DirectorLink UniFi Protect - picture server on the controller
    Control4 apps and DirectorLink take a camera's pictures from the camera
    proxy's address, port, login and snapshot path. The console wants the API
    key in a header, which they cannot send, so the hub answers instead:

      GET /snapshot/<camera device id>.jpg[?high=1]   Basic login of that camera
      GET /snapshot/<id>.jpg?high=1&t=<token>         a notification's short-lived token

    It fetches the picture from the console with the key, keeps it at most
    PICTURE_MAX_AGE_MS, and answers only the login of that camera (each camera
    has its own random one, written to its proxy properties). Requests that
    arrive while a picture is on its way share it.

    The hub sets:
      PictureLogin(deviceId) -> user, pass, protectId   (nil when the camera is unknown or disabled)
      PictureFetch(protectId, high, cb)                  cb(code, jpeg, err)

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

PICTURE_MAX_AGE_MS = 1000
PICTURE_MAX_CLIENTS = 32
PICTURE_HEAD_TIMEOUT_S = 5      -- a client has this long to send its request
PICTURE_CLIENT_TIMEOUT_S = 35   -- and this long to get its answer
PICTURE_MAX_HEADER = 8192
PICTURE_TOKEN_S = 600           -- notification links work this long
PICTURE_REALM = "UniFi Protect pictures"

gPictures = {
	server = nil, port = nil, wantPort = nil, state = "stopped", error = nil,
	clients = {}, clientCount = 0, cache = {}, pending = {}, served = 0, refused = 0, failed = 0,
	tokens = {}, onState = nil,
}

-- A token that opens one camera's picture for PICTURE_TOKEN_S, for a notification's URL attachment
-- (the notification service cannot send a Basic login, and the camera's own login must not leave)
function PictureToken(deviceId)
	local now = os.time()
	local count = 0
	for t, info in pairs(gPictures.tokens) do
		if info.expires <= now then gPictures.tokens[t] = nil else count = count + 1 end
	end
	if count >= 20 then
		local oldest, at
		for t, info in pairs(gPictures.tokens) do
			if not at or info.expires < at then oldest, at = t, info.expires end
		end
		if oldest then gPictures.tokens[oldest] = nil end
	end
	local token = string.sub(NewSecret("token" .. tostring(deviceId)), 1, 32)
	gPictures.tokens[token] = { id = tonumber(deviceId), expires = now + PICTURE_TOKEN_S }
	RegisterSecret(token)
	return token
end

local function QueryValue(query, name)
	return string.match("&" .. (query or ""), "&" .. name .. "=([^&]*)")
end

local STATUS_TEXT = { [200] = "OK", [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
	[405] = "Method Not Allowed", [429] = "Too Many Requests", [502] = "Bad Gateway", [503] = "Service Unavailable",
	[504] = "Gateway Timeout" }

local function RemoteText(client)
	local ok, a = pcall(function() return client:GetRemoteAddress() end)
	if ok and type(a) == "table" and a.ip then return tostring(a.ip) end
	return "?"
end

local function Forget(client)
	if gPictures.clients[client] then
		gPictures.clients[client] = nil
		gPictures.clientCount = gPictures.clientCount - 1
	end
end

local function Respond(client, code, contentType, body, extraHeaders, head)
	body = body or ""
	local lines = {
		"HTTP/1.1 " .. code .. " " .. (STATUS_TEXT[code] or "Error"),
		"Content-Type: " .. (contentType or "text/plain; charset=utf-8"),
		"Content-Length: " .. #body,
		"Cache-Control: no-store",
		"Connection: close",
	}
	for _, h in ipairs(extraHeaders or {}) do lines[#lines + 1] = h end
	local data = table.concat(lines, "\r\n") .. "\r\n\r\n" .. (head and "" or body)
	pcall(function() client:Write(data):Close(true) end)
	Forget(client)
end

-- user, pass from "Authorization: Basic ..."
function ParseBasicAuth(value)
	local b64 = string.match(tostring(value or ""), "^%s*[Bb][Aa][Ss][Ii][Cc]%s+([%w%+/=]+)%s*$")
	if not b64 then return nil end
	local decoded = Base64Decode(b64)
	if type(decoded) ~= "string" then return nil end
	return string.match(decoded, "^([^:]*):(.*)$")
end

local function LoginMatches(user, pass, wantUser, wantPass)
	if not user or not wantUser or wantUser == "" or wantPass == "" then return false end
	-- The camera page may hand the password on Base64 encoded; both are the same secret
	return user == wantUser and (pass == wantPass or pass == Base64Encode(wantPass))
end

-- Parse one request head; returns method, path, query, headers (lower-case names)
function ParseRequestHead(text)
	local method, target = string.match(text, "^(%u+)%s+(%S+)%s+HTTP/%d%.%d\r?\n")
	if not method then return nil end
	local headers = {}
	for k, v in string.gmatch(text, "\n([^:\r\n]+):[ \t]*([^\r\n]*)") do headers[string.lower(k)] = trim(v) end
	local path, query = string.match(target, "^([^?]*)%??(.*)$")
	return method, path, query or "", headers
end

local function Deliver(key, code, jpeg, err)
	local waiting = gPictures.pending[key]
	gPictures.pending[key] = nil
	if not waiting then return end
	if code == 200 and type(jpeg) == "string" and #jpeg > 0 then
		gPictures.cache[key] = { at = NowMs(), jpeg = jpeg }
	end
	for _, w in ipairs(waiting.clients) do
		if gPictures.clients[w.client] then
			if code == 200 and jpeg then
				gPictures.served = gPictures.served + 1
				LogDebug("Picture %s for %s -> 200 in %d ms (%s)", key, w.from, NowMs() - w.startedMs, ByteSize(#jpeg))
				Respond(w.client, 200, "image/jpeg", jpeg, nil, w.head)
			else
				gPictures.failed = gPictures.failed + 1
				local out = (code == 429) and 503 or (code and 502) or 504
				LogDebug("Picture %s for %s -> %d (the console: %s)", key, w.from, out, tostring(err or code))
				Respond(w.client, out, nil, "The console gave no picture: " .. tostring(err or ("HTTP " .. tostring(code))) .. "\n",
					code == 429 and { "Retry-After: 2" } or nil, w.head)
			end
		end
	end
end

local function HandleRequest(client, text)
	local info = gPictures.clients[client]
	if not info then return end
	info.gotRequest = true
	local from = RemoteText(client)
	if #text > PICTURE_MAX_HEADER then
		LogDebug("Picture request from %s -> 400 (request too long)", from)
		return Respond(client, 400, nil, "Request too long\n")
	end
	local method, path, query, headers = ParseRequestHead(text)
	if not method then
		LogDebug("Picture request from %s -> 400 (not HTTP)", from)
		return Respond(client, 400, nil, "Bad request\n")
	end
	if method ~= "GET" and method ~= "HEAD" then
		return Respond(client, 405, nil, "Only GET\n", { "Allow: GET, HEAD" })
	end
	local id = tonumber(string.match(path, "^/snapshot/(%d+)%.jpg$") or "")
	if not id then
		LogDebug("Picture request from %s for %s -> 404", from, path)
		return Respond(client, 404, nil, "Not found\n", nil, method == "HEAD")
	end
	local wantUser, wantPass, protectId = PictureLogin(id)
	local user, pass = ParseBasicAuth(headers["authorization"])
	local token = QueryValue(query, "t")
	local tokenInfo = token and gPictures.tokens[token]
	local tokenOk = tokenInfo ~= nil and tokenInfo.id == id and tokenInfo.expires > os.time()
	if not wantUser or not (tokenOk or LoginMatches(user, pass, wantUser, wantPass)) then
		gPictures.refused = gPictures.refused + 1
		LogDebug("Picture request from %s for camera %d -> 401 (%s)", from, id,
			not wantUser and "unknown camera" or (user and "wrong login" or "no login"))
		return Respond(client, 401, nil, "Login required\n", { 'WWW-Authenticate: Basic realm="' .. PICTURE_REALM .. '"' }, method == "HEAD")
	end
	if not protectId then
		return Respond(client, 503, nil, "This camera is not linked to a UniFi camera yet\n", nil, method == "HEAD")
	end
	local high = QueryValue(query, "high") == "1"
	local key = id .. (high and ":high" or ":std")
	local cached = gPictures.cache[key]
	if cached and NowMs() - cached.at < PICTURE_MAX_AGE_MS then
		gPictures.served = gPictures.served + 1
		LogDebug("Picture %s for %s -> 200 from the last second's picture (%s)", key, from, ByteSize(#cached.jpeg))
		return Respond(client, 200, "image/jpeg", cached.jpeg, nil, method == "HEAD")
	end
	local waiter = { client = client, from = from, startedMs = NowMs(), head = method == "HEAD" }
	if gPictures.pending[key] then
		table.insert(gPictures.pending[key].clients, waiter)
		return
	end
	gPictures.pending[key] = { clients = { waiter }, startedMs = NowMs() }
	PictureFetch(protectId, high, function(code, jpeg, err) Deliver(key, code, jpeg, err) end)
end

local function Accept(srv, client)
	if gPictures.clientCount >= PICTURE_MAX_CLIENTS then
		LogDebug("Picture server: too many connections, refusing one")
		pcall(function() client:Write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"):Close(true) end)
		return
	end
	gPictures.clients[client] = { at = os.time() }
	gPictures.clientCount = gPictures.clientCount + 1
	pcall(function()
		client
			:OnRead(function(cli, data)
				local ok, err = pcall(HandleRequest, cli, data or "")
				if not ok then
					LogError("Picture request failed: %s", err)
					Respond(cli, 503, nil, "Error\n")
				end
			end)
			:OnDisconnect(function(cli) Forget(cli) end)
			:OnError(function(cli) Forget(cli) end)
			:ReadUntil("\r\n\r\n")
	end)
end

local function SetState(state, err)
	gPictures.state, gPictures.error = state, err
	if gPictures.onState then pcall(gPictures.onState, state, err) end
end

local function Sweep()
	local now, nowMs = os.time(), NowMs()
	for key, c in pairs(gPictures.cache) do
		if nowMs - c.at >= PICTURE_MAX_AGE_MS then gPictures.cache[key] = nil end
	end
	for client, info in pairs(gPictures.clients) do
		if now - info.at > (info.gotRequest and PICTURE_CLIENT_TIMEOUT_S or PICTURE_HEAD_TIMEOUT_S) then
			pcall(function() client:Close() end)
			Forget(client)
		end
	end
	for key, p in pairs(gPictures.pending) do
		if nowMs - p.startedMs > (PICTURE_CLIENT_TIMEOUT_S + 15) * 1000 then Deliver(key, nil, nil, "no answer") end
	end
	for t, info in pairs(gPictures.tokens) do
		if info.expires <= now then gPictures.tokens[t] = nil end
	end
end

function PictureServerStop()
	KillTimer("PICTURE_SWEEP")
	if gPictures.server then
		local s = gPictures.server
		gPictures.server = nil
		pcall(function() s:Close() end)
	end
	for client in pairs(gPictures.clients) do pcall(function() client:Close() end) end
	gPictures.clients, gPictures.clientCount, gPictures.cache, gPictures.pending = {}, 0, {}, {}
	gPictures.port = nil
	SetState("stopped")
end

function PictureServerStart(port)
	PictureServerStop()
	gPictures.wantPort = tonumber(port)
	SetState("starting")
	local ok, err = pcall(function()
		gPictures.server = C4:CreateTCPServer()
			:OnListen(function(srv)
				local okA, addr = pcall(function() return srv:GetLocalAddress() end)
				gPictures.port = okA and type(addr) == "table" and tonumber(addr.port) or gPictures.wantPort
				LogInfo("Picture server listening on port %s", tostring(gPictures.port))
				SetState("listening")
			end)
			:OnError(function(_, code, msg)
				LogError("Picture server error on port %s: %s (%s)", tostring(gPictures.wantPort), tostring(msg), tostring(code))
				SetState("error", tostring(msg or code))
			end)
			:OnAccept(Accept)
			:Listen("*", gPictures.wantPort)
	end)
	if not ok then
		LogError("Picture server could not start: %s", err)
		SetState("error", tostring(err))
		return
	end
	SetTimer("PICTURE_SWEEP", 5000, Sweep, true)
end
