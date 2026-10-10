--[[=============================================================================
    DirectorLink · UniFi Protect Camera - Control4 DriverWorks driver
    https://directorlink.io/drivers/unifi-protect

    One UniFi Protect camera or doorbell on Control4's camera proxy. The
    UniFi Protect Hub driver adds it and gives it everything: its pictures come
    from the hub's picture server on the controller (with this camera's own
    random Basic login, written to its Control4 camera page), its live video is
    the console's RTSP or RTSPS stream, and its events (smart detections,
    motion, doorbell rings) come from the console's event stream through the
    hub. This driver never sees the API key.

    DirectorLink camera agreement v1: variables DIRECTORLINK_CAMERA = "1" and
    DIRECTORLINK_CAMERA_KIND = "camera" / "doorbell"; an alert sets LAST_ALERT,
    then fires "Alert"; a doorbell press sets LAST_RING (ISO 8601 UTC), then
    fires "Ring".

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
    DirectorLink is an independent project, not affiliated with Control4 or Snap One.
    Not affiliated with or endorsed by Ubiquiti. Product names are trademarks of their owners.
===============================================================================]]

local CAMERA_PROXY = 5001
USER_AGENT_PRODUCT = "DirectorLink-UniFi-Protect-Camera"
LOG_PREFIX = "UniFi Protect Camera"
HUB_DRIVER = "DirectorLink-UniFi-Protect.c4z"
RTSP_PORT = 7447               -- the console's plain RTSP
DYNAMIC_STREAMS_OS = "3.3.2"    -- Control4 asks drivers for stream URLs (GET_STREAM_URLS) from this OS on
DETECTION_SAFETY_S = 600        -- a detection whose end never arrives ends by itself
RING_ACTIVE_S = 10
RING_DEBOUNCE_S = 2
STATUS_REPORT_MS = 60000
PICTURE_WAIT_MS = 1500          -- Alert / Ring wait this long for their own picture (Snapshot With Alerts)
SAVED_VARS = { "LAST_ALERT", "LAST_RING", "LAST_ALERT_TIME", "LAST_DETECTION", "LAST_SOUND" }

--[[=============================================================================
    State
===============================================================================]]
local gCfg = {
	hubId = nil, protectId = nil, name = "", kind = "", model = "", smartTypes = "",
	serverAddress = "", serverPort = nil, picUser = "", picPass = "", liveVideo = "RTSP", consoleHost = "",
	hubAlerts = true, snoozeUntil = 0, ringSeen = false, streams = {},
}

local gState = {
	online = nil, protectState = nil, consoleUp = true, eventsLive = false,
	effectiveAlerts = nil, alertActive = false, lastAlert = "", alerted = {}, alertedOrder = {},
	eventSnapshot = nil, attention = {}, lastHubReport = nil, pageWrittenAt = 0,
	started = {}, startedOrder = {}, rings = {}, ringOrder = {}, lastRingAt = 0, claim = nil, claimError = nil,
	startedAt = os.time(), savedVars = {}, pictureSeq = 0,
}

local function CameraEnabled()
	return (Properties["Camera Enabled"] or "Yes") == "Yes"
end

local function Kind()
	local t = Properties["Camera Type"] or "Automatic"
	if t == "Doorbell" then return "doorbell" end
	if t == "Camera" then return "camera" end
	return (gCfg.kind == "doorbell" or gCfg.ringSeen) and "doorbell" or "camera"
end

local function CameraName()
	if gCfg.name ~= "" then return gCfg.name end
	local ok, n = pcall(function() return C4:GetDeviceDisplayName(ProxyId()) end)
	return (ok and type(n) == "string" and n ~= "") and n or "Camera"
end

local function SetLogPrefix()
	LOG_PREFIX = "UniFi Protect Camera '" .. CameraName() .. "'"
end

local function Configured()
	return gCfg.protectId ~= nil and ValidAddress(gCfg.serverAddress) and gCfg.serverPort ~= nil and gCfg.picUser ~= "" and gCfg.picPass ~= ""
end

local function HasStreams()
	return (gCfg.streams.high or "") ~= "" or (gCfg.streams.medium or "") ~= "" or (gCfg.streams.low or "") ~= ""
end

--[[=============================================================================
    Saved settings (the picture password and stream URLs encrypted)
===============================================================================]]
local function SaveCfg()
	pcall(function()
		C4:PersistSetValue("DL_CFG", {
			hubId = gCfg.hubId, protectId = gCfg.protectId, name = gCfg.name, kind = gCfg.kind, model = gCfg.model,
			smartTypes = gCfg.smartTypes, serverAddress = gCfg.serverAddress, serverPort = gCfg.serverPort,
			picUser = gCfg.picUser, liveVideo = gCfg.liveVideo, consoleHost = gCfg.consoleHost,
			hubAlerts = gCfg.hubAlerts, snoozeUntil = gCfg.snoozeUntil, ringSeen = gCfg.ringSeen,
		})
		local vars = {}
		for _, name in ipairs(SAVED_VARS) do vars[name] = GetVar(name) end
		C4:PersistSetValue("DL_VARS", vars)
		-- Director refuses to encrypt an empty value
		if gCfg.picPass ~= "" then C4:PersistSetValue("DL_PASS", gCfg.picPass, true) else C4:PersistDeleteValue("DL_PASS") end
		local s = table.concat({ gCfg.streams.high or "", gCfg.streams.medium or "", gCfg.streams.low or "" }, "\n")
		if s ~= "\n\n" then C4:PersistSetValue("DL_STREAMS", s, true) else C4:PersistDeleteValue("DL_STREAMS") end
	end)
end

local function RegisterStreamSecrets()
	for _, q in ipairs({ "high", "medium", "low" }) do
		local token = string.match(gCfg.streams[q] or "", "^%a+://[^/]+/([^?]+)")
		RegisterSecret(token)
	end
end

local function LoadCfg()
	pcall(function()
		local t = C4:PersistGetValue("DL_CFG")
		if type(t) == "table" then
			gCfg.hubId = tonumber(t.hubId)
			gCfg.protectId = (type(t.protectId) == "string" and t.protectId ~= "") and t.protectId or nil
			gCfg.name, gCfg.kind, gCfg.model = t.name or "", t.kind or "", t.model or ""
			gCfg.smartTypes = t.smartTypes or ""
			gCfg.serverAddress, gCfg.serverPort = t.serverAddress or "", tonumber(t.serverPort)
			gCfg.picUser, gCfg.liveVideo, gCfg.consoleHost = t.picUser or "", t.liveVideo or "RTSP", t.consoleHost or ""
			gCfg.hubAlerts = t.hubAlerts ~= false
			gCfg.snoozeUntil = tonumber(t.snoozeUntil) or 0
			gCfg.ringSeen = t.ringSeen == true
		end
		local v = C4:PersistGetValue("DL_VARS")
		if type(v) == "table" then gState.savedVars = v end
		local p = C4:PersistGetValue("DL_PASS", true)
		if type(p) == "string" then gCfg.picPass = p end
		local s = C4:PersistGetValue("DL_STREAMS", true)
		if type(s) == "string" then
			local h, m, l = string.match(s, "^([^\n]*)\n([^\n]*)\n([^\n]*)$")
			gCfg.streams = { high = h or "", medium = m or "", low = l or "" }
		end
	end)
	RegisterSecret(gCfg.picPass)
	RegisterStreamSecrets()
end

--[[=============================================================================
    Status and attention
===============================================================================]]
local ReportToHub, UpdateExtras, UpdateVideo -- forward

local ATTENTION_ORDER = { "claim", "os", "streams", "proxy" }

