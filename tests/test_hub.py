"""Hub driver tests (offline).   python tests/test_hub.py

The console is played by Console(): it answers the official Protect Integration API
with the recorded answers in tests/fixtures (shaped like Ubiquiti's OpenAPI schema).
"""
import base64
import json
import re

from harness import Driver, check, finish, fixture

from fake_console import BASE, CAM, GUID, HOST, KEY, TOKENS, Console, jpeg, ws_open, ws_send  # noqa: F401


def hub(console=None, address=HOST, key=KEY, connect=True):
    console = console or Console()
    d = Driver("hub", console)
    d.g.Properties["Console Address"] = address
    d.g.Properties["API Key"] = key
    d.run("DEVICE_ID = 500")
    d.call("OnDriverInit")
    d.call("OnDriverLateInit")
    if connect:
        d.timers()      # STARTUP_CONNECT -> meta/info, nvrs, cameras, sockets
    return d, console


def events_from(name):
    return [json.loads(line) for line in fixture(name).splitlines() if line.strip()]


def add_all(d):
    d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "AddCameras"}))
    ids = []
    for n in range(20):
        added = list(d.g.ADDED.values())
        if len(added) <= len(ids):
            break
        dev = 1001 + len(ids)
        added[len(ids)].cb(dev, d.table({}))
        ids.append(dev)
        d.timers()
    status = d.prop("Status")
    for _ in range(12):
        d.timers(max_ms=60000)
    return ids, status


def all_logs(d):
    return "\n".join(d.logs())


# ---------------------------------------------------------------- setup guidance
d, _ = hub(address="", key="", connect=False)
check(d.prop("Status").startswith("Setup: enter the Console Address and the API Key"), f"asks for the address and key ({d.prop('Status')})")
check("Settings > Control Plane > Integrations" in d.prop("Status"), "says where the API key is made")
check(not any(t.ms == 3000 for t in d.g.TIMERS.values()), "no connection attempt without a key")

# ---------------------------------------------------------------- connect
d, con = hub()
calls = [(m, p) for m, p, _ in con.calls]
check(calls[:3] == [("GET", "/v1/meta/info"), ("GET", "/v1/nvrs"), ("GET", "/v1/cameras")], f"connects: version first, then the console and its cameras ({calls[:3]})")
check(all(h.get("X-API-Key") == KEY for _, _, h in con.calls), "every request carries the X-API-Key header")
log = d.http_log()
check(all(e["url"].startswith(BASE + "/") for e in log) and not con.foreign, "requests go only to the configured console")
check(all(e["headers"].get("User-Agent") == "DirectorLink-UniFi-Protect/test" for e in log), "User-Agent DirectorLink-UniFi-Protect/<version>")
check(all(e["opts"].get("ssl_verify_peer") is False and e["opts"].get("ssl_verify_host") is False for e in log), "the console's self-signed certificate is accepted")
check(d.prop("Console") == "Demo UNVR - UniFi Protect 6.2.83" and d.var("PROTECT_VERSION") == "6.2.83", f"Console property ({d.prop('Console')})")
check(d.prop("Status") == "Connected - run Actions > Add New Cameras to add the console's cameras", f"status ({d.prop('Status')})")
check(d.prop("Found On Console") == "4 cameras, 1 doorbell - 5 not added yet", f"found summary ({d.prop('Found On Console')})")
check(d.var("CONSOLE_ONLINE") == "1", "CONSOLE_ONLINE")
net = d.net()
creates = [x for x in net if x[0] == "create"]
check([x[1:4] for x in creates] == [[6101, HOST, "SSL"], [6102, HOST, "SSL"]] or [x[1:4] for x in creates] == [[6102, HOST, "SSL"], [6101, HOST, "SSL"]],
      "opens the events and devices WebSockets to the console")
