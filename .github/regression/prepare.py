#!/usr/bin/env python3
"""Add regression observations and XCTest methods ONLY in disposable CI builds."""
import sys
from pathlib import Path
root=Path(__file__).resolve().parents[2]
source=Path(__file__).resolve().parent
if len(sys.argv)!=2 or sys.argv[1] not in ('web','native'):
    raise SystemExit("Usage: prepare.py web|native")
if sys.argv[1]=='web':
    p=root/'src/main.js'
    p.write_text(p.read_text()+'\n'+(source/'observer.js').read_text())
else:
    p=root/'.github/simulator/PlaybackUITests.swift'
    s=p.read_text()
    at=s.rfind('\n}')
    assert at>=0,"Regression tests need native SimulatorPlayback class"
    p.write_text(s[:at]+'\n'+(source/'tests.swift').read_text()+s[at:])
