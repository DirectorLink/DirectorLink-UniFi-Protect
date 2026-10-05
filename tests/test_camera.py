"""Camera driver tests (offline).   python tests/test_camera.py"""
import datetime
import re
import xml.etree.ElementTree as ET

from harness import Driver, check, finish

PROTECT_ID = "66f1a2b3c4d5e6f7081920a2"
PIC_USER, PIC_PASS = "c4cam1a2b3c4d", "0123456789abcdef0123456789"
STREAMS = {"HIGH": "rtsps://192.168.50.1:7441/HiTok3nQ8xZp2Lm?enableSrtp", "MEDIUM": "rtsps://192.168.50.1:7441/MedTok3nW4vB7nK?enableSrtp",
           "LOW": "rtsps://192.168.50.1:7441/LowTok3nR6tY9uP?enableSrtp", "LIVE_VIDEO": "RTSP"}
T = 1791230400000
T_ISO = datetime.datetime.fromtimestamp(T // 1000, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def jpeg(w, h):
    return (b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xc0\x00\x11\x08"
            + h.to_bytes(2, "big") + w.to_bytes(2, "big") + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xff\xd9")


def picture_server(method, url, headers, body):
    """The hub's picture server, as the camera's own requests see it."""
    import base64
    if not url.startswith("http://192.168.50.10:47080/snapshot/1003.jpg"):
        return 404, {}, "no"
    if headers.get("Authorization") != "Basic " + base64.b64encode(f"{PIC_USER}:{PIC_PASS}".encode()).decode():
        return 401, {}, ""
    return 200, {"Content-Type": "image/jpeg"}, jpeg(1920, 1080) if url.endswith("?high=1") else jpeg(640, 360)


def started(os_version="3.4.3.123", responder=picture_server):
    d = Driver("camera", responder)
    d.run(f'DEVICE_ID = 1003; PROXY_DEVICE = 1004; OS_VERSION = "{os_version}"; DISPLAY_NAMES[1004] = "Front Door"')
    d.call("OnDriverInit")
    d.run("OnDriverLateInit('DIT_ADDING')")
    return d


def configure(d, **extra):
    p = {"HUB_ID": "500", "HUB_ALERTS": "1", "PROTECT_ID": PROTECT_ID, "NAME": "Front Door", "KIND": "doorbell", "MODEL": "",
         "STATE": "CONNECTED", "SMART_TYPES": "person,package,face", "SERVER_ADDRESS": "192.168.50.10", "SERVER_PORT": "47080",
         "PIC_USER": PIC_USER, "PIC_PASS": PIC_PASS, "LIVE_VIDEO": "RTSP", "CONSOLE_HOST": "192.168.50.1", "CONSOLE": "1", "EVENTS": "1",
         "LOG_LEVEL": "Debug", "RENAME": "1"}
    p.update(extra)
    d.call("ExecuteCommand", "DL_CONFIGURE", d.table(p))
    d.call("ExecuteCommand", "DL_STREAMS", d.table(STREAMS))


def event(d, etype, eid, types="", end=False, action=None, start=T):
    d.call("ExecuteCommand", "DL_EVENT", d.table({"ACTION": action or ("update" if end else "add"), "TYPE": etype, "ID": eid, "TYPES": types,
                                                   "START": str(start), "END": str(start + 5000) if end else ""}))


def ui(d, cmd, params=None):
    return d.call("UIRequest", cmd, d.table(params or {}))


# ---------------------------------------------------------------- a new camera
d = started()
check(d.var("DIRECTORLINK_CAMERA") == "1" and d.var("DIRECTORLINK_CAMERA_KIND") == "camera", "DirectorLink agreement: DIRECTORLINK_CAMERA = 1, kind camera")
vars_order = [k for k in ("DIRECTORLINK_CAMERA", "DIRECTORLINK_CAMERA_KIND", "LAST_ALERT", "LAST_RING")]
check(all(d.var(v) is not None for v in vars_order), "agreement variables exist")
check(any(c == "PROPERTY_DEFAULTS" and p.get("AUTHENTICATION_TYPE") == "BASIC" and p.get("RTSP_PORT") == "7447" for _, c, p in d.proxy()),
      "a new camera page starts with Basic login and RTSP port 7447")
check(d.prop("Status").startswith("Waiting for the UniFi Protect Hub"), f"without a hub it says what to do ({d.prop('Status')})")
check(ui(d, "GET_SNAPSHOT_QUERY_STRING", {"SIZE_X": "320"}) == "<snapshot_query_string></snapshot_query_string>", "no snapshot path before it is set up (an empty document, not nothing)")
check(ui(d, "GET_STREAM_URLS") == "<streams></streams>", "no stream before it is set up")
check(ui(d, "GET_MJPEG_QUERY_STRING") == "<mjpeg_query_string></mjpeg_query_string>", "MJPEG query answered with an empty document")

# ---------------------------------------------------------------- the hub configures it
d.run('PROXY_PROPS = "<camera_properties><address>127.0.0.1</address><http_port>80</http_port><authentication_type>DIGEST</authentication_type></camera_properties>"')
d.clear()
configure(d)
cmds = {c: p for dev, c, p, _ in d.device_cmds(device=1004)}
check(cmds.get("SET_ADDRESS", {}).get("ADDRESS") == "192.168.50.10" and cmds.get("SET_HTTP_PORT", {}).get("PORT") == "47080",
      "camera page: the controller's address and the picture server's port")
check(cmds.get("SET_AUTHENTICATION_TYPE", {}).get("TYPE") == "BASIC" and cmds.get("SET_AUTHENTICATION_REQUIRED", {}).get("REQUIRED") == "True",
      "camera page: Basic login required")
check(cmds.get("SET_USERNAME", {}).get("USERNAME") == PIC_USER and cmds.get("SET_PASSWORD", {}).get("PASSWORD") == PIC_PASS, "camera page: this camera's own login")
check(all(log is False for dev, c, p, log in d.device_cmds(device=1004)), "the page writes are not logged by Director")
check(not d.g.RENAMED[1], "not renamed: the Control4 name is already the UniFi name")
d.run('DISPLAY_NAMES[1004] = "Camera 1"')
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "PROTECT_ID": PROTECT_ID, "NAME": "Front Door", "RENAME": "1"}))
check(list(d.g.RENAMED[1].values()) == [1004, "Front Door"], "renamed to the UniFi name when it differs")
d.run('DISPLAY_NAMES[1004] = "Front Door"')
check(d.var("DIRECTORLINK_CAMERA_KIND") == "doorbell", "kind doorbell from the hub")
check(d.prop("Log Level") == "Debug", "the hub's Log Level is taken")
check(d.prop("Status") == "Online - events live - alerts on", f"status ({d.prop('Status')})")
check(d.prop("Video") == "RTSP (port 7447) - streams: High, Medium, Low", f"Video ({d.prop('Video')})")
check(d.prop("UniFi Camera") == "Front Door", "UniFi Camera shows the linked camera")
check(d.g.PERSIST_ENC["DL_PASS"] is True and d.g.PERSIST_ENC["DL_STREAMS"] is True, "the picture password and stream URLs are kept encrypted")
check(PIC_PASS not in str(dict(d.g.PERSIST["DL_CFG"])), "the plain settings hold no password")
rep = [p for dev, c, p, _ in d.device_cmds("DL_CAMERA_STATUS")][-1]
check(rep["PROTECT_ID"] == PROTECT_ID and rep["ONLINE"] == "1" and rep["KIND"] == "doorbell" and rep["NEED_STREAMS"] == "0", "reports to the hub")