req = ws_open(d, 6101)
check(b"GET /proxy/protect/integration/v1/subscribe/events HTTP/1.1" in req and b"X-API-Key: " + KEY.encode() in req, "WebSocket /subscribe/events with the API key")
ws_open(d, 6102)
check(d.prop("Event Connection").startswith("Live since"), f"Event Connection shows it live ({d.prop('Event Connection')})")
check(d.prop("Picture Server").startswith("Listening on 192.168.50.10:47080"), f"picture server listening ({d.prop('Picture Server')})")

# older Protect (5.3.48 answers, fields that came later missing) works the same
d53, con53 = hub(Console(version="5.3.48", cameras="cameras_5.3.48.json"))
check(d53.prop("Found On Console") == "4 cameras, 1 doorbell - 5 not added yet" and d53.prop("Status").startswith("Connected"),
      f"Protect 5.3.48 answers understood ({d53.prop('Found On Console')})")

# ---------------------------------------------------------------- refusals are explained
dold, conold = hub(Console(version="5.2.39"))
check("UniFi Protect 5.2.39 on the console is too old" in dold.prop("Status") and "5.3 or newer" in dold.prop("Status"), f"too old Protect refused ({dold.prop('Status')})")
check("too old" in dold.prop("Last Error") and [p for _, p, _ in conold.calls] == ["/v1/meta/info"], "Last Error says so; nothing else is asked")
check(not [x for x in dold.net() if x[0] == "create"], "no WebSocket to a console that is too old")
check(any("[ERROR]" in l and "too old" in l for l in dold.logs()), "and the log says it as an error")
con401 = Console()
d401, _ = hub(con401, key="WrongKey-000000")
check(d401.prop("Status").startswith("The console refused the API key (HTTP 401)"), f"wrong key explained ({d401.prop('Status')})")
c404 = Console()
c404.status["/v1/meta/info"] = 404
d404, _ = hub(c404)
check("no UniFi Protect Integration API" in d404.prop("Status"), f"no API explained ({d404.prop('Status')})")
dnone, _ = hub(Console(), address="192.168.50.99")
check(dnone.prop("Status").startswith("Cannot reach the console at 192.168.50.99"), f"unreachable console explained ({dnone.prop('Status')})")
check(any(t.ms == 60000 and t.active for t in dnone.g.TIMERS.values()), "and retried in a minute")
dpref, conpref = hub(Console(), address="https://192.168.50.1/protect/dashboard")
check(dpref.prop("Status").startswith("Connected") and not conpref.foreign, "a pasted https:// address works")

# ---------------------------------------------------------------- redirects are never followed; 429 is retried
cred = Console()
cred.redirect.add("/v1/cameras")
dred, _ = hub(cred)
check("redirect" in dred.prop("Last Error") and not cred.foreign, f"a redirect is not followed, so the key stays on the console ({dred.prop('Last Error')})")
c429 = Console()
c429.limited = 1
d429, _ = hub(c429)
d429.timers()
check([p for _, p, _ in c429.calls].count("/v1/cameras") == 2 and d429.prop("Found On Console").startswith("4 cameras"),
      "HTTP 429 (rate limited) is retried after Retry-After")

# ---------------------------------------------------------------- add the cameras
d.clear()
ids, added_status = add_all(d)
added = list(d.g.ADDED.values())
names = [a.name for a in added]
check(names == ["Back Gate", "Driveway", "Front Door", "Garden", "UniFi Camera B2C3"], f"every camera added with its UniFi name ({names})")
check(all(a.file == "DirectorLink-UniFi-Protect-Camera.c4z" and a.room == 81 for a in added), "camera driver added in the hub's room")
cfg = {}
for dev, cmd, p, logged in d.device_cmds("DL_CONFIGURE"):
    cfg.setdefault(dev, p)
check(all(logged is False for _, _, _, logged in d.device_cmds("DL_CONFIGURE")), "settings messages are not logged by Director (they carry the picture login)")
by_name = {p["NAME"]: p for p in cfg.values()}
fd = by_name["Front Door"]
check(fd["PROTECT_ID"] == CAM[2] and fd["KIND"] == "doorbell" and fd["SERVER_ADDRESS"] == "192.168.50.10" and fd["SERVER_PORT"] == "47080",
      "Front Door: its UniFi id, a doorbell (it has a doorbell screen message), pictures from the controller's picture server")
