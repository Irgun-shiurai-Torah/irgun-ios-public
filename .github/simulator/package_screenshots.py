#!/usr/bin/env python3
"""Package original XCUIScreen PNGs separately from the large xcresult bundle."""
import json
from pathlib import Path
import shutil
import zipfile

root = Path('simulator-results')
attachments = root / 'attachments'
destination = root / 'app-store'
destination.mkdir(exist_ok=True)
manifest = json.loads((attachments / 'manifest.json').read_text())

def collect(value):
    if isinstance(value, list):
        for item in value: collect(item)
    elif isinstance(value, dict):
        label = str(value.get('suggestedHumanReadableName', value.get('name', '')))
        filename = value.get('exportedFileName', '')
        if 'store-' in label and str(filename).lower().endswith('.png'):
            name = 'store-' + label.split('store-',1)[1].split('.png')[0].split('_0_')[0]
            name = ''.join(c for c in name if c.isalnum() or c in '-_') + '.png'
            shutil.copyfile(attachments / filename, destination / name)
        for child in value.values():
            if isinstance(child,(dict,list)): collect(child)

collect(manifest)
files = sorted(destination.glob('*.png'))
print('App Store screenshots:', [p.name for p in files])
# Keep each downloadable archive under the file-transfer limit. No resizing,
# cropping, overlays, synthetic content or diagnostic panel in these PNGs.
out = root / 'screenshot-downloads'
out.mkdir(exist_ok=True)
for index in range(0,len(files),6):
    with zipfile.ZipFile(out / f'App-Store-Screenshots-{index//6+1}.zip','w',zipfile.ZIP_DEFLATED) as archive:
        for file in files[index:index+6]: archive.write(file,file.name)
if len(files) != 26:
    raise SystemExit(f'Expected 26 clean screenshots; found {len(files)}. Partial captures have been packaged for review.')
