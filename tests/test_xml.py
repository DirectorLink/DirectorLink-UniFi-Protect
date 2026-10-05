"""driver.xml checks (offline).   python tests/test_xml.py

Catches definitions Composer rejects at install time - for example a property of
type PASSWORD, which Composer reports as "Property Invalid ... Object reference not
set to an instance of an object". Password fields are STRING + <password>true</password>.
"""
import os
import xml.etree.ElementTree as ET

from harness import ROOT, check, finish

PROPERTY_TYPES = {"STRING", "LIST", "RANGED_INTEGER", "RANGED_FLOAT", "LABEL", "DYNAMIC_LIST",
                  "DEVICE_SELECTOR", "COLOR_SELECTOR", "LINK", "SCROLL", "TRACK"}
PARAM_TYPES = {"STRING", "LIST", "RANGED_INTEGER", "RANGED_FLOAT", "DEVICE_SELECTOR", "COLOR_SELECTOR", "CUSTOM_SELECT", "DYNAMIC_LIST"}
CONDITIONAL_TYPES = {"SIMPLE", "BOOL", "NUMBER", "STRING", "LIST", "ROOM", "DEVICE"}

for drv in ("hub", "camera"):
    path = os.path.join(ROOT, "src", drv, "driver.xml")
    root = ET.parse(path).getroot()
    props = root.findall("config/properties/property")
    names = [p.findtext("name") for p in props]
    bad = [(p.findtext("name"), p.findtext("type")) for p in props if (p.findtext("type") or "").strip() not in PROPERTY_TYPES]
    check(not bad, f"{drv}: every property type is one Composer supports {bad or ''}")
    check(len(names) == len(set(names)), f"{drv}: property names are unique")
    lists = [p.findtext("name") for p in props if p.findtext("type") == "LIST" and p.findtext("default") not in [i.text for i in p.findall("items/item")]]
    check(not lists, f"{drv}: every LIST default is one of its items {lists or ''}")
    ranged = [p.findtext("name") for p in props if p.findtext("type") == "RANGED_INTEGER"
              and not (int(p.findtext("minimum")) <= int(p.findtext("default")) <= int(p.findtext("maximum")))]
    check(not ranged, f"{drv}: every RANGED_INTEGER default is in range {ranged or ''}")
    params = [(c.findtext("name"), q.findtext("type")) for c in root.findall("config/commands/command") for q in c.findall("params/param")
              if q.findtext("type") not in PARAM_TYPES]
    check(not params, f"{drv}: every command parameter type is valid {params or ''}")
    conds = [(c.findtext("name"), c.findtext("type")) for c in root.findall("conditionals/conditional") if c.findtext("type") not in CONDITIONAL_TYPES]
    check(not conds, f"{drv}: every conditional type is valid {conds or ''}")
    events = root.findall("events/event")
    ids = [e.findtext("id") for e in events]
    check(len(ids) == len(set(ids)), f"{drv}: event ids are unique")
    check(all((e.findtext("description") or "").strip() for e in events), f"{drv}: every event has a description (Composer's Programming tab needs one)")
    check(root.find("states") is None, f"{drv}: no empty <states/>")
    for tag in ("properties", "actions", "script", "documentation"):
        check(root.find("config/" + tag) is not None and root.find(tag) is None, f"{drv}: <{tag}> is inside <config>")
    pw = [p.findtext("name") for p in props if "password" in (p.findtext("name") or "").lower() or "key" in (p.findtext("name") or "").lower().split()]
    check(all(next(x for x in props if x.findtext("name") == n).findtext("password") == "true" for n in pw), f"{drv}: secret fields are masked ({pw})")
    version = root.findtext("version")
    check(version is not None and version.isdigit(), f"{drv}: <version> is an integer ({version})")

    # DirectorLink brand: Composer name and maker metadata; no brand on anything the family sees
    expected = {"hub": "DirectorLink · UniFi Protect", "camera": "DirectorLink · UniFi Protect Camera"}[drv]
    check(root.findtext("name") == expected, f"{drv}: Composer name is '{expected}' ({root.findtext('name')})")
    check(root.findtext("creator") == "DirectorLink" and root.findtext("manufacturer") == "Ubiquiti"
          and root.findtext("copyright") == "Copyright 2026 DirectorLink", f"{drv}: creator, manufacturer and copyright")
    doc = root.find("config/documentation").get("file")
    check(doc == "www/documentation.html" and os.path.exists(os.path.join(ROOT, "src", drv, doc)), f"{drv}: documentation tab file exists ({doc})")
    for img in [root.findtext("small"), root.findtext("large")]:
        check(os.path.exists(os.path.join(ROOT, "src", drv, "www", img)), f"{drv}: icon {img} exists (paths are relative to www/)")
    family = ([p.get("name") for p in root.findall("proxies/proxy")] + [e.findtext("name") for e in events]
              + [c.findtext("connectionname") for c in root.findall("connections/connection")]
              + [c.findtext("name") for c in root.findall("conditionals/conditional")])
    check(not [n for n in family if "directorlink" in (n or "").lower()], f"{drv}: no brand in proxy, event, connection or conditional names")

# The DirectorLink camera agreement v1: events named exactly "Alert" and "Ring" (ids 1 and 2, never to change)
cam = ET.parse(os.path.join(ROOT, "src", "camera", "driver.xml")).getroot()
ev = {e.findtext("name"): e.findtext("id") for e in cam.findall("events/event")}
check(ev.get("Alert") == "1" and ev.get("Ring") == "2", f"camera: events 'Alert' (1) and 'Ring' (2) ({ev.get('Alert')}, {ev.get('Ring')})")
for name in ("Motion Detected", "Person Detected", "Vehicle Detected", "Animal Detected", "Package Detected", "Face Detected",
             "License Plate Detected", "Line Crossing", "Intrusion Detected"):
    check(name in ev, f"camera: programming event '{name}'")
caps = cam.find("capabilities")
check(caps.findtext("requires_dynamic_stream_urls") == "true", "camera: live video through GET_STREAM_URLS (requires_dynamic_stream_urls)")
check(caps.findtext("default_authentication_type") == "BASIC" and caps.findtext("default_rtsp_port") == "7447", "camera: Basic login, RTSP port 7447")
dup = {"Address", "HTTP Port", "RTSP Port", "Username", "Password", "API Key"} & {p.findtext("name") for p in cam.findall("config/properties/property")}
check(not dup, f"camera: no copy of the Control4 camera page or the API key in its properties {sorted(dup) or ''}")

finish()