check(fd["LIVE_VIDEO"] == "RTSP" and fd["RENAME"] == "1" and fd["ALERT_ON"] == "Any detection", "live video RTSP by default; renamed; Default Alert On")
users = {p["PIC_USER"] for p in cfg.values()}
passes = {p["PIC_PASS"] for p in cfg.values()}
check(len(users) == 5 and len(passes) == 5 and all(len(x) == 26 for x in passes), "each camera has its own random picture login")
check(by_name["Driveway"]["KIND"] == "camera" and by_name["Driveway"]["SMART_TYPES"] == "person,vehicle,licensePlate,animal", "Driveway: camera with smart detections")
check(added_status == "Added 5 cameras - drag them to their rooms in Composer", f"final status ({added_status})")
check(d.prop("Found On Console").endswith("0 not added yet"), f"Found On Console updated ({d.prop('Found On Console')})")
dev_of = {p["NAME"]: dev for dev, p in cfg.items()}

# streams: existing ones read, missing ones switched on
streams = {dev: p for dev, cmd, p, _ in d.device_cmds("DL_STREAMS")}
check(streams[dev_of["Driveway"]]["HIGH"].startswith("rtsps://192.168.50.1:7441/HiTok3n") and streams[dev_of["Driveway"]]["LOW"] != "",
      "streams already on are handed to the camera")
garden = streams.get(dev_of["Garden"], {})
check(garden.get("HIGH", "").endswith("/NewHiTok3nA1sD?enableSrtp"), "a camera with RTSP off gets its streams switched on (Create Streams = Automatic)")
check((CAM[3], "application/json", {"qualities": ["high", "medium", "low"]}) in con.posts, "POST /rtsps-stream with Content-Type application/json and the qualities")
check(not [x for x in con.posts if x[0] == CAM[1]], "no POST for a camera whose streams are on")

# ---------------------------------------------------------------- camera reports, alerts, rings
for name, dev in dev_of.items():
    d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": str(dev), "NAME": name, "ONLINE": "1", "PROTECT_ID": cfg[dev]["PROTECT_ID"], "VERSION": "test"}))
check(d.prop("Cameras") == "5 cameras - 5 online" and d.var("ALL_ONLINE") == "1", f"camera summary ({d.prop('Cameras')})")
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_ALERT", d.table({"DEVICE_ID": str(dev_of["Driveway"]), "NAME": "Driveway", "TYPE": "Person", "TIME": "2026-10-05T18:00:00Z"}))
check(d.events() == ["Camera Alert"] and d.var("LAST_ALERT_CAMERA") == "Driveway" and d.var("LAST_ALERT_TYPE") == "Person", "Camera Alert with camera and type")
check(len(d.call("GetNotificationAttachmentBytes")) > 0, "notification picture of the alerting camera")
url = d.call("GetNotificationAttachmentURL")
check(url.startswith("http://192.168.50.10:47080/snapshot/" + str(dev_of["Driveway"]) + ".jpg?high=1&t=") and "@" not in url,
      "live snapshot URL through the picture server, with a short-lived token instead of the camera's login")
notif_token = url.split("&t=")[1]
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_RING", d.table({"DEVICE_ID": str(dev_of["Front Door"]), "NAME": "Front Door", "TIME": "2026-10-05T18:01:00Z"}))
check(d.events() == ["Doorbell Ring"] and d.var("LAST_RING_CAMERA") == "Front Door" and d.var("LAST_RING_TIME") == "2026-10-05T18:01:00Z", "Doorbell Ring with camera and time")
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": str(dev_of["Garden"]), "NAME": "Garden", "ONLINE": "0", "PROTECT_ID": CAM[3]}))
check("Camera Offline" in d.events() and d.var("LAST_OFFLINE_CAMERA") == "Garden" and "offline: Garden" in d.prop("Cameras"), "Camera Offline names the camera")

# ---------------------------------------------------------------- events from the console reach the right camera
d.clear()
for e in events_from("ws_events.jsonl"):
    ws_send(d, 6101, e)
