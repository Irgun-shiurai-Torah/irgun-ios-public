import os,sys
from pathlib import Path
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[2]
here=Path(__file__).resolve().parent
if sys.argv[1]=='web':
 p=root/'src/main.js';p.write_text(p.read_text()+'\n'+(here/'observer.js').read_text())
 p=root/'.github/simulator/PlaybackUITests.swift';s=p.read_text();at=s.rfind('\n}');assert at>=0
 p.write_text(s[:at]+'\n'+(here/'test.swift').read_text()+s[at:])
elif sys.argv[1]=='scheme':
 p=root/'ios/App/App.xcodeproj/xcshareddata/xcschemes/SimulatorPlayback.xcscheme'
 t=ET.parse(p);a=t.getroot().find('TestAction');assert a is not None
 # The generated scheme inherits LaunchAction by default, ignoring test-only env.
 a.set('shouldUseLaunchSchemeArgsEnv','NO')
 for previous in list(a.findall('EnvironmentVariables')): a.remove(previous)
 v=ET.SubElement(a,'EnvironmentVariables')
 for k in ['IRGUN_TEST_EMAIL','IRGUN_TEST_PASSWORD']:
  assert os.environ.get(k),f'Missing {k}'
  ET.SubElement(v,'EnvironmentVariable',key=k,value=os.environ[k],isEnabled='YES')
 t.write(p,encoding='utf-8',xml_declaration=True)

