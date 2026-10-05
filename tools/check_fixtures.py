"""Check the test fixtures against Ubiquiti's official OpenAPI specifications.

    pip install jsonschema
    python tools/check_fixtures.py            # downloads the specs from developer.ui.com

The fixtures in tests/fixtures are the API answers the tests play back. This makes
sure each one has the shape the documented Protect versions answer with. The specs
are downloaded each time (they are Ubiquiti's, so they are not kept in this repository).
"""
import json
import os
import sys
import urllib.request

try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("pip install jsonschema")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "tests", "fixtures")
# Protect version -> the camera list fixture recorded in that version's shape
VERSIONS = {"5.3.48": "cameras_5.3.48.json", "6.2.83": "cameras_6.2.83.json"}
ALSO = ["6.0.53", "6.1.79"]  # the newer list must fit these too


def spec(version):
    url = f"https://developer.ui.com/protect/v{version}/openapi.json"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "DirectorLink-UniFi-Protect fixture check"}), timeout=30) as r:
        return json.load(r)


def load(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


def lines(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return [json.loads(x) for x in f if x.strip()]


def ref(n):
    return {"$ref": "#/components/schemas/" + n}


bad = 0


def check(root, version, label, data, schema):
    global bad
    doc = dict(root)
    doc.update(schema)
    errors = list(Draft202012Validator(doc).iter_errors(data))
    print(("OK   " if not errors else "BAD  ") + f"{version}: {label}" + ("" if not errors else " - " + "; ".join(e.message[:100] for e in errors[:3])))
    bad += bool(errors)


for version in list(VERSIONS) + ALSO:
    root = spec(version)
    cams = VERSIONS.get(version, "cameras_6.2.83.json" if version != "5.3.48" else "cameras_5.3.48.json")
    if version in ALSO:
        cams = "cameras_5.3.48.json"
    check(root, version, cams, load(cams), {"type": "array", "items": ref("camera")})
    check(root, version, "meta info", {"applicationVersion": version}, {"type": "object", "properties": {"applicationVersion": ref("protectVersion")}})
    check(root, version, "nvrs.json", load("nvrs.json"), ref("nvr"))
    for name, schema in (("rtsps_stream_all.json", "existingRtspsStreams"), ("rtsps_stream_none.json", "existingRtspsStreams"),
                         ("rtsps_stream_created.json", "createdRtspsStreams"), ("error_401.json", "genericError")):
        check(root, version, name, load(name), ref(schema))
    for i, m in enumerate(lines("ws_events.jsonl")):
        check(root, version, f"ws_events.jsonl line {i + 1} ({m['item']['type']})", m, {"oneOf": [ref("eventAdd"), ref("eventUpdate")]})
    for i, m in enumerate(lines("ws_devices.jsonl")):
        schema = {"add": ref("deviceAdd"), "update": ref("deviceUpdate"), "remove": ref("deviceRemove")}[m["type"]]
        check(root, version, f"ws_devices.jsonl line {i + 1} ({m['type']} {m['item']['modelKey']})", m, schema)

print()
print("ALL FIXTURES MATCH" if not bad else f"{bad} DO NOT MATCH")
sys.exit(1 if bad else 0)