routed = [(dev, p["TYPE"], p["ID"], p["TYPES"], p["END"] != "") for dev, cmd, p, _ in d.device_cmds("DL_EVENT")]
drive, door = dev_of["Driveway"], dev_of["Front Door"]
check(routed[:4] == [(drive, "motion", "e01", "", False), (drive, "motion", "e01", "", True), (drive, "smartDetectZone", "e02", "person", False),
                     (drive, "smartDetectZone", "e02", "person,vehicle", False)], f"motion and smart detections go to their camera ({routed[:4]})")
check((door, "ring", "e03", "", False) in routed and (door, "smartAudioDetect", "e05", "alrmSmoke", False) in routed, "rings and sounds go to the doorbell")
check(not [r for r in routed if r[2] == "e06"], "sensor events are not sent to cameras")
check(all(log is False for _, _, _, log in d.device_cmds("DL_EVENT")), "event messages are not logged by Director")
first = [p for dev, cmd, p, _ in d.device_cmds("DL_EVENT") if p["ID"] == "e01"][0]
check(first["START"] == "1791230400000", "event times are passed exactly (milliseconds)")
d.clear()
ws_send(d, 6101, events_from("ws_events.jsonl")[0])
check(not d.device_cmds("DL_EVENT"), "the same event message twice is passed on once")
ws_send(d, 6101, "not json")
ws_send(d, 6101, {"type": "add"})
check(True, "messages that are not understood are skipped")

# ---------------------------------------------------------------- device changes
d.clear()
for e in events_from("ws_devices.jsonl"):
    ws_send(d, 6102, e)
states = [(dev, p.get("STATE"), p.get("NAME")) for dev, cmd, p, _ in d.device_cmds("DL_STATE")]
check((drive, "DISCONNECTED", "Driveway") in states and (drive, "CONNECTED", "Driveway East") in states, f"camera state and name changes reach the camera ({states[:2]})")
check((dev_of["Garden"], "REMOVED", None) in states, "a camera removed from Protect is told so")
check("New Cameras Found" in d.events() and d.prop("Found On Console").endswith("1 not added yet"), f"a new camera on the console is noticed ({d.prop('Found On Console')})")

# ---------------------------------------------------------------- the picture server
def request(d, path, login=None, method="GET", ip="192.168.50.20"):
    c = d.call("FakeConnect", ip)
    auth = ("Authorization: Basic " + base64.b64encode(login.encode()).decode() + "\r\n") if login else ""
    d.call("FakeRequest", c, f"{method} {path} HTTP/1.1\r\nHost: 192.168.50.10:47080\r\n{auth}\r\n")
    return c


def response(d, c):
    raw = d.call("Written", c)
    raw = raw if isinstance(raw, bytes) else raw.encode("latin-1")
    head, _, body = raw.partition(b"\r\n\r\n")
    return int(head.split()[1]) if head else None, head.decode("latin-1"), body


