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
      testRegressionOfflineDownloadPlaysWithoutNetworkAndSyncsHistory
      testRegressionHebrewRtlAndVisibleControls
      testRegressionLongPlaybackLockAndModeChanges
      testRegressionLoginErrorServerRevocationNameAndRelogin
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
for method in "${methods[@]}"; do
  selected+=("-only-testing:SimulatorUITests/PlaybackUITests/$method")
done
xcodebuild "${CONTAINER[@]}" \
  -scheme SimulatorPlayback -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -destination-timeout 120 \
  -derivedDataPath "$RUNNER_TEMP/ExtendedRegressionDerivedData" \
  -resultBundlePath "simulator-results/$result.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  "${selected[@]}" test 2>&1 | tee "simulator-results/$result-xcodebuild.log"
if [ "$group" = push ]; then wait "$sender"; fi