# ---------------------------------------------------------------- pictures and video for Navigators
check(ui(d, "GET_SNAPSHOT_QUERY_STRING", {"SIZE_X": "320", "SIZE_Y": "180"}) == "<snapshot_query_string>snapshot/1003.jpg</snapshot_query_string>",
      "a tile gets the standard picture")
check(ui(d, "GET_SNAPSHOT_QUERY_STRING", {"SIZE_X": "1920", "SIZE_Y": "1080"}) == "<snapshot_query_string>snapshot/1003.jpg?high=1</snapshot_query_string>",
      "full screen gets the full view")
xml = ui(d, "GET_STREAM_URLS", {"RESOLUTION": "1920x1080", "CODEC": "h264"})
root = ET.fromstring(xml)
urls = [s.get("url") for s in root.findall("stream")]
check(urls[0] == "rtsp://192.168.50.1:7447/HiTok3nQ8xZp2Lm" and len(urls) == 3, f"RTSP: the console's plain RTSP form on port 7447, high first ({urls[0][:30]}...)")
check(all(s.get("codec") == "h264" and s.get("resolution") for s in root.findall("stream")) and "/>" in xml and "</stream>" not in xml,
      "self-closing <stream/> elements, well-formed XML")
small = ET.fromstring(ui(d, "GET_STREAM_URLS", {"RESOLUTION": "640x360"})).findall("stream")[0].get("url")
check(small.endswith("/LowTok3nR6tY9uP"), "a small tile gets the low stream")
check(ET.fromstring(ui(d, "GET_STREAM_URLS", {"RESOLUTION": "1280x720", "KEY": "77"})).get("key") == "77", "the client's KEY is echoed")
d.call("ExecuteCommand", "DL_STATE", d.table({"LIVE_VIDEO": "RTSPS"}))
check(any(c == "DYNAMIC_URLS_CHANGED" for _, c, _ in d.proxy()), "switching RTSP/RTSPS tells Navigators to ask again")
rtsps = ET.fromstring(ui(d, "GET_STREAM_URLS", {"RESOLUTION": "1920x1080"})).findall("stream")[0].get("url")
check(rtsps == STREAMS["HIGH"], "RTSPS: the console's own rtsps:// URL (port 7441)")
d.call("ExecuteCommand", "DL_STATE", d.table({"LIVE_VIDEO": "RTSP"}))
d.g.Properties["Video Quality"] = "Low"
check(ET.fromstring(ui(d, "GET_STREAM_URLS", {"RESOLUTION": "1920x1080"})).findall("stream")[0].get("url").endswith("/LowTok3nR6tY9uP"), "Video Quality Low always uses the low stream")
d.g.Properties["Video Quality"] = "Auto"
check(ui(d, "GET_RTSP_H264_QUERY_STRING", {"SIZE_X": "1920"}) == "<rtsp_h264_query_string>HiTok3nQ8xZp2Lm</rtsp_h264_query_string>", "the static path query is the bare token")
d.call("ExecuteCommand", "DL_STREAMS", d.table({"HIGH": STREAMS["HIGH"], "MEDIUM": "", "LOW": ""}))
check(ET.fromstring(ui(d, "GET_STREAM_URLS", {"RESOLUTION": "320x180"})).findall("stream")[0].get("url").endswith("/HiTok3nQ8xZp2Lm"), "a missing quality falls back to the nearest one")
d.call("ExecuteCommand", "DL_STREAMS", d.table(STREAMS))

