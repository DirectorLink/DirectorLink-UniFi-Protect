"""In-process test harness: runs a driver's assembled Lua in a real Lua 5.1 runtime
(lupa) against a stubbed Control4 API. No network access.

HTTP (C4:url) is answered by a Python `responder(method, url, headers, body)` that
returns (code, headers, body). With d.async_http() replies wait for d.flush_http(),
so ordering bugs show. Network connections (the WebSocket), the TCP server (the
picture server) and the clock are stubbed too, and every log line is captured.
"""
import base64
import hashlib
import json
import os
import re
import sys

import lupa.lua51 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build  # noqa: E402  (assemble_lua)

STUB = r"""
EVENTS = {}; VARS = {}; PROXY = {}; DEVICE_CMDS = {}; TIMERS = {}; PERSIST = {}; RENAMED = {}
HISTORY = {}; ADDED = {}; NET = {}; ATTRIBS = {}; HTTP_LOG = {}; LOGS = {}; HTTP_QUEUE = {}
PROXY_PROPS = ""; DEVICE_ID = 900; PROXY_DEVICE = 901; CONTROLLER_IP = "192.168.50.10"; OS_VERSION = "3.4.3.123"
NOW_MS = nil; HTTP_ASYNC = false; BUSY_PORTS = {}; SERVERS = {}
local timerSeq = 0
C4 = {}
VAR_ORDER = {}
function C4:AddVariable(n, v) VARS[n] = v; VAR_ORDER[#VAR_ORDER + 1] = n; return 1, true end
function C4:SetVariable(n, v) VARS[n] = v; VAR_LOG = VAR_LOG or {}; VAR_LOG[#VAR_LOG + 1] = n end
function C4:FireEvent(n) EVENTS[#EVENTS + 1] = n; EVENT_VARS = EVENT_VARS or {}; EVENT_VARS[#EVENT_VARS + 1] = { n, VARS["LAST_ALERT"], VARS["LAST_RING"], VARS["DIRECTORLINK_CAMERA_KIND"], VARS["DIRECTORLINK_CAMERA_EVENTS"] } end
function C4:UpdateProperty(n, v) Properties[n] = v end
function C4:SetPropertyAttribs(n, v) ATTRIBS[n] = v end
function C4:SendToProxy(b, c, p, k) PROXY[#PROXY + 1] = { b, c, p } end
function C4:SendToDevice(id, c, p, allowEmpty, log) DEVICE_CMDS[#DEVICE_CMDS + 1] = { id, c, p, log } end
function C4:GetProxyDevices() return PROXY_DEVICE end
function C4:GetDeviceID() return DEVICE_ID end
DELETED_DEVICES = {}
DISPLAY_NAMES = {}
function C4:GetDeviceDisplayName(id) if DELETED_DEVICES[id] then return nil end return DISPLAY_NAMES[id] or ("Device " .. tostring(id)) end
UI_PROPS = {}
function C4:SendUIRequest(id) return UI_PROPS[id] or PROXY_PROPS end
function C4:RenameDevice(id, name) RENAMED[#RENAMED + 1] = { id, name } end
function C4:RecordHistory(...) HISTORY[#HISTORY + 1] = { ... } end
function C4:RoomGetId() return 81 end
C4I_BY_NAME = {}
function C4:GetDevicesByC4iName(n) return C4I_BY_NAME[n] or {} end
function C4:AddDevice(file, room, name, cb) ADDED[#ADDED + 1] = { file = file, room = room, name = name, cb = cb } end
function C4:CreateNetworkConnection(...) NET[#NET + 1] = { "create", ... } end
function C4:NetPortOptions(...) NET[#NET + 1] = { "options", ... } end
function C4:NetConnect(...) NET[#NET + 1] = { "connect", ... } end
function C4:NetDisconnect(...) NET[#NET + 1] = { "disconnect", ... } end
function C4:SendToNetwork(b, p, data) NET[#NET + 1] = { "send", b, p, data } end
function C4:GetControllerNetworkAddress() return CONTROLLER_IP end
function C4:GetVersionInfo() return { version = OS_VERSION } end
function C4:GetTime() return NOW_MS or (os.time() * 1000) end
function C4:PersistSetValue(n, v, enc) PERSIST[n] = v; PERSIST_ENC = PERSIST_ENC or {}; PERSIST_ENC[n] = enc and true or false end
function C4:PersistGetValue(n) return PERSIST[n] end
function C4:PersistDeleteValue(n) PERSIST[n] = nil end
function C4:GetDriverConfigInfo() return "900" end
function C4:DebugLog(s) LOGS[#LOGS + 1] = s end
function C4:ErrorLog(s) LOGS[#LOGS + 1] = s end
function C4:Hash(alg, s, opts) return PY_HASH(alg, s, opts and opts.return_encoding or "HEX") end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function C4:Base64Encode(s)  -- pure Lua: binary data must not cross into Python as text
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = string.byte(s, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
    local c3, c4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end
function C4:Base64Decode(s) return PY_B64D(s) end
function C4:SetTimer(ms, fn, rep)
  timerSeq = timerSeq + 1
  local t = { id = timerSeq, ms = ms, fn = fn, rep = rep, active = true }
  function t:Cancel() self.active = false end
  TIMERS[#TIMERS + 1] = t
  return t
end
-- Run every pending one-shot timer once (repeating ones stay); timers they set wait for the next call
function RunOneShotTimers(maxMs)
  local list = TIMERS; TIMERS = {}
  for _, t in ipairs(list) do
    if t.active and not t.rep and (maxMs == nil or t.ms <= maxMs) then t.active = false; t.fn(t)
    elseif t.active then TIMERS[#TIMERS + 1] = t end
  end
end
function RunRepeatingTimers()
  for _, t in ipairs(TIMERS) do if t.active and t.rep then t.fn(t) end end
end
-- C4:url(): answered by PY_HTTP, at once or (HTTP_ASYNC) when FlushHttp() runs. Like libcurl it
-- follows a 3xx Location with the same headers, unless the OnHeaders callback returns true (abort).
function C4:url()
  local x = { opts = {} }
  function x:SetOptions(o) self.opts = o; return self end
  function x:OnDone(f) self.done = f; return self end
  function x:OnHeaders(f) self.headersCb = f; return self end
  local function run(self, method, url, body, headers)
    HTTP_LOG[#HTTP_LOG + 1] = { method = method, url = url, headers = headers, body = body, opts = self.opts }
    local function answer()
      local responses, target = {}, url
      for _ = 1, 5 do
        local code, hdrs, rbody = PY_HTTP(method, target, headers, body)
        if code == nil then self.done(self, responses, 7, "Couldn't connect to server") return end
        local resp = { code = code, headers = hdrs, body = rbody }
        responses[#responses + 1] = resp
        if self.headersCb and self.headersCb(self, resp) == true then self.done(self, responses, -1, "aborted") return end
        local location = hdrs and (hdrs.Location or hdrs.location)
        if code >= 300 and code < 400 and location then target = location else break end
      end
      self.done(self, responses, 0, nil)
    end
    if HTTP_ASYNC then HTTP_QUEUE[#HTTP_QUEUE + 1] = answer else answer() end
    return self
  end
  function x:Get(url, headers) return run(self, "GET", url, nil, headers) end
  function x:Put(url, body, headers) return run(self, "PUT", url, body, headers) end
  function x:Post(url, body, headers) return run(self, "POST", url, body, headers) end
  function x:Custom(url, m, body, headers) return run(self, m, url, body, headers) end
  return x
end
function FlushHttp()
  local n = 0
  while #HTTP_QUEUE > 0 do
    local q = HTTP_QUEUE; HTTP_QUEUE = {}
    for _, f in ipairs(q) do f(); n = n + 1 end
  end
  return n
end
-- TCP server: Listen succeeds at once unless the port is in BUSY_PORTS
function C4:CreateTCPServer()
  local s = { cb = {} }
  for _, m in ipairs({ "OnResolve", "OnListen", "OnError", "OnAccept" }) do s[m] = function(self, f) self.cb[m] = f; return self end end
  function s:Listen(host, port)
    self.host, self.port = host, port
    SERVERS[#SERVERS + 1] = self
    if BUSY_PORTS[port] then self.cb.OnError(self, 98, "Address already in use", "listen") else self.cb.OnListen(self, { ip = "0.0.0.0", port = port }) end
    return self
  end
  function s:GetLocalAddress() return { ip = "0.0.0.0", port = self.port } end
  function s:Close() self.closed = true end
  return s
end
-- A client connection to the last server: returns it; FakeRequest(client, text) delivers a request head
function FakeConnect(ip)
  local srv = SERVERS[#SERVERS]
  local c = { cb = {}, written = {}, closed = false, ip = ip or "192.168.50.20" }
  for _, m in ipairs({ "OnRead", "OnWrite", "OnDisconnect", "OnError" }) do c[m] = function(self, f) self.cb[m] = f; return self end end
  function c:ReadUntil(d) self.reading = d; return self end
  function c:Write(data) self.written[#self.written + 1] = data; return self end
  function c:Close() self.closed = true; return self end
  function c:GetRemoteAddress() return { ip = self.ip, port = 50000 } end
  srv.cb.OnAccept(srv, c)
  return c
end
function FakeRequest(c, text) if c.cb.OnRead then c.cb.OnRead(c, text) end end
function Written(c) return table.concat(c.written) end
print = function(s) LOGS[#LOGS + 1] = s end
"""


