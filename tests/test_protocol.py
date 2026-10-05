"""JSON and WebSocket tests (offline).   python tests/test_protocol.py

The WebSocket client is driven the way Director drives it: OnConnectionStatusChanged
and ReceivedFromNetwork, with the console's bytes split at awkward places.
"""
import base64
import hashlib
import json
import re

from harness import Driver, check, finish

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

d = Driver("hub")

# ---------------------------------------------------------------- JSON
src = json.dumps({"a": [1, 2.5, -3e2, True, False, None, "x"], "s": "tab\t\"q\" \\ é \U0001F600", "o": {}, "e": [], "n": None})
d.g.TEXT = src.encode("utf-8")
d.run("V, ERR = JsonDecode(TEXT)")
v = d.g.V
check(v is not None and d.g.ERR is None, "JSON: decodes an object with every kind of value")
check(v.a[1] == 1 and v.a[2] == 2.5 and v.a[3] == -300 and v.a[4] is True and v.a[5] is False, "JSON: numbers and booleans")
check(d.eval("V.a[6] == JSON_NULL") and v.a[7] == "x", "JSON: null in an array keeps its place (JSON_NULL)")
check(d.eval("V.n == nil"), "JSON: null in an object is nil")
check(d.eval('V.s == "tab\\t\\"q\\" \\\\ \\195\\169 \\240\\159\\152\\128"'), "JSON: escapes, \\u00e9 and a surrogate pair become UTF-8")
for bad in ('{"a":}', '[1,2', '{"a":1} x', '"open', '{"a" 1}', "nul"):
    d.g.TEXT = bad
    d.run("V, ERR = JsonDecode(TEXT)")
    check(d.g.V is None and d.g.ERR is not None, f"JSON: refuses {bad!r}")
check(d.eval('JsonEncode({ qualities = { "high", "medium", "low" } })') == '{"qualities":["high","medium","low"]}', "JSON: encodes the stream request body")
check(d.eval("JsonEncode(1791230400000)") == "1791230400000", "JSON: encodes large integers exactly")

# ---------------------------------------------------------------- WebSocket
received, closed = [], []


def server_frame(opcode, payload=b"", fin=True, mask=None):
    b1 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n <= 125:
        head = bytes([b1, (0x80 if mask else 0) | n])
    elif n <= 65535:
        head = bytes([b1, (0x80 if mask else 0) | 126]) + n.to_bytes(2, "big")
    else:
        head = bytes([b1, (0x80 if mask else 0) | 127]) + n.to_bytes(8, "big")
    if mask:
        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        return head + mask + payload
    return head + payload


def decode_client_frames(data):
    """Client frames must be masked (RFC 6455): returns [(opcode, payload)] or raises."""
    out, i = [], 0
    while i < len(data):
        b1, b2 = data[i], data[i + 1]
        assert b2 & 0x80, "client frame not masked"
        n, i = b2 & 0x7F, i + 2
        if n == 126:
            n, i = int.from_bytes(data[i:i + 2], "big"), i + 2
        elif n == 127:
            n, i = int.from_bytes(data[i:i + 8], "big"), i + 8
        mask, i = data[i:i + 4], i + 4
        out.append((b1 & 0x0F, bytes(c ^ mask[k % 4] for k, c in enumerate(data[i:i + n]))))
        i += n
    return out


d.run("""
GOT = {}; CLOSED = {}; OPENED = 0
WS = WsNew({ name = "events", binding = 6101, host = "192.168.50.1", port = 443,
  path = "/proxy/protect/integration/v1/subscribe/events",
  headers = function() return { "X-API-Key: K3yForT3stsOnly" } end,
  onOpen = function() OPENED = OPENED + 1 end,
  onMessage = function(ws, text) GOT[#GOT + 1] = text end,
  onClose = function(ws, reason, status) CLOSED[#CLOSED + 1] = { reason, status } end })
WsOpen(WS)
""")
net = d.net()
check(net[0][:4] == ["create", 6101, "192.168.50.1", "SSL"] and net[1][:4] == ["options", 6101, 443, "SSL"] and net[2][:3] == ["connect", 6101, 443],
      "opens an SSL network connection to the console, port 443")
opts = dict(net[1][4])
check(opts.get("VERIFY_MODE") == "none" and opts.get("AUTO_CONNECT") is False and opts.get("KEEP_CONNECTION") is False,
      "self-signed certificate accepted (VERIFY_MODE none); the driver reconnects itself")
d.clear()
d.call("WsStatus", 6101, "ONLINE")
sent = [x for x in d.net() if x[0] == "send"]
req = sent[0][3].encode("latin-1") if sent else b""
check(req.startswith(b"GET /proxy/protect/integration/v1/subscribe/events HTTP/1.1\r\n") and req.endswith(b"\r\n\r\n"), "upgrade request for /subscribe/events")
heads = dict(re.findall(rb"\r\n([^:\r\n]+): ([^\r\n]*)", req))
check(heads.get(b"Upgrade") == b"websocket" and heads.get(b"Connection") == b"Upgrade" and heads.get(b"Sec-WebSocket-Version") == b"13", "WebSocket upgrade headers")
check(heads.get(b"X-API-Key") == b"K3yForT3stsOnly" and heads.get(b"Host") == b"192.168.50.1", "the API key goes in the X-API-Key header, to the console")
key = heads.get(b"Sec-WebSocket-Key", b"")
check(len(base64.b64decode(key)) == 16, "Sec-WebSocket-Key is 16 random bytes")

