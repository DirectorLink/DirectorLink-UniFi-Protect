--[[=============================================================================
    DirectorLink · UniFi Protect (the UniFi Protect Hub) - Control4 DriverWorks driver
    https://directorlink.io/drivers/unifi-protect

    One UniFi console (Dream Machine, UNVR, Cloud Key Gen2+) through Ubiquiti's
    official Protect Integration API and an API key. The hub lists the console's
    cameras and doorbells, adds them as "DirectorLink · UniFi Protect Camera"
    devices, serves their pictures from a small HTTP server on the controller,
    hands them their live video streams, and passes them the console's events
    (smart detections, motion, doorbell rings) from the WebSocket
    /subscribe/events. It gives the home one alerts tile and one Camera Alert
    and one Doorbell Ring event for all cameras.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
    DirectorLink is an independent project, not affiliated with Control4 or Snap One.
    Not affiliated with or endorsed by Ubiquiti. Product names are trademarks of their owners.
===============================================================================]]

local TILE_PROXY = 5001
EVENTS_BINDING, DEVICES_BINDING = 6101, 6102
USER_AGENT_PRODUCT = "DirectorLink-UniFi-Protect"
LOG_PREFIX = "UniFi Protect Hub"
CAMERA_DRIVER = "DirectorLink-UniFi-Protect-Camera.c4z"
HUB_DRIVER = "DirectorLink-UniFi-Protect.c4z"
DRIVER_PAGE = "directorlink.io/drivers/unifi-protect"

MIN_PROTECT = "5.3.0"         -- the Integration API arrived with Protect 5.3
REFRESH_INTERVAL_MS = 300000  -- /cameras again every 5 minutes
STREAM_SPACING_MS = 600       -- stream lookups are paced: Protect rate-limits bursts
ADD_SPACING_MS = 2500
CONFIGURE_DELAY_MS = 4000
EVENT_HISTORY = 10
WS_RETRY_MIN_S, WS_RETRY_MAX_S = 5, 120
PICTURE_WAIT_MS = 1500        -- Camera Alert / Doorbell Ring wait this long for their own picture
ADD_WATCHDOG_MS = 30000       -- Director should answer C4:AddDevice well within this
SAVED_VARS = { "LAST_ALERT_CAMERA", "LAST_ALERT_TYPE", "LAST_ALERT_TIME", "LAST_RING_CAMERA", "LAST_RING_TIME", "LAST_OFFLINE_CAMERA" }

--[[=============================================================================
    State
===============================================================================]]
gProtect = { cameras = {}, version = nil, nvr = nil, fields = nil, flagFields = nil, fetchedAt = nil }
gCameras = {}        -- camera driver device id -> what the hub knows about it
gEvents = {}         -- the last EVENT_HISTORY events from the console, oldest first
gConn = { state = "setup", error = nil, errorAt = nil, online = nil }
local gHub = { snoozeUntil = 0, secret = nil }
local gState = {
	adding = false, addQueue = {}, addedCount = 0, tileIcon = nil, alertActive = false, effectiveAlerts = nil,
	lastAlertCamera = nil, lastAlertType = nil, alertSnapshot = nil, message = nil, messageTransient = false,
	lastNewCount = nil, streamQueue = {}, seenEvents = {}, seenOrder = {}, wsFails = { events = 0, devices = 0 },
}
local gWs = {}       -- events / devices sockets

--[[=============================================================================
    Saved state
===============================================================================]]
local function SaveState()
	pcall(function()
		local cams = {}
		for id, c in pairs(gCameras) do
			cams[tostring(id)] = { name = c.name, protectId = c.protectId, managed = c.managed, proxyId = c.proxyId }
		end
		local vars = {}
		for _, name in ipairs(SAVED_VARS) do vars[name] = GetVar(name) end
		C4:PersistSetValue("DL_HUB", { cameras = cams, snoozeUntil = gHub.snoozeUntil, vars = vars })
	end)
end

-- A variable whose value survives a restart (Director starts added variables at their default)
local function SetSavedVar(name, value)
	SetVar(name, value)
	SaveState()
end

local function LoadState()
	pcall(function()
		local t = C4:PersistGetValue("DL_HUB")
		if type(t) ~= "table" then return end
		gHub.snoozeUntil = tonumber(t.snoozeUntil) or 0
		gHub.savedVars = type(t.vars) == "table" and t.vars or {}
		for id, c in pairs(t.cameras or {}) do
			local n = tonumber(id)
			if n then
				gCameras[n] = { id = n, name = c.name, protectId = c.protectId, managed = c.managed, proxyId = c.proxyId }
			end
		end
	end)
	-- The secret the picture logins are made from; kept encrypted, made once
	pcall(function()
		local s = C4:PersistGetValue("DL_SECRET", true)
		if type(s) == "string" and #s >= 32 then gHub.secret = s end
	end)
	if not gHub.secret then
		gHub.secret = NewSecret("hub")
		pcall(function() C4:PersistSetValue("DL_SECRET", gHub.secret, true) end)
	end
	RegisterSecret(gHub.secret)
end

-- Each camera's own random picture login, made from the hub's secret
function PictureCredentials(deviceId)
	local function part(what, n)
		local h = HashHex("SHA256", gHub.secret .. ":" .. what .. ":" .. tostring(deviceId)) or HashHex("MD5", gHub.secret .. what .. tostring(deviceId)) or ""
		return string.sub(h, 1, n)
	end
	local user, pass = "c4cam" .. part("user", 8), part("pass", 26)
	RegisterSecret(pass)
	return user, pass
end

--[[=============================================================================
    Helpers
===============================================================================]]
local UpdateTile, UpdateSummary, UpdateFoundSummary, ConfigureCamera, QueueStreams -- forward

local function ControllerAddress()
	local ok, a = pcall(function() return C4:GetControllerNetworkAddress() end)
	if ok and type(a) == "string" and ValidAddress(a) then return trim(a) end
	return nil
end

local function PictureServerPort()
	return gPictures.port or tonumber(Properties["Picture Server Port"]) or 47080
end

local function LiveVideo()
	return string.find(Properties["Live Video"] or "", "RTSPS", 1, true) and "RTSPS" or "RTSP"
end