def defaults_from_xml(path):
    xml = open(path, encoding="utf-8").read()
    props = {}
    for block in re.findall(r"<property>(.*?)</property>", xml, re.S):
        name = re.search(r"<name>(.*?)</name>", block).group(1)
        d = re.search(r"<default>(.*?)</default>", block, re.S)
        props[name] = d.group(1) if d else ""
    return props


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


def fixture_json(name):
    return json.loads(fixture(name))


def py_hash(alg, s, enc):
    data = s.encode("latin-1")
    h = {"MD5": hashlib.md5, "SHA1": hashlib.sha1, "SHA256": hashlib.sha256}[str(alg).upper()](data)
    if str(enc).upper() == "BASE64":
        return base64.b64encode(h.digest()).decode()
    return h.hexdigest().upper()


class Driver:
    def __init__(self, driver, responder=None):
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = self.lua.globals()
        self.responder = responder or (lambda m, u, h, b: (None, None, None))
        g.PY_HASH = py_hash
        g.PY_B64D = lambda s: base64.b64decode(s).decode("latin-1")
        g.PY_HTTP = self._http
        g.Properties = self.lua.table_from(defaults_from_xml(os.path.join(ROOT, "src", driver, "driver.xml")))
        self.lua.execute(STUB)
        self.lua.execute(build.assemble_lua(driver, "test"))
        self.g = g

    def _http(self, method, url, headers, body):
        h = dict(headers) if headers is not None else {}
        code, rh, rb = self.responder(method, url, h, body)
        if code is None:
            return None, None, None
        return code, self.lua.table_from(rh or {}), rb

    # helpers
    def call(self, fn, *args):
        return self.g[fn](*args)

    def table(self, d):
        return self.lua.table_from(d)

    def run(self, code):
        self.lua.execute(code)

    def eval(self, code):
        return self.lua.eval(code)

    def events(self):
        return list(self.g.EVENTS.values())

    def clear(self):
        self.lua.execute("EVENTS = {}; PROXY = {}; DEVICE_CMDS = {}; HTTP_LOG = {}; RENAMED = {}; HISTORY = {}; NET = {}; EVENT_VARS = {}; VAR_LOG = {}")

    def var(self, name):
        return self.g.VARS[name]

    def prop(self, name):
        return self.g.Properties[name]

    def set_prop(self, name, value):
        self.g.Properties[name] = value
        self.call("OnPropertyChanged", name)

    def proxy(self, cmd=None, binding=None):
        out = []
        for m in self.g.PROXY.values():
            if (cmd is None or m[2] == cmd) and (binding is None or m[1] == binding):
                out.append((m[1], m[2], dict(m[3]) if m[3] is not None else {}))
        return out

    def device_cmds(self, cmd=None, device=None):
        out = []
        for m in self.g.DEVICE_CMDS.values():
            if (cmd is None or m[2] == cmd) and (device is None or m[1] == device):
                out.append((m[1], m[2], dict(m[3]) if m[3] is not None else {}, m[4]))
        return out

    def http_log(self):
        out = []
        for e in self.g.HTTP_LOG.values():
            out.append({"method": e.method, "url": e.url, "headers": dict(e.headers) if e.headers else {}, "body": e.body,
                        "opts": dict(e.opts) if e.opts else {}})
        return out

    def net(self):
        return [list(x.values()) for x in self.g.NET.values()]

    def logs(self):
        return [str(x) for x in self.g.LOGS.values()]

    def timers(self, max_ms=None):
        self.call("RunOneShotTimers", max_ms)

    def repeating(self):
        self.call("RunRepeatingTimers")

    def copy_persist_from(self, other, keys):
        """Restart: the saved values of another driver (another Lua runtime) become this one's."""
        def to_py(v):
            if lupa.lua_type(v) == "table":
                return {k: to_py(x) for k, x in v.items()}
            return v

        def to_lua(v):
            if isinstance(v, dict):
                return self.lua.table_from({k: to_lua(x) for k, x in v.items()})
            return v
        for k in keys:
            v = other.g.PERSIST[k]
            if v is not None:
                self.g.PERSIST[k] = to_lua(to_py(v))

    def async_http(self, on=True):
        self.g.HTTP_ASYNC = on

    def flush_http(self):
        return self.call("FlushHttp")


FAILS = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


def finish():
    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED")
        sys.exit(1)
    print("ALL PASSED")
