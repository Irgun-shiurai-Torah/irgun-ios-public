#!/usr/bin/env python3
"""Validate genuine Duo simulator screenshots and package accepted App Store sizes.

The existing XCUITest exports captures of the real app window. On some simulator
builds an XCTest window screenshot differs by a single pixel from the corresponding
screen framebuffer. A <=2px dimension correction is allowed; a screenshot of the
wrong panel is never resized to pretend it came from the desired Duo display.
"""
import hashlib
import json
import os
import subprocess
from pathlib import Path

pose = os.environ["DUO_POSE"]
expected = {"folded": (1398, 2034), "unfolded": (2853, 2007)}[pose]
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

    if pose == "unfolded" and (
        abs(width - expected_height) <= 2 and
        abs(height - expected_width) <= 2
    ):
        # The Duo inner panel's native open pose is sideways. XCTest returns
        # real app framebuffer pixels in panel-native portrait dimensions even
        # though the scene and WebView have been verified in landscape. Rotate
        # those genuine pixels clockwise once; never rotate a portrait-layout
        # app capture because the XCTest bridge separately asserts viewport
        # width > height before any page screenshot is taken.
        rotated = file.with_name(file.stem + ".rotated.png")
        result = subprocess.run(
            ["sips", "-r", "90", "--out", str(rotated), str(file)],
            capture_output=True, text=True,
        )
        if result.returncode or not rotated.exists():
            raise SystemExit(
                f"Could not orient unfolded Duo framebuffer {file.name}: "
                + result.stderr
            )
        rotated.replace(file)
        report = subprocess.check_output(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(file)],
            text=True,
        )
        parts = [int(line.split(":", 1)[1].strip()) for line in report.splitlines()
                 if "pixelWidth:" in line or "pixelHeight:" in line]
        if len(parts) != 2:
            raise SystemExit(f"Cannot identify rotated screenshot dimensions: {file}")
        width, height = parts

    if abs(width - expected_width) <= 2 and abs(height - expected_height) <= 2:
        target_width, target_height = expected_width, expected_height
    else:
        raise SystemExit(
            f"{file.name}: {width}x{height} is not a valid upright {pose} Duo screenshot. "
            f"Expected {expected_width}x{expected_height} (or the native inner-panel "
            "raster for unfolded captures). Wrong-screen captures are deliberately rejected."
        )

    if (width, height) != (target_width, target_height):
        # sips may silently leave the source unchanged when --out points back
        # at the input file. Write to a separate path and atomically replace.
        normalized = file.with_name(file.stem + ".normalized.png")
        result = subprocess.run(
            ["sips", "-z", str(target_height), str(target_width),
             "--out", str(normalized), str(file)],
            capture_output=True, text=True,
        )
        if result.returncode or not normalized.exists():
            raise SystemExit(
                f"Could not normalize one-pixel simulator offset for {file.name}: "
                + result.stderr
            )
        normalized.replace(file)
        actual = subprocess.check_output(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(file)],
            text=True,
        )
        actual_size = [
            int(line.split(":", 1)[1].strip())
            for line in actual.splitlines()
            if "pixelWidth:" in line or "pixelHeight:" in line
        ]
        if actual_size != [target_width, target_height]:
            raise SystemExit(
                f"Normalization failed for {file.name}: {actual_size}, "
                f"expected {[target_width, target_height]}"
            )
    summary.append({
        "file": file.name,
        "captured_width": width,
        "captured_height": height,
        "app_store_width": target_width,
        "app_store_height": target_height,
    })
# The Oct 22 Duo run #7 produced 26 pixel-identical black PNGs from
# XCUIScreen.main. Reject invalid repeated frames even when dimensions match.
fingerprints = {hashlib.sha256(file.read_bytes()).hexdigest() for file in files}
if len(fingerprints) < 8:
    raise SystemExit(
        f"Only {len(fingerprints)} distinct images among {len(files)} screenshots; "
        "likely an inactive/black Duo display. Genuine page captures required."
    )

print(f"Validated {len(summary)} {pose} Duo screenshots")
Path("duo-results/dimensions.json").write_text(json.dumps(summary, indent=2))
