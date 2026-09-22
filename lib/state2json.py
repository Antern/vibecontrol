#!/usr/bin/env python3
"""Turn the daemon's flat key=value state into the JSON clients consume.

Input lines (order of f.<n>.* decides feature order):
    daemon_pid=123      msg=...        graphical=0|1
    t.<n>.<field>=...   g.<group>.<field>=...   c.<key>=0|1
"""
import json
import sys

raw = {"daemon": {}, "toggles": {}, "groups": {}, "config": {}, "presets": {}, "msg": "",
       "graphical": "0", "llm_profile": "", "profiles": {},
       "llm_model": "", "llm_loaded": "", "models": {},
       "hidden": set(), "on_boot": "", "on_resume": ""}

for line in sys.stdin:
    line = line.rstrip("\n")
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key == "daemon_pid":
        raw["daemon"]["pid"] = int(value or 0)
    elif key == "msg":
        raw["msg"] = value
    elif key == "graphical":
        raw["graphical"] = value
    elif key == "llm_profile":
        raw["llm_profile"] = value
    elif key == "llm_model":
        raw["llm_model"] = value
    elif key == "llm_loaded":
        raw["llm_loaded"] = value
    elif key.startswith("m."):
        # m.<n>.<field>=value -- discovered models, ordered by the daemon
        _, index, field = key.split(".", 2)
        raw["models"].setdefault(int(index), {})[field] = value
    elif key.startswith("lp."):
        # lp.<profile>.<field>=value
        _, name, field = key.split(".", 2)
        raw["profiles"].setdefault(name, {})[field] = value
    elif key.startswith("t."):
        _, index, field = key.split(".", 2)
        raw["toggles"].setdefault(int(index), {})[field] = value
    elif key.startswith("g."):
        _, name, field = key.split(".", 2)
        raw["groups"].setdefault(name, {})[field] = value
    elif key.startswith("c."):
        raw["config"][key[2:]] = int(value or 0)
    elif key in ("on_boot", "on_resume"):
        raw[key] = value
    elif key.startswith("ph."):
        raw["hidden"].add(key[3:].split(".", 1)[0])
    elif key.startswith("p."):
        _, name, toggle = key.split(".", 2)
        raw["presets"].setdefault(name, {})[toggle] = value

doc = {
    "v": 2,
    "daemon": raw["daemon"],
    "session": {"graphical": raw["graphical"] == "1"},
    "toggles": [
        {
            "id": f.get("id", ""),
            "label": f.get("label", ""),
            "key": f.get("key", ""),
            "parent": f.get("parent") or None,
            "group": f.get("group", ""),
            "composite": f.get("composite") == "1",
            "category": f.get("category", "common"),
            "section": f.get("section") or f.get("category", "common"),
            "available": f.get("available", "1") == "1",
            "status": f.get("status", "off"),
            "busy": f.get("busy") or None,
            # Present only while busy. busy_since lets a client show elapsed
            # time without the daemon having to push a tick, and timeout lets
            # it say what happens when the time runs out.
            "busy_since": int(f["busy_since"]) if f.get("busy_since") else None,
            "timeout": int(f["timeout"]) if f.get("timeout") else None,
            "forced": f.get("forced") == "1",
            "note": f.get("note") or None,
        }
        for _, f in sorted(raw["toggles"].items())
    ],
    "groups": {
        name: {"busy": g.get("busy") == "1", "owner": g.get("owner") or None}
        for name, g in raw["groups"].items()
    },
    "config": raw["config"],
    "presets": raw["presets"],
    "llm": {
        "profile": raw["llm_profile"] or None,
        "profiles": raw["profiles"],
        # selected is what loads next; loaded is what the running server has.
        # They differ whenever the model changed without a restart, and a client
        # that shows only one of them will sometimes show the wrong thing.
        "selected": raw["llm_model"] or None,
        "loaded": raw["llm_loaded"] or None,
        "models": [
            {
                "path": m.get("path", ""),
                "name": m.get("name") or "",
                "arch": m.get("arch") or "?",
                "size": int(m["size"]) if m.get("size") else 0,
            }
            for _, m in sorted(raw["models"].items())
        ],
    },
    # Presets the daemon applies on its own, and which of them to keep out of a
    # client's preset matrix.
    "auto": {"on_boot": raw["on_boot"] or None, "on_resume": raw["on_resume"] or None,
             "hidden": sorted(raw["hidden"])},
    "msg": raw["msg"],
}
json.dump(doc, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
