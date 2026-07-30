#!/usr/bin/env python3
"""Génère l'instantané de catalogue embarqué à partir du cfg.json officiel de cMouse.

Le catalogue n'est jamais téléchargé à l'exécution : ce script produit un fichier
versionné, relu par `PulsarCatalog`, et le test `CatalogSnapshotTests` compare ce
fichier à la source officielle pour signaler toute famille nouvellement déclarée.

    python3 Tools/generate_catalog.py                 # télécharge et régénère
    python3 Tools/generate_catalog.py --from cfg.json # depuis un fichier local
    python3 Tools/generate_catalog.py --check         # ne réécrit rien, sort 1 si divergent
"""

import argparse
import json
import pathlib
import sys
import urllib.request

SOURCE_URL = "https://bbb.pulsar.gg/cMouse/cfg.json"
SENSOR_URL = "https://bbb.pulsar.gg/cMouse/sensor.json"
DEVICE_NAME_URL = "https://bbb.pulsar.gg/cMouse/devicename.json"
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Sources/PulsarCatalog/Resources/catalog.json"
SCHEMA_VERSION = 2


def fetch(url, path=None):
    if path:
        return json.loads(pathlib.Path(path).read_text())
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.loads(response.read().decode())


def parse_color(value):
    """"rgb(52,248,242)" -> {"red": 52, "green": 248, "blue": 242}"""
    inner = value[value.index("(") + 1: value.rindex(")")]
    red, green, blue = (int(part.strip()) for part in inner.split(","))
    return {"red": red, "green": green, "blue": blue}


def build_sensors(sensors):
    """Retient les plages DPI. Les tables `values`/`office` concernent des capteurs
    absents du catalogue souris actuel et ne sont pas reprises."""
    result = {}
    for name, entry in sensors.items():
        if not isinstance(entry, dict) or "range" not in entry:
            continue
        result[name] = {
            "ranges": [
                {
                    "minimum": r["min"],
                    "maximum": r["max"],
                    "step": r["step"],
                    "exponentCode": r["DPIex"] & 0x03,
                }
                for r in entry["range"]
            ],
            "hasLookupTable": "values" in entry or "office" in entry,
        }
    return result


def normalize_device_name(value):
    """Aplatit le format officiel, qui utilise une chaîne ou deux lignes."""
    parts = value if isinstance(value, list) else [value]
    return " ".join(part.strip() for part in parts if part and part.strip())


def build_models(device_names):
    models = []
    for group in device_names["deviceName"]:
        cid = group["cid"]
        for offset, name in enumerate(group["name"]):
            mid = offset + 1
            models.append({
                "cid": cid,
                "mid": mid,
                "name": normalize_device_name(name),
                "imageName": f"mouse-{cid:02X}-{mid:02X}",
            })
    return models


def build(cfg, sensors, device_names):
    families = []
    seen_mids = set()

    for group in cfg["mouse"]:
        cid = group["cid"]
        fan_mids = set(group.get("FanMIDList") or [])
        for entry in group["cfg"]:
            # Un MID dupliqué entre deux groupes est résolu par « le premier gagne »,
            # comme le fait le site en s'arrêtant à la première correspondance.
            mids = [m for m in entry["mid"] if (cid, m) not in seen_mids]
            seen_mids.update((cid, m) for m in mids)
            if not mids:
                continue

            sensor = entry["sensor"]
            upgrade = entry.get("upgrade") or {}
            families.append({
                "cid": cid,
                "mids": sorted(mids),
                "theme": entry.get("theme", "General"),
                "microcontroller": entry.get("mouse"),
                "sensor": {
                    "type": sensor["type"],
                    "defaultLiftOff": sensor.get("lod", 1),
                    "supportsMotionSync": "motionSync" in sensor,
                    "supportsAngleSnap": "angle" in sensor,
                    "supportsRippleControl": "ripple" in sensor,
                    "supportsPerformanceMode": "performanceState" in sensor,
                    "defaultPerformance": sensor.get("performance", 0),
                    "defaultSensorMode": sensor.get("sensorMode", 0),
                },
                "dpi": {
                    "maximum": entry["maxDpi"],
                    "middle": entry.get("middleDpi", 3200),
                    "defaultStage": entry.get("currentDpi", 1),
                    "stages": [
                        {"value": stage["value"], "color": parse_color(stage["color"])}
                        for stage in entry["dpis"]
                    ],
                },
                "buttons": [
                    {
                        "index": key["index"],
                        "position": {"x": key["loc"][0], "y": key["loc"][1]},
                        "defaultType": int(key["value"][0], 16),
                        "defaultParameter": int(key["value"][1], 16),
                    }
                    for key in sorted(entry.get("keys", []), key=lambda k: k["index"])
                ],
                "debounce": {
                    "default": entry.get("debounce", 2),
                    "maximum": entry.get("maxDebounce", 15),
                    "warnAbove": entry.get("tipsDebounce", 8),
                },
                "power": {
                    "defaultSleepMinutes": entry.get("sleepTime", 6),
                    "defaultPowerSaveBattery": entry.get("powerSaveBattery", 0),
                    "supportsLongDistance": "longDistance" in entry,
                    "defaultLongDistance": bool(entry.get("longDistance", False)),
                },
                "supportsAngleTune": "angleTune" in entry,
                "supportsFanMode": any(m in fan_mids for m in mids),
                "maximumReportRate": entry.get("reportRate", 1000),
                "dongleFirmware": {
                    key: entry[key] for key in ("dongle1", "dongle2", "dongle4") if entry.get(key)
                },
                "firmware": {
                    "deviceVersion": (upgrade.get("device") or {}).get("version"),
                    "dongleVersion": (upgrade.get("dongle") or {}).get("version"),
                },
            })

    return {
        "schemaVersion": SCHEMA_VERSION,
        "sourceVersion": cfg["version"],
        "sourceURL": SOURCE_URL,
        "deviceNameSourceURL": DEVICE_NAME_URL,
        "vendorIDs": [int(v, 16) for v in cfg["vid"]],
        "mouseProductIDs": {
            "wired": sorted(int(p, 16) for p in cfg["pid"]["mouse"]["wired"]),
            "wireless": sorted(int(p, 16) for p in cfg["pid"]["mouse"]["wireless"]),
        },
        "sensors": build_sensors(sensors),
        "families": families,
        "models": build_models(device_names),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="source", help="cfg.json local au lieu du réseau")
    parser.add_argument("--sensors", dest="sensors", help="sensor.json local au lieu du réseau")
    parser.add_argument(
        "--device-names",
        dest="device_names",
        help="devicename.json local au lieu du réseau",
    )
    parser.add_argument("--check", action="store_true", help="compare sans réécrire")
    args = parser.parse_args()

    catalog = build(
        fetch(SOURCE_URL, args.source),
        fetch(SENSOR_URL, args.sensors),
        fetch(DEVICE_NAME_URL, args.device_names),
    )
    rendered = json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n"

    if args.check:
        if not OUTPUT.exists():
            print("catalogue absent", file=sys.stderr)
            return 1
        if OUTPUT.read_text() != rendered:
            print("le catalogue embarqué diffère de la source officielle", file=sys.stderr)
            return 1
        print("catalogue à jour")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    total_mids = sum(len(f["mids"]) for f in catalog["families"])
    print(f"{OUTPUT.relative_to(OUTPUT.parent.parent.parent.parent)} : "
          f"{len(catalog['families'])} familles, {total_mids} MID, "
          f"{len(catalog['models'])} visuels, source v{catalog['sourceVersion']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