local function CameraList()
	local list = {}
	for _, c in pairs(gCameras) do list[#list + 1] = c end
	table.sort(list, function(a, b) return tostring(a.name or "") < tostring(b.name or "") end)
	return list
end

local function DevicesFor(protectId)
	local ids = {}
	for id, c in pairs(gCameras) do
		if c.protectId == protectId then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

local function ProtectName(p)
	if not p then return nil end
	local n = trim(type(p.name) == "string" and p.name or "")
	if n ~= "" then return n end
	local mac = type(p.mac) == "string" and string.gsub(p.mac, "[^%x]", "") or ""
	return "UniFi Camera" .. (#mac >= 4 and (" " .. string.upper(string.sub(mac, -4))) or "")
end

-- A model name, when the API gives one (the documented camera object has none)
local function ModelOf(raw)
	for _, k in ipairs({ "marketName", "model", "type", "displayModel" }) do
		if type(raw[k]) == "string" and raw[k] ~= "" then return raw[k] end
	end
	return nil
end

-- Doorbells (G4 Doorbell, G4 Doorbell Pro, G6 Entry) are cameras with a ring.
-- The documented camera object has no "doorbell" field, so: a feature flag when the console sends
-- one, an LCD message (only doorbells have a screen), a name or model that says so, or a ring seen.
local function KindOf(raw, model)
	local flags = type(raw.featureFlags) == "table" and raw.featureFlags or {}
	if flags.isDoorbell == true or flags.hasChime == true then return "doorbell", "the console flags it as a doorbell" end
	local lcd = raw.lcdMessage
	if type(lcd) == "table" and (lcd.type or lcd.text) then return "doorbell", "it has a doorbell screen message" end
	local text = string.lower(tostring(model or "") .. " " .. tostring(raw.name or ""))
	if string.find(text, "doorbell", 1, true) or string.find(text, "g6 entry", 1, true) then
		return "doorbell", "its name or model says doorbell"
	end
	return "camera", nil
end

local function StringList(arr)
	local out = {}
	for _, v in ipairs(type(arr) == "table" and arr or {}) do
		if type(v) == "string" then out[#out + 1] = v end
	end
	return out
end

local function KeysOf(t)
	local keys = {}
	for k in pairs(type(t) == "table" and t or {}) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	return keys
end

-- One /cameras entry -> what the hub keeps
function ParseCamera(raw)
	if type(raw) ~= "table" or type(raw.id) ~= "string" or raw.id == "" then return nil end
	local model = ModelOf(raw)
	local kind, why = KindOf(raw, model)
	local flags = type(raw.featureFlags) == "table" and raw.featureFlags or {}
	local settings = type(raw.smartDetectSettings) == "table" and raw.smartDetectSettings or {}
	return {
		id = raw.id, name = ProtectName(raw), rawName = raw.name, state = tostring(raw.state or ""), mac = raw.mac,
		model = model, kind = kind, kindWhy = why,
		smartTypes = StringList(flags.smartDetectTypes), smartEnabled = StringList(settings.objectTypes),
		audioTypes = StringList(flags.smartDetectAudioTypes),
		fullHdSnapshot = flags.supportFullHdSnapshot == true,
	}
end

--[[=============================================================================
    Alerts (master switch for every camera)
===============================================================================]]
local function HubAlertsEnabled()
	if os.time() < (gHub.snoozeUntil or 0) then return false end
	return (Properties["Alerts"] or "On") == "On"
end

local function PushAlertsToCameras()
	local on = HubAlertsEnabled()
	for id in pairs(gCameras) do
		SendToDriver(id, "DL_HUB_ALERTS", { HUB_ID = MyDeviceId(), ENABLED = on and "1" or "0" })
	end
end

local function AlertsChanged(reason)
	local now = HubAlertsEnabled()
	SetVar("ALERTS_ENABLED", now)
	if gState.effectiveAlerts ~= nil and gState.effectiveAlerts ~= now then
		LogInfo("Alerts %s (%s)", now and "on" or "off", reason or "")
		FireEvent(now and "Alerts On" or "Alerts Off")
	end
	gState.effectiveAlerts = now
	if gState.messageTransient and reason ~= "startup" then
		gState.message = nil
		KillTimer("MESSAGE_CLEAR")
	end
	if os.time() < (gHub.snoozeUntil or 0) then
		SetTimer("SNOOZE_END", (gHub.snoozeUntil - os.time() + 1) * 1000, function() AlertsChanged("snooze ended") end)
	else
		KillTimer("SNOOZE_END")
	end
	PushAlertsToCameras()
	UpdateTile()
	UpdateSummary()
end

local function SetAlerts(on, reason)
	gHub.snoozeUntil = 0
	SaveState()
	UpdateProperty("Alerts", on and "On" or "Off")
	AlertsChanged(reason)
end

local function SnoozeAlerts(minutes, reason)
	minutes = math.max(1, math.min(1440, tonumber(minutes) or 60))
	gHub.snoozeUntil = os.time() + minutes * 60
	SaveState()
	AlertsChanged(reason or ("snooze " .. minutes .. " min"))
end

--[[=============================================================================
    Status, summary and the alerts tile (the only writers of those properties)
===============================================================================]]
local function SetLastError(text)
	gConn.error = text
	gConn.errorAt = os.time()
	UpdateProperty("Last Error", text and (os.date("%Y-%m-%d %H:%M:%S") .. " - " .. text) or "")
end

local function Problems()
	local offline = {}
	for _, c in ipairs(CameraList()) do
		if not c.disabled and c.online == false then offline[#offline + 1] = c.name or ("#" .. c.id) end
	end
	return offline
end

local function Counts()
	local list = CameraList()
	local active, online, disabled = 0, 0, 0
	for _, c in ipairs(list) do
		if c.disabled then
			disabled = disabled + 1
		else
			active = active + 1
			if c.online then online = online + 1 end
		end
	end
	return list, active, online, disabled
end

UpdateTile = function(force)
	local icon, desc
	local offline = Problems()
	if gState.adding or gConn.state == "connecting" then
		icon, desc = "pending", gState.adding and "Adding cameras" or "Connecting to the console"
	elseif gConn.online == false or #offline > 0 then
		icon = "error"
		desc = gConn.online == false and "The console does not answer" or ("Offline: " .. table.concat(offline, ", "))
	elseif not HubAlertsEnabled() then
		icon = "off"
		desc = os.time() < (gHub.snoozeUntil or 0) and ("Alerts snoozed until " .. os.date("%H:%M", gHub.snoozeUntil)) or "Alerts off"
	elseif gState.alertActive then
		icon, desc = "alert", "Alert: " .. tostring(gState.lastAlertCamera or "")
	else
		icon, desc = "on", "Alerts on"
	end
	if gState.tileIcon == icon and not force then return end
	gState.tileIcon = icon
	pcall(function() C4:SendToProxy(TILE_PROXY, "ICON_CHANGED", { icon = icon, icon_description = desc }, "NOTIFY") end)
end

function OldCameraDrivers()
	if DRIVER_SEMVER == "dev" then return nil end
	local old, version = {}, nil
	for _, c in ipairs(CameraList()) do
		if c.version and c.version ~= "dev" and c.version ~= DRIVER_SEMVER then
			old[#old + 1] = c.name or ("#" .. c.id)
			version = c.version
		end
	end
	if #old == 0 then return nil end
	local who = #old == 1 and ("Camera '" .. old[1] .. "' runs") or (#old .. " cameras run")
	return who .. " camera driver " .. version .. "; the hub is " .. DRIVER_SEMVER .. ". Update " .. CAMERA_DRIVER
		.. " with Driver > Add or Update Driver"
end

local function SocketText()
	local ws = gWs.events
	if not ApiReady() or gConn.state ~= "ok" then return "Not connected" end
	if not ws then return "Not started" end
	if ws.state == "open" then
		return "Live since " .. os.date("%H:%M", ws.openedAt or os.time()) .. " - " .. tostring(ws.messages or 0) .. " messages"
	end
	if TimerActive("WS_RETRY_events") then
		return "Reconnecting" .. (ws.lastReason and (" (" .. ws.lastReason .. ")") or "")
	end
	return "Connecting..."
end

UpdateSummary = function()
	local list, active, online, disabled = Counts()
	SetVar("CAMERAS_TOTAL", #list)
	SetVar("CAMERAS_ONLINE", online)
	local offline = Problems()
	local text
	if #list == 0 then
		text = "No cameras yet"
	else
		text = #list .. " camera" .. (#list == 1 and "" or "s") .. " - " .. online .. " online"
		if disabled > 0 then text = text .. " - " .. disabled .. " disabled" end
		if #offline > 0 then text = text .. " - offline: " .. table.concat(offline, ", ") end
	end
	UpdateProperty("Cameras", text)
	UpdateProperty("Event Connection", SocketText())

	local status
	if not ApiReady() then
		status = "Setup: enter the Console Address and the API Key (UniFi console: Settings > Control Plane > Integrations > Create API Key)"
	elseif gConn.state == "tooOld" or gConn.state == "unauthorized" or gConn.state == "noApi" then
		status = gConn.message or "The console refuses the connection"
	elseif gConn.state == "unreachable" then
		status = "Cannot reach the console at " .. ApiConsole() .. " (" .. tostring(gConn.message or "") .. ") - retrying"
	elseif gConn.state == "connecting" then
		status = "Connecting to the console at " .. ApiConsole() .. "..."
	elseif gPictures.state == "error" then
		status = "The picture server cannot use port " .. tostring(Properties["Picture Server Port"]) .. " (" .. tostring(gPictures.error)
			.. "): choose another Picture Server Port"
	elseif OldCameraDrivers() then
		status = OldCameraDrivers()
	elseif gState.message then
		status = gState.message
	elseif #list == 0 then
		status = "Connected - run Actions > Add New Cameras to add the console's cameras"
	elseif #offline > 0 then
		status = "Attention: offline: " .. table.concat(offline, ", ")
	else
		status = "Connected - " .. online .. " of " .. active .. " cameras online - "
			.. (HubAlertsEnabled() and "alerts on" or (os.time() < (gHub.snoozeUntil or 0) and ("alerts snoozed until " .. os.date("%H:%M", gHub.snoozeUntil)) or "alerts off"))
	end
	UpdateProperty("Status", status)
	SetVar("ALL_ONLINE", active > 0 and online == active)
end

local function SetMessage(msg, transientMs)
	gState.message = msg
	gState.messageTransient = transientMs ~= nil
	if msg and transientMs then
		SetTimer("MESSAGE_CLEAR", transientMs, function()
			gState.message = nil
			UpdateSummary()
		end)
	else
		KillTimer("MESSAGE_CLEAR")
	end
	UpdateSummary()
	UpdateTile()
end

local function SetConsoleOnline(on)
	if gConn.online == on then return end
	local was = gConn.online
	gConn.online = on
	SetVar("CONSOLE_ONLINE", on)
	if was ~= nil then FireEvent(on and "Console Online" or "Console Offline") end
	for id in pairs(gCameras) do SendToDriver(id, "DL_STATE", { CONSOLE = on and "1" or "0" }) end
	UpdateTile()
end

local function UpdatePictureProperty()
	local addr = ControllerAddress() or "?"
	local text
	if gPictures.state == "listening" then
		text = "Listening on " .. addr .. ":" .. tostring(gPictures.port) .. " - " .. gPictures.served .. " pictures served"
			.. (gPictures.refused > 0 and (", " .. gPictures.refused .. " refused (wrong login)") or "")
	elseif gPictures.state == "error" then
		text = "Error on port " .. tostring(Properties["Picture Server Port"]) .. ": " .. tostring(gPictures.error)
	else
		text = "Starting..."
	end
	UpdateProperty("Picture Server", text)
end

--[[=============================================================================
    Console connection: version check, cameras, streams, WebSockets
===============================================================================]]
local OpenSockets, CloseSockets, RefreshCameras -- forward

local function ConsoleProperty()
	local parts = {}
	if gProtect.nvr and gProtect.nvr.name then parts[#parts + 1] = gProtect.nvr.name end
	if gProtect.nvr and gProtect.nvr.model then parts[#parts + 1] = gProtect.nvr.model end
	if gProtect.version then parts[#parts + 1] = "UniFi Protect " .. gProtect.version end
	UpdateProperty("Console", #parts > 0 and table.concat(parts, " - ") or "")
	SetVar("PROTECT_VERSION", gProtect.version or "")
end

-- Results of every API call keep the connection state and the last error honest
local function OnApiResult(method, path, code, body, err, opts)
	-- A slow picture says nothing about the console: only other requests count
	if opts and opts.noHealth then
		if code and code < 300 then
			gConn.failures = 0
			SetConsoleOnline(true)
		end
		return
	end
	if code == nil then
		gConn.failures = (gConn.failures or 0) + 1
		SetLastError(method .. " " .. path .. ": " .. tostring(err))
		if gConn.failures >= 2 then SetConsoleOnline(false) end
	elseif err then
		SetLastError(method .. " " .. path .. ": " .. tostring(err))
	elseif code == 401 or code == 403 then
		SetLastError(method .. " " .. path .. ": HTTP " .. code .. " - the console refused the API key")
	elseif code >= 400 and code ~= 404 then
		SetLastError(method .. " " .. path .. ": " .. ApiErrorText(code, body, nil))
		gConn.failures = 0
		SetConsoleOnline(true)
	else
		gConn.failures = 0
		SetConsoleOnline(true)
	end
end

local function ConnectFailed(state, message, retryMs)
	gConn.state, gConn.message = state, message
	LogError("%s", message)
	SetLastError(message)
	CloseSockets()
	UpdateSummary()
	UpdateTile()
	if retryMs then SetTimer("CONNECT_RETRY", retryMs, function() ConnectConsole("retry") end) end
end

function ConnectConsole(reason)
	KillTimer("CONNECT_RETRY")
	if not ApiConfigure(Properties["Console Address"], Properties["API Key"]) then
		gConn.state = "setup"
		CloseSockets()
		UpdateSummary()
		return
	end
	gConn.state = "connecting"
	UpdateSummary()
	UpdateTile()
	LogInfo("Connecting to the console at %s (%s)", ApiConsole(), reason or "")
	ApiGetJson("/v1/meta/info", function(info, code, err)
		if code == nil then
			return ConnectFailed("unreachable", "Cannot reach the console at " .. ApiConsole() .. ": " .. tostring(err), 60000)
		elseif code == 401 or code == 403 then
			return ConnectFailed("unauthorized", "The console refused the API key (HTTP " .. code .. "). Create a new key in the UniFi console: "
				.. "Settings > Control Plane > Integrations, and paste it into API Key", 30 * 60000)
		elseif code == 404 then
			return ConnectFailed("noApi", "The console at " .. ApiConsole() .. " has no UniFi Protect Integration API (HTTP 404): "
				.. "UniFi Protect is older than 5.3, or not running on this console. Update UniFi Protect to 5.3 or newer", 30 * 60000)
		elseif not info then
			return ConnectFailed("unreachable", "The console's /v1/meta/info answer was not understood: " .. tostring(err), 120000)
		end
		local version = ApiVersionOf(info)
		gProtect.version = version
		ConsoleProperty()
		LogInfo("Console: UniFi Protect %s", tostring(version))
		if not version or not VersionAtLeast(version, MIN_PROTECT) then
			return ConnectFailed("tooOld", "UniFi Protect " .. tostring(version or "(unknown version)") .. " on the console is too old for these drivers: "
				.. "update UniFi Protect to 5.3 or newer", 30 * 60000)
		end
		gConn.state, gConn.message = "ok", nil
		SetConsoleOnline(true)
		UpdateSummary()
		UpdateTile()
		ApiGetJson("/v1/nvrs", function(nvr)
			if type(nvr) == "table" then
				gProtect.nvr = { name = type(nvr.name) == "string" and nvr.name or nil, model = ModelOf(nvr), fields = KeysOf(nvr) }
				ConsoleProperty()
			end
		end)
		RefreshCameras("connect", function()
			OpenSockets()
			-- Settings again (the controller address or port may have changed) and fresh streams
			ConfigureAll()
		end)
	end, { front = true })
end

local function ForwardCameraInfo(deviceId, p)
	if not p then return end
	SendToDriver(deviceId, "DL_STATE", {
		PROTECT_ID = p.id, NAME = p.name, STATE = p.state, KIND = p.kind, MODEL = p.model or "",
		SMART_TYPES = table.concat(p.smartTypes, ","), CONSOLE = gConn.online == false and "0" or "1",
		EVENTS = (gWs.events and gWs.events.state == "open") and "1" or "0",
	})
end

-- GET /v1/cameras: the console's cameras, their names and states
RefreshCameras = function(reason, done)
	ApiGetJson("/v1/cameras", function(list, code, err)
		if type(list) ~= "table" then
			LogWarn("Could not read the cameras (%s): %s", reason or "", tostring(err))
			if done then done(false) end
			return
		end
		local cams, n, doorbells = {}, 0, 0
		local fields, flagFields = {}, {}
		for _, raw in ipairs(list) do
			local p = ParseCamera(raw)
			if p then
				local old = gProtect.cameras[p.id]
				if old and old.ringSeen then p.ringSeen, p.kind = true, "doorbell" end
				cams[p.id] = p
				n = n + 1
				if p.kind == "doorbell" then doorbells = doorbells + 1 end
				for k in pairs(raw) do fields[k] = true end
				for k in pairs(type(raw.featureFlags) == "table" and raw.featureFlags or {}) do flagFields[k] = true end
			end
		end
		gProtect.cameras = cams
		gProtect.fields, gProtect.flagFields = KeysOf(fields), KeysOf(flagFields)
		gProtect.fetchedAt = os.time()
		LogDebug("Cameras: %d (%d doorbells)", n, doorbells)
		for id, c in pairs(gCameras) do
			if c.protectId then ForwardCameraInfo(id, cams[c.protectId]) end
		end
		UpdateFoundSummary(true)
		if ResolvePendingClaims then ResolvePendingClaims() end
		if done then done(true) end
	end, { front = reason == "connect" })
end

--[[------------------------------------------------------------------ Streams
    GET /cameras/{id}/rtsps-stream lists the camera's stream URLs (rtsps://<console>:7441/<token>?enableSrtp);
    a quality that is off is null. With "Create Streams" on Automatic, missing qualities are switched on
    with POST (the same as turning on RTSP for the camera in Protect). The URLs go to the camera driver
    only, over SendToDevice, and are never logged.                                                      ]]
local QUALITIES = { "high", "medium", "low" }

local function SendStreams(deviceId, streams)
	local p = {}
	for _, q in ipairs(QUALITIES) do
		local url = type(streams[q]) == "string" and streams[q] or ""
		p[string.upper(q)] = url
		RegisterSecret(StreamToken(url))
	end
	p.LIVE_VIDEO = LiveVideo()
	SendToDriver(deviceId, "DL_STREAMS", p)
end

local function StreamSummary(streams)
	local have = {}
	for _, q in ipairs(QUALITIES) do
		if type(streams[q]) == "string" and streams[q] ~= "" then have[#have + 1] = q end
	end
	return #have > 0 and table.concat(have, ", ") or "none"
end

function FetchStreams(deviceId, done)
	done = done or function() end
	local c = gCameras[deviceId]
	if not c or not c.protectId or c.disabled then return done() end
	local base = "/v1/cameras/" .. UrlEncode(c.protectId) .. "/rtsps-stream"
	ApiRequest("GET", base, nil, function(code, body, err)
		local streams = {}
		if code == 200 then
			streams = JsonDecode(body) or {}
			if type(streams) ~= "table" then streams = {} end
		elseif code ~= 404 then
			LogWarn("Streams of '%s': %s", tostring(c.name), ApiErrorText(code, body, err))
			return done()
		end
		local missing = {}
		for _, q in ipairs(QUALITIES) do
			if type(streams[q]) ~= "string" or streams[q] == "" then missing[#missing + 1] = q end
		end
		LogDebug("Streams of '%s': %s", tostring(c.name), StreamSummary(streams))
		if #missing == 0 or (Properties["Create Streams"] or "Automatic") ~= "Automatic" then
			SendStreams(deviceId, streams)
			return done()
		end
		local function create(qualities, fallback)
			LogInfo("Switching on the %s stream%s of '%s' in UniFi Protect", table.concat(qualities, ", "), #qualities == 1 and "" or "s", tostring(c.name))
			ApiRequest("POST", base, JsonEncode({ qualities = qualities }), function(pcode, pbody, perr)
				if pcode == 200 then
					local made = JsonDecode(pbody)
					for _, q in ipairs(QUALITIES) do
						if type(made) == "table" and type(made[q]) == "string" then streams[q] = made[q] end
					end
					LogDebug("Streams of '%s' now: %s", tostring(c.name), StreamSummary(streams))
				elseif fallback then
					LogDebug("Creating %s streams failed (%s); trying the high stream alone", table.concat(qualities, ", "), ApiErrorText(pcode, pbody, perr))
					return create(fallback, nil)
				else
					LogWarn("UniFi Protect did not switch on the streams of '%s': %s", tostring(c.name), ApiErrorText(pcode, pbody, perr))
					SetLastError("Streams of '" .. tostring(c.name) .. "': " .. ApiErrorText(pcode, pbody, perr))
				end
				SendStreams(deviceId, streams)
				done()
			end)
		end
		create(missing, (#missing > 1 and (type(streams.high) ~= "string")) and { "high" } or nil)
	end, { retry429 = true })
end

-- One camera at a time, paced
QueueStreams = function(deviceId)
	for _, id in ipairs(gState.streamQueue) do
		if id == deviceId then return end
	end
	table.insert(gState.streamQueue, deviceId)
	if gState.streamBusy then return end
	local function nextOne()
		local id = table.remove(gState.streamQueue, 1)
		if not id then
			gState.streamBusy = false
			return
		end
		gState.streamBusy = true
		FetchStreams(id, function() SetTimer("STREAM_NEXT", STREAM_SPACING_MS, nextOne) end)
	end
	nextOne()
end

--[[------------------------------------------------------------------ WebSockets ]]
local HandleEventMessage, HandleDeviceMessage -- forward

local function SocketHeaders()
	return { "X-API-Key: " .. gApi.key }
end

local function ScheduleSocketRetry(name, httpStatus)
	gState.wsFails[name] = (gState.wsFails[name] or 0) + 1
	local delay = math.min(WS_RETRY_MAX_S, WS_RETRY_MIN_S * (2 ^ math.min(gState.wsFails[name] - 1, 5)))
	if httpStatus == 401 or httpStatus == 403 then delay = 600 end
	LogDebug("WebSocket %s: retry %d in %d s", name, gState.wsFails[name], delay)
	SetTimer("WS_RETRY_" .. name, delay * 1000, function()
		if gConn.state == "ok" and gWs[name] then WsOpen(gWs[name]) end
	end)
end

OpenSockets = function()
	for name, binding in pairs({ events = EVENTS_BINDING, devices = DEVICES_BINDING }) do
		local ws = gWs[name]
		if not ws then
			ws = WsNew({
				name = name, binding = binding, host = gApi.host, port = gApi.port,
				path = PROTECT_BASE .. "/subscribe/" .. name, headers = SocketHeaders,
				onOpen = function(sock)
					gState.wsFails[name] = 0
					LogInfo("Event stream %s connected", name)
					SetConsoleOnline(true)
					if name == "events" then
						for id in pairs(gCameras) do SendToDriver(id, "DL_STATE", { EVENTS = "1" }) end
					end
					UpdateSummary()
				end,
				onMessage = function(sock, text)
					if name == "events" then HandleEventMessage(text) else HandleDeviceMessage(text) end
				end,
				onClose = function(sock, reason, httpStatus)
					LogWarn("Event stream %s closed: %s", name, tostring(reason))
					if httpStatus == 401 or httpStatus == 403 then SetLastError("WebSocket " .. name .. ": the console refused the API key (HTTP " .. httpStatus .. ")")
					else SetLastError("WebSocket " .. name .. ": " .. tostring(reason)) end
					if name == "events" then
						for id in pairs(gCameras) do SendToDriver(id, "DL_STATE", { EVENTS = "0" }) end
					end
					ScheduleSocketRetry(name, httpStatus)
					UpdateSummary()
				end,
			})
			gWs[name] = ws
		end
		ws.host, ws.port = gApi.host, gApi.port
		KillTimer("WS_RETRY_" .. name)
		if ws.state ~= "open" then WsOpen(ws) end
	end
	UpdateSummary()
end

CloseSockets = function()
	for name, ws in pairs(gWs) do
		KillTimer("WS_RETRY_" .. name)
		WsClose(ws)
	end
end

--[[------------------------------------------------------------------ Events from the console ]]
local function RememberEvent(e)
	gEvents[#gEvents + 1] = e
	while #gEvents > EVENT_HISTORY do table.remove(gEvents, 1) end
end

-- Event ids seen lately (add, then update with "end": one event)
local function SeenBefore(id, action)
	if not id then return false end
	local key = id .. ":" .. action
	if gState.seenEvents[key] then return true end
	gState.seenEvents[key] = true
	table.insert(gState.seenOrder, key)
	while #gState.seenOrder > 400 do gState.seenEvents[table.remove(gState.seenOrder, 1)] = nil end
	return false
end

local CAMERA_EVENTS = { ring = true, motion = true, smartDetectZone = true, smartDetectLine = true,
	smartDetectLoiterZone = true, smartAudioDetect = true }

HandleEventMessage = function(text)
	local msg, err = JsonDecode(text)
	if type(msg) ~= "table" then
		LogDebug("Event message not understood (%s): %s", tostring(err), string.sub(text, 1, 120))
		return
	end
	local item = type(msg.item) == "table" and msg.item or nil
	if not item then
		LogDebug("Event message without an item (fields: %s)", table.concat(KeysOf(msg), ", "))
		return
	end
	local action = tostring(msg.type or "?")
	local etype = tostring(item.type or "?")
	local device = type(item.device) == "string" and item.device or nil
	local p = device and gProtect.cameras[device] or nil
	local types = StringList(item.smartDetectTypes)
	local started = tonumber(item.start)
	local ended = tonumber(item["end"])
	LogDebug("Event %s %s%s on %s (event %s, camera %s)%s", action, etype, #types > 0 and (" [" .. table.concat(types, ",") .. "]") or "",
		p and p.name or "an unknown device", tostring(item.id), tostring(device), ended and " - ended" or "")
	RememberEvent({ at = os.time(), action = action, type = etype, device = device, name = p and p.name or nil,
		types = table.concat(types, ","), id = item.id, ended = ended ~= nil })
	if not CAMERA_EVENTS[etype] or not device then return end
	if SeenBefore(item.id, action .. ":" .. table.concat(types, ",") .. (ended and ":end" or "")) then
		LogDebug("Event %s already handled", tostring(item.id))
		return
	end
	if etype == "ring" and p and not p.ringSeen then
		p.ringSeen = true
		if p.kind ~= "doorbell" then
			p.kind, p.kindWhy = "doorbell", "it rang"
			LogInfo("'%s' rang: it is a doorbell", tostring(p.name))
		end
	end
	local targets = DevicesFor(device)
	if #targets == 0 then
		LogDebug("No camera driver for UniFi camera %s yet (run Add New Cameras)", device)
		return
	end
	for _, id in ipairs(targets) do
		SendToDriver(id, "DL_EVENT", {
			ACTION = action, TYPE = etype, ID = tostring(item.id or ""), TYPES = table.concat(types, ","),
			START = started and string.format("%.0f", started) or "", ["END"] = ended and string.format("%.0f", ended) or "",
		})
	end
end

HandleDeviceMessage = function(text)
	local msg = JsonDecode(text)
	if type(msg) ~= "table" or type(msg.item) ~= "table" then return end
	local item, action = msg.item, tostring(msg.type or "?")
	if item.modelKey ~= "camera" or type(item.id) ~= "string" then
		LogTrace("Device %s for a %s", action, tostring(item.modelKey))
		return
	end
	local p = gProtect.cameras[item.id]
	LogDebug("Device %s: camera %s (%s)%s", action, item.id, p and p.name or tostring(item.name or "new"),
		item.state and (" state " .. tostring(item.state)) or "")
	if action == "remove" then
		gProtect.cameras[item.id] = nil
		for _, id in ipairs(DevicesFor(item.id)) do SendToDriver(id, "DL_STATE", { STATE = "REMOVED" }) end
		UpdateFoundSummary(true)
		return
	end
	if action == "add" then
		local np = ParseCamera(item)
		if np then gProtect.cameras[np.id] = np end
		UpdateFoundSummary(true)
		return
	end
	if not p then
		-- An update for a camera not seen yet: read the list again
		SetTimer("CAMERAS_AGAIN", 3000, function() RefreshCameras("device update") end)
		return
	end
	local changed = false
	if type(item.state) == "string" and item.state ~= p.state then p.state, changed = item.state, true end
	if type(item.name) == "string" and item.name ~= "" and item.name ~= p.rawName then p.rawName, p.name, changed = item.name, item.name, true end
	if type(item.featureFlags) == "table" and type(item.featureFlags.smartDetectTypes) == "table" then
		p.smartTypes, changed = StringList(item.featureFlags.smartDetectTypes), true
	end
	if changed then
		for _, id in ipairs(DevicesFor(item.id)) do ForwardCameraInfo(id, p) end
	end
end

--[[=============================================================================
    Pictures for the picture server (pictures.lua) and notifications
===============================================================================]]
function PictureLogin(deviceId)
	local c = gCameras[tonumber(deviceId)]
	if not c or c.disabled then return nil end
	local user, pass = PictureCredentials(c.id)
	return user, pass, c.protectId
end

PICTURE_QUEUE_LIMIT = 24

function PictureFetch(protectId, high, cb)
	-- A slow or absent console must not pile up requests: answer "busy" at once
	if ApiQueueLength() >= PICTURE_QUEUE_LIMIT then return cb(429, nil, "too many pictures waiting for the console") end
	local path = "/v1/cameras/" .. UrlEncode(protectId) .. "/snapshot" .. (high and "?highQuality=true" or "")
	ApiRequest("GET", path, nil, function(code, body, err)
		if code == 200 and type(body) == "string" and #body > 0 then return cb(200, body) end
		cb(code, nil, ApiErrorText(code, body, err))
	end, { accept = "image/jpeg", timeout = 12, noHealth = true })
end

--[[=============================================================================
    Cameras in the project
===============================================================================]]
function PruneDeleted()
	local ok, devs = pcall(function() return C4:GetDevicesByC4iName(CAMERA_DRIVER) end)
	local listed = {}
	if ok and type(devs) == "table" then
		for k, v in pairs(devs) do
			local id = tonumber(v) or tonumber(k)
			if id then listed[id] = true end
		end
	end
	local trusted = false
	for id in pairs(gCameras) do
		if listed[id] then trusted = true break end
	end
	local changed = false
	for id in pairs(gCameras) do
		if not listed[id] then
			local gone = trusted
			if not gone then
				local okName, name = pcall(function() return C4:GetDeviceDisplayName(id) end)
				gone = not okName or name == nil or name == ""
			end
			if gone then
				LogInfo("Camera device %d was removed from the project", id)
				gCameras[id] = nil
				changed = true
			end
		end
	end
	if changed then
		SaveState()
		UpdateSummary()
		UpdateFoundSummary()
	end
	return listed
end

local function IgnoredCameras()
	local set = {}
	for item in string.gmatch(Properties["Ignored Cameras"] or "", "[^,;]+") do
		item = string.lower(trim(item))
		if item ~= "" then set[item] = true end
	end
	return set
end

local function InProject(protectId)
	for _, c in pairs(gCameras) do
		if c.protectId == protectId then return true end
	end
	return false
end

-- Protect cameras not in the project yet (and not ignored), sorted by name
function NewCandidates()
	local new, ignored, skip = {}, 0, IgnoredCameras()
	for id, p in pairs(gProtect.cameras) do
		if not InProject(id) then
			if skip[string.lower(id)] or skip[string.lower(p.name or "")] then ignored = ignored + 1 else new[#new + 1] = p end
		end
	end
	table.sort(new, function(a, b) return tostring(a.name) < tostring(b.name) end)
	return new, ignored
end

UpdateFoundSummary = function(fromConsole)
	if not gProtect.fetchedAt then
		UpdateProperty("Found On Console", "")
		return nil
	end
	local cams, bells = 0, 0
	for _, p in pairs(gProtect.cameras) do
		if p.kind == "doorbell" then bells = bells + 1 else cams = cams + 1 end
	end
	local new, ignored = NewCandidates()
	local text = cams .. " camera" .. (cams == 1 and "" or "s")
	if bells > 0 then text = text .. ", " .. bells .. " doorbell" .. (bells == 1 and "" or "s") end
	text = text .. " - " .. #new .. " not added yet"
	if ignored > 0 then text = text .. " - " .. ignored .. " ignored" end
	UpdateProperty("Found On Console", text)
	if fromConsole and #new > 0 and gState.lastNewCount ~= nil and #new > gState.lastNewCount then FireEvent("New Cameras Found") end
	gState.lastNewCount = #new
	UpdateSummary()
	return text, new
end

local function UniqueName(name, exceptId)
	local used = {}
	for id, c in pairs(gCameras) do
		if c.name and id ~= exceptId then used[c.name] = true end
	end
	if not used[name] then return name end
	local n = 2
	while used[name .. " " .. n] do n = n + 1 end
	return name .. " " .. n
end

ConfigureCamera = function(id, extra)
	local c = gCameras[id]
	if not c then return end
	local p = c.protectId and gProtect.cameras[c.protectId] or nil
	local user, pass = PictureCredentials(id)
	local params = {
		HUB_ID = MyDeviceId(), HUB_ALERTS = HubAlertsEnabled() and "1" or "0",
		PROTECT_ID = c.protectId or "", NAME = c.name or (p and p.name) or "",
		KIND = p and p.kind or "", MODEL = p and p.model or "", STATE = p and p.state or "",
		SMART_TYPES = p and table.concat(p.smartTypes, ",") or "",
		SERVER_ADDRESS = ControllerAddress() or "", SERVER_PORT = PictureServerPort(),
		PIC_USER = user, PIC_PASS = pass, LIVE_VIDEO = LiveVideo(), CONSOLE_HOST = gApi.host,
		CONSOLE = gConn.online == false and "0" or "1",
		EVENTS = (gWs.events and gWs.events.state == "open") and "1" or "0",
		LOG_LEVEL = Properties["Log Level"] or "",
	}
	for k, v in pairs(extra or {}) do params[k] = v end
	c.configuredAt = os.time()
	LogDebug("Configuring camera %d ('%s', UniFi camera %s)", id, tostring(params.NAME), tostring(params.PROTECT_ID))
	SendToDriver(id, "DL_CONFIGURE", params)
	if c.protectId and gConn.state == "ok" then QueueStreams(id) end
end

function ConfigureAll()
	local n = 0
	for id, c in pairs(gCameras) do
		if c.protectId then
			ConfigureCamera(id)
			n = n + 1
		end
	end
	LogInfo("Settings sent to %d cameras", n)
	return n
end

local function AddNext()
	local p = table.remove(gState.addQueue, 1)
	if not p then
		gState.adding = false
		SaveState()
		UpdateFoundSummary()
		SetMessage(gState.addedCount > 0
			and ("Added " .. gState.addedCount .. " camera" .. (gState.addedCount == 1 and "" or "s") .. " - drag them to their rooms in Composer")
			or nil, 120000)
		return
	end
	local total = gState.addedCount + #gState.addQueue + 1
	SetMessage("Adding cameras: " .. (gState.addedCount + 1) .. " of " .. total .. "...")
	local name = UniqueName(p.name)
	local room = nil
	pcall(function() room = C4:RoomGetId() end)
	local answered = false
	SetTimer("ADD_WATCHDOG", ADD_WATCHDOG_MS, function()
		if answered then return end
		gState.addQueue = {}
		gState.adding = false
		LogError("Director did not answer when adding '%s'", name)
		SetMessage("Adding cameras stopped: Director did not add '" .. name .. "'. Check that " .. CAMERA_DRIVER
			.. " is uploaded (Driver > Add or Update Driver), then run Add New Cameras again")
	end)
	local ok, err = pcall(function()
		local function onAdded(deviceId)
			if answered then return end
			answered = true
			KillTimer("ADD_WATCHDOG")
			deviceId = tonumber(deviceId)
			if not deviceId or deviceId == 0 then
				gState.addQueue = {}
				gState.adding = false
				SetMessage("Could not add the camera driver. Upload " .. CAMERA_DRIVER .. " with Driver > Add or Update Driver, then run Add New Cameras again")
				return
			end
			LogInfo("Added '%s' as device %d (UniFi camera %s, %s)", name, deviceId, p.id, p.kind)
			gCameras[deviceId] = { id = deviceId, name = name, protectId = p.id, managed = true }
			gState.addedCount = gState.addedCount + 1
			SaveState()
			-- Give the new driver time to start, then send its settings (twice, it is idempotent)
			SetTimer("CONFIGURE_" .. deviceId, CONFIGURE_DELAY_MS, function()
				ConfigureCamera(deviceId, { RENAME = "1", ALERT_ON = Properties["Default Alert On"] or "Any detection" })
			end)
			SetTimer("CONFIGURE2_" .. deviceId, CONFIGURE_DELAY_MS * 3, function()
				local cam = gCameras[deviceId]
				if cam and not cam.reported then ConfigureCamera(deviceId, { RENAME = "1" }) end
			end)
			SetTimer("CONFIGURE_CHECK_" .. deviceId, CONFIGURE_DELAY_MS * 6, function()
				local cam = gCameras[deviceId]
				if cam and not cam.reported then
					SetMessage("Camera '" .. tostring(cam.name) .. "' does not answer the hub. Update " .. CAMERA_DRIVER
						.. " (Driver > Add or Update Driver) to version " .. DRIVER_SEMVER .. ", delete the cameras that do not answer, and run Add New Cameras again")
				end
			end)
			UpdateSummary()
			SetTimer("ADD_NEXT", ADD_SPACING_MS, AddNext)
		end
		if room then C4:AddDevice(CAMERA_DRIVER, room, name, onAdded) else C4:AddDevice(CAMERA_DRIVER, onAdded) end
	end)
	if not ok then
		KillTimer("ADD_WATCHDOG")
		gState.addQueue = {}
		gState.adding = false
		SetMessage("Adding cameras failed: " .. tostring(err))
	end
end

function AddNewCameras()
	if gState.adding then return end
	PruneDeleted()
	if gConn.state ~= "ok" then
		SetMessage("Not connected to the console yet: check Status, then run Add New Cameras again", 120000)
		return
	end
	if not ControllerAddress() then
		SetMessage("The controller's address is unknown, so cameras cannot get their pictures. Check the controller's network settings")
		return
	end
	RefreshCameras("add", function(ok)
		if not ok then
			SetMessage("Could not read the console's cameras - see Last Error", 120000)
			return
		end
		local new = NewCandidates()
		if #new == 0 then
			SetMessage("No new cameras to add", 60000)
			return
		end
		gState.addQueue = new
		gState.addedCount = 0
		gState.adding = true
		UpdateTile()
		AddNext()
	end)
end

function UpdateCameraNames()
	local renamed = 0
	for id, c in pairs(gCameras) do
		local p = c.protectId and gProtect.cameras[c.protectId] or nil
		if c.managed and p and p.name and p.name ~= c.name then
			c.name = UniqueName(p.name, id)
			renamed = renamed + 1
			LogInfo("Renaming camera %d to %s", id, c.name)
			ConfigureCamera(id, { RENAME = "1" })
		end
	end
	SaveState()
	SetMessage("Camera names updated: " .. renamed .. " renamed", 120000)
end

--[[=============================================================================
    Messages from camera drivers
===============================================================================]]
-- Fire an event once this camera's picture is in (for the notification attachment), or after
-- PICTURE_WAIT_MS: the picture attached is always this alert's, never the previous one's
local function FireWithPicture(event, c)
	gState.alertSnapshot = nil
	gState.pictureSeq = (gState.pictureSeq or 0) + 1
	local seq, fired = gState.pictureSeq, false
	local function fire()
		if fired then return end
		fired = true
		KillTimer("PICTURE_WAIT")
		FireEvent(event)
	end
	if (Properties["Snapshot With Alerts"] or "Yes") ~= "Yes" or not c or not c.protectId then return fire() end
	SetTimer("PICTURE_WAIT", PICTURE_WAIT_MS, fire)
	PictureFetch(c.protectId, true, function(code, jpeg)
		if seq == gState.pictureSeq and code == 200 and IsJpeg(jpeg) then
			gState.alertSnapshot = jpeg
			LogDebug("Notification picture from '%s' (%s)", tostring(c.name), ByteSize(#jpeg))
		end
		if seq == gState.pictureSeq then fire() end
	end)
end

-- A camera that names its UniFi camera itself (added by hand): match a Protect id or name
local function ResolveClaim(text)
	text = trim(text or "")
	if text == "" then return nil end
	if gProtect.cameras[text] then return text end
	local lower, found = string.lower(text), nil
	for id, p in pairs(gProtect.cameras) do
		if string.lower(p.name or "") == lower then
			if found then return nil, "two UniFi cameras are named '" .. text .. "'; use the camera id" end
			found = id
		end
	end
	return found
end

function ResolvePendingClaims()
	for id, c in pairs(gCameras) do
		local claim = c.pendingClaim
		if claim then
			c.pendingClaim = nil
			local pid, why = ResolveClaim(claim)
			if pid and pid == c.protectId then
				ConfigureCamera(id)
			elseif pid then
				LogInfo("Camera %d ('%s') linked to UniFi camera '%s' (%s)", id, tostring(c.name), tostring(gProtect.cameras[pid].name), pid)
				c.protectId, c.managed = pid, true
				SaveState()
				ConfigureCamera(id)
			else
				SendToDriver(id, "DL_CLAIM_FAILED", { TEXT = why or ("No UniFi camera named '" .. claim .. "' on the console") })
			end
		end
	end
end

local function CameraStatus(p)
	local id = tonumber(p.DEVICE_ID)
	if not id then return end
	local c = gCameras[id]
	if not c then
		c = { id = id, managed = false }
		gCameras[id] = c
	end
	local wasOnline = c.online
	c.reported = true
	c.name = (p.NAME and p.NAME ~= "") and p.NAME or c.name
	c.proxyId = tonumber(p.PROXY_ID) or c.proxyId
	c.version = p.VERSION
	c.kind = p.KIND
	c.status = p.STATUS
	if p.DISABLED then c.disabled = p.DISABLED == "1" end
	if not c.protectId and p.PROTECT_ID and p.PROTECT_ID ~= "" then
		c.protectId = p.PROTECT_ID
		c.managed = true
		LogInfo("Camera %d ('%s') is UniFi camera %s", id, tostring(c.name), c.protectId)
	end
	local claim = trim(p.CLAIM or "")
	if claim ~= "" then
		c.pendingClaim = claim
		if gProtect.fetchedAt then
			ResolvePendingClaims()
		else
			LogInfo("Camera %d asks for the UniFi camera '%s': linked once the hub reads the console's cameras", id, claim)
		end
	elseif p.NEED_CONFIG == "1" and c.protectId and os.time() - (c.configuredAt or 0) > 60 then
		LogInfo("Camera '%s' asks for its settings", tostring(c.name))
		ConfigureCamera(id)
	elseif p.NEED_STREAMS == "1" and c.protectId and os.time() - (c.streamsAskedAt or 0) > 30 then
		c.streamsAskedAt = os.time()
		QueueStreams(id)
	end
	if c.disabled then
		c.online = nil
	elseif p.ONLINE == "1" then c.online = true elseif p.ONLINE == "0" then c.online = false end
	if wasOnline == true and c.online == false then
		SetSavedVar("LAST_OFFLINE_CAMERA", c.name or "")
		FireEvent("Camera Offline")
	elseif wasOnline == false and c.online == true then
		FireEvent("Camera Online")
	end
	SaveState()
	UpdateSummary()
	UpdateTile()
	UpdateFoundSummary()
end

local function AlertClear()
	gState.alertActive = false
	SetVar("ALERT_ACTIVE", false)
	UpdateTile()
end

local function CameraAlert(p)
	local id = tonumber(p.DEVICE_ID)
	local c = id and gCameras[id] or {}
	local name = p.NAME or c.name or "Camera"
	gState.lastAlertCamera, gState.lastAlertType, gState.lastAlertId = name, p.TYPE or "", id
	gState.alertActive = true
	SetVar("ALERT_ACTIVE", true)
	SetVar("LAST_ALERT_CAMERA", name)
	SetVar("LAST_ALERT_TYPE", p.TYPE or "")
	SetSavedVar("LAST_ALERT_TIME", p.TIME or IsoUtc())
	FireWithPicture("Camera Alert", c)
	UpdateTile()
	SetTimer("ALERT_CLEAR", 30000, AlertClear)
end

local function CameraRing(p)
	local id = tonumber(p.DEVICE_ID)
	local c = id and gCameras[id] or {}
	local name = p.NAME or c.name or "Doorbell"
	gState.lastAlertId = id
	SetVar("LAST_RING_CAMERA", name)
	SetSavedVar("LAST_RING_TIME", p.TIME or IsoUtc())
	FireWithPicture("Doorbell Ring", c)
end

local function HelloCameras()
	local found = PruneDeleted()
	for id in pairs(gCameras) do found[id] = true end
	for id in pairs(found) do
		SendToDriver(id, "DL_HUB_HELLO", { HUB_ID = MyDeviceId(), HUB_ALERTS = HubAlertsEnabled() and "1" or "0" })
	end
	SaveState()
	UpdateSummary()
end

--[[=============================================================================
    Print Diagnostics: everything a log needs to tell what the console does
===============================================================================]]
local function Ago(t)
	if not t then return "never" end
	local s = os.time() - t
	if s < 120 then return s .. " s ago" end
	if s < 7200 then return math.floor(s / 60) .. " min ago" end
	return math.floor(s / 3600) .. " h ago"
end

function PrintDiagnostics()
	local lines = { "===== UniFi Protect Hub - diagnostics =====" }
	local function add(...) lines[#lines + 1] = string.format(...) end
	local v = ControllerVersion()
	add("Hub driver      : %s (%s), Control4 OS %s", DRIVER_SEMVER, tostring(Properties["Driver Version"]), v and v.text or "?")
	add("Status          : %s", tostring(Properties["Status"]))
	add("Last error      : %s", (Properties["Last Error"] or "") ~= "" and Properties["Last Error"] or "none")
	add("Console address : %s   API key: %s", ApiConsole() ~= "" and ApiConsole() or "(not set)",
		gApi.key ~= "" and ("set, " .. #gApi.key .. " characters") or "NOT SET")
	add("Picture server  : %s (controller %s)", tostring(Properties["Picture Server"]), tostring(ControllerAddress()))
	add("Live video      : %s   Create Streams: %s", LiveVideo(), tostring(Properties["Create Streams"]))
	local steps = {}
	local function nextStep()
		local s = table.remove(steps, 1)
		if s then s() end
	end
	steps[#steps + 1] = function()
		ApiGetJson("/v1/meta/info", function(info, code, err, ms)
			local version = info and ApiVersionOf(info)
			add("GET /v1/meta/info : %s in %s ms - UniFi Protect %s%s", code and ("HTTP " .. code) or tostring(err), tostring(ms),
				tostring(version or "?"), version and (VersionAtLeast(version, MIN_PROTECT) and " (supported)" or " (TOO OLD: needs 5.3 or newer)") or "")
			if err and code then add("                    %s", err) end
			nextStep()
		end, { front = true })
	end
	steps[#steps + 1] = function()
		ApiGetJson("/v1/nvrs", function(nvr, code, err, ms)
			if type(nvr) == "table" then
				add("GET /v1/nvrs      : HTTP %s in %s ms - name '%s', model %s", tostring(code), tostring(ms), tostring(nvr.name),
					tostring(ModelOf(nvr) or "not reported by the API"))
				add("                    fields: %s", table.concat(KeysOf(nvr), ", "))
			else
				add("GET /v1/nvrs      : %s", tostring(err))
			end
			nextStep()
		end, { front = true })
	end
	steps[#steps + 1] = function()
		ApiGetJson("/v1/cameras", function(list, code, err, ms)
			if type(list) ~= "table" then
				add("GET /v1/cameras   : %s", tostring(err))
				return nextStep()
			end
			add("GET /v1/cameras   : HTTP %s in %s ms - %d cameras", tostring(code), tostring(ms), #list)
			local fields, flags = {}, {}
			local parsed = {}
			for _, raw in ipairs(list) do
				for k in pairs(type(raw) == "table" and raw or {}) do fields[k] = true end
				for k in pairs(type(raw) == "table" and type(raw.featureFlags) == "table" and raw.featureFlags or {}) do flags[k] = true end
				-- Listed with their null fields; parsed without them
				for k, v in pairs(type(raw) == "table" and raw or {}) do
					if v == JSON_NULL then raw[k] = nil end
				end
				local p = ParseCamera(raw)
				if p then
					local known = gProtect.cameras[p.id]
					if known and known.ringSeen then p.kind, p.kindWhy = "doorbell", "it rang" end
					parsed[#parsed + 1] = p
				end
			end
			add("                    camera fields: %s", table.concat(KeysOf(fields), ", "))
			add("                    featureFlags : %s", table.concat(KeysOf(flags), ", "))
			local i = 0
			local function nextCamera()
				i = i + 1
				local p = parsed[i]
				if not p then return nextStep() end
				local devices = DevicesFor(p.id)
				ApiRequest("GET", "/v1/cameras/" .. UrlEncode(p.id) .. "/rtsps-stream", nil, function(scode, sbody, serr)
					local streams = "?"
					if scode == 200 then streams = StreamSummary(JsonDecode(sbody) or {})
					elseif scode == 404 then streams = "none (RTSP is off for this camera)"
					else streams = ApiErrorText(scode, sbody, serr) end
					add("  - '%s'  id %s  model %s  %s  %s%s", p.name, p.id, tostring(p.model or "-"), p.state, p.kind, p.kindWhy and (" (" .. p.kindWhy .. ")") or "")
					add("      smart detections: %s (on: %s)%s  streams: %s  %s", #p.smartTypes > 0 and table.concat(p.smartTypes, ", ") or "none",
						#p.smartEnabled > 0 and table.concat(p.smartEnabled, ", ") or "none",
						#p.audioTypes > 0 and ("  audio: " .. table.concat(p.audioTypes, ", ")) or "", streams,
						#devices > 0 and ("in Control4 as device " .. table.concat(devices, ", ")) or "NOT IN THE PROJECT")
					SetTimer("DIAG_NEXT", 300, nextCamera)
				end, { quiet = false, retry429 = true })
			end
			nextCamera()
		end, { front = true, keepNull = true })
	end
	steps[#steps + 1] = function()
		for _, name in ipairs({ "events", "devices" }) do
			local ws = gWs[name]
			if ws then
				add("WebSocket %-7s: %s, opened %s, %d messages, last %s%s", name, ws.state, Ago(ws.openedAt), ws.messages or 0,
					Ago(ws.lastMessageAt), ws.lastReason and (", last close: " .. ws.lastReason) or "")
			else
				add("WebSocket %-7s: not started", name)
			end
		end
		add("Last %d events from the console (oldest first):", EVENT_HISTORY)
		if #gEvents == 0 then add("  (none yet)") end
		for _, e in ipairs(gEvents) do
			add("  %s  %-6s %-22s %-20s camera %s  event %s%s", os.date("%H:%M:%S", e.at), e.action, e.type .. (e.types ~= "" and ("[" .. e.types .. "]") or ""),
				tostring(e.name or "?"), tostring(e.device), tostring(e.id), e.ended and "  ended" or "")
		end
		add("Cameras in the project:")
		for _, c in ipairs(CameraList()) do
			add("  device %-6s %-24s UniFi %s  %s%s  driver %s", tostring(c.id), tostring(c.name), tostring(c.protectId or "-"),
				c.disabled and "DISABLED" or (c.online == true and "online" or (c.online == false and "OFFLINE" or "?")),
				c.kind and ("  " .. c.kind) or "", tostring(c.version or "?"))
		end
		add("============================================")
		PrintReport(lines)
	end
	if not ApiReady() then
		add("Not configured: enter the Console Address and API Key")
		add("============================================")
		return PrintReport(lines)
	end
	nextStep()
end

--[[=============================================================================
    DriverWorks entry points
===============================================================================]]
local VARIABLES = {
	{ "ALERTS_ENABLED", "1", "BOOL" },
	{ "ALERT_ACTIVE", "0", "BOOL" },
	{ "ALL_ONLINE", "0", "BOOL" },
	{ "CONSOLE_ONLINE", "0", "BOOL" },
	{ "CAMERAS_TOTAL", "0", "NUMBER" },
	{ "CAMERAS_ONLINE", "0", "NUMBER" },
	{ "LAST_ALERT_CAMERA", "", "STRING" },
	{ "LAST_ALERT_TYPE", "", "STRING" },
	{ "LAST_ALERT_TIME", "", "STRING" },
	{ "LAST_RING_CAMERA", "", "STRING" },
	{ "LAST_RING_TIME", "", "STRING" },
	{ "LAST_OFFLINE_CAMERA", "", "STRING" },
	{ "PROTECT_VERSION", "", "STRING" },
}

local function StartPictures()
	gPictures.onState = function()
		UpdatePictureProperty()
		UpdateSummary()
	end
	PictureServerStart(tonumber(Properties["Picture Server Port"]) or 47080)
	UpdatePictureProperty()
	SetTimer("PICTURE_PROPERTY", 60000, UpdatePictureProperty, true)
end

local ACTIONS = {
	Refresh = function() ConnectConsole("action") end,
	AddCameras = function() AddNewCameras() end,
	UpdateNames = function() UpdateCameraNames() end,
	SendSettings = function()
		local n = ConfigureAll()
		SetMessage("Settings sent to " .. n .. " camera" .. (n == 1 and "" or "s"), 60000)
	end,
	Diagnostics = PrintDiagnostics,
}

local COMMANDS = {
	SET_ALERTS = function(p)
		local s = string.upper(p["State"] or "TOGGLE")
		if s == "ON" then SetAlerts(true, "programming")
		elseif s == "OFF" then SetAlerts(false, "programming")
		else SetAlerts(not HubAlertsEnabled(), "programming") end
	end,
	SNOOZE_ALERTS = function(p) SnoozeAlerts(p["Minutes"], "programming") end,
	REFRESH = function() ConnectConsole("programming") end,
	DL_CAMERA_STATUS = CameraStatus,
	DL_CAMERA_ALERT = CameraAlert,
	DL_CAMERA_RING = CameraRing,
}

local function ShowDriverVersion()
	local build = ""
	pcall(function() build = tostring(C4:GetDriverConfigInfo("version") or "") end)
	UpdateProperty("Driver Version", DRIVER_SEMVER ~= "dev" and (DRIVER_SEMVER .. " (" .. build .. ")") or build)
end

function OnDriverInit()
	math.randomseed(os.time())
	LoadState()
	for _, v in ipairs(VARIABLES) do
		local saved = gHub.savedVars and gHub.savedVars[v[1]]
		if type(saved) == "string" then v[2] = saved end
	end
	AddVariables(VARIABLES)
	gState.lastAlertType = GetVar("LAST_ALERT_TYPE")
end

function OnDriverLateInit()
	ApplyLogSettings()
	ShowDriverVersion()
	gApi.onResult = OnApiResult
	ApiConfigure(Properties["Console Address"], Properties["API Key"])
	local v = ControllerVersion()
	LogInfo("Starting %s on Control4 OS %s", DRIVER_SEMVER, v and v.text or "?")
	AlertsChanged("startup")
	UpdateTile(true)
	HelloCameras()
	StartPictures()
	SetTimer("REFRESH_CAMERAS", REFRESH_INTERVAL_MS, function()
		if gConn.state == "ok" then
			RefreshCameras("periodic")
			for name, ws in pairs(gWs) do
				if ws.state == "closed" and not TimerActive("WS_RETRY_" .. name) then WsOpen(ws) end
			end
		end
	end, true)
	if ApiReady() then SetTimer("STARTUP_CONNECT", 3000, function() ConnectConsole("startup") end) else UpdateSummary() end
end

function OnDriverDestroyed()
	CloseSockets()
	PictureServerStop()
	KillAllTimers()
end

function OnPropertyChanged(name)
	if name == "Log Level" then
		ApplyLogSettings()
		for id in pairs(gCameras) do SendToDriver(id, "DL_LOG_LEVEL", { LOG_LEVEL = Properties["Log Level"] }) end
	elseif name == "Alerts" then
		gHub.snoozeUntil = 0
		SaveState()
		AlertsChanged("Composer")
	elseif name == "Console Address" or name == "API Key" then
		CloseSockets()
		gWs = {}
		gProtect.cameras, gProtect.fetchedAt = {}, nil
		SetTimer("CONNECT_CHANGED", 2000, function()
			ConnectConsole("settings changed")
		end)
		UpdateSummary()
	elseif name == "Ignored Cameras" then
		UpdateFoundSummary()
	elseif name == "Live Video" then
		for id, c in pairs(gCameras) do
			if c.protectId then SendToDriver(id, "DL_STATE", { LIVE_VIDEO = LiveVideo() }) end
		end
		LogInfo("Live video: %s", LiveVideo())
	elseif name == "Create Streams" then
		if (Properties["Create Streams"] or "") == "Automatic" then
			for id, c in pairs(gCameras) do
				if c.protectId then QueueStreams(id) end
			end
		end
	elseif name == "Picture Server Port" then
		StartPictures()
		SetTimer("SEND_PORT", 3000, ConfigureAll)
	end
end

function ReceivedFromProxy(idBinding, strCommand)
	if idBinding == TILE_PROXY and strCommand == "SELECT" then
		SetAlerts(not HubAlertsEnabled(), "hub tile")
	end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	WsReceived(idBinding, strData)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	WsStatus(idBinding, strStatus)
end

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	if strCommand == "LUA_ACTION" then
		local action = ACTIONS[tParams.ACTION]
		if action then
			local ok, err = pcall(action)
			if not ok then LogError("Action %s failed: %s", tostring(tParams.ACTION), err) end
		end
		return
	end
	local cmd = COMMANDS[strCommand]
	if cmd then
		if string.sub(strCommand, 1, 3) ~= "DL_" then LogInfo("Command %s", strCommand) end
		local ok, err = pcall(cmd, tParams)
		if not ok then LogError("Command %s failed: %s", strCommand, err) end
	end
end

function TestCondition(name, tParams)
	tParams = tParams or {}
	if name == "ALERTS_ENABLED" then return TestBool(HubAlertsEnabled(), tParams, "On")
	elseif name == "ALERT_ACTIVE" then return TestBool(gState.alertActive, tParams, "Active")
	elseif name == "CONSOLE_ONLINE" then return TestBool(gConn.online == true, tParams, "Online")
	elseif name == "ALL_ONLINE" then
		local _, active, online = Counts()
		return TestBool(active > 0 and online == active, tParams, "Online")
	elseif name == "LAST_ALERT_TYPE" then
		return TestEquals(gState.lastAlertType or "", tParams)
	end
	return false
end

-- Notification attachments: the camera that raised the last alert or ring
function GetNotificationAttachmentBytes()
	if gState.alertSnapshot then return Base64Encode(gState.alertSnapshot) end
	return ""
end

-- A short-lived token in the URL, so the camera's own picture login never leaves the driver
function GetNotificationAttachmentURL()
	local id = gState.lastAlertId
	local addr = ControllerAddress()
	if not id or not gCameras[id] or not addr then return "" end
	return "http://" .. addr .. ":" .. PictureServerPort() .. "/snapshot/" .. id .. ".jpg?high=1&t=" .. PictureToken(id)
end

function FinishedWithNotificationAttachment()
end
