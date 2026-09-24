#!/bin/bash
set -euo pipefail

# Guard against the iOS/iPadOS 15-17 launch crash caused by a HARD dependency on
# /System/Library/Frameworks/SwiftUICore.framework/SwiftUICore.
# SwiftUICore does not exist on those systems. A weak dependency is allowed.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA=""
for candidate in \
  "$ROOT"/ios/App/build/ios/ipa/*.ipa \
  "$ROOT"/build/ios/ipa/*.ipa; do
  if [ -f "$candidate" ]; then
    IPA="$candidate"
    break
  fi
done

if [ -z "$IPA" ]; then
  echo "ERROR: No IPA found for iOS 15 compatibility verification." >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$IPA" -d "$TMP"
APP="$(find "$TMP/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [ -z "$APP" ]; then
  echo "ERROR: IPA does not contain an .app bundle." >&2
  exit 2
fi

INFO="$APP/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO" 2>/dev/null || true)"
if [ -z "$EXECUTABLE" ] || [ ! -f "$APP/$EXECUTABLE" ]; then
  echo "ERROR: Could not locate the main executable in $APP." >&2
  exit 2
fi

# Keep the native executable unique rather than the generic `App` used by the
# Capacitor target/scheme. This is extra hardening; the weak-link check below is
# the authoritative launch-safety test.
if [ "$EXECUTABLE" = "App" ]; then
  echo "ERROR: Native executable is still named 'App'." >&2
  exit 3
fi

FOUND_HARD=0
FOUND_WEAK=0
while IFS= read -r -d '' bin; do
  if ! file "$bin" | grep -q 'Mach-O'; then
    continue
  fi

  # Inspect Mach-O load commands. LC_LOAD_DYLIB is hard; LC_LOAD_WEAK_DYLIB is safe.
  LOADS="$(otool -l "$bin" 2>/dev/null || true)"
  if [ -z "$LOADS" ]; then
    continue
  fi

  # Parse each load command and the following framework name lines.
  CURRENT_CMD=""
  while IFS= read -r line; do
    case "$line" in
      *"cmd LC_LOAD_WEAK_DYLIB"*) CURRENT_CMD="weak" ;;
      *"cmd LC_LOAD_DYLIB"*) CURRENT_CMD="hard" ;;
      *"cmd LC_REEXPORT_DYLIB"*) CURRENT_CMD="hard" ;;
      *"cmd LC_LAZY_LOAD_DYLIB"*) CURRENT_CMD="weak" ;;
      *"name /System/Library/Frameworks/SwiftUICore.framework/SwiftUICore"*)
        if [ "$CURRENT_CMD" = "weak" ]; then
          echo "OK: weak SwiftUICore dependency in: $bin"
          FOUND_WEAK=1
        else
          echo "ERROR: HARD SwiftUICore dependency found in: $bin" >&2
          FOUND_HARD=1
        fi
        ;;
    esac
  done <<< "$LOADS"
done < <(find "$APP" -type f -print0)

if [ "$FOUND_HARD" -ne 0 ]; then
  echo "ERROR: Build is not safe for iPadOS 15; refusing to publish." >&2
  exit 4
fi

echo "iOS 15 launch compatibility check passed."
echo "Executable: $EXECUTABLE"
if [ "$FOUND_WEAK" -eq 1 ]; then
  echo "SwiftUICore is weak-linked only (safe when absent on iPadOS 15-17)."
else
  echo "No SwiftUICore dependency found."
fi
