"""Hub and camera together (offline).   python tests/test_integration.py

Two drivers in two Lua runtimes; their C4:SendToDevice messages are delivered to
each other. Then a picture is taken the way DirectorLink and Control4 apps take it:
from the camera page's address, port and Basic login plus GET_SNAPSHOT_QUERY_STRING.
"""
import base64

from harness import Driver, check, finish
from fake_console import CAM, HOST, KEY, Console, ws_open, ws_send

console = Console()
hub = Driver("hub", console)
hub.g.Properties["Console Address"] = HOST
hub.g.Properties["API Key"] = KEY
hub.run("DEVICE_ID = 500")
hub.call("OnDriverInit")
hub.call("OnDriverLateInit")
hub.timers()
ws_open(hub, 6101)
ws_open(hub, 6102)

cam = Driver("camera")
cam.run("DEVICE_ID = 1001; PROXY_DEVICE = 1002; C4I_BY_NAME['DirectorLink-UniFi-Protect.c4z'] = { 500 }")
cam.call("OnDriverInit")
cam.run("OnDriverLateInit('DIT_ADDING')")

page = {}   # the camera proxy's stored properties, as the page commands set them


def deliver():
    """Move messages between the drivers until nothing is left."""
    for _ in range(20):
        moved = False
        for src, dst, dst_id in ((hub, cam, 1001), (cam, hub, 500)):
            msgs = src.device_cmds()
            src.run("DEVICE_CMDS = {}")
            for dev, cmd, params, _ in msgs:
                if src is cam and dev == 1002:      # page commands to the camera proxy
                    for k in ("ADDRESS", "PORT", "TYPE", "REQUIRED", "USERNAME", "PASSWORD"):
                        if k in params:
                            page[(cmd, k)] = params[k]
                    continue
                if dev == dst_id:
                    dst.call("ExecuteCommand", cmd, dst.table(params))
                    moved = True
        hub.timers(max_ms=5000)
        cam.timers(max_ms=5000)
        if not moved:
            break


# the hub adds the Front Door doorbell (the only camera added here)
hub.g.Properties["Ignored Cameras"] = "Driveway, Garden, Back Gate, " + CAM[5]
hub.call("ExecuteCommand", "LUA_ACTION", hub.table({"ACTION": "AddCameras"}))
list(hub.g.ADDED.values())[0].cb(1001, hub.table({}))
hub.timers()
deliver()
deliver()
check(cam.var("DIRECTORLINK_CAMERA") == "1" and cam.var("DIRECTORLINK_CAMERA_KIND") == "doorbell", "the camera says it is a DirectorLink camera, a doorbell")
check(cam.prop("Status") == "Online - events live - alerts on", f"camera online ({cam.prop('Status')})")
check(page[("SET_ADDRESS", "ADDRESS")] == "192.168.50.10" and page[("SET_HTTP_PORT", "PORT")] == "47080" and page[("SET_AUTHENTICATION_TYPE", "TYPE")] == "BASIC",
      "the camera page points at the picture server with Basic login")

# take a picture the way DirectorLink does: page address/port/login + the snapshot path
cam.run('PROXY_PROPS = "<camera_properties><address>%s</address><http_port>%s</http_port><authentication_required>True</authentication_required>'
        '<authentication_type>BASIC</authentication_type><username>%s</username><password>%s</password></camera_properties>"'
        % (page[("SET_ADDRESS", "ADDRESS")], page[("SET_HTTP_PORT", "PORT")], page[("SET_USERNAME", "USERNAME")], page[("SET_PASSWORD", "PASSWORD")]))
query = cam.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", cam.table({"SIZE_X": "1280", "SIZE_Y": "720"}))
path = "/" + query.split(">")[1].split("<")[0]
login = page[("SET_USERNAME", "USERNAME")] + ":" + page[("SET_PASSWORD", "PASSWORD")]
c = hub.call("FakeConnect", "192.168.50.30")
hub.call("FakeRequest", c, f"GET {path} HTTP/1.1\r\nHost: 192.168.50.10:47080\r\nAuthorization: Basic {base64.b64encode(login.encode()).decode()}\r\n\r\n")
raw = hub.call("Written", c)
raw = raw if isinstance(raw, bytes) else raw.encode("latin-1")
check(raw.startswith(b"HTTP/1.1 200 OK") and b"\r\n\r\n\xff\xd8" in raw, f"DirectorLink's way to a picture works end to end ({path})")
check(console.calls[-1][1] == f"/v1/cameras/{CAM[2]}/snapshot?highQuality=true", "the hub fetched Front Door's picture from the console")
cam.call("ExecuteCommand", "LUA_ACTION", cam.table({"ACTION": "Setup Report"}))
check(cam.call("UIRequest", "GET_STREAM_URLS", cam.table({"RESOLUTION": "1920x1080"})).startswith('<streams><stream url="rtsp://192.168.50.1:7447/'),
      "live video handed to Navigators: the console's RTSP stream")

# an event from the console: LAST_ALERT then Alert on the camera, Camera Alert on the hub
cam.clear()
hub.clear()
ws_send(hub, 6101, {"type": "add", "item": {"id": "x1", "modelKey": "event", "type": "smartDetectZone", "start": 1791230400000, "end": None,
                                            "device": CAM[2], "smartDetectTypes": ["person"]}})
deliver()
order = [list(x.values()) for x in cam.g.EVENT_VARS.values()]
check(["Alert", "Person", None] in [[e[0], e[1], None] for e in order] and cam.var("LAST_ALERT") == "Person", "the camera: LAST_ALERT = Person, then Alert")
check("Camera Alert" in hub.events() and hub.var("LAST_ALERT_CAMERA") == "Front Door", "the hub: Camera Alert from Front Door")
import datetime
import time
press = int(time.time()) - 3
ws_send(hub, 6101, {"type": "add", "item": {"id": "x2", "modelKey": "event", "type": "ring", "start": press * 1000, "end": None, "device": CAM[2]}})
deliver()
press_iso = datetime.datetime.fromtimestamp(press, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
check("Ring" in cam.events() and cam.var("LAST_RING") == press_iso, f"a ring: LAST_RING (the console's time of the press), then Ring ({cam.var('LAST_RING')})")
check("Doorbell Ring" in hub.events() and hub.var("LAST_RING_CAMERA") == "Front Door", "the hub: Doorbell Ring")

# the console goes away and comes back
cam.clear()
ws_send(hub, 6102, {"type": "update", "item": {"id": CAM[2], "modelKey": "camera", "state": "DISCONNECTED"}})
deliver()
check("Camera Offline" in cam.events() and hub.prop("Cameras") == "1 camera - 0 online - offline: Front Door", f"a disconnected camera is offline on both ({hub.prop('Cameras')})")

finish()
