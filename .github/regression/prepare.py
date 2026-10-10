#!/usr/bin/env python3
"""Add regression observations and XCTest methods ONLY in disposable CI builds."""
import sys
import os
import xml.etree.ElementTree as ET
from pathlib import Path
root=Path(__file__).resolve().parents[2]
source=Path(__file__).resolve().parent
if len(sys.argv)!=2 or sys.argv[1] not in ('web','native','scheme'):
    raise SystemExit("Usage: prepare.py web|native|scheme")
if sys.argv[1]=='web':
    p=root/'src/main.js'
    p.write_text(p.read_text()+'\n'+(source/'observer.js').read_text())
elif sys.argv[1]=='native':
    p=root/'.github/simulator/PlaybackUITests.swift'
    s=p.read_text()
    at=s.rfind('\n}')
    assert at>=0,"Regression tests need native SimulatorPlayback class"
    p.write_text(s[:at]+'\n'+(source/'tests.swift').read_text()+s[at:])

else:
    p=root/'ios/App/App.xcodeproj/xcshareddata/xcschemes/SimulatorPlayback.xcscheme'
    tree=ET.parse(p)
    action=tree.getroot().find('TestAction')
    assert action is not None,'Missing XCTest scheme TestAction'
    variables=action.find('EnvironmentVariables')
    assert variables is not None,'Account secrets must already be configured'
    marker=os.environ.get('IRGUN_SYNC_MARKER','').strip()
    assert marker and marker.isdigit(),'Need numeric unique Actions run marker'
    ET.SubElement(variables,'EnvironmentVariable',key='IRGUN_SYNC_MARKER',
                  value=marker,isEnabled='YES')
    tree.write(p,encoding='utf-8',xml_declaration=True)