login = {name: cfg[dev]["PIC_USER"] + ":" + cfg[dev]["PIC_PASS"] for name, dev in dev_of.items()}
path_drive = f"/snapshot/{drive}.jpg"
d.run("NOW_MS = 1791230400000")
code, head, _ = response(d, request(d, path_drive))
check(code == 401 and 'WWW-Authenticate: Basic realm="UniFi Protect pictures"' in head, "no login: 401 with a Basic challenge")
code, _, _ = response(d, request(d, path_drive, login["Front Door"]))
check(code == 401, "another camera's login is refused")
code, _, _ = response(d, request(d, path_drive, cfg[drive]["PIC_USER"] + ":wrong"))
check(code == 401, "a wrong password is refused")
before = len(con.calls)
c = request(d, path_drive, login["Driveway"])
code, head, body = response(d, c)
check(code == 200 and "Content-Type: image/jpeg" in head and body[:2] == b"\xff\xd8" and f"Content-Length: {len(body)}" in head, "its own login: 200 with the picture")
snap = con.calls[-1]
check(snap[1] == f"/v1/cameras/{CAM[1]}/snapshot" and snap[2].get("X-API-Key") == KEY and snap[2].get("Accept") == "image/jpeg", "fetched from the console with the API key")
check(d.call("Written", c) and c.closed, "the connection is closed after the answer")
response(d, request(d, path_drive, login["Driveway"]))
check(len(con.calls) == before + 1, "asked again within a second: the same picture, no new request to the console")
d.run("NOW_MS = 1791230401500")
response(d, request(d, path_drive, login["Driveway"]))
check(len(con.calls) == before + 2, "a picture is kept at most one second")
code, _, body = response(d, request(d, path_drive + "?high=1", login["Driveway"]))
check(code == 200 and con.calls[-1][1].endswith("/snapshot?highQuality=true"), "?high=1 asks the console for the full view (highQuality=true)")
code, _, body = response(d, request(d, path_drive + "?high=1&t=" + notif_token))
check(code == 200 and body[:2] == b"\xff\xd8", "the notification's token opens that camera's picture without a login")
code, _, _ = response(d, request(d, f"/snapshot/{dev_of['Garden']}.jpg?high=1&t=" + notif_token))
check(code == 401, "the token opens no other camera")
code, _, _ = response(d, request(d, path_drive + "?high=1&t=" + "0" * 32))
check(code == 401, "a made-up token is refused")
d.run("for t, info in pairs(gPictures.tokens) do info.expires = os.time() - 1 end")
code, _, _ = response(d, request(d, path_drive + "?high=1&t=" + notif_token))
check(code == 401, "an expired token is refused")
check(notif_token not in all_logs(d), "the token is not logged")
code, _, _ = response(d, request(d, "/snapshot/999.jpg", "x:y"))
check(code == 401, "an unknown camera is refused like a wrong login")
code, _, _ = response(d, request(d, "/etc/passwd", login["Driveway"]))
check(code == 404, "any other path: 404")
code, head, body = response(d, request(d, path_drive, login["Driveway"], method="HEAD"))
check(code == 200 and body == b"", "HEAD answers the headers only")
# requests that arrive together share one fetch
d.run("NOW_MS = 1791230410000")
d.async_http(True)
n0 = len(con.calls)
c1, c2 = request(d, path_drive, login["Driveway"], ip="192.168.50.21"), request(d, path_drive, login["Driveway"], ip="192.168.50.22")
check(d.call("Written", c1) == "" and d.call("Written", c2) == "", "both wait for the console")
d.flush_http()
check(len(con.calls) == n0 + 1 and response(d, c1)[0] == 200 and response(d, c2)[0] == 200, "two requests at once: one fetch, both answered")
d.async_http(False)
con.status[f"/v1/cameras/{CAM[1]}/snapshot"] = 429
d.run("NOW_MS = 1791230420000")
code, head, _ = response(d, request(d, path_drive, login["Driveway"]))
check(code == 503 and "Retry-After" in head, "the console rate-limits: 503 with Retry-After")
del con.status[f"/v1/cameras/{CAM[1]}/snapshot"]
# a console that does not answer: requests do not pile up
d.async_http(True)
d.run("NOW_MS = 1791230430000")
waiting = []
for i, (name, dev) in enumerate(list(dev_of.items()) * 6):
    waiting.append(request(d, f"/snapshot/{dev}.jpg" + ("?high=1" if i % 2 else ""), login[name]))
d.run("NOW_MS = 1791230440000")
for name, dev in dev_of.items():
    waiting.append(request(d, f"/snapshot/{dev}.jpg?x={name[:1]}", login[name]))
queued = d.call("ApiQueueLength")
check(queued <= 24, f"pictures waiting for the console are capped ({queued})")
refused = [c for c in waiting if d.call("Written", c).startswith("HTTP/1.1 503")]
check(len(refused) >= len(waiting) - 32, f"connections beyond 32 at once are refused with 503 ({len(refused)} of {len(waiting)})")
d.flush_http()
d.async_http(False)
d.run("NOW_MS = nil")

