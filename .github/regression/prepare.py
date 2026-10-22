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
    # Simulator prepare.py already copied its XCTest file into the generated
    # Xcode project. Change that actual, compiled target, NOT the source copy.
    p=root/'ios/App/SimulatorUITests/PlaybackUITests.swift'
    assert p.is_file(), 'Generated native XCTest file missing'
    s=p.read_text()
    methods=(source/'native-login.swift').read_text()+'\n'+(source/'tests.swift').read_text()+'\n'+(source/'account-regressions.swift').read_text()
    at=s.rfind('\n}')
    assert at>=0 and 'class PlaybackUITests' in s, 'Unexpected XCTest class layout'
    assert 'func testRegression' not in s, 'Regression methods already injected'
    count=methods.count('func testRegression')
    assert count==12, f'Expected 12 real regression methods, got {count}'
    p.write_text(s[:at]+'\n'+methods+s[at:])
    compiled=p.read_text()
    for method in ('testRegressionBackgroundAudioAndReopenControls',
                   'testRegressionNotificationTapRestoresInlinePlayer',
                   'testRegressionCrossDeviceWriterOnIPhone',
                   'testRegressionCrossDeviceReaderOnIPad',
                   'testRegressionAuthenticatedCommentsMediaProfile'):
        assert compiled.count('func '+method+'(')==1, 'Not in native XCTest target: '+method
    print('Injected',count,'regression XCTest methods into generated native target')

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