# ---------------------------------------------------------------- alerts: LAST_ALERT, then "Alert"
d.clear()
event(d, "smartDetectZone", "ev1", "person")
check(d.events()[:2] == ["Person Detected", "Alert"], f"a person: Person Detected, then Alert ({d.events()})")
ev = [list(x.values()) for x in d.g.EVENT_VARS.values()]
alert_ev = [e for e in ev if e[0] == "Alert"][0]
check(alert_ev[1] == "Person", "LAST_ALERT is 'Person' when Alert fires")
check(d.var("PERSON") == "1" and d.var("ALERT_ACTIVE") == "1" and re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", d.var("LAST_ALERT_TIME")), "variables")
hub_alert = d.device_cmds("DL_CAMERA_ALERT", 500)
check(hub_alert and hub_alert[0][2]["TYPE"] == "Person", "the hub hears of the alert")
check(len(d.g.HISTORY) == 1, "recorded in the Control4 History")
check(len(d.call("GetNotificationAttachmentBytes")) > 0, "a notification picture taken through the hub's picture server")
d.clear()
event(d, "smartDetectZone", "ev1", "person,vehicle", action="update")
check(d.events() == ["Vehicle Detected"], f"an update of the same event adds Vehicle Detected but no second Alert ({d.events()})")
event(d, "smartDetectZone", "ev1", "person,vehicle", end=True)
check(d.var("PERSON") == "0" and d.var("VEHICLE") == "0", "the end of the event ends its detections")
d.clear()
event(d, "smartDetectZone", "ev2", "vehicle")
check("Alert" not in d.events() and d.events() == ["Vehicle Detected"], "another event within Hold Time: detection events, no Alert")
d.timers()  # Hold Time passes
check(d.var("ALERT_ACTIVE") == "0", "the alert ends after Hold Time")
d.clear()
event(d, "motion", "ev3")
check(d.events() == ["Motion Detected", "Alert"] and d.var("LAST_ALERT") == "Motion", "Any detection: motion alerts as 'Motion'")
event(d, "motion", "ev3", end=True)
check("Motion Ended" in d.events() and d.var("MOTION") == "0", "Motion Ended")
d.timers()

# Alert On filters
d.g.Properties["Alert On"] = "People only"
d.clear()
event(d, "smartDetectZone", "ev4", "vehicle")
event(d, "motion", "ev5")
check("Alert" not in d.events() and "Vehicle Detected" in d.events(), "People only: a vehicle or motion runs automations but does not alert")
event(d, "smartDetectZone", "ev6", "face")
check(d.events()[-1] == "Alert" and d.var("LAST_ALERT") == "Face", "People only: a face alerts")
d.timers()
d.g.Properties["Alert On"] = "People and vehicles"
d.clear()
event(d, "smartDetectLine", "ev7", "licensePlate")
check(d.events() == ["License Plate Detected", "Line Crossing", "Alert"] and d.var("LAST_ALERT") == "License Plate",
      f"People and vehicles: a license plate crossing a line alerts as 'License Plate', and fires Line Crossing ({d.events()})")
d.timers()
event(d, "smartDetectZone", "ev8", "animal")
check(d.events()[-1] != "Alert", "People and vehicles: an animal does not alert")
d.g.Properties["Alert On"] = "Any detection"
d.timers()
d.clear()
event(d, "smartDetectZone", "ev9", "")
check(d.events() == ["Intrusion Detected", "Alert"] and d.var("LAST_ALERT") == "Intrusion", "a zone event without a type: Intrusion")
d.timers()
d.clear()
event(d, "smartDetectZone", "ev10", "person,package")
check(d.var("LAST_ALERT") == "Person", "several things in one event: the person is named")
d.timers()
# a short event that arrives already ended
d.clear()
event(d, "smartDetectZone", "ev11", "package", end=True, action="add")
check(d.events() == ["Package Detected", "Alert"] and d.var("LAST_ALERT") == "Package", "an event that arrives already finished still counts once")
d.timers()
check(d.var("PACKAGE") == "0", "and ends by itself")

# alerts off, hub alerts off, snooze: detections still fire, no Alert
for setup, label in ((lambda: d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "Off"})), "alerts off"),
                     (lambda: d.call("ExecuteCommand", "DL_HUB_ALERTS", d.table({"HUB_ID": "500", "ENABLED": "0"})), "the hub's alerts off"),
                     (lambda: d.call("ExecuteCommand", "SNOOZE_ALERTS", d.table({"Minutes": "30"})), "snoozed")):
    d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "On"}))
    d.call("ExecuteCommand", "DL_HUB_ALERTS", d.table({"HUB_ID": "500", "ENABLED": "1"}))
    d.timers()
    setup()
    d.clear()
    event(d, "smartDetectZone", "off-" + label, "person")
    check(d.events() == ["Person Detected"], f"{label}: Person Detected, no Alert ({d.events()})")
    event(d, "smartDetectZone", "off-" + label, "person", end=True)