# slow pictures do not make the console look offline
con.status[f"/v1/cameras/{CAM[1]}/snapshot?highQuality=true"] = None
d.clear()
d.run("NOW_MS = 1791230450000")
saved_responder = d.responder
d.responder = lambda m, u, h, b: (None, None, None) if "/snapshot" in u else saved_responder(m, u, h, b)
for i in range(3):
    d.run(f"NOW_MS = {1791230450000 + i * 2000}")
    response(d, request(d, path_drive + "?high=1", login["Driveway"]))
d.responder = saved_responder
del con.status[f"/v1/cameras/{CAM[1]}/snapshot?highQuality=true"]
check("Console Offline" not in d.events() and d.var("CONSOLE_ONLINE") == "1" and not d.device_cmds("DL_STATE"),
      "pictures that time out do not mark the console offline (no flapping)")
d.run("NOW_MS = nil")

# a busy port is explained
dbusy = Driver("hub", Console())
dbusy.g.Properties["Console Address"] = HOST
dbusy.g.Properties["API Key"] = KEY
dbusy.run("BUSY_PORTS[47080] = true")
dbusy.call("OnDriverInit")
dbusy.call("OnDriverLateInit")
dbusy.timers()
check("picture server cannot use port 47080" in dbusy.prop("Status") and dbusy.prop("Picture Server").startswith("Error on port 47080"),
      f"a port in use is explained ({dbusy.prop('Status')})")
dbusy.run("BUSY_PORTS[47080] = nil")
dbusy.set_prop("Picture Server Port", "47090")
check(dbusy.prop("Picture Server").startswith("Listening on 192.168.50.10:47090"), "another port can be chosen")

# ---------------------------------------------------------------- settings pushed to cameras
d.clear()
d.set_prop("Live Video", "RTSPS (port 7441)")
check(sorted(dev for dev, cmd, p, _ in d.device_cmds("DL_STATE") if p.get("LIVE_VIDEO") == "RTSPS") == sorted(dev_of.values()), "Live Video RTSPS is sent to every camera")
d.clear()
d.set_prop("Log Level", "Debug")
check(len(d.device_cmds("DL_LOG_LEVEL")) == 5 and all(p["LOG_LEVEL"] == "Debug" for _, _, p, _ in d.device_cmds("DL_LOG_LEVEL")), "the hub's Log Level is every camera's")
d.clear()
d.call("ReceivedFromProxy", 5001, "SELECT", d.table({}))
check(all(p["ENABLED"] == "0" for _, _, p, _ in d.device_cmds("DL_HUB_ALERTS")) and "Alerts Off" in d.events(), "tile tap turns alerts off on every camera")
d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "On"}))

# a camera added by hand links itself by name
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "2001", "NAME": "Hand", "CLAIM": "pool"}))
claimed = d.device_cmds("DL_CONFIGURE", 2001)
check(claimed and claimed[0][2]["PROTECT_ID"] == CAM[6], "a camera added by hand links to the UniFi camera it names (any case)")
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "2002", "NAME": "Hand 2", "CLAIM": "Attic"}))
check(d.device_cmds("DL_CLAIM_FAILED", 2002), "an unknown name is answered")

dc, _ = hub(connect=False)
dc.call("ExecuteCommand", "DL_CAMERA_STATUS", dc.table({"DEVICE_ID": "2003", "NAME": "Early", "CLAIM": "Garden"}))
check(not dc.device_cmds("DL_CONFIGURE", 2003) and not dc.device_cmds("DL_CLAIM_FAILED", 2003), "a link asked for before the hub is connected waits")
dc.timers()
check([p["PROTECT_ID"] for _, _, p, _ in dc.device_cmds("DL_CONFIGURE", 2003)][:1] == [CAM[3]], "and is made once the hub reads the cameras")

