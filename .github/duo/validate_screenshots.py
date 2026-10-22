#!/usr/bin/env python3
"""Validate genuine Duo simulator screenshots and package accepted App Store sizes.

The existing XCUITest exports captures of the real app window. On some simulator
builds an XCTest window screenshot differs by a single pixel from the corresponding
screen framebuffer. A <=2px dimension correction is allowed; a screenshot of the
wrong panel is never resized to pretend it came from the desired Duo display.
"""
import json
import os
import subprocess
from pathlib import Path

pose = os.environ["DUO_POSE"]
expected = {"folded": (1398, 2034), "unfolded": (2007, 2853)}[pose]
directory = Path("simulator-results/app-store")
files = sorted(directory.glob("*.png"))
if len(files) != 26:
    raise SystemExit(f"Expected 26 real app screenshots, found {len(files)}")

summary = []
for file in files:
    report = subprocess.check_output(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(file)], text=True
    )
    parts = [int(line.split(":", 1)[1].strip()) for line in report.splitlines()
             if "pixelWidth:" in line or "pixelHeight:" in line]
    if len(parts) != 2:
        raise SystemExit(f"Cannot identify screenshot dimensions: {file}")

    width, height = parts
    expected_width, expected_height = expected
    if abs(width - expected_width) <= 2 and abs(height - expected_height) <= 2:
        target_width, target_height = expected_width, expected_height
    elif abs(width - expected_height) <= 2 and abs(height - expected_width) <= 2:
        target_width, target_height = expected_height, expected_width
    else:
        raise SystemExit(
            f"{file.name}: {width}x{height} is not a {pose} Duo screenshot. "
            f"Expected {expected_width}x{expected_height} or rotated. "
            "Wrong-screen captures are deliberately rejected."
        )

    if (width, height) != (target_width, target_height):
        result = subprocess.run(
            ["sips", "-z", str(target_height), str(target_width),
             "--out", str(file), str(file)],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise SystemExit(f"Could not normalize one-pixel simulator offset for {file.name}: {result.stderr}")
    summary.append({
        "file": file.name,
        "captured_width": width,
        "captured_height": height,
        "app_store_width": target_width,
        "app_store_height": target_height,
    })
print(f"Validated {len(summary)} {pose} Duo screenshots")
Path("duo-results/dimensions.json").write_text(json.dumps(summary, indent=2))