d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "On"}))
d.call("ExecuteCommand", "DL_HUB_ALERTS", d.table({"HUB_ID": "500", "ENABLED": "1"}))
check(d.var("ALERTS_ENABLED") == "1", "alerts back on")
d.timers()

# ---------------------------------------------------------------- rings: LAST_RING, then "Ring"
d.clear()
event(d, "ring", "r1")
check(d.events() == ["Ring"] and d.var("LAST_RING") == T_ISO, f"Ring with LAST_RING in ISO 8601 UTC, the console's time of the press ({d.var('LAST_RING')})")
ring_ev = [list(x.values()) for x in d.g.EVENT_VARS.values() if list(x.values())[0] == "Ring"][0]
check(ring_ev[2] == T_ISO, "LAST_RING is set when Ring fires")
check(d.var("RINGING") == "1" and d.device_cmds("DL_CAMERA_RING", 500), "RINGING and the hub hears of it")
event(d, "ring", "r1", end=True)
event(d, "ring", "r1")
check(d.events() == ["Ring"], "the same ring is not rung twice")
d.timers()
check(d.var("RINGING") == "0", "RINGING ends")
d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "Off"}))
d.run("os.time = (function(real) return function(t) if t then return real(t) end return real() + 5 end end)(os.time)")
d.clear()
event(d, "ring", "r2")
check(d.events() == ["Ring"], "rings ring even with alerts off")
d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "On"}))

