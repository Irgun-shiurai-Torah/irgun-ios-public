#!/usr/bin/env python3
"""Pick a real installed, available CoreSimulator iOS device and export its UDID."""
import json
import os
import re
import sys
import subprocess
from pathlib import Path

family=sys.argv[1] if len(sys.argv)>1 else os.environ["DEVICE_FAMILY"]
devices=json.loads(subprocess.check_output(
    ["xcrun","simctl","list","devices","available","--json"]
))["devices"]
choices=[(rt,d) for rt,rows in devices.items() if ".iOS-" in rt
         for d in rows if d.get("isAvailable") and d["name"].startswith(family)]
if not choices:
    raise SystemExit("No iOS Simulator device installed for "+family)
def score(item):
    rt,d=item
    name=d["name"]
    preferred=("Pro Max" in name) if family=="iPhone" else ("13" in name and "Pro" in name)
    return (tuple(map(int,re.findall(r"\d+",rt))),preferred,
            tuple(map(int,re.findall(r"\d+",name))))
choices.sort(key=score,reverse=True)
device=choices[0][1]
Path("simulator-results").mkdir(parents=True,exist_ok=True)
Path("simulator-results/"+family+".json").write_text(json.dumps(device,indent=2))
var=family.upper()+"_UDID"
with open(os.environ["GITHUB_ENV"],"a") as f:
    f.write(var+"="+device["udid"]+"\n")
print(var+"="+device["udid"]+" ("+device["name"]+")")
