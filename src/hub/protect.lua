--[[=============================================================================
    DirectorLink UniFi Protect - Protect Integration API client
    Ubiquiti's official API only: https://<console>/proxy/protect/integration/v1
    with the header "X-API-Key". No username, no password, no private API.

    The key is sent only to the configured console: every URL is built here from
    gApi.host, and a redirect is never followed (C4:url would follow it and carry
    the X-API-Key header along, so OnHeaders aborts the transfer at any 3xx). The
    key is registered as a secret so no log line can show it. The console's
    certificate is self-signed, so it is not verified.

    ApiRequest(method, path, body, cb, opts)
      cb(code, body, err, headers, ms)    code is nil when the console did not answer
      opts: accept, timeout, retry429 (GET only), front (jump the queue), quiet,
            noHealth (a failure does not count against the console: slow snapshots)

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

PROTECT_BASE = "/proxy/protect/integration/v1"
API_MAX_IN_FLIGHT = 4
API_TIMEOUT_S = 15
API_MAX_429_RETRIES = 3

gApi = { host = "", port = 443, key = "", queue = {}, inFlight = 0, requests = 0, onResult = nil }

-- "192.168.50.1", "unvr.local" or "192.168.50.1:8443" -> host, port
function ParseConsoleAddress(text)
	text = trim(text or "")
	text = string.gsub(text, "^[Hh][Tt][Tt][Pp][Ss]?://", "")
	text = string.gsub(text, "/.*$", "")
	local host, port = string.match(text, "^([^:]+):(%d+)$")
	if not host then host = text end
	port = tonumber(port) or 443
	if not ValidAddress(host) or port < 1 or port > 65535 then return nil, nil end
	return host, port
end

function ApiConfigure(address, key)
	local host, port = ParseConsoleAddress(address)
	if gApi.key ~= "" and gApi.key ~= key then ForgetSecret(gApi.key) end
	gApi.host, gApi.port = host or "", port or 443
	gApi.key = trim(key or "")
	RegisterSecret(gApi.key)
	return host ~= nil and gApi.key ~= ""
end

function ApiReady()
	return gApi.host ~= "" and gApi.key ~= ""
end

function ApiConsole()
	return HostPort(gApi.host, gApi.port, 443)
end

-- The genericError body ({ "error": ..., "name": ... }) in a few words
function ApiErrorText(code, body, err)
	if err then return err end
	local text = "HTTP " .. tostring(code)
	local d = type(body) == "string" and string.sub(body, 1, 1) == "{" and JsonDecode(body) or nil
	if type(d) == "table" then
		local what = trim(tostring(d.name or "") .. ((d.name and d.error) and ": " or "") .. tostring(d.error or ""))
		if what ~= "" then text = text .. " (" .. string.sub(what, 1, 160) .. ")" end
	end
	return text
end

local function HeaderValue(headers, name)
	if type(headers) ~= "table" then return nil end
	name = string.lower(name)
	for k, v in pairs(headers) do
		if string.lower(tostring(k)) == name then return type(v) == "table" and v[1] or v end
	end
	return nil
end
ApiHeader = HeaderValue

local Size = function(n) return ByteSize(n) end

local Pump -- forward

local function Start(job)
	gApi.inFlight = gApi.inFlight + 1
	gApi.requests = gApi.requests + 1
	job.tries = (job.tries or 0) + 1
	local startedMs = NowMs()
	local finished = false
	local guard
	local function finish(code, body, err, headers)
		if finished then return end
		finished = true
		if guard then pcall(function() guard:Cancel() end) end
		gApi.inFlight = gApi.inFlight - 1
		local ms = NowMs() - startedMs
		if code == 429 and job.opts.retry429 and job.method == "GET" and job.tries <= API_MAX_429_RETRIES then
			local wait = tonumber(HeaderValue(headers, "Retry-After") or "") or (2 ^ job.tries)
			wait = math.max(1, math.min(60, wait)) + math.random() * 0.5
			LogDebug("API %s %s -> 429 (rate limited), retry %d in %.1f s", job.method, job.path, job.tries, wait)
			SetTimer("API_RETRY_" .. tostring(job), wait * 1000, function()
				table.insert(gApi.queue, 1, job)
				Pump()
			end)
			Pump()
			return
		end
		if not job.opts.quiet then
			if code then
				LogDebug("API %s %s -> %d in %d ms (%s)", job.method, job.path, code, ms, Size(body and #body or 0))
			else
				LogDebug("API %s %s -> no answer after %d ms: %s", job.method, job.path, ms, tostring(err))
			end
		end
		if gApi.onResult then pcall(gApi.onResult, job.method, job.path, code, body, err, job.opts) end
		local ok, cbErr = pcall(job.cb, code, body, err, headers, ms)
		if not ok then LogError("API callback for %s failed: %s", job.path, cbErr) end
		Pump()
	end
	if not ApiReady() then return finish(nil, nil, "the console address or API key is not set") end
	-- The only place a URL with the key is made: the configured console, our fixed base path
	if string.sub(job.path, 1, 1) ~= "/" or string.find(job.path, "://", 1, true) or string.find(job.path, "@", 1, true) then
		return finish(nil, nil, "refused: not an API path")
	end
	local url = "https://" .. ApiConsole() .. PROTECT_BASE .. job.path
	local headers = { ["X-API-Key"] = gApi.key, ["Accept"] = job.opts.accept or "application/json", ["User-Agent"] = UserAgent() }
	if job.body then headers["Content-Type"] = "application/json" end
	local timeout = job.opts.timeout or API_TIMEOUT_S
	guard = C4:SetTimer((timeout + 10) * 1000, function() finish(nil, nil, "no answer (timeout)") end)
	local redirected = nil
	local ok, err = pcall(function()
		local x = C4:url()
		x:SetOptions({
			fail_on_error = false, timeout = timeout, connect_timeout = 5,
			ssl_verify_host = false, ssl_verify_peer = false,
		})
		-- Stop at a redirect before it is followed: the next request would carry the key elsewhere
		x:OnHeaders(function(_, resp)
			local c = tonumber(resp and resp.code) or 0
			if c >= 300 and c < 400 then
				redirected = c
				return true
			end
		end)
		x:OnDone(function(_, responses, errCode, errMsg)
			if redirected then
				return finish(redirected, "", "the console answered with a redirect (HTTP " .. redirected .. "); stopped there, so the API key stays on the console")
			end
			local resp = responses and responses[#responses]
			if (errCode ~= nil and errCode ~= 0) or resp == nil then
				return finish(nil, nil, errMsg or ("transfer error " .. tostring(errCode)))
			end
			local code = tonumber(resp.code) or 0
			if (responses and #responses > 1) or (code >= 300 and code < 400) then
				return finish(code, "", "the console answered with a redirect (HTTP " .. code .. ")", resp.headers)
			end
			finish(code, resp.body or "", nil, resp.headers)
		end)
		if job.method == "GET" then
			x:Get(url, headers)
		elseif job.method == "POST" then
			x:Post(url, job.body or "", headers)
		else
			x:Custom(url, job.method, job.body or "", headers)
		end
	end)
	if not ok then finish(nil, nil, "request error: " .. tostring(err)) end
end

Pump = function()
	while gApi.inFlight < API_MAX_IN_FLIGHT and #gApi.queue > 0 do
		Start(table.remove(gApi.queue, 1))
	end
end

function ApiQueueLength()
	return #gApi.queue
end

function ApiRequest(method, path, body, cb, opts)
	local job = { method = method, path = path, body = body, cb = cb or function() end, opts = opts or {} }
	if job.opts.front then table.insert(gApi.queue, 1, job) else table.insert(gApi.queue, job) end
	Pump()
end

-- GET with a JSON answer: cb(data, code, err, ms); data is nil unless HTTP 200 with valid JSON
function ApiGetJson(path, cb, opts)
	opts = opts or {}
	if opts.retry429 == nil then opts.retry429 = true end
	ApiRequest("GET", path, nil, function(code, body, err, _, ms)
		if code ~= 200 then return cb(nil, code, ApiErrorText(code, body, err), ms) end
		local data, jerr = JsonDecode(body, opts.keepNull)
		if data == nil then return cb(nil, code, "the console's answer is not valid JSON (" .. tostring(jerr) .. ")", ms) end
		cb(data, code, nil, ms)
	end, opts)
end

-- The Protect version as "a.b.c" from /v1/meta/info
function ApiVersionOf(info)
	local v = type(info) == "table" and tostring(info.applicationVersion or "") or ""
	return string.match(v, "^%d+%.%d+%.?%d*") and v or nil
end

-- Hide a stream token: rtsps://host:7441/abcd...?enableSrtp -> rtsps://host:7441/***?enableSrtp
function MaskStreamUrl(url)
	if type(url) ~= "string" or url == "" then return "" end
	return (string.gsub(url, "^(%a+://[^/]+/)[^?]*", "%1***"))
end

function StreamToken(url)
	return type(url) == "string" and string.match(url, "^%a+://[^/]+/([^?]+)") or nil
end