# a camera that rings is a doorbell
d2 = started()
configure(d2, KIND="camera", NAME="Back Gate", PROTECT_ID="66f1a2b3c4d5e6f7081920a4")
check(d2.var("DIRECTORLINK_CAMERA_KIND") == "camera", "Back Gate starts as a camera")
event(d2, "ring", "r9")
check(d2.var("DIRECTORLINK_CAMERA_KIND") == "doorbell" and d2.call("TestCondition", "IS_DOORBELL", d2.table({"VALUE": "Doorbell"})) is True,
      "the first ring makes it a doorbell")
d2.g.Properties["Camera Type"] = "Camera"
d2.call("OnPropertyChanged", "Camera Type")
check(d2.var("DIRECTORLINK_CAMERA_KIND") == "camera", "Camera Type overrides it")

# sounds
d.clear()
event(d, "smartAudioDetect", "s1", "alrmSmoke")
check(d.events() == ["Sound Detected"] and d.var("LAST_SOUND") == "Smoke alarm", "a smoke alarm sound: Sound Detected, LAST_SOUND")

# ---------------------------------------------------------------- state from the console
d.clear()
d.call("ExecuteCommand", "DL_STATE", d.table({"STATE": "DISCONNECTED"}))
check(d.prop("Status") == "Offline - the camera is disconnected from UniFi Protect" and "Camera Offline" in d.events() and d.var("ONLINE") == "0",
      "a camera disconnected from Protect is offline")
d.call("ExecuteCommand", "DL_STATE", d.table({"STATE": "CONNECTED", "CONSOLE": "0"}))
check(d.prop("Status") == "Offline - the hub cannot reach the UniFi console", "the console unreachable")
d.call("ExecuteCommand", "DL_STATE", d.table({"CONSOLE": "1", "EVENTS": "0"}))
check(d.prop("Status") == "Online - events reconnecting - alerts on", f"the event stream down ({d.prop('Status')})")
d.call("ExecuteCommand", "DL_STATE", d.table({"EVENTS": "1"}))
d.call("ExecuteCommand", "DL_STATE", d.table({"STATE": "REMOVED"}))
check(d.prop("Status") == "This camera was removed from UniFi Protect", "removed from Protect")
d.call("ExecuteCommand", "DL_STATE", d.table({"STATE": "CONNECTED"}))