local function SetAttention(key, text, force)
	if gState.attention[key] == text and not force then return end
	gState.attention[key] = text
	local items = {}
	for _, k in ipairs(ATTENTION_ORDER) do
		if gState.attention[k] then items[#items + 1] = gState.attention[k] end
	end
	UpdateProperty("Attention", table.concat(items, "  |  "))
	pcall(function() C4:SetPropertyAttribs("Attention", #items > 0 and 0 or 1) end)
end

local function AlertsDescription()
	if os.time() < (gCfg.snoozeUntil or 0) then return "alerts snoozed until " .. os.date("%H:%M", gCfg.snoozeUntil) end
	if not gCfg.hubAlerts then return "alerts off (hub)" end
	if (Properties["Alerts"] or "On") ~= "On" then return "alerts off" end
	return "alerts on"
end

local function ComputeOnline()
	if not CameraEnabled() or not Configured() then return nil end
	if gState.consoleUp == false then return false end
	if gState.protectState == nil or gState.protectState == "" then return nil end
	return gState.protectState == "CONNECTED"
end

local function SetOnline()
	local on = ComputeOnline()
	if gState.online == on then return end
	local prev = gState.online
	gState.online = on
	SetVar("ONLINE", on == true)
	if prev ~= nil and on ~= nil then FireEvent(on and "Camera Online" or "Camera Offline") end
end

function UpdateStatus()
	SetOnline()
	local s
	if not CameraEnabled() then
		s = "Disabled - no events, alerts or pictures (set Camera Enabled to Yes to resume)"
	elseif not gCfg.hubId then
		s = "Waiting for the UniFi Protect Hub: add DirectorLink · UniFi Protect to the project and run its Add New Cameras"
	elseif not gCfg.protectId then
		s = gState.claimError or "Not linked to a UniFi camera: run Add New Cameras on the UniFi Protect Hub, or type the camera's name in UniFi Camera"
	elseif not Configured() then
		s = "Waiting for the settings from the UniFi Protect Hub..."
	elseif gState.protectState == "REMOVED" then
		s = "This camera was removed from UniFi Protect"
	elseif gState.consoleUp == false then
		s = "Offline - the hub cannot reach the UniFi console"
	elseif gState.protectState == "DISCONNECTED" then
		s = "Offline - the camera is disconnected from UniFi Protect"
	elseif gState.protectState == "CONNECTING" then
		s = "Connecting - UniFi Protect is connecting to the camera"
	elseif gState.online == nil then
		s = "Waiting for the camera's state from the hub..."
	else
		s = "Online - " .. (gState.eventsLive and "events live" or "events reconnecting") .. " - " .. AlertsDescription()
	end
	UpdateProperty("Status", s)
	if ReportToHub then ReportToHub() end
end

local function CheckControllerVersion()
	local v = ControllerVersion()
	if v and not VersionAtLeast(v, DYNAMIC_STREAMS_OS) then
		SetAttention("os", "Live video needs Control4 OS " .. DYNAMIC_STREAMS_OS .. " or newer (this controller runs " .. v.text
			.. "); pictures, alerts and rings work")
	else
		SetAttention("os", nil)
	end
end

--[[=============================================================================
    The Control4 camera page (camera proxy)
    Address = the controller, HTTP port = the hub's picture server, Basic login =
    this camera's own picture login. Control4 apps and DirectorLink take pictures
    from exactly these values. The hub owns them: edits are put back.
===============================================================================]]
local function ReadProxyProperties()
	local pid = ProxyId()
	if not pid then return nil end
	local ok, xml = pcall(function() return C4:SendUIRequest(pid, "GET_PROPERTIES", {}) end)
	if not ok or type(xml) ~= "string" or not string.find(xml, "<address>", 1, true) then return nil end
	return {
		address = XmlTag(xml, "address"), httpPort = tonumber(XmlTag(xml, "http_port") or ""),
		rtspPort = tonumber(XmlTag(xml, "rtsp_port") or ""), authRequired = XmlTag(xml, "authentication_required"),
		authType = XmlTag(xml, "authentication_type"), username = XmlTag(xml, "username"), useHttps = XmlTag(xml, "use_https"),
	}
end

local function PageMatches(p)
	return p ~= nil and trim(p.address or "") == gCfg.serverAddress and p.httpPort == gCfg.serverPort
		and string.upper(p.authType or "") == "BASIC" and toboolean(p.authRequired)
		and (p.username == nil or IsMasked(p.username) or p.username == gCfg.picUser)
		and not toboolean(p.useHttps)
end

local function WriteProxySettings(reason)
	local pid = ProxyId()
	if not pid or not Configured() then return end
	local function cmd(c, p) pcall(function() C4:SendToDevice(pid, c, p, true, false) end) end
	local function notify(c, p) pcall(function() C4:SendToProxy(CAMERA_PROXY, c, p, "NOTIFY") end) end
	LogInfo("Writing the camera page: %s:%d, Basic login (%s)", gCfg.serverAddress, gCfg.serverPort, reason or "settings")
	gState.pageWrittenAt = os.time()
	cmd("SET_ADDRESS", { ADDRESS = gCfg.serverAddress })
	cmd("SET_HTTP_PORT", { PORT = tostring(gCfg.serverPort) })
	cmd("SET_RTSP_PORT", { PORT = tostring(RTSP_PORT) })
	cmd("SET_AUTHENTICATION_REQUIRED", { REQUIRED = "True" })
	cmd("SET_AUTHENTICATION_TYPE", { TYPE = "BASIC" })
	cmd("SET_USERNAME", { USERNAME = gCfg.picUser })
	cmd("SET_PASSWORD", { PASSWORD = gCfg.picPass })
	notify("ADDRESS_CHANGED", { ADDRESS = gCfg.serverAddress })
	notify("HTTP_PORT_CHANGED", { PORT = tostring(gCfg.serverPort) })
	notify("RTSP_PORT_CHANGED", { PORT = tostring(RTSP_PORT) })
	notify("USE_HTTPS_CHANGED", { USE_HTTPS = "False" })
	SetTimer("PROXY_VERIFY", 3000, function()
		local p = ReadProxyProperties()
		if not p then return end
		if PageMatches(p) then
			LogDebug("Camera page verified: %s:%s, %s", tostring(p.address), tostring(p.httpPort), tostring(p.authType))
			SetAttention("proxy", nil)
		else
			LogWarn("Camera page shows address=%s port=%s auth=%s required=%s", tostring(p.address), tostring(p.httpPort), tostring(p.authType), tostring(p.authRequired))
			SetAttention("proxy", "Open the camera's Properties page and set Address " .. gCfg.serverAddress .. ", HTTP Port " .. gCfg.serverPort
				.. ", Authentication Required, type BASIC (run Setup Report for the login)")
		end
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
	end)
end

local function SyncCameraPage(reason)
	if not Configured() then return end
	local p = ReadProxyProperties()
	if p and PageMatches(p) then return end
	WriteProxySettings(reason)
end

--[[=============================================================================
    Alerts
    Detection events always fire (for automation). The "Alert" event fires only
    when alerts are on for this camera and on the hub, not snoozed, the
    detection matches "Alert On", and no alert is already active (Hold Time):
    one event alerts once.
===============================================================================]]
local ALERT_FILTERS = {
	["Any detection"] = { person = true, vehicle = true, other = true, motion = true },
	["People and vehicles"] = { person = true, vehicle = true },
	["People only"] = { person = true },
}

local function AlertsEnabled()
	if os.time() < (gCfg.snoozeUntil or 0) then return false end
	return (Properties["Alerts"] or "On") == "On" and gCfg.hubAlerts ~= false
end

local function AlertsChanged(reason)
	local now = AlertsEnabled()
	SetVar("ALERTS_ENABLED", now)
	if gState.effectiveAlerts ~= nil and gState.effectiveAlerts ~= now then
		LogInfo("Alerts %s (%s)", now and "on" or "off", reason or "")
		FireEvent(now and "Alerts On" or "Alerts Off")
	end
	gState.effectiveAlerts = now
	if os.time() < (gCfg.snoozeUntil or 0) then
		SetTimer("SNOOZE_END", (gCfg.snoozeUntil - os.time() + 1) * 1000, function() AlertsChanged("snooze ended") end)
	else
		KillTimer("SNOOZE_END")
	end
	if UpdateExtras then UpdateExtras() end
	UpdateStatus()
end

local function SetAlerts(on, reason)
	gCfg.snoozeUntil = 0
	SaveCfg()
	UpdateProperty("Alerts", on and "On" or "Off")
	AlertsChanged(reason)
end

local function SnoozeAlerts(minutes, reason)
	minutes = math.max(1, math.min(1440, tonumber(minutes) or 60))
	gCfg.snoozeUntil = os.time() + minutes * 60
	SaveCfg()
	AlertsChanged(reason or ("snooze " .. minutes .. " min"))
end

--[[=============================================================================
    Detections
===============================================================================]]
local DETECTIONS = {
	motion       = { label = "Motion", var = "MOTION", contact = 101, event = "Motion Detected", endEvent = "Motion Ended", class = "motion" },
	person       = { label = "Person", var = "PERSON", contact = 102, event = "Person Detected", class = "person" },
	vehicle      = { label = "Vehicle", var = "VEHICLE", contact = 103, event = "Vehicle Detected", class = "vehicle" },
	animal       = { label = "Animal", var = "ANIMAL", contact = 104, event = "Animal Detected", class = "other" },
	package      = { label = "Package", var = "PACKAGE", contact = 105, event = "Package Detected", class = "other" },
	face         = { label = "Face", var = "FACE", event = "Face Detected", class = "person" },
	licensePlate = { label = "License Plate", var = "LICENSE_PLATE", event = "License Plate Detected", class = "vehicle" },
	line         = { label = "Line Crossing", var = "LINE_CROSSING", event = "Line Crossing", class = "motion" },
	intrusion    = { label = "Intrusion", var = "INTRUSION", event = "Intrusion Detected", class = "motion" },
}
-- The label LAST_ALERT gets when one event saw several things
local ALERT_PRIORITY = { "person", "face", "vehicle", "licensePlate", "package", "animal", "line", "intrusion", "motion" }
-- Protect's smartDetectTypes -> detections
local SMART_TYPES = { person = "person", vehicle = "vehicle", animal = "animal", package = "package", face = "face", licensePlate = "licensePlate" }
local AUDIO_LABELS = {
	alrmSmoke = "Smoke alarm", alrmCmonx = "CO alarm", alrmSiren = "Siren", alrmBabyCry = "Baby crying", alrmSpeak = "Speech",
	alrmBark = "Barking", alrmBurglar = "Burglar alarm", alrmCarHorn = "Car horn", alrmGlassBreak = "Glass break",
}

local ALERT_CONTACT, RING_CONTACT = 100, 106
local CONTACT_BINDINGS = { [ALERT_CONTACT] = "alert", [RING_CONTACT] = "ring" }
for key, d in pairs(DETECTIONS) do
	if d.contact then CONTACT_BINDINGS[d.contact] = key end
end

local gDet = {}

local function ContactClosed(active)
	local closedWhenActive = (Properties["Contact State When Active"] or "Closed") == "Closed"
	if active then return closedWhenActive end
	return not closedWhenActive
end

local function SendContact(binding, active, initial)
	local closed = ContactClosed(active)
	local cmd
	if initial then cmd = closed and "STATE_CLOSED" or "STATE_OPENED" else cmd = closed and "CLOSED" or "OPENED" end
	pcall(function() C4:SendToProxy(binding, cmd, {}, "NOTIFY") end)
end

local function HoldSeconds()
	return tonumber(Properties["Hold Time (s)"]) or 30
end

local function ContactActive(binding)
	local key = CONTACT_BINDINGS[binding]
	if key == "alert" then return gState.alertActive end
	if key == "ring" then return GetVar("RINGING") == "1" end
	return gDet[key] ~= nil and gDet[key].active == true
end

local function PictureUrl(high, withLogin)
	if not Configured() then return nil end
	local login = withLogin and (gCfg.picUser .. ":" .. gCfg.picPass .. "@") or ""
	return "http://" .. login .. gCfg.serverAddress .. ":" .. gCfg.serverPort .. "/snapshot/" .. tostring(MyDeviceId()) .. ".jpg" .. (high and "?high=1" or "")
end

-- GET one of this camera's own pictures, the way Control4 apps do: cb(code, body, err, ms)
local function GetOwnPicture(high, cb)
	local url = PictureUrl(high, false)
	if not url then return cb(nil, nil, "not configured yet", 0) end
	local started = NowMs()
	local ok, err = pcall(function()
		local x = C4:url()
		x:SetOptions({ fail_on_error = false, timeout = 20, connect_timeout = 5 })
		x:OnDone(function(_, responses, errCode, errMsg)
			local resp = responses and responses[#responses]
			if (errCode ~= nil and errCode ~= 0) or not resp then return cb(nil, nil, errMsg or tostring(errCode), NowMs() - started) end
			cb(tonumber(resp.code), resp.body, nil, NowMs() - started)
		end)
		x:Get(url, { Authorization = "Basic " .. Base64Encode(gCfg.picUser .. ":" .. gCfg.picPass), ["User-Agent"] = UserAgent() })
	end)
	if not ok then cb(nil, nil, tostring(err), 0) end
end

-- Fire an event once this camera's picture is in (for the notification attachment), or after
-- PICTURE_WAIT_MS: the picture attached is always this event's, never the previous one's
local function FireWithPicture(event)
	gState.eventSnapshot = nil
	gState.pictureSeq = gState.pictureSeq + 1
	local seq, fired = gState.pictureSeq, false
	local function fire()
		if fired then return end
		fired = true
		KillTimer("PICTURE_WAIT_" .. event)
		FireEvent(event)
	end
	if (Properties["Snapshot With Alerts"] or "Yes") ~= "Yes" or not Configured() then return fire() end
	SetTimer("PICTURE_WAIT_" .. event, PICTURE_WAIT_MS, fire)
	GetOwnPicture(true, function(code, body)
		if seq ~= gState.pictureSeq then return fire() end
		if code == 200 and IsJpeg(body) then
			gState.eventSnapshot = body
			LogDebug("Notification picture captured (%s)", ByteSize(#body))
		end
		fire()
	end)
end

local function AlertEnd()
	KillTimer("ALERT_HOLD")
	if not gState.alertActive then return end
	gState.alertActive = false
	SetVar("ALERT_ACTIVE", false)
	SendContact(ALERT_CONTACT, false)
	UpdateStatus()
end

local function Remember(set, order, key)
	set[key] = true
	order[#order + 1] = key
	while #order > 200 do set[table.remove(order, 1)] = nil end
end

local function TriggerAlert(keys, eventId)
	if not AlertsEnabled() then
		LogDebug("Not alerting (%s)", AlertsDescription())
		return
	end
	if eventId and eventId ~= "" and gState.alerted[eventId] then return end
	local filterName = Properties["Alert On"] or "Any detection"
	local filter = ALERT_FILTERS[filterName] or ALERT_FILTERS["Any detection"]
	local wanted = {}
	for _, k in ipairs(keys) do wanted[k] = true end
	local pick
	for _, k in ipairs(ALERT_PRIORITY) do
		if wanted[k] and filter[DETECTIONS[k].class] then
			pick = k
			break
		end
	end
	if not pick then
		LogDebug("Not alerting: Alert On is '%s'", filterName)
		return
	end
	if eventId and eventId ~= "" then Remember(gState.alerted, gState.alertedOrder, eventId) end
	if gState.alertActive then
		LogDebug("%s: an alert is already active (Hold Time %d s)", DETECTIONS[pick].label, HoldSeconds())
		SetTimer("ALERT_HOLD", HoldSeconds() * 1000, AlertEnd)
		return
	end
	local label = DETECTIONS[pick].label
	gState.alertActive = true
	gState.lastAlert = label
	local stamp = IsoUtc()
	SetVar("ALERT_ACTIVE", true)
	SetVar("LAST_ALERT", label)       -- DirectorLink reads LAST_ALERT when "Alert" fires: set it first
	SetVar("LAST_ALERT_TIME", stamp)
	SaveCfg()
	SendContact(ALERT_CONTACT, true)
	FireWithPicture("Alert")
	if (Properties["Record Alerts In History"] or "Yes") == "Yes" then
		pcall(function() C4:RecordHistory("Info", label .. " detected", "Cameras", CameraName(), { camera = CameraName(), detection = label }) end)
	end
	if gCfg.hubId then
		SendToDriver(gCfg.hubId, "DL_CAMERA_ALERT", { DEVICE_ID = MyDeviceId(), PROXY_ID = ProxyId(), NAME = CameraName(), TYPE = label, TIME = stamp })
	end
	SetTimer("ALERT_HOLD", HoldSeconds() * 1000, AlertEnd)
	UpdateStatus()
end

local function DetectionEnd(key)
	local d, st = DETECTIONS[key], gDet[key]
	KillTimer("DET_" .. key)
	if not st or not st.active then return end
	st.active, st.events = false, {}
	LogDebug("%s ended", d.label)
	SetVar(d.var, false)
	if d.contact then SendContact(d.contact, false) end
	if d.endEvent then FireEvent(d.endEvent) end
end

local function DetectionStart(key, eventId)
	local d = DETECTIONS[key]
	local st = gDet[key]
	if not st then
		st = { active = false, events = {} }
		gDet[key] = st
	end
	st.events[eventId or "?"] = true
	if not st.active then
		st.active = true
		LogDebug("%s started", d.label)
		SetVar("LAST_DETECTION", d.label)
		SetVar(d.var, true)
		if d.contact then SendContact(d.contact, true) end
		FireEvent(d.event)
	end
	SetTimer("DET_" .. key, DETECTION_SAFETY_S * 1000, function() DetectionEnd(key) end)
end

local function DetectionEventEnd(key, eventId)
	local st = gDet[key]
	if not st or not st.active then return end
	st.events[eventId or "?"] = nil
	if next(st.events) == nil then DetectionEnd(key) end
end

local function EndAllDetections()
	for key in pairs(DETECTIONS) do DetectionEnd(key) end
	AlertEnd()
end

local function IsDetectionActive(label)
	for key, d in pairs(DETECTIONS) do
		if d.label == label then return gDet[key] ~= nil and gDet[key].active == true end
	end
	return false
end

local function Split(s)
	local out = {}
	for v in string.gmatch(s or "", "[^,]+") do out[#out + 1] = trim(v) end
	return out
end

-- The time of an event from the console (milliseconds), or now when it looks wrong
local function EventSeconds(ms)
	local s = tonumber(ms) and tonumber(ms) / 1000 or nil
	if not s or math.abs(s - os.time()) > 86400 then return os.time() end
	return math.floor(s)
end

-- DirectorLink camera agreement v1: the marker, the kind, and the ids of its events in driver.xml
-- (Alert = 1, Ring = 2; a camera says only its Alert). force: written on every start, so they are
-- right after a driver update too.
local function SetAgreementVariables(force)
	local kind = Kind()
	SetVar("DIRECTORLINK_CAMERA", "1", force)
	SetVar("DIRECTORLINK_CAMERA_KIND", kind, force)
	SetVar("DIRECTORLINK_CAMERA_EVENTS", kind == "doorbell" and "Alert=1,Ring=2" or "Alert=1", force)
end

local function KindChanged()
	SetAgreementVariables(false)
	if UpdateVideo then UpdateVideo() end
end

local function Ring(p)
	if p["END"] ~= "" and p.ACTION == "update" then return end -- the end of a ring needs nothing
	local id = p.ID ~= "" and p.ID or nil
	if id and gState.rings[id] then return end
	if id then Remember(gState.rings, gState.ringOrder, id) end
	if os.time() - gState.lastRingAt < RING_DEBOUNCE_S then
		LogDebug("Second press within %d s: one ring", RING_DEBOUNCE_S)
		return
	end
	if not gCfg.ringSeen then
		gCfg.ringSeen = true
		SaveCfg()
		KindChanged()                 -- the kind (doorbell) is set before the first Ring
	end
	if Kind() ~= "doorbell" then
		-- Camera Type = Camera: a camera never fires Ring (DirectorLink camera agreement)
		LogInfo("A ring from UniFi Protect ignored: Camera Type is set to Camera")
		return
	end
	gState.lastRingAt = os.time()
	-- The console's time of the press when it is plausible (DirectorLink trusts LAST_RING from two
	-- minutes behind the controller's clock to five seconds ahead), else now; every ring gets a new
	-- LAST_RING, later than the one before
	local seconds = tonumber(p.START) and math.floor(tonumber(p.START) / 1000) or os.time()
	if seconds < os.time() - 120 or seconds > os.time() + 5 then seconds = os.time() end
	if seconds <= (gState.lastRingSeconds or 0) then seconds = gState.lastRingSeconds + 1 end
	gState.lastRingSeconds = seconds
	local stamp = IsoUtc(seconds)
	SetVar("LAST_RING", stamp)        -- set before "Ring" fires
	SaveCfg()
	SetVar("RINGING", true)
	SendContact(RING_CONTACT, true)
	FireWithPicture("Ring")
	if (Properties["Record Alerts In History"] or "Yes") == "Yes" then
		pcall(function() C4:RecordHistory("Info", "Doorbell pressed", "Cameras", CameraName(), { camera = CameraName() }) end)
	end
	if gCfg.hubId then
		SendToDriver(gCfg.hubId, "DL_CAMERA_RING", { DEVICE_ID = MyDeviceId(), PROXY_ID = ProxyId(), NAME = CameraName(), TIME = stamp })
	end
	SetTimer("RING_END", RING_ACTIVE_S * 1000, function()
		SetVar("RINGING", false)
		SendContact(RING_CONTACT, false)
	end)
	UpdateProperty("Last Event", os.date("%H:%M:%S") .. " ring")
end

-- One event from the console, passed on by the hub
function HandleEvent(p)
	if not CameraEnabled() then return end
	local etype, id = p.TYPE or "", p.ID or ""
	local types = Split(p.TYPES)
	local ended = (p["END"] or "") ~= ""
	LogDebug("Event %s %s%s (event %s)%s", tostring(p.ACTION), etype, #types > 0 and (" [" .. table.concat(types, ",") .. "]") or "", id, ended and " - ended" or "")
	if etype == "ring" then return Ring(p) end
	if etype == "smartAudioDetect" then
		if ended or gState.started[id] then return end
		if id ~= "" then Remember(gState.started, gState.startedOrder, id) end
		local labels = {}
		for _, t in ipairs(types) do labels[#labels + 1] = AUDIO_LABELS[t] or t end
		SetVar("LAST_SOUND", #labels > 0 and table.concat(labels, ", ") or "Sound")
		SaveCfg()
		FireEvent("Sound Detected")
		UpdateProperty("Last Event", os.date("%H:%M:%S") .. " sound: " .. (#labels > 0 and table.concat(labels, ", ") or "?"))
		return
	end
	local keys, seen = {}, {}
	local function add(k)
		if k and not seen[k] then
			seen[k] = true
			keys[#keys + 1] = k
		end
	end
	if etype == "motion" then
		add("motion")
	elseif etype == "smartDetectZone" or etype == "smartDetectLine" or etype == "smartDetectLoiterZone" then
		for _, t in ipairs(types) do add(SMART_TYPES[t]) end
		if etype == "smartDetectLine" then add("line") end
		if #keys == 0 then add(etype == "smartDetectLine" and "line" or "intrusion") end
	else
		return
	end
	local labels = {}
	for _, k in ipairs(keys) do labels[#labels + 1] = DETECTIONS[k].label end
	UpdateProperty("Last Event", os.date("%H:%M:%S") .. " " .. table.concat(labels, ", ") .. (ended and " (ended)" or ""))
	if ended then
		-- What this event had not shown yet (a short event sent already finished, or a type first
		-- named in the update that ends it) still counts once, then ends
		local fresh = {}
		for _, k in ipairs(keys) do
			if not (gDet[k] and gDet[k].active and gDet[k].events[id ~= "" and id or "?"]) then fresh[#fresh + 1] = k end
		end
		if id ~= "" and not gState.started[id] and EventSeconds(p.START) < gState.startedAt - 2 then
			-- It began before this driver started: its start was handled (or missed) before a restart
			LogDebug("Event %s began before the driver started: not alerting again", id)
			fresh = {}
		end
		if id ~= "" and not gState.started[id] then Remember(gState.started, gState.startedOrder, id) end
		if #fresh > 0 then
			for _, k in ipairs(fresh) do DetectionStart(k, id) end
			TriggerAlert(fresh, id)
			SetTimer("PULSE_" .. id, 3000, function()
				for _, k in ipairs(keys) do DetectionEventEnd(k, id) end
			end)
			return
		end
		for _, k in ipairs(keys) do DetectionEventEnd(k, id) end
		return
	end
	if id ~= "" and not gState.started[id] then Remember(gState.started, gState.startedOrder, id) end
	for _, k in ipairs(keys) do DetectionStart(k, id) end
	TriggerAlert(keys, id)
end

--[[=============================================================================
    Live video and pictures for Navigators
    Pictures: the camera page points at the hub's picture server, so the proxy
    builds http://<controller>:<port>/<snapshot path> with this camera's login.
    Video: GET_STREAM_URLS hands the console's stream (RTSP on 7447, or RTSPS
    on 7441, as the hub's Live Video says) to Control4 OS 3.3.2 and newer.
===============================================================================]]
local QUALITY_ORDER = { "high", "medium", "low" }
local RESOLUTION_HINT = { high = "1920x1080", medium = "1280x720", low = "640x360" }

local function Available(q)
	return (gCfg.streams[q] or "") ~= ""
end

local function RequestedWidth(tParams)
	local w = tonumber(string.match(tostring(tParams.RESOLUTION or tParams.resolution or ""), "^(%d+)") or "")
	return w or tonumber(tParams.SIZE_X or tParams.size_x or "")
end

-- The quality that fits the screen, else the nearest one there is
function PickQuality(tParams)
	local setting = string.lower(Properties["Video Quality"] or "Auto")
	local want
	if setting == "high" or setting == "medium" or setting == "low" then
		want = setting
	else
		local w = RequestedWidth(tParams or {}) or 0
		want = (w > 0 and w <= 700) and "low" or ((w > 0 and w <= 1300) and "medium" or "high")
	end
	if Available(want) then return want end
	local fallback = { high = { "medium", "low" }, medium = { "high", "low" }, low = { "medium", "high" } }
	for _, q in ipairs(fallback[want]) do
		if Available(q) then return q end
	end
	return nil
end

function StreamUrl(q)
	local url = gCfg.streams[q] or ""
	if url == "" then return nil end
	if gCfg.liveVideo == "RTSPS" then return url end
	local host, token = string.match(url, "^%a+://([^/:]+)[^/]*/([^?]+)")
	if not host then return nil end
	return "rtsp://" .. host .. ":" .. RTSP_PORT .. "/" .. token
end

local function MaskUrl(url)
	return (string.gsub(url or "", "^(%a+://[^/]+/)[^?]*", "%1***"))
end

local function LogRequest(name, tParams, result)
	if LOG_LEVEL >= 4 then
		local parts = {}
		for k, v in pairs(tParams or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
		table.sort(parts)
		LogDebug("%s(%s) -> %s", name, table.concat(parts, ", "), result)
	end
end

function StreamsXml(tParams)
	tParams = tParams or {}
	if not CameraEnabled() then return "<streams></streams>" end
	local first = PickQuality(tParams)
	if not first then
		if gCfg.protectId and ReportToHub then ReportToHub(true) end
		LogRequest("GET_STREAM_URLS", tParams, "no stream yet")
		return "<streams></streams>"
	end
	local order = { first }
	for _, q in ipairs(QUALITY_ORDER) do
		if q ~= first and Available(q) then order[#order + 1] = q end
	end
	local out, shown = {}, {}
	for _, q in ipairs(order) do
		local url = StreamUrl(q)
		if url then
			-- Self-closing elements: one malformed answer can break every camera's list in Navigator
			out[#out + 1] = '<stream url="' .. XmlEscape(url) .. '" codec="h264" resolution="' .. RESOLUTION_HINT[q] .. '"/>'
			shown[#shown + 1] = q .. " " .. MaskUrl(url)
		end
	end
	local head = tParams.KEY and ('<streams key="' .. XmlEscape(tParams.KEY) .. '">') or "<streams>"
	LogRequest("GET_STREAM_URLS", tParams, table.concat(shown, ", "))
	return head .. table.concat(out) .. "</streams>"
end

UI_REQ = {}

UI_REQ.GET_STREAM_URLS = function(tParams) return StreamsXml(tParams) end

UI_REQ.GET_SNAPSHOT_QUERY_STRING = function(tParams)
	if not CameraEnabled() or not Configured() then
		LogRequest("GET_SNAPSHOT_QUERY_STRING", tParams, "not configured")
		return "<snapshot_query_string></snapshot_query_string>"
	end
	local quality = Properties["Video Quality"] or "Auto"
	local w = tonumber(tParams.SIZE_X or "") or 0
	local high = quality == "High" or (quality == "Auto" and (w == 0 or w > 640))
	local q = "snapshot/" .. tostring(MyDeviceId()) .. ".jpg" .. (high and "?high=1" or "")
	LogRequest("GET_SNAPSHOT_QUERY_STRING", tParams, q)
	return "<snapshot_query_string>" .. XmlEscape(q) .. "</snapshot_query_string>"
end

-- The static path (rtsp://<page address>:<rtsp port>/<query>) only works when the page points at
-- the console, which it does not (it points at the picture server): Control4 uses GET_STREAM_URLS.
UI_REQ.GET_RTSP_H264_QUERY_STRING = function(tParams)
	local q = PickQuality(tParams)
	local token = q and string.match(gCfg.streams[q] or "", "^%a+://[^/]+/([^?]+)") or ""
	LogRequest("GET_RTSP_H264_QUERY_STRING", tParams, token ~= "" and (q .. " stream (token hidden)") or "no stream")
	return "<rtsp_h264_query_string>" .. XmlEscape(token) .. "</rtsp_h264_query_string>"
end
UI_REQ.GET_RTSP_H264_QUERY = UI_REQ.GET_RTSP_H264_QUERY_STRING

UI_REQ.GET_MJPEG_QUERY_STRING = function() return "<mjpeg_query_string></mjpeg_query_string>" end
UI_REQ.GET_MJPEG_QUERY = UI_REQ.GET_MJPEG_QUERY_STRING

--[[=============================================================================
    Touchscreen controls in the camera view (Extras)
===============================================================================]]
local EXTRAS_ALERT_ON = { "Any detection", "People and vehicles", "People only" }

function ExtrasSetupXml()
	local items = {}
	for _, v in ipairs(EXTRAS_ALERT_ON) do items[#items + 1] = '<item text="' .. XmlEscape(v) .. '" value="' .. XmlEscape(v) .. '"/>' end
	return table.concat({
		"<extras_setup><extra>", '<section label="Alerts">',
		'<object type="checkbox" id="alerts" label="Alerts from this camera" command="EXTRAS_ALERTS"/>',
		'<object type="list" id="alerton" label="Alert on" command="EXTRAS_ALERT_ON"><list maxselections="1" minselections="1">',
		table.concat(items), "</list></object>",
		'<object type="button" id="snooze" label="Pause alerts for 1 hour" command="EXTRAS_SNOOZE"><buttontext>Snooze</buttontext></object>',
		"</section></extra></extras_setup>",
	})
end

function ExtrasStateXml()
	return '<extras_state><extra><object id="alerts" value="' .. (AlertsEnabled() and "True" or "False") .. '"/>'
		.. '<object id="alerton" value="' .. XmlEscape(Properties["Alert On"] or "Any detection") .. '"/></extra></extras_state>'
end

local function SendExtrasSetup()
	pcall(function() C4:SendToProxy(CAMERA_PROXY, "EXTRAS_SETUP_CHANGED", { XML = ExtrasSetupXml() }, "NOTIFY") end)
end

UpdateExtras = function()
	pcall(function() C4:SendToProxy(CAMERA_PROXY, "EXTRAS_STATE_CHANGED", { XML = ExtrasStateXml() }, "NOTIFY") end)
end

UI_REQ.GET_EXTRAS_SETUP = function() return ExtrasSetupXml() end
UI_REQ.GET_EXTRAS_STATE = function() return ExtrasStateXml() end

--[[=============================================================================
    Hub link
===============================================================================]]
local function FindHub()
	if gCfg.hubId then return gCfg.hubId end
	local ok, devs = pcall(function() return C4:GetDevicesByC4iName(HUB_DRIVER) end)
	local found = {}
	if ok and type(devs) == "table" then
		for k, v in pairs(devs) do
			local id = tonumber(v) or tonumber(k)
			if id then found[#found + 1] = id end
		end
	end
	-- One hub in the project: it is this camera's (with two consoles, the hub links it when it answers)
	if #found == 1 then gCfg.hubId = found[1] end
	return found[1]
end

ReportToHub = function(force)
	local hub = FindHub()
	if not hub then return end
	local p = {
		DEVICE_ID = MyDeviceId(), PROXY_ID = ProxyId(), PROTECT_ID = gCfg.protectId or "", NAME = CameraName(),
		ONLINE = gState.online == true and "1" or (gState.online == false and "0" or ""),
		DISABLED = CameraEnabled() and "0" or "1", KIND = Kind(), VERSION = DRIVER_SEMVER,
		STATUS = Properties["Status"] or "",
		NEED_CONFIG = (gCfg.protectId and not Configured()) and "1" or "0",
		NEED_STREAMS = (gCfg.protectId and CameraEnabled() and not HasStreams()) and "1" or "0",
		CLAIM = gState.claim or "",
	}
	local sig = table.concat({ p.PROTECT_ID, p.NAME, p.ONLINE, p.DISABLED, p.KIND, p.STATUS, p.NEED_CONFIG, p.NEED_STREAMS, p.CLAIM }, "|")
	if sig == gState.lastHubReport and not force then return end
	gState.lastHubReport = sig
	SendToDriver(hub, "DL_CAMERA_STATUS", p)
	gState.claim = nil
end

local function UpdateHubProperty()
	local name
	if gCfg.hubId then
		local ok, n = pcall(function() return C4:GetDeviceDisplayName(gCfg.hubId) end)
		name = (ok and n and n ~= "") and n or ("device " .. gCfg.hubId)
	end
	UpdateProperty("Managed By", name or "No UniFi Protect Hub yet")
end

UpdateVideo = function()
	local have = {}
	for _, q in ipairs(QUALITY_ORDER) do
		if Available(q) then have[#have + 1] = q:sub(1, 1):upper() .. q:sub(2) end
	end
	local mode = gCfg.liveVideo == "RTSPS" and "RTSPS (port 7441)" or "RTSP (port 7447)"
	UpdateProperty("Video", #have > 0 and (mode .. " - streams: " .. table.concat(have, ", ")) or (mode .. " - no stream yet"))
	local parts = { gCfg.model ~= "" and gCfg.model or "UniFi camera", Kind() }
	if gCfg.protectId then parts[#parts + 1] = "UniFi id " .. gCfg.protectId end
	UpdateProperty("Camera", table.concat(parts, " - "))
	UpdateProperty("Pictures", Configured() and ("From the hub at " .. gCfg.serverAddress .. ":" .. gCfg.serverPort) or "Not set up yet")
	if gCfg.protectId and Configured() and not HasStreams() then
		SetAttention("streams", "No live video stream yet: the hub switches the stream on in UniFi Protect (Create Streams = Automatic), or turn on RTSP for this camera in UniFi Protect")
	else
		SetAttention("streams", nil)
	end
end

local function ApplyState(p)
	local changed = false
	if p.STATE and p.STATE ~= "" and p.STATE ~= gState.protectState then
		LogInfo("UniFi Protect state: %s", p.STATE)
		gState.protectState = p.STATE
		if p.STATE ~= "CONNECTED" then EndAllDetections() end
		changed = true
	end
	if p.NAME and p.NAME ~= "" and p.NAME ~= gCfg.name then gCfg.name, changed = p.NAME, true end
	if p.KIND and p.KIND ~= "" and p.KIND ~= gCfg.kind then gCfg.kind, changed = p.KIND, true end
	if p.MODEL and p.MODEL ~= gCfg.model then gCfg.model, changed = p.MODEL, true end
	if p.SMART_TYPES and p.SMART_TYPES ~= gCfg.smartTypes then gCfg.smartTypes, changed = p.SMART_TYPES, true end
	if p.CONSOLE then gState.consoleUp = p.CONSOLE ~= "0" end
	if p.EVENTS then
		gState.eventsLive = p.EVENTS == "1"
		if not gState.eventsLive then EndAllDetections() end
	end
	if p.LIVE_VIDEO and (p.LIVE_VIDEO == "RTSP" or p.LIVE_VIDEO == "RTSPS") and p.LIVE_VIDEO ~= gCfg.liveVideo then
		gCfg.liveVideo, changed = p.LIVE_VIDEO, true
		LogInfo("Live video: %s", p.LIVE_VIDEO)
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
	end
	if changed then SaveCfg() end
	SetLogPrefix()
	KindChanged()
	UpdateVideo()
	UpdateStatus()
end

--[[=============================================================================
    Report (Actions tab)
===============================================================================]]
local function Report()
	local v = ControllerVersion()
	local lines = {
		"===== UniFi Protect camera - setup report =====",
		"Status        : " .. tostring(Properties["Status"]),
		"Name          : " .. CameraName() .. "   kind: " .. Kind() .. " (Camera Type " .. tostring(Properties["Camera Type"]) .. ")",
		"Enabled       : " .. (CameraEnabled() and "yes" or "NO (Camera Enabled = No)"),
		"UniFi camera  : " .. tostring(gCfg.protectId or "not linked") .. "  state " .. tostring(gState.protectState or "?")
			.. "  model " .. (gCfg.model ~= "" and gCfg.model or "not reported"),
		"Smart types   : " .. (gCfg.smartTypes ~= "" and gCfg.smartTypes or "none reported"),
		"Managed by    : " .. tostring(Properties["Managed By"]) .. (gCfg.hubId and (" (device " .. gCfg.hubId .. ")") or ""),
		"Pictures      : " .. (PictureUrl(true, false) or "not set up") .. "  Basic login " .. (gCfg.picUser ~= "" and gCfg.picUser or "-")
			.. " / password " .. (gCfg.picPass ~= "" and "set" or "NOT SET"),
		"Live video    : " .. gCfg.liveVideo .. " on Control4 OS " .. (v and v.text or "?")
			.. ((v and not VersionAtLeast(v, DYNAMIC_STREAMS_OS)) and " (needs " .. DYNAMIC_STREAMS_OS .. " for video)" or ""),
	}
	for _, q in ipairs(QUALITY_ORDER) do
		lines[#lines + 1] = string.format("Stream %-7s: %s", q, Available(q) and MaskUrl(StreamUrl(q)) or "none")
	end
	local p = ReadProxyProperties()
	lines[#lines + 1] = "Camera page   : " .. (p and (tostring(p.address) .. ":" .. tostring(p.httpPort) .. " auth " .. tostring(p.authType)
		.. " required " .. tostring(p.authRequired) .. (PageMatches(p) and " (as it should be)" or " (DIFFERS - see Attention)")) or "cannot be read")
	lines[#lines + 1] = "Alerts        : " .. AlertsDescription() .. " - alert on: " .. tostring(Properties["Alert On"]) .. " - hold " .. HoldSeconds() .. " s"
	lines[#lines + 1] = "Events        : " .. (gState.eventsLive and "live" or "not live") .. " - last: " .. tostring(Properties["Last Event"] or "")
	lines[#lines + 1] = "Variables     : DIRECTORLINK_CAMERA=" .. tostring(GetVar("DIRECTORLINK_CAMERA")) .. " KIND=" .. tostring(GetVar("DIRECTORLINK_CAMERA_KIND"))
		.. " LAST_ALERT=" .. tostring(GetVar("LAST_ALERT")) .. " LAST_RING=" .. tostring(GetVar("LAST_RING"))
	if (Properties["Attention"] or "") ~= "" then lines[#lines + 1] = "ATTENTION     : " .. Properties["Attention"] end
	lines[#lines + 1] = "================================================"
	PrintReport(lines)
end

local function TestPicture()
	for _, high in ipairs({ false, true }) do
		GetOwnPicture(high, function(code, body, err, ms)
			local what = high and "full view" or "tile"
			if code == 200 and IsJpeg(body) then
				local w, h = JpegSize(body)
				PrintReport({ string.format("Test Picture %s: OK in %d ms - %sx%s, %s (%s)", what, ms or 0, tostring(w or "?"), tostring(h or "?"),
					ByteSize(#body), tostring(PictureUrl(high, false))) })
			else
				PrintReport({ string.format("Test Picture %s: FAILED - %s (%s)", what, err or ("HTTP " .. tostring(code) .. " " .. string.sub(tostring(body or ""), 1, 120)),
					tostring(PictureUrl(high, false))) })
			end
		end)
	end
end

--[[=============================================================================
    Commands, actions, proxy messages
===============================================================================]]
local ACTIONS = {
	Reconnect = function()
		gState.lastHubReport = nil
		local hub = FindHub()
		if hub then SendToDriver(hub, "DL_CAMERA_STATUS", { DEVICE_ID = MyDeviceId(), PROTECT_ID = gCfg.protectId or "", NAME = CameraName(),
			NEED_CONFIG = "1", NEED_STREAMS = "1", VERSION = DRIVER_SEMVER, KIND = Kind(), DISABLED = CameraEnabled() and "0" or "1" }) end
		SyncCameraPage("reconnect")
	end,
	TestPicture = TestPicture,
	Report = Report,
}

local COMMANDS = {
	SET_ALERTS = function(p)
		local s = string.upper(p["State"] or "TOGGLE")
		if s == "ON" then SetAlerts(true, "programming")
		elseif s == "OFF" then SetAlerts(false, "programming")
		else SetAlerts(not AlertsEnabled(), "programming") end
	end,
	SNOOZE_ALERTS = function(p) SnoozeAlerts(p["Minutes"], "programming") end,
	SET_ALERT_ON = function(p)
		if ALERT_FILTERS[p["Alert On"] or ""] then
			UpdateProperty("Alert On", p["Alert On"])
			UpdateExtras()
		end
	end,

	-- Messages from the UniFi Protect Hub
	DL_CONFIGURE = function(p)
		gCfg.hubId = tonumber(p.HUB_ID) or gCfg.hubId
		if p.HUB_ALERTS then gCfg.hubAlerts = toboolean(p.HUB_ALERTS) end
		if p.PROTECT_ID and p.PROTECT_ID ~= "" and p.PROTECT_ID ~= gCfg.protectId then
			if gCfg.protectId then LogInfo("Now UniFi camera %s (was %s)", p.PROTECT_ID, gCfg.protectId) end
			gCfg.protectId = p.PROTECT_ID
			gCfg.streams, gCfg.ringSeen = {}, false
			gState.protectState = nil
		end
		gState.claimError = nil
		SetAttention("claim", nil)
		local pageBefore = table.concat({ gCfg.serverAddress, tostring(gCfg.serverPort), gCfg.picUser, gCfg.picPass }, "|")
		if ValidAddress(p.SERVER_ADDRESS) then gCfg.serverAddress = trim(p.SERVER_ADDRESS) end
		if tonumber(p.SERVER_PORT) then gCfg.serverPort = tonumber(p.SERVER_PORT) end
		if p.PIC_USER and p.PIC_USER ~= "" then gCfg.picUser = p.PIC_USER end
		if p.PIC_PASS and p.PIC_PASS ~= "" then
			gCfg.picPass = p.PIC_PASS
			RegisterSecret(gCfg.picPass)
		end
		if p.CONSOLE_HOST then gCfg.consoleHost = p.CONSOLE_HOST end
		if p.ALERT_ON and ALERT_FILTERS[p.ALERT_ON] then UpdateProperty("Alert On", p.ALERT_ON) end
		if p.LOG_LEVEL and LOG_LEVELS[p.LOG_LEVEL] and p.LOG_LEVEL ~= Properties["Log Level"] then
			UpdateProperty("Log Level", p.LOG_LEVEL)
			ApplyLogSettings()
		end
		if p.NAME and p.NAME ~= "" then
			gCfg.name = p.NAME
			UpdateProperty("UniFi Camera", p.NAME)
			if p.RENAME == "1" then
				local pid = ProxyId()
				local okName, current = pcall(function() return C4:GetDeviceDisplayName(pid) end)
				if pid and not (okName and current == p.NAME) then pcall(function() C4:RenameDevice(pid, p.NAME) end) end
			end
		end
		SaveCfg()
		SetLogPrefix()
		LogInfo("Settings from the hub: UniFi camera %s, pictures from %s:%s, live video %s", tostring(gCfg.protectId),
			gCfg.serverAddress, tostring(gCfg.serverPort), tostring(p.LIVE_VIDEO or gCfg.liveVideo))
		UpdateHubProperty()
		local pageAfter = table.concat({ gCfg.serverAddress, tostring(gCfg.serverPort), gCfg.picUser, gCfg.picPass }, "|")
		if pageAfter ~= pageBefore then WriteProxySettings("settings from the hub") else SyncCameraPage("settings from the hub") end
		ApplyState(p)
		AlertsChanged("hub")
		gState.lastHubReport = nil
		ReportToHub(true)
	end,
	DL_STREAMS = function(p)
		gCfg.streams = { high = p.HIGH or "", medium = p.MEDIUM or "", low = p.LOW or "" }
		RegisterStreamSecrets()
		if p.LIVE_VIDEO == "RTSP" or p.LIVE_VIDEO == "RTSPS" then gCfg.liveVideo = p.LIVE_VIDEO end
		SaveCfg()
		local have = {}
		for _, q in ipairs(QUALITY_ORDER) do if Available(q) then have[#have + 1] = q end end
		LogInfo("Streams from the hub: %s", #have > 0 and table.concat(have, ", ") or "none")
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
		UpdateVideo()
		UpdateStatus()
	end,
	DL_STATE = function(p) ApplyState(p) end,
	DL_EVENT = function(p) HandleEvent(p) end,
	DL_HUB_ALERTS = function(p)
		gCfg.hubId = tonumber(p.HUB_ID) or gCfg.hubId
		gCfg.hubAlerts = toboolean(p.ENABLED)
		SaveCfg()
		AlertsChanged("hub")
	end,
	DL_HUB_HELLO = function(p)
		gCfg.hubId = tonumber(p.HUB_ID) or gCfg.hubId
		if p.HUB_ALERTS then gCfg.hubAlerts = toboolean(p.HUB_ALERTS) end
		SaveCfg()
		UpdateHubProperty()
		AlertsChanged("hub")
		ReportToHub(true)
	end,
	DL_LOG_LEVEL = function(p)
		if LOG_LEVELS[p.LOG_LEVEL or ""] then
			UpdateProperty("Log Level", p.LOG_LEVEL)
			ApplyLogSettings()
		end
	end,
	DL_CLAIM_FAILED = function(p)
		gState.claimError = p.TEXT or "The hub found no such UniFi camera"
		SetAttention("claim", gState.claimError)
		UpdateStatus()
	end,
}

local EXTRAS_COMMANDS = {
	EXTRAS_ALERTS = function(v) SetAlerts(toboolean(v), "camera controls") end,
	EXTRAS_ALERT_ON = function(v) COMMANDS.SET_ALERT_ON({ ["Alert On"] = v }) end,
	EXTRAS_SNOOZE = function() SnoozeAlerts(60, "camera controls") end,
}
local EXTRAS_IDS = { EXTRAS_ALERTS = "alerts", EXTRAS_ALERT_ON = "alerton" }

-- Edits on the camera's Properties page: the hub owns those values, so they are put back
local PAGE_COMMANDS = { SET_ADDRESS = true, SET_HTTP_PORT = true, SET_HTTPS_PORT = true, SET_USE_HTTPS = true, SET_USERNAME = true,
	SET_PASSWORD = true, SET_AUTHENTICATION_REQUIRED = true, SET_AUTHENTICATION_TYPE = true }

local function PageEdited(cmd)
	if os.time() - (gState.pageWrittenAt or 0) <= 10 then return end -- our own write coming back
	if not Configured() then return end
	-- The page does not show the login back, so a login edit is always put back
	local login = cmd == "SET_USERNAME" or cmd == "SET_PASSWORD"
	SetTimer("PAGE_RESTORE", 2000, function()
		local p = ReadProxyProperties()
		if p and PageMatches(p) and not login then return end
		LogInfo("The camera page is set by the UniFi Protect Hub (%s changed): putting it back", cmd)
		WriteProxySettings("camera page edited")
	end)
end

--[[=============================================================================
    DriverWorks entry points
===============================================================================]]
-- Never reorder: Director numbers variables in this order and other drivers read them.
local VARIABLES = {
	{ "DIRECTORLINK_CAMERA", "1", "STRING" },
	{ "DIRECTORLINK_CAMERA_KIND", "camera", "STRING" },
	{ "LAST_ALERT", "", "STRING" },
	{ "LAST_RING", "", "STRING" },
	{ "LAST_ALERT_TIME", "", "STRING" },
	{ "LAST_DETECTION", "", "STRING" },
	{ "ONLINE", "0", "BOOL" },
	{ "ALERTS_ENABLED", "1", "BOOL" },
	{ "ALERT_ACTIVE", "0", "BOOL" },
	{ "MOTION", "0", "BOOL" },
	{ "PERSON", "0", "BOOL" },
	{ "VEHICLE", "0", "BOOL" },
	{ "ANIMAL", "0", "BOOL" },
	{ "PACKAGE", "0", "BOOL" },
	{ "FACE", "0", "BOOL" },
	{ "LICENSE_PLATE", "0", "BOOL" },
	{ "LINE_CROSSING", "0", "BOOL" },
	{ "INTRUSION", "0", "BOOL" },
	{ "RINGING", "0", "BOOL" },
	{ "LAST_SOUND", "", "STRING" },
	-- 1.0.1: the ids of Alert and Ring for DirectorLink (after the others: their order never changes)
	{ "DIRECTORLINK_CAMERA_EVENTS", "Alert=1", "STRING" },
}

function OnDriverInit()
	math.randomseed(os.time())
	gState.startedAt = os.time()
	LoadCfg()
	-- Director starts added variables at their default: the last alert and ring come back
	for _, v in ipairs(VARIABLES) do
		local saved = gState.savedVars[v[1]]
		if type(saved) == "string" then v[2] = saved end
	end
	AddVariables(VARIABLES)
	SetAgreementVariables(true)
	gState.lastAlert = GetVar("LAST_ALERT") or ""
end

function OnDriverLateInit(dit)
	ApplyLogSettings()
	SetLogPrefix()
	pcall(function()
		local build = tostring(C4:GetDriverConfigInfo("version") or "")
		UpdateProperty("Driver Version", DRIVER_SEMVER ~= "dev" and (DRIVER_SEMVER .. " (" .. build .. ")") or build)
	end)
	SetVar("DIRECTORLINK_CAMERA", "1")
	for binding in pairs(CONTACT_BINDINGS) do SendContact(binding, false, true) end
	for _, d in pairs(DETECTIONS) do SetVar(d.var, false) end
	SetVar("ONLINE", false)
	SetVar("ALERT_ACTIVE", false)
	SetVar("RINGING", false)
	if dit == "DIT_ADDING" or (DIT_ADDING ~= nil and dit == DIT_ADDING) then
		pcall(function()
			C4:SendToProxy(CAMERA_PROXY, "PROPERTY_DEFAULTS", {
				HTTP_PORT = tostring(gCfg.serverPort or 47080), RTSP_PORT = tostring(RTSP_PORT),
				AUTHENTICATION_REQUIRED = "true", AUTHENTICATION_TYPE = "BASIC",
			}, "NOTIFY")
		end)
	end
	CheckControllerVersion()
	SetAttention("proxy", nil, true) -- also hides the empty Attention line
	KindChanged()
	UpdateHubProperty()
	UpdateVideo()
	AlertsChanged("startup")
	SendExtrasSetup()
	UpdateExtras()
	if gCfg.protectId and gCfg.name ~= "" then UpdateProperty("UniFi Camera", gCfg.name) end
	SetTimer("PAGE_SYNC", 5000, function() SyncCameraPage("startup") end)
	SetTimer("REPORT", STATUS_REPORT_MS, function() ReportToHub() end, true)
	ReportToHub(true)
end

function OnDriverDestroyed()
	KillAllTimers()
end

function OnPropertyChanged(name)
	LogDebug("Property changed: %s = %s", name, Properties[name])
	if name == "Log Level" then
		ApplyLogSettings()
	elseif name == "Alerts" then
		if gCfg.snoozeUntil ~= 0 then gCfg.snoozeUntil = 0; SaveCfg() end
		AlertsChanged("Composer")
	elseif name == "Alert On" then
		UpdateExtras()
	elseif name == "Contact State When Active" then
		for binding in pairs(CONTACT_BINDINGS) do SendContact(binding, ContactActive(binding)) end
	elseif name == "Camera Enabled" then
		if not CameraEnabled() then
			LogInfo("Camera disabled: no events, alerts or pictures")
			EndAllDetections()
		else
			LogInfo("Camera enabled")
		end
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
		UpdateStatus()
		ReportToHub(true)
	elseif name == "Camera Type" then
		KindChanged()
		UpdateStatus()
		ReportToHub(true)
	elseif name == "UniFi Camera" then
		local text = trim(Properties["UniFi Camera"] or "")
		if text ~= "" and text ~= gCfg.name and text ~= gCfg.protectId then
			LogInfo("Linking to the UniFi camera '%s'", text)
			gState.claim = text
			gState.claimError = nil
			gState.lastHubReport = nil
			ReportToHub(true)
		end
	elseif name == "Video Quality" then
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
	end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	if LOG_LEVEL >= 4 and strCommand ~= "GET_STREAM_URLS" and string.sub(strCommand, 1, 4) ~= "GET_" then
		local parts = {}
		for k, v in pairs(tParams) do
			parts[#parts + 1] = tostring(k) .. "=" .. (string.find(string.upper(tostring(k)), "PASSWORD", 1, true) and "***" or tostring(v))
		end
		LogDebug("ReceivedFromProxy(%s, %s, {%s})", idBinding, strCommand, table.concat(parts, ", "))
	end

	if CONTACT_BINDINGS[idBinding] then
		if strCommand == "GET_STATE" then SendContact(idBinding, ContactActive(idBinding), true) end
		return
	end

	if UI_REQ[strCommand] then
		local ok, res = pcall(UI_REQ[strCommand], tParams)
		if ok then return res end
		LogError("%s failed: %s", strCommand, res)
		return
	end

	if EXTRAS_COMMANDS[strCommand] then
		local id = EXTRAS_IDS[strCommand]
		local value = tParams.VALUE or tParams.value or (id and tParams[id])
		local ok, err = pcall(EXTRAS_COMMANDS[strCommand], value)
		if not ok then
			LogError("%s failed: %s", strCommand, err)
			UpdateExtras()
		end
		return
	end

	if PAGE_COMMANDS[strCommand] or strCommand == "SET_RSTP_PORT" or strCommand == "SET_RTSP_PORT" then
		if PAGE_COMMANDS[strCommand] then PageEdited(strCommand) end
	end
end

-- The camera proxy takes its answers (stream URLs, snapshot path) from UIRequest
function UIRequest(strCommand, tParams)
	local handler = UI_REQ[strCommand]
	if handler then
		local ok, res = pcall(handler, tParams or {})
		if ok then return res end
		LogError("UIRequest %s failed: %s", strCommand, res)
	end
	return ""
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
	if name == "CAMERA_ONLINE" then return TestBool(gState.online == true, tParams, "Online")
	elseif name == "ALERTS_ENABLED" then return TestBool(AlertsEnabled(), tParams, "On")
	elseif name == "ALERT_ACTIVE" then return TestBool(gState.alertActive, tParams, "Active")
	elseif name == "MOTION_ACTIVE" then return TestBool(IsDetectionActive("Motion"), tParams, "Active")
	elseif name == "IS_DOORBELL" then return TestBool(Kind() == "doorbell", tParams, "Doorbell")
	elseif name == "DETECTION_ACTIVE" then
		local active = IsDetectionActive(tostring(tParams.VALUE or ""))
		if tParams.LOGIC == "NOT_EQUAL" then return not active end
		return active
	elseif name == "LAST_ALERT" then return TestEquals(gState.lastAlert, tParams)
	end
	return false
end

-- Notification attachments: the picture taken at the last alert or ring. (No URL attachment: it
-- would have to carry the camera's picture login; the hub offers a live one with a short-lived token.)
function GetNotificationAttachmentURL()
	return ""
end

function GetNotificationAttachmentBytes()
	if gState.eventSnapshot then return Base64Encode(gState.eventSnapshot) end
	return ""
end

function FinishedWithNotificationAttachment()
end
