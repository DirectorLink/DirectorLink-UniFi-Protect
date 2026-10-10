--[[=============================================================================
    DirectorLink UniFi Protect - shared core
    Logging (with secret redaction), utilities, timers, variables/events and a
    small XML parser for the Control4 camera page. tools/build.py inlines this
    file at the top of each driver.lua.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

unpack = unpack or table.unpack

-- Replaced by tools/build.py with the contents of the VERSION file
DRIVER_SEMVER = "dev"

-- HTTP User-Agent "<product>/<version>"; each driver sets its product (its .c4z file name)
USER_AGENT_PRODUCT = "DirectorLink-UniFi-Protect"
function UserAgent()
	return USER_AGENT_PRODUCT .. "/" .. DRIVER_SEMVER
end

--[[------------------------------------------------------------------ Logging
    One "Log Level" property: Off, Errors, Warnings, Info, Debug, Trace.
    Lines go to the Lua tab (print) and to Director's driver log (C4:DebugLog,
    C4:ErrorLog for errors), so a shared driver_log.log shows them.
    Every line passes through Redact(): the API key, stream tokens and picture
    passwords are registered as secrets and never reach a log.               ]]
LOG_LEVEL = 2
LOG_PREFIX = "UniFi Protect"
local LEVEL_TAGS = { "ERROR", "WARN", "INFO", "DEBUG", "TRACE" }
LOG_LEVELS = { Off = 0, Errors = 1, Warnings = 2, Info = 3, Debug = 4, Trace = 5 }

local gSecrets = {}

-- A value that must never be logged (shorter values are too likely to be ordinary text)
function RegisterSecret(s)
	if type(s) == "string" and #s >= 6 then gSecrets[s] = true end
end

function ForgetSecret(s)
	if s then gSecrets[s] = nil end
end

local function PlainPattern(s)
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

function Redact(msg)
	msg = tostring(msg)
	for s in pairs(gSecrets) do
		if string.find(msg, s, 1, true) then msg = string.gsub(msg, PlainPattern(s), "***") end
	end
	return msg
end

local function WriteLog(level, line)
	print(line)
	if level <= 1 then
		pcall(function() C4:ErrorLog(line) end)
	else
		pcall(function() C4:DebugLog(line) end)
	end
end

function Log(level, fmt, ...)
	if level > LOG_LEVEL then return end
	local msg
	local n = select("#", ...)
	if n > 0 then
		local args = { ... }
		for i = 1, n do
			if type(args[i]) ~= "number" then args[i] = tostring(args[i]) end
		end
		local ok, res = pcall(string.format, fmt, unpack(args, 1, n))
		msg = ok and res or (tostring(fmt) .. " (format error)")
	else
		msg = tostring(fmt)
	end
	WriteLog(level, Redact(os.date("%H:%M:%S") .. " [" .. (LEVEL_TAGS[level] or "LOG") .. "] " .. LOG_PREFIX .. ": " .. msg))
end

function LogError(...) Log(1, ...) end
function LogWarn(...) Log(2, ...) end
function LogInfo(...) Log(3, ...) end
function LogDebug(...) Log(4, ...) end
function LogTrace(...) Log(5, ...) end

-- Reports (Setup Report, Print Diagnostics) are printed whatever the Log Level
function PrintReport(lines)
	local text = Redact(table.concat(lines, "\n"))
	print(text)
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		pcall(function() C4:DebugLog(LOG_PREFIX .. ": " .. line) end)
	end
end

function ApplyLogSettings()
	LOG_LEVEL = LOG_LEVELS[Properties["Log Level"] or "Warnings"] or 2
end

--[[------------------------------------------------------------------ Utilities ]]
function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function toboolean(v)
	if type(v) == "boolean" then return v end
	v = string.lower(tostring(v or ""))
	return v == "true" or v == "1" or v == "yes" or v == "on" or v == "enabled"
end

function UpdateProperty(name, value)
	value = tostring(value == nil and "" or value)
	if Properties[name] ~= value then
		pcall(function() C4:UpdateProperty(name, value) end)
		Properties[name] = value
	end
end

function UrlEncode(s)
	return (tostring(s or ""):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function XmlEscape(s)
	s = tostring(s or "")
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

function Base64Encode(s)
	local ok, res = pcall(function() return C4:Base64Encode(s) end)
	return ok and res or ""
end

function Base64Decode(s)
	local ok, res = pcall(function() return C4:Base64Decode(s) end)
	return ok and res or nil
end

-- Hex digest; algorithm "MD5", "SHA1" or "SHA256"
function HashHex(algorithm, s)
	local ok, res = pcall(function() return C4:Hash(algorithm, s, { return_encoding = "HEX", data_encoding = "NONE" }) end)
	if ok and type(res) == "string" and res ~= "" then return string.lower(res) end
	return nil
end

-- Milliseconds, for timings and the one-second picture cache
function NowMs()
	local ok, t = pcall(function() return C4:GetTime() end)
	t = ok and tonumber(t) or nil
	if t and t > 1e12 then return t end
	if t and t > 1e9 then return t * 1000 end
	return os.time() * 1000
end

function ByteSize(n)
	n = tonumber(n) or 0
	if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
	if n >= 1024 then return string.format("%.1f KB", n / 1024) end
	return n .. " B"
end

function IsJpeg(body)
	return type(body) == "string" and string.sub(body, 1, 2) == "\255\216"
end

-- Width and height from a JPEG's frame header (nil when not found)
function JpegSize(data)
	if not IsJpeg(data) then return nil end
	local i, n = 3, #data
	while i + 8 <= n do
		if string.byte(data, i) ~= 0xFF then return nil end
		local marker = string.byte(data, i + 1)
		if marker == 0xFF then
			i = i + 1
		else
			if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
				local h = string.byte(data, i + 5) * 256 + string.byte(data, i + 6)
				local w = string.byte(data, i + 7) * 256 + string.byte(data, i + 8)
				return w, h
			end
			i = i + 2 + string.byte(data, i + 2) * 256 + string.byte(data, i + 3)
		end
	end
	return nil
end

-- ISO 8601 UTC, e.g. 2026-10-05T18:30:00Z
function IsoUtc(seconds)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(tonumber(seconds) or os.time()))
end

function HostPort(addr, port, default)
	port = tonumber(port)
	if port and port ~= default then return addr .. ":" .. port end
	return addr
end

-- A device never lives on the controller itself; the camera proxy reports 127.0.0.1 until set.
function ValidAddress(a)
	if type(a) ~= "string" then return false end
	local l = string.lower(trim(a))
	if l == "" or l == "localhost" or l == "0.0.0.0" or l == "::1" or string.match(l, "^127%.") then
		return false
	end
	return string.match(l, "^[%w%.%-:%[%]]+$") ~= nil
end

function IsMasked(s)
	return type(s) == "string" and s ~= "" and string.match(s, "^%*+$") ~= nil
end

function ProxyId()
	local ok, p = pcall(function() return C4:GetProxyDevices() end)
	if not ok or p == nil then return nil end
	if type(p) == "table" then
		for _, v in pairs(p) do return tonumber(v) end
		return nil
	end
	return tonumber(string.match(tostring(p), "%d+"))
end

function MyDeviceId()
	local ok, id = pcall(function() return C4:GetDeviceID() end)
	return ok and tonumber(id) or nil
end

-- Control4 OS version as { major, minor, patch, text }, or nil when Director does not say
function ControllerVersion()
	local ok, info = pcall(function() return C4:GetVersionInfo() end)
	local text = ok and type(info) == "table" and tostring(info.version or info.VERSION or "") or ""
	local a, b, c = string.match(text, "(%d+)%.(%d+)%.(%d+)")
	if not a then return nil end
	return { tonumber(a), tonumber(b), tonumber(c), text = text }
end

-- true when version v ({ a, b, c } or "a.b.c") is at least the minimum "x.y.z"
function VersionAtLeast(v, minimum)
	if type(v) == "string" then
		local a, b, c = string.match(v, "(%d+)%.(%d+)%.?(%d*)")
		if not a then return false end
		v = { tonumber(a), tonumber(b), tonumber(c) or 0 }
	end
	if type(v) ~= "table" then return false end
	local x, y, z = string.match(minimum, "(%d+)%.(%d+)%.(%d+)")
	local want = { tonumber(x), tonumber(y), tonumber(z) }
	for i = 1, 3 do
		local have = tonumber(v[i]) or 0
		if have ~= want[i] then return have > want[i] end
	end
	return true
end

-- Inter-driver message (hub <-> camera). Values are sent as strings; never logged by Director.
function SendToDriver(deviceId, command, params)
	if not deviceId then return false end
	local p = {}
	for k, v in pairs(params or {}) do p[k] = tostring(v) end
	local ok, err = pcall(function() C4:SendToDevice(tonumber(deviceId), command, p, true, false) end)
	if not ok then LogDebug("SendToDevice(%s, %s) failed: %s", deviceId, command, err) end
	return ok
end

-- A random-looking secret. DriverWorks has no random source of its own, so several
-- changing values are mixed and hashed (SHA-256 when available).
function NewSecret(extra)
	local parts = { tostring(os.time()), tostring(os.clock()), tostring({}), tostring(math.random()),
		tostring(math.random(1, 2147483646)), tostring(collectgarbage("count")), tostring(MyDeviceId()), tostring(extra or "") }
	pcall(function() parts[#parts + 1] = tostring(C4:UUID("Random")) end)
	pcall(function() parts[#parts + 1] = tostring(C4:GetTime()) end)
	local s = table.concat(parts, "|")
	local h = HashHex("SHA256", s) or ((HashHex("MD5", s .. "a") or "") .. (HashHex("MD5", s .. "b") or ""))
	if #h < 32 then
		local t = {}
		for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
		h = table.concat(t)
	end
	return h
end

--[[------------------------------------------------------------------ Timers ]]
local gTimers = {}

function SetTimer(name, ms, fn, rep)
	if gTimers[name] then
		pcall(function() gTimers[name]:Cancel() end)
		gTimers[name] = nil
	end
	local ok, t = pcall(function()
		return C4:SetTimer(ms, function()
			if not rep then gTimers[name] = nil end
			local ok2, err = pcall(fn)
			if not ok2 then LogError("Timer %s failed: %s", name, err) end
		end, rep and true or false)
	end)
	if ok then gTimers[name] = t else LogError("SetTimer(%s) failed: %s", name, t) end
end

function KillTimer(name)
	if gTimers[name] then
		pcall(function() gTimers[name]:Cancel() end)
		gTimers[name] = nil
	end
end

function TimerActive(name)
	return gTimers[name] ~= nil
end

function KillAllTimers()
	for name in pairs(gTimers) do KillTimer(name) end
end

--[[------------------------------------------------------------------ Variables & events ]]
local gVarValues = {}

function AddVariables(list)
	for _, v in ipairs(list) do
		pcall(function() C4:AddVariable(v[1], v[2], v[3], true, false) end)
		gVarValues[v[1]] = v[2]
	end
end

-- force: write it even when it seems unchanged (a variable kept from an older driver version)
function SetVar(name, value, force)
	if type(value) == "boolean" then value = value and "1" or "0" end
	value = tostring(value)
	if gVarValues[name] == value and not force then return end
	gVarValues[name] = value
	pcall(function() C4:SetVariable(name, value) end)
end

function GetVar(name)
	return gVarValues[name]
end

function FireEvent(name)
	LogInfo("Event: %s", name)
	local ok, err = pcall(function() C4:FireEvent(name) end)
	if not ok then LogError("FireEvent(%s) failed: %s", name, err) end
end

-- BOOL conditionals: Director may pass the chosen text (true_text/false_text) and a LOGIC
function TestBool(state, tParams, trueText)
	local v = tParams and (tParams.VALUE or tParams.value)
	local result
	if v == nil then
		result = state
	else
		local lv = string.lower(tostring(v))
		local wantTrue = (lv == string.lower(trueText) or lv == "true" or lv == "1")
		result = (state == wantTrue)
	end
	if tParams and tParams.LOGIC == "NOT_EQUAL" then result = not result end
	return result
end

function TestEquals(actual, tParams)
	local eq = (tostring(actual or "") == tostring(tParams and tParams.VALUE or ""))
	if tParams and tParams.LOGIC == "NOT_EQUAL" then return not eq end
	return eq
end

--[[------------------------------------------------------------------ XML
    Small parser for the Control4 camera page (GET_PROPERTIES).             ]]
local XML_ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

function XmlUnescape(s)
	return (s:gsub("&(#?)([xX]?)(%w+);", function(hash, x, v)
		if hash == "" then return XML_ENTITIES[v] or ("&" .. x .. v .. ";") end
		local n = (x ~= "") and tonumber(v, 16) or tonumber(v)
		if n and n < 128 then return string.char(n) end
		return "&#" .. x .. v .. ";"
	end))
end

-- Text of the first <tag>...</tag> in a document, unescaped
function XmlTag(xml, tag)
	local v = string.match(tostring(xml or ""), "<" .. tag .. ">(.-)</" .. tag .. ">")
	return v and XmlUnescape(trim(v)) or nil
end