# ---------------------------------------------------------------- disabled
d.g.Properties["Camera Enabled"] = "No"
d.call("OnPropertyChanged", "Camera Enabled")
d.clear()
event(d, "smartDetectZone", "dis1", "person")
check(d.events() == [] and d.prop("Status").startswith("Disabled"), "Camera Enabled = No: no events")
check(ui(d, "GET_STREAM_URLS") == "<streams></streams>" and ui(d, "GET_SNAPSHOT_QUERY_STRING", {"SIZE_X": "320"}) == "<snapshot_query_string></snapshot_query_string>",
      "and no pictures or video")
d.g.Properties["Camera Enabled"] = "Yes"
d.call("OnPropertyChanged", "Camera Enabled")

# ---------------------------------------------------------------- the camera page is the hub's
d.run('PROXY_PROPS = "<camera_properties><address>192.168.50.77</address><http_port>80</http_port><authentication_type>BASIC</authentication_type>'
      '<authentication_required>True</authentication_required></camera_properties>"')
d.run("OnDriverLateInit('')")  # pageWrittenAt is not reset; pretend the last write was long ago
d.run("for k, t in pairs(TIMERS) do end")
d.clear()
d.call("ReceivedFromProxy", 5001, "SET_ADDRESS", d.table({"ADDRESS": "192.168.50.77"}))
d.run("os.time = (function(real) return function(t) if t then return real(t) end return real() + 60 end end)(os.time)")
d.call("ReceivedFromProxy", 5001, "SET_ADDRESS", d.table({"ADDRESS": "192.168.50.77"}))
d.timers()
restored = [p for dev, c, p, _ in d.device_cmds("SET_ADDRESS", 1004)]
check(restored and restored[-1]["ADDRESS"] == "192.168.50.10", "an edited camera page is put back (the hub owns it)")
# the page does not show the password back: an edited login is always put back
d.run('PROXY_PROPS = "<camera_properties><address>192.168.50.10</address><http_port>47080</http_port><authentication_type>BASIC</authentication_type>'
      '<authentication_required>True</authentication_required><username>******</username><password>******</password></camera_properties>"')
d.run("os.time = (function(real) return function(t) if t then return real(t) end return real() + 60 end end)(os.time)")
d.clear()
d.call("ReceivedFromProxy", 5001, "SET_PASSWORD", d.table({"PASSWORD": "typed-by-hand"}))
d.timers()
check([p["PASSWORD"] for dev, c, p, _ in d.device_cmds("SET_PASSWORD", 1004)] == [PIC_PASS], "a password typed on the camera page is replaced by the camera's own")

# ---------------------------------------------------------------- Test Picture and Setup Report use the real path
d.run("LOGS = {}")
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "TestPicture"}))
logs = "\n".join(d.logs())
check("Test Picture tile: OK" in logs and "640x360" in logs and "Test Picture full view: OK" in logs and "1920x1080" in logs,
      "Test Picture fetches its own pictures from the picture server with its login")
req = [e for e in d.http_log() if "snapshot" in e["url"]][-1]
check(req["url"] == "http://192.168.50.10:47080/snapshot/1003.jpg?high=1" and req["headers"]["Authorization"].startswith("Basic "), "with Basic login, to the controller")
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "Report"}))
logs = "\n".join(d.logs())
check("Stream high   : rtsp://192.168.50.1:7447/***" in logs and "UniFi camera  : " + PROTECT_ID in logs, "Setup Report shows streams with the token hidden")
check(not [s for s in ("HiTok3nQ8xZp2Lm", "MedTok3nW4vB7nK", "LowTok3nR6tY9uP", PIC_PASS) if s in "\n".join(d.logs()) + "\n".join(d2.logs())],
      "no log line shows a stream token or the picture password")

