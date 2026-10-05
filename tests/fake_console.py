"""A UniFi console for the tests: answers the Protect Integration API with the
recorded answers in tests/fixtures (shaped like Ubiquiti's OpenAPI schema), and
helpers that open and feed the hub's WebSockets."""
import base64
import hashlib
import json
import re

from harness import fixture

KEY = "K3y-Abc123-ProtectTest"
HOST = "192.168.50.1"
BASE = f"https://{HOST}/proxy/protect/integration/v1"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CAM = {i: "66f1a2b3c4d5e6f7081920a%d" % i for i in range(1, 7)}
TOKENS = ["HiTok3nQ8xZp2Lm", "MedTok3nW4vB7nK", "LowTok3nR6tY9uP", "NewHiTok3nA1sD", "NewMedTok3nF5gH", "NewLowTok3nJ8kL"]


def jpeg(w, h, pad=0):
    return (b"\xff\xd8" + b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
            + b"\xff\xc0\x00\x11\x08" + h.to_bytes(2, "big") + w.to_bytes(2, "big") + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01"
            + b"\x00" * pad + b"\xff\xd9")


class Console:
    def __init__(self, version="6.2.83", cameras="cameras_6.2.83.json"):
        self.version, self.cameras = version, cameras
        self.calls, self.foreign, self.posts = [], [], []
        self.streams = {CAM[1]: "all", CAM[2]: "all", CAM[4]: "all"}   # the others have RTSP off
        self.status = {}        # path -> forced status
        self.redirect = set()
        self.limited = 0        # answer this many /cameras with 429 first

    def __call__(self, method, url, headers, body):
        if not url.startswith(BASE + "/"):
            self.foreign.append(url)
            return None, None, None
        path = url[len(BASE):]
        self.calls.append((method, path, headers))
        if headers.get("X-API-Key") != KEY:
            return 401, {"Content-Type": "application/json"}, fixture("error_401.json")
        if path in self.status:
            return self.status[path], {}, ""
        if path in self.redirect:
            return 302, {"Location": "https://elsewhere.example/steal"}, ""
        if path == "/v1/meta/info":
            return 200, {}, json.dumps({"applicationVersion": self.version})
        if path == "/v1/nvrs":
            return 200, {}, fixture("nvrs.json")
        if path == "/v1/cameras":
            if self.limited > 0:
                self.limited -= 1
                return 429, {"Retry-After": "2"}, fixture("error_429.json")
            return 200, {}, fixture(self.cameras).encode("utf-8")
        m = re.match(r"^/v1/cameras/(\w+)/rtsps-stream$", path)
        if m:
            cid = m.group(1)
            if method == "POST":
                self.posts.append((cid, headers.get("Content-Type"), json.loads(body)))
                self.streams[cid] = "created"
                return 200, {}, fixture("rtsps_stream_created.json")
            state = self.streams.get(cid)
            if state == "all":
                return 200, {}, fixture("rtsps_stream_all.json")
            if state == "created":
                return 200, {}, fixture("rtsps_stream_created.json")
            return 200, {}, fixture("rtsps_stream_none.json")
        m = re.match(r"^/v1/cameras/(\w+)/snapshot(\?highQuality=true)?$", path)
        if m:
            if headers.get("Accept") != "image/jpeg":
                return 406, {}, ""
            return 200, {"Content-Type": "image/jpeg"}, (jpeg(1920, 1080, 4000) if m.group(2) else jpeg(640, 360, 800))
        return 404, {}, json.dumps({"error": "Not found", "name": "NOT_FOUND"})


def ws_open(d, binding):
    d.call("WsStatus", binding, "ONLINE")
    req = [x for x in d.net() if x[0] == "send" and x[1] == binding][-1][3].encode("latin-1")
    key = dict(re.findall(rb"\r\n([^:\r\n]+): ([^\r\n]*)", req))[b"Sec-WebSocket-Key"]
    accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
    d.call("WsReceived", binding, b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    return req


def ws_send(d, binding, obj):
    payload = (json.dumps(obj) if not isinstance(obj, str) else obj).encode()
    n = len(payload)
    head = bytes([0x81, n]) if n <= 125 else bytes([0x81, 126]) + n.to_bytes(2, "big")
    d.call("WsReceived", binding, head + payload)


