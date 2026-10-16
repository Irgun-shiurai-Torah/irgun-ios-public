#!/usr/bin/env python3
"""Advance the iOS marketing version by one patch release.

The repository keeps the package version with a '-ios' suffix so it is not
mistaken for the Android package version. The iOS build workflow strips that
suffix when writing CFBundleShortVersionString.

This script runs only after a successful iOS build. The binary that just
finished therefore keeps its current version, while package.json is advanced
for the next build.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

PACKAGE = Path("package.json")
PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)(-ios)?$")


def main() -> None:
    data = json.loads(PACKAGE.read_text(encoding="utf-8"))
    current = str(data.get("version", ""))
    match = PATTERN.fullmatch(current)
    if not match:
        raise SystemExit(
            f"Unsupported iOS package version {current!r}; expected X.Y.Z or X.Y.Z-ios."
        )

    major, minor, patch = (int(match.group(i)) for i in range(1, 4))
    suffix = match.group(4) or "-ios"
    next_version = f"{major}.{minor}.{patch + 1}{suffix}"

    data["version"] = next_version
    PACKAGE.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Advanced iOS marketing version: {current} -> {next_version}")


if __name__ == "__main__":
    main()