# ---------------------------------------------------------------- the picture belongs to its own alert
seq = started(responder=lambda m, u, h, b: picture_server(m, u, h, b))
configure(seq)
seq.async_http(True)
seq.clear()
event(seq, "smartDetectZone", "pa1", "person")
check("Alert" not in seq.events() and seq.var("LAST_ALERT") == "Person", "Alert waits for its picture (LAST_ALERT is already set)")
check(seq.call("GetNotificationAttachmentBytes") == "", "no old picture is offered meanwhile")
seq.flush_http()
check(seq.events()[-1] == "Alert" and len(seq.call("GetNotificationAttachmentBytes")) > 0, "Alert fires once its picture is in")
seq.timers()
seq.clear()
event(seq, "ring", "pr1")
check("Ring" not in seq.events() and seq.var("LAST_RING") != "", "Ring waits for its picture too")
seq.timers(max_ms=1500)
check(seq.events()[-1] == "Ring", "but at most 1.5 s")
seq.async_http(False)

# a type first named in the update that ends the event still counts
d.g.Properties["Alert On"] = "People only"
d.timers()
d.clear()
event(d, "smartDetectZone", "late1", "vehicle")
event(d, "smartDetectZone", "late1", "vehicle,person", end=True)
check("Person Detected" in d.events() and d.events().count("Alert") == 1 and d.var("LAST_ALERT") == "Person",
      f"a person first named as the event ends: Person Detected and an alert ({d.events()})")
d.timers()
check(d.var("PERSON") == "0" and d.var("VEHICLE") == "0", "and the detections end")
d.g.Properties["Alert On"] = "Any detection"

# the last alert and ring survive a restart; an event already running at the restart does not alert again
r = Driver("camera", picture_server)
r.run('DEVICE_ID = 1003; PROXY_DEVICE = 1004')
r.copy_persist_from(d, ("DL_CFG", "DL_PASS", "DL_STREAMS", "DL_VARS"))
r.call("OnDriverInit")
r.run("OnDriverLateInit('')")
check(r.var("LAST_ALERT") == d.var("LAST_ALERT") and r.var("LAST_RING") == d.var("LAST_RING") and r.var("LAST_RING") != "",
      "LAST_ALERT and LAST_RING survive a restart")
check(r.call("TestCondition", "LAST_ALERT", r.table({"VALUE": d.var("LAST_ALERT")})) is True, "and so does the Last alert conditional")
r.call("ExecuteCommand", "DL_STATE", r.table({"STATE": "CONNECTED", "CONSOLE": "1", "EVENTS": "1"}))
r.clear()
event(r, "smartDetectZone", "before-restart", "person", end=True, start=(r.eval("os.time()") - 120) * 1000)
check("Alert" not in r.events(), "the end of an event that began before the restart raises no second alert")

# ---------------------------------------------------------------- older Control4
old = started(os_version="3.3.1.500")
configure(old)
check("Live video needs Control4 OS 3.3.2 or newer" in old.prop("Attention") and old.g.ATTRIBS["Attention"] == 0, "OS 3.3.1: Attention says live video needs 3.3.2")
check(old.prop("Status").startswith("Online"), "pictures, alerts and rings still work")
new = started(os_version="3.3.2.1")
check(new.g.ATTRIBS["Attention"] == 1, "OS 3.3.2: nothing to say")

# ---------------------------------------------------------------- linking a camera added by hand
h = started()
h.run("C4I_BY_NAME['DirectorLink-UniFi-Protect.c4z'] = { 500 }")
h.clear()
h.g.Properties["UniFi Camera"] = "Garden"
h.call("OnPropertyChanged", "UniFi Camera")
claim = [p for dev, c, p, _ in h.device_cmds("DL_CAMERA_STATUS", 500)]
check(claim and claim[-1]["CLAIM"] == "Garden", "typing a name in UniFi Camera asks the hub to link it")
h.call("ExecuteCommand", "DL_CLAIM_FAILED", h.table({"TEXT": "No UniFi camera named 'Garden' on the console"}))
check(h.prop("Status") == "No UniFi camera named 'Garden' on the console", "a failed link is explained")

finish()
