#!/usr/bin/env python3
"""Deliver real simulated APNs notifications through SpringBoard during XCTest.

No JS injection and no artificial invocation of the Firebase Messaging callback.
Simulator sees actual xcrun simctl push; XCTest must tap the visible notification.
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: push_sender.py <simulator-udid> <bundle-id>")
udid,bundle=sys.argv[1:]
target_id=""


def snapshot():
    try:
        with socket.create_connection(("127.0.0.1",47291),timeout=2) as s:
            payload=b""
            while b"\n" not in payload and len(payload)<400000:
                chunk=s.recv(65536)
                if not chunk:
                    break
                payload+=chunk
        return json.loads(payload)
    except (OSError,ValueError):
        return {}


deadline=time.monotonic()+125
while time.monotonic()<deadline:
    state=snapshot()
    if state.get("id") and state.get("mode")=="video":
        target_id=str(state["id"])
        break
    time.sleep(1)
if not target_id:
    raise SystemExit("Never saw a real selected shiur ID in the simulator")

# The payload matches the production FirebaseMessaging listener's data.url.
payload={
    "aps":{
        "alert":{"title":"Irgun QA Playback","body":"Tap to reopen the same shiur"},
        "sound":"default"
    },
    "url":"https://irgunshiuraitorah.com/watch.html?v="+target_id
}
path=Path("simulator-results/qa-notification.apns")
path.parent.mkdir(exist_ok=True,parents=True)
path.write_text(json.dumps(payload))
deadline=time.monotonic()+100
success=0
while time.monotonic()<deadline:
    state=snapshot()
    if int((state.get("regression") or {}).get("pushActions") or 0)>0:
        break
    # Repetition covers the race between Home transition and notification
    # display; XCTest still must TAP an actual SpringBoard notification.
    out=subprocess.run(["xcrun","simctl","push",udid,bundle,str(path)],
                       capture_output=True,text=True,timeout=15)
    if out.returncode:
        print("Push failure:",out.stderr[-400:],flush=True)
    else:
        success+=1
    time.sleep(6)
if success==0:
    raise SystemExit("Simulator never accepted a real notification push")
print("Simulated APNs deliveries accepted:",success,flush=True)
