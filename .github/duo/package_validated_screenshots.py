#!/usr/bin/env python3
"""Package screenshots only after the Duo validator has normalized their pixels."""
import hashlib
import os
from pathlib import Path
import struct
import zipfile

pose = os.environ.get("DUO_POSE")
expected = {
    "folded": (1398, 2034),
    "unfolded": (2853, 2007),
}.get(pose)
if expected is None:
    raise SystemExit(f"Unknown DUO_POSE: {pose!r}")

directory = Path("simulator-results/app-store")
files = sorted(directory.glob("*.png"))
if len(files) != 26:
    raise SystemExit(f"Expected 26 validated screenshots, found {len(files)}")

fingerprints = set()
for file in files:
    with file.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{file.name}: not a valid PNG")
    width, height = struct.unpack(">II", header[16:24])
    if (width, height) != expected:
        raise SystemExit(
            f"{file.name}: packaged dimensions {width}x{height}; "
            f"expected validated {expected[0]}x{expected[1]}"
        )
    fingerprints.add(hashlib.sha256(file.read_bytes()).hexdigest())

if len(fingerprints) < 8:
    raise SystemExit(
        f"Only {len(fingerprints)} distinct images among {len(files)} screenshots"
    )

out = Path("simulator-results/screenshot-downloads")
out.mkdir(parents=True, exist_ok=True)
for old in out.glob("App-Store-Screenshots-*.zip"):
    old.unlink()

for start in range(0, len(files), 6):
    target = out / f"App-Store-Screenshots-{start // 6 + 1}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in files[start:start + 6]:
            archive.write(file, file.name)

print(f"Packaged {len(files)} validated {pose} screenshots at {expected[0]}x{expected[1]}")
