"""Static checks of the assembled Lua (offline).   python tests/test_static.py

Uses luac 5.1 (luac5.1 / luac on PATH) to compile each driver and list every global
it reads. A global that is read but never defined is a bug that only shows when that
line runs: a typo, or a function that calls a `local` declared further down the file
(Lua then looks up a global of that name, which is nil).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

from harness import ROOT, check, finish

sys.path.insert(0, os.path.join(ROOT, "tools"))
import build  # noqa: E402

# Provided by Lua 5.1 or by Director at run time
RUNTIME = {
    "C4", "Properties", "print", "pairs", "ipairs", "next", "type", "tostring", "tonumber", "pcall", "error", "select",
    "setmetatable", "getmetatable", "rawget", "rawset", "unpack", "string", "table", "math", "os", "collectgarbage", "bit",
    "DIT_ADDING", "assert", "loadstring",
}
# Entry points Director calls (defined, never read by the driver itself)
ENTRY_POINTS = {"OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "OnPropertyChanged", "ReceivedFromProxy", "UIRequest",
                "ExecuteCommand", "TestCondition", "ReceivedFromNetwork", "OnConnectionStatusChanged",
                "GetNotificationAttachmentURL", "GetNotificationAttachmentBytes", "FinishedWithNotificationAttachment"}


def luac():
    for name in ("luac5.1", "luac5.1.exe", "luac"):
        p = shutil.which(name)
        if p:
            return p
    local = os.path.join(os.path.expanduser("~"), "AppData", "Local", "Programs", "lua51", "luac5.1.exe")
    return local if os.path.exists(local) else None


LUAC = luac()
if not LUAC:
    print("SKIP luac 5.1 not found (install lua5.1)")
    finish()

for driver in build.DRIVERS:
    src = build.assemble_lua(driver, "test")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as f:
        f.write(src)
        path = f.name
    try:
        out = subprocess.run([LUAC, "-p", "-l", path], capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        os.unlink(path)
    check(out.returncode == 0, f"{driver}: compiles with Lua 5.1 {out.stderr.strip()[:300]}")
    gets, sets = {}, set()
    for line in out.stdout.splitlines():
        m = re.search(r"\[(\d+)\]\s+(GETGLOBAL|SETGLOBAL)\s+.*;\s*(\S+)", line)
        if m:
            name = m.group(3)
            if m.group(2) == "GETGLOBAL":
                gets.setdefault(name, int(m.group(1)))
            else:
                sets.add(name)
    undefined = sorted(n for n in gets if n not in sets and n not in RUNTIME)
    lines = src.splitlines()
    detail = [f"{n} (line {gets[n]}: {lines[gets[n] - 1].strip()[:70]})" for n in undefined]
    check(not undefined, f"{driver}: every global it reads is defined {detail or ''}")
    unused = sorted(n for n in sets if n in ENTRY_POINTS)
    check(len(unused) >= 5, f"{driver}: defines the DriverWorks entry points ({len(unused)})")

finish()
