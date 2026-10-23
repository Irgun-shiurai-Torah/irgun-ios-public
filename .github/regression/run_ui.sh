#!/usr/bin/env bash
# Actual iOS Simulator XCTest method selection, never disabled assertions.
set -euo pipefail
group="$1"
udid="$2"
mkdir -p simulator-results
CONTAINER=(-project ios/App/App.xcodeproj)
if [ -d ios/App/App.xcworkspace ]; then CONTAINER=(-workspace ios/App/App.xcworkspace); fi
case "$group" in
  core)
    result="Regression"
    methods=(
      testRegressionBackgroundAudioAndReopenControls
      testRegressionMiniFullscreenPiPCycle
      testRegressionNetworkLossAndRecovery
      testRegressionSpeedDefaultAndOnePointFiveAfterReopen
      testRegressionDirectListenAndOriginalFullPlayer
      testRegressionWatchOptionThreePopupAndNativeSpeed
      testRegressionOfflineDownloadPlaysWithoutNetworkAndSyncsHistory
      testRegressionHebrewRtlAndVisibleControls
      testRegressionLongPlaybackLockAndModeChanges
      testRegressionLoginErrorServerRevocationNameAndRelogin
      testRegressionAuthenticatedCommentsMediaProfile
    )
    ;;
  push)
    result="Push"
    methods=(testRegressionNotificationTapRestoresInlinePlayer)
    python3 -u .github/regression/push_sender.py "$udid" "$BUNDLE_ID" > simulator-results/push-sender.log 2>&1 &
    sender="$!"
    trap 'kill "$sender" 2>/dev/null || true' EXIT
    ;;
  writer)
    result="CrossDeviceWriter"
    methods=(testRegressionCrossDeviceWriterOnIPhone)
    ;;
  reader)
    result="CrossDeviceReader"
    methods=(testRegressionCrossDeviceReaderOnIPad)
    ;;
  *)
    echo "Unknown genuine XCTest group: $group"
    exit 2
    ;;
esac
selected=()
test_file="ios/App/SimulatorUITests/PlaybackUITests.swift"
test -s "$test_file" || { echo "XCTest compilation source is missing"; exit 1; }
for method in "${methods[@]}"; do
  # The *compiled* file must contain each real test. A typo in -only-testing
  # would otherwise make xcodebuild report success with zero executions.
  grep -Fq "func $method(" "$test_file" || {
    echo "Required method not injected into real Xcode project: $method"
    exit 1
  }
  selected+=("-only-testing:SimulatorUITests/PlaybackUITests/$method")
done
xcodebuild "${CONTAINER[@]}" \
  -scheme SimulatorPlayback -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -destination-timeout 120 \
  -derivedDataPath "$RUNNER_TEMP/ExtendedRegressionDerivedData" \
  -resultBundlePath "simulator-results/$result.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  "${selected[@]}" test 2>&1 | tee "simulator-results/$result-xcodebuild.log"
python3 - "simulator-results/$result-xcodebuild.log" "${methods[@]}" <<'PY'
import sys
from pathlib import Path
log=Path(sys.argv[1]).read_text(errors='replace')
methods=sys.argv[2:]
passed=0
skipped=0
for name in methods:
    prefix="Test Case '-[SimulatorUITests.PlaybackUITests "+name+"]' "
    if prefix+"passed (" in log:
        passed+=1
        continue
    # Native system PiP is unavailable on some iOS Simulator runtimes. XCTest
    # deliberately skips that hardware-only case; don't turn the expected skip
    # into a red workflow after Xcode has correctly reported TEST SUCCEEDED.
    if (name=="testRegressionMiniFullscreenPiPCycle"
        and prefix+"skipped (" in log
        and "Native system PiP is unsupported in this simulator; physical-device PiP verification remains required" in log):
        skipped+=1
        print("SKIP (expected simulator limitation; physical-device PiP still required): "+name)
        continue
    print("FAIL: required native XCTest did not execute and pass: "+name)
    raise SystemExit(1)
if "Executed 0 tests" in log:
    raise SystemExit("FAIL: the simulator ran zero tests")
if "** TEST SUCCEEDED **" not in log:
    raise SystemExit("FAIL: xcodebuild did not report TEST SUCCEEDED")
print("PASS:",passed,"requested XCTest methods passed;",skipped,"documented simulator-only skips")
PY
if [ "$group" = push ]; then wait "$sender"; fi
