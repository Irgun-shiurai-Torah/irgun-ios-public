#!/usr/bin/env python3
"""Real macOS PF network blackout for disposable GitHub macOS simulator runners.

Blocks external 80/443 TCP+UDP for only the duration of a requested test.
Never mistakes simctl's decorative Wi-Fi status bar for lost connectivity.
Requires passwordless sudo on the private, ephemeral Actions runner.
Restores system pf.conf on UP, at timeout, on process shutdown, or on signal.
"""
import atexit
import os
import signal
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

PORT = 47311
RULES = "block drop out quick on ! lo0 proto { tcp udp } to any port { 80 443 }\n"
BLOCK_WINDOW_SEC = 75
lock = threading.Lock()
blocked = False
timer = None
was_active = False


def cmd(*args, stdin=None):
    return subprocess.run(
        ["sudo", "-n", "pfctl", *args], input=stdin, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12, check=True
    )


def restore():
    global blocked, timer
    with lock:
        if timer is not None:
            timer.cancel()
            timer = None
        if not blocked:
            return
        try:
            cmd("-f", "/etc/pf.conf")
            if not was_active:
                cmd("-d")
            blocked = False
            print("NETWORK GATE: restored original system pf.conf",flush=True)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            print("NETWORK GATE RESTORE ERROR: " + str(error),flush=True)
            raise


def blackout():
    global blocked, timer, was_active
    with lock:
        if blocked:
            if timer is not None:
                timer.cancel()
        else:
            info = cmd("-s","info").stdout
            was_active = "Status: Enabled" in info
            with tempfile.NamedTemporaryFile("w",prefix="irgun-pf-",delete=False) as file:
                file.write(RULES)
                filename=file.name
            try:
                # Preserve system PF configuration only until RESTORE.
                cmd("-f", filename)
                cmd("-E")
                blocked = True
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                # A failed PF install is NOT an offline test pass.
                try:
                    cmd("-f", "/etc/pf.conf")
                    if not was_active:
                        cmd("-d")
                finally:
                    raise
            finally:
                Path(filename).unlink(missing_ok=True)
        timer = threading.Timer(BLOCK_WINDOW_SEC,restore)
        timer.daemon = True
        timer.start()
        print("NETWORK GATE: real external TCP/UDP 80/443 blocked",flush=True)


def handle(connection):
    try:
        connection.settimeout(8)
        data=bytearray()
        while not data.endswith(b"\n") and len(data)<100:
            part=connection.recv(100)
            if not part:
                break
            data.extend(part)
        command=bytes(data).decode("ascii","replace").strip()
        if command=="DOWN":
            blackout()
        elif command=="UP":
            restore()
        else:
            connection.sendall(b"ERROR:unknown command\n")
            return
        connection.sendall(("OK:"+command+"\n").encode("ascii"))
    except Exception as error:
        print("NETWORK GATE failure:",type(error).__name__,str(error),flush=True)
        try:
            connection.sendall(("ERROR:"+type(error).__name__+"\n").encode("ascii"))
        except OSError:
            pass
    finally:
        connection.close()


atexit.register(restore)


def exit_signal(_signum, _frame):
    restore()
    raise SystemExit(0)


for sig in (signal.SIGTERM,signal.SIGINT):
    signal.signal(sig,exit_signal)

with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    server.bind(("127.0.0.1",PORT))
    server.listen(4)
    print("NETWORK GATE READY 127.0.0.1:%d" % PORT,flush=True)
    while True:
        client,_ = server.accept()
        handle(client)
