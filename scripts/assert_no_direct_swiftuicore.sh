#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/ios/App/App.xcodeproj/project.pbxproj"
if [ ! -f "$PBX" ]; then
  echo "ERROR: Xcode project is missing: $PBX" >&2
  exit 2
fi
if grep -nE '(^|[[:space:]"=])(-weak_framework|-framework)[[:space:]]+SwiftUICore|SwiftUICore\.framework|SwiftUICore' "$PBX"; then
  echo "ERROR: The generated Xcode project still contains a direct SwiftUICore reference." >&2
  echo "iPadOS 15-17 cannot use SwiftUICore directly, and Xcode 26 rejects it as a private framework." >&2
  exit 3
fi
echo "OK: no direct SwiftUICore reference in the generated app project."
