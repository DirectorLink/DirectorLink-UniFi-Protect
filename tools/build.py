"""Build the driver packages.

    python tools/build.py   ->  dist/DirectorLink-UniFi-Protect.c4z          (the hub)
                                dist/DirectorLink-UniFi-Protect-Camera.c4z
                                dist/SHA256SUMS.txt

Each driver.lua is assembled from its Lua parts (the shared src/common/core.lua
first, then the driver's own modules, then its driver.lua). The version comes
from the VERSION file (1.0.0, or 1.0.0-beta.2 for a beta). The packaged
driver.xml gets <version> = major*1000000 + minor*10000 + patch*100 + build,
where build is the beta number (1-98) or 99 for the release itself, so every
beta and the release that follows it count up (1.0.0-beta.1 -> 1000001,
1.0.0-beta.2 -> 1000002, 1.0.0 -> 1000099, 1.0.1 -> 1000199). The files in
src/ are not modified. Never rename a package: Composer updates by file name.
"""
import datetime
import hashlib
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DIST = os.path.join(ROOT, "dist")
# driver -> (package, Lua parts in order; the driver's own driver.lua comes last)
DRIVERS = {
    "hub": ("DirectorLink-UniFi-Protect.c4z", ["common/core.lua", "hub/json.lua", "hub/websocket.lua", "hub/protect.lua", "hub/pictures.lua"]),
    "camera": ("DirectorLink-UniFi-Protect-Camera.c4z", ["common/core.lua"]),
}


def parse_version(semver):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?", semver)
    if not m:
        sys.exit(f"VERSION '{semver}' must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-beta.N")
    major, minor, patch = (int(x) for x in m.groups()[:3])
    beta = int(m.group(4)) if m.group(4) else None
    if minor > 99 or patch > 99 or (beta is not None and not 1 <= beta <= 98):
        sys.exit("minor and patch must be 0-99 and the beta number 1-98")
    return major * 1000000 + minor * 10000 + patch * 100 + (beta if beta is not None else 99)


def read_version():
    semver = open(os.path.join(ROOT, "VERSION"), encoding="utf-8").read().strip()
    return semver, parse_version(semver)


def assemble_lua(driver, semver):
    parts = []
    for name in DRIVERS[driver][1] + [f"{driver}/driver.lua"]:
        parts.append(f"-- ===== {name} =====\n" + open(os.path.join(SRC, name), encoding="utf-8").read())
    lua = "\n".join(parts)
    lua, n = re.subn(r'^DRIVER_SEMVER = "[^"]*"', f'DRIVER_SEMVER = "{semver}"', lua, count=1, flags=re.M)
    if n != 1:
        sys.exit("DRIVER_SEMVER line not found")
    return lua


def stamp_xml(xml, number):
    now = datetime.datetime.now().strftime("%m/%d/%Y %H:%M")
    xml, n1 = re.subn(r"<version>\d+</version>", f"<version>{number}</version>", xml, count=1)
    xml, n2 = re.subn(r"<modified>[^<]*</modified>", f"<modified>{now}</modified>", xml, count=1)
    if n1 != 1 or n2 != 1:
        sys.exit("driver.xml: <version> or <modified> not found")
    return xml


def build(driver, semver, number):
    package = DRIVERS[driver][0]
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, package)
    if os.path.exists(out):
        os.remove(out)
    base = os.path.join(SRC, driver)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("driver.xml", stamp_xml(open(os.path.join(base, "driver.xml"), encoding="utf-8").read(), number))
        z.writestr("driver.lua", assemble_lua(driver, semver))
        for root, _, files in os.walk(os.path.join(base, "www")):
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, base).replace(os.sep, "/"))
        z.write(os.path.join(ROOT, "LICENSE"), "www/LICENSE.txt")
        z.write(os.path.join(ROOT, "NOTICE"), "www/NOTICE.txt")
    print(f"built {out}  ({os.path.getsize(out)} bytes)")


def main():
    semver, number = read_version()
    print(f"version {semver} (driver.xml version {number})")
    for driver in DRIVERS:
        build(driver, semver, number)
    with open(os.path.join(DIST, "SHA256SUMS.txt"), "w", newline="\n") as sums:
        for package, _ in DRIVERS.values():
            digest = hashlib.sha256(open(os.path.join(DIST, package), "rb").read()).hexdigest()
            sums.write(f"{digest}  {package}\n")
    print("wrote dist/SHA256SUMS.txt")


if __name__ == "__main__":
    main()