# a wrong Sec-WebSocket-Accept is refused
d.run("WS2 = WsNew({ name = 'bad', binding = 6150, host = '192.168.50.1', path = '/x', onClose = function(ws, r) BADCLOSE = r end }); WsOpen(WS2)")
d.call("WsStatus", 6150, "ONLINE")
d.call("WsReceived", 6150, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: AAAA\r\n\r\n")
check("Sec-WebSocket-Accept" in str(d.g.BADCLOSE), f"a wrong Sec-WebSocket-Accept closes the connection ({d.g.BADCLOSE})")
d.run("WS3 = WsNew({ name = 'unauth', binding = 6151, host = '192.168.50.1', path = '/x', onClose = function(ws, r, s) UNAUTH = s end }); WsOpen(WS3)")
d.call("WsStatus", 6151, "ONLINE")
d.call("WsReceived", 6151, 'HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{"error":"Unauthorized"}')
check(d.g.UNAUTH == 401, "HTTP 401 on the upgrade is reported with its status (the hub then waits before retrying)")

accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
answer = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n"
first = json.dumps({"type": "add", "item": {"id": "e1", "type": "motion"}}).encode()
stream = answer + server_frame(1, first)
# delivered in tiny pieces, the handshake and the first frame together
for i in range(0, len(stream), 7):
    d.call("WsReceived", 6101, stream[i:i + 7])
check(d.g.OPENED == 1 and d.eval("WS.state") == "open", "handshake accepted (Sec-WebSocket-Accept checked)")
check(list(d.g.GOT.values()) == [first.decode()], "a message split across reads arrives whole")

big = json.dumps({"type": "add", "item": {"id": "e2", "pad": "x" * 70000}}).encode()
mid = json.dumps({"type": "add", "item": {"id": "e3", "pad": "y" * 300}}).encode()
frag = server_frame(1, b'{"type":"upd', fin=False) + server_frame(9, b"hi") + server_frame(0, b'ate","item":{"id":"e4"}}', fin=True)
d.clear()
d.call("WsReceived", 6101, server_frame(1, big) + server_frame(1, mid) + frag)
got = list(d.g.GOT.values())
check(got[1:] == [big.decode(), mid.decode(), '{"type":"update","item":{"id":"e4"}}'], "64-bit and 16-bit lengths, and a fragmented message with a ping in between")
replies = decode_client_frames(b"".join(x[3].encode("latin-1") for x in d.net() if x[0] == "send"))
check(replies == [(10, b"hi")], f"a ping is answered with a masked pong carrying its payload ({replies})")

# keep-alive ping, then silence closes
d.clear()
d.run("WS.lastData = os.time()")
d.repeating()
pings = decode_client_frames(b"".join(x[3].encode("latin-1") for x in d.net() if x[0] == "send"))
check(pings and pings[0][0] == 9, "a ping every 30 s keeps the connection alive")
d.run("WS.lastData = os.time() - 120")
d.repeating()
check("no data from the console" in str(d.eval("CLOSED[#CLOSED][1]")), "no data for 90 s closes the connection (the hub reconnects)")

# the console closes
d.run("WsOpen(WS)")
d.timers(max_ms=1000)  # a reopen waits a second; the 15 s connect timeout must not run
d.call("WsStatus", 6101, "ONLINE")
req = [x for x in d.net() if x[0] == "send"][-1][3].encode("latin-1")
key = dict(re.findall(rb"\r\n([^:\r\n]+): ([^\r\n]*)", req))[b"Sec-WebSocket-Key"]
accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
d.call("WsReceived", 6101, b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
d.clear()
d.call("WsReceived", 6101, server_frame(8, (1001).to_bytes(2, "big") + b"bye"))
check("closed by the console (code 1001)" in str(d.eval("CLOSED[#CLOSED][1]")) and d.eval("WS.state") == "closed", "a close frame from the console ends the connection")
echo = decode_client_frames(b"".join(x[3].encode("latin-1") for x in d.net() if x[0] == "send"))
check(echo and echo[0][0] == 8, "and is answered with a close frame")
d.call("WsReceived", 6101, server_frame(1, b"late"))
check(list(d.g.GOT.values())[-1] != "late", "nothing is delivered after the close")

# a dropped TLS connection
d.run("WsOpen(WS)")
d.timers(max_ms=1000)
d.call("WsStatus", 6101, "ONLINE")
d.call("WsStatus", 6101, "OFFLINE")
check("dropped" in str(d.eval("CLOSED[#CLOSED][1]")), "a dropped connection is reported")
# OFFLINE of an old connection while a new one waits to start does not kill it
d.run("WsOpen(WS)")
d.call("WsStatus", 6101, "ONLINE")
req = [x for x in d.net() if x[0] == "send"][-1][3].encode("latin-1")
key = dict(re.findall(rb"\r\n([^:\r\n]+): ([^\r\n]*)", req))[b"Sec-WebSocket-Key"]
accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
d.call("WsReceived", 6101, b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
check(d.eval("WS.state") == "open", "open again after a reconnect")
d.run("WsOpen(WS)")
d.call("WsStatus", 6101, "OFFLINE")
check(d.eval("WS.state") == "reopening", "the old connection's OFFLINE does not end a reopen")

finish()
