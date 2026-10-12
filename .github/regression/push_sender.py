#!/usr/bin/env python3
"""Wait for the actual backgrounded XCTest, then deliver real APNs via simctl."""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit('usage: push_sender.py <simulator-udid> <bundle-id>')
udid, bundle = sys.argv[1:]

def snapshot():
    try:
        with socket.create_connection(('127.0.0.1',47291),timeout=2) as connection:
            payload = b''
            while b'\n' not in payload and len(payload) < 400000:
                chunk = connection.recv(65536)
                if not chunk: break
                payload += chunk
        return json.loads(payload)
    except (OSError,ValueError):
        return {}

# Compilation can take many minutes. Only the current native test can arm
# delivery, after OS authorization, real playback and pressing Home. Never
# send against a stale snapshot left behind by the previous XCTest group.
with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    server.bind(('127.0.0.1',47312))
    server.listen(1)
    server.settimeout(1800)
    print('Waiting for backgrounded native notification test',flush=True)
    with server.accept()[0] as connection:
        connection.settimeout(15)
        payload = b''
        while b'\n' not in payload and len(payload) < 4096:
            chunk = connection.recv(4096)
            if not chunk: break
            payload += chunk
        ready = json.loads(payload)
        target_id = str(ready.get('id') or '')
        previous = int(ready.get('previousActions') or 0)
        if not target_id:
            raise SystemExit('Native XCTest did not select a real shiur')
        connection.sendall(b'READY\n')

path = Path('simulator-results/qa-notification.apns')
path.parent.mkdir(exist_ok=True,parents=True)
path.write_text(json.dumps({
    'aps':{'alert':{'title':'Irgun QA Playback','body':'Tap to reopen the same shiur'},'sound':'default'},
    'url':'https://irgunshiuraitorah.com/watch.html?v='+target_id
}))
deadline = time.monotonic()+125
accepted = 0
tapped = False
while time.monotonic() < deadline:
    if int((snapshot().get('regression') or {}).get('pushActions') or 0) > previous:
        tapped = True
        break
    try:
        result = subprocess.run(['xcrun','simctl','push',udid,bundle,str(path)],
                                capture_output=True,text=True,timeout=30)
        if result.returncode:
            print('Real simctl push failed:',result.stderr[-400:],flush=True)
        else:
            accepted += 1
            print('Real simctl push accepted:',accepted,flush=True)
    except subprocess.TimeoutExpired:
        # A cold simulator service may hang once. Retry the actual operation;
        # an accepted delivery and observed native action remain mandatory.
        print('Real simctl push timed out; retrying while test waits',flush=True)
    time.sleep(5)
if not accepted or not tapped:
    raise SystemExit('Real APNs delivery and native notification tap were not both verified')
print('Verified real APNs delivery and native tap',flush=True)