# Director never answers C4:AddDevice: adding stops with a message
dw, _ = hub()
dw.call("ExecuteCommand", "LUA_ACTION", dw.table({"ACTION": "AddCameras"}))
dw.timers()
check("Director did not add" in dw.prop("Status"), f"adding stops when Director does not answer ({dw.prop('Status')})")
dw.call("ExecuteCommand", "LUA_ACTION", dw.table({"ACTION": "AddCameras"}))
check(len(list(dw.g.ADDED.values())) == 2, "and Add New Cameras can run again")

# the last alert and ring survive a restart
dr = Driver("hub", Console())
dr.g.Properties["Console Address"] = HOST
dr.g.Properties["API Key"] = KEY
dr.run("DEVICE_ID = 500")
dr.call("OnDriverInit")
dr.call("OnDriverLateInit")
dr.call("ExecuteCommand", "DL_CAMERA_STATUS", dr.table({"DEVICE_ID": "1001", "NAME": "Garden", "PROTECT_ID": CAM[3]}))
dr.call("ExecuteCommand", "DL_CAMERA_ALERT", dr.table({"DEVICE_ID": "1001", "NAME": "Garden", "TYPE": "Vehicle", "TIME": "2026-10-05T18:00:00Z"}))
dr.call("ExecuteCommand", "DL_CAMERA_RING", dr.table({"DEVICE_ID": "1001", "NAME": "Garden", "TIME": "2026-10-05T18:05:00Z"}))
dr2 = Driver("hub", Console())
dr2.copy_persist_from(dr, ("DL_HUB", "DL_SECRET"))
dr2.call("OnDriverInit")
check(dr2.var("LAST_ALERT_TYPE") == "Vehicle" and dr2.var("LAST_RING_TIME") == "2026-10-05T18:05:00Z" and dr2.var("LAST_ALERT_CAMERA") == "Garden",
      "LAST_ALERT_* and LAST_RING_* survive a restart")
check(dr2.call("TestCondition", "LAST_ALERT_TYPE", dr2.table({"VALUE": "Vehicle"})) is True, "and so does the Last alert conditional")

# ---------------------------------------------------------------- Print Diagnostics
d.clear()
d.run("LOGS = {}")
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "Diagnostics"}))
for _ in range(10):
    d.timers()
text = all_logs(d)
check("GET /v1/meta/info : HTTP 200" in text and "UniFi Protect 6.2.83 (supported)" in text, "diagnostics: Protect version and whether it is supported")
check("name 'Demo UNVR', model not reported by the API" in text, "diagnostics: the console's name and model")
check(f"'Front Door'  id {CAM[2]}" in text and re.search(r"CONNECTED  doorbell \((it rang|it has a doorbell screen message)\)", text) is not None,
      "diagnostics: names, ids and kinds")
check("streams: high, medium, low" in text and "streams: none (RTSP is off for this camera)" not in text.split("Garden")[0][-10:], "diagnostics: stream availability")
check("camera fields: activePatrolSlot, featureFlags, hdrType, id, isMicEnabled, lcdMessage" in text, "diagnostics: the camera fields the console sends (to learn the real shape)")
check("WebSocket events : open" in text and "Last 10 events" in text and "smartDetectZone[person,vehicle]" in text, "diagnostics: WebSocket state and the last events")
check(re.search(r"add\s+ring\s+Front Door\s+camera 66f1a2b3c4d5e6f7081920a2\s+event e03", text) is not None, "diagnostics: each event's type, camera and id")
check(any(l.startswith("UniFi Protect Hub: ") for l in d.logs()), "diagnostics go to Director's driver log too")

# ---------------------------------------------------------------- secrets never reach a log
d.set_prop("Log Level", "Trace")
for e in events_from("ws_events.jsonl"):
    e["item"]["id"] = e["item"]["id"] + "b"
    ws_send(d, 6101, e)
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "Diagnostics"}))
for _ in range(10):
    d.timers()
secrets = [KEY] + TOKENS + [cfg[dev]["PIC_PASS"] for dev in cfg]
everything = all_logs(d) + all_logs(dold) + all_logs(d401) + all_logs(d53)
leaks = [s for s in secrets if s in everything]
check(not leaks, f"no log line shows the API key, a stream token or a picture password {leaks or ''}")

finish()
