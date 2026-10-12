# iOS Extended Regression Tests (real iPhone and iPad simulators)

This is an **additional** CI workflow. Do not mistake it for the original public
`iOS Simulator Playback Tests` or the existing dedicated `iOS Login & Account Tests`.

## Coverage (never silently skipped)

- **Background playback:** actual Home button, native background audio clock sampling,
  video resumed with visible controls and working native Pause/Play.
- **Notification reopening:** `xcrun simctl push` delivers a notification to SpringBoard.
  XCTest taps that notification (not `app.activate()`), then verifies the native
  notification callback, inline player, controls, one playing video, real decoded frames.
  This tests simulator delivery, **not** live APNs infrastructure.
- **Mini, fullscreen and PiP:** real controls, Home/reopen, a single player, valid clocks
  and moving decoded frames. Unsupported PiP is a **failure**, not a passing skip.
- **Internet interruptions:** real macOS PF drops external HTTP(S) traffic. An actual
  cache-busted Worker request must fail during blackout and succeed after restoration.
  It is a host-network simulation, not an iPhone Wi-Fi radio toggle.
- **Playback speed:** native WebKit speed picker starts at 1×, selects 1.5×, then
  verifies the underlying video playbackRate after app relaunch. Resets QA preference.
- **Offline playback:** real Capacitor FileTransfer downloads audio, checks nonempty
  saved bytes, drops the actual network, plays the on-device downloaded file and
  requires advancing audio and a successful history write after connectivity returns.
- **Hebrew interface:** real language button, actual HTML dir=rtl, visible Hebrew nav,
  viewport containment, successful Hebrew navigation, returning to English.
- **Cross-device account sync:** new, independently installed iPhone simulator logs
  in with the QA account and writes Like, speaker Follow and a run-unique playlist.
  Independently booted iPad signs into the same account and checks server-loaded state.
  This is sequential independent-device sync, not simultaneous real-time live updates.
- **Long-session reliability:** three minutes of repeated video observations, device
  lock/unlock and three real video ↔ audio switches; real clocks and single ownership.
- **Login edge cases:** real wrong-password response, successful retry, saving and
  restoring a temporarily edited QA account name, process relaunch, real server-side
  session revocation, 401 recovery, logout and re-login. Revocation is not a
  wall-clock token-TTL expiry; it exercises the same invalid-session recovery path.

## Safety

Use a verified non-admin **dedicated QA account**. All credentials are private Actions
secrets. The UI test types through the native keyboard; no credentials are hardcoded.
The cross-device test leaves Like, Follow and its run-unique QA playlist enabled on the
QA account for inspection. Profile rename tests restore the original name on success.
Do not run against an ordinary user's account.

A simulator build only is instrumented: `observer.js` reads the real app/DOM and
server operations; it does not supply fabricated API or media results.
The additional debug-only QA revocation button makes a **real /logout request**
without removing the local token, specifically to test server invalidation recovery.
These probes and controls never go into App Store release builds.

The PF gate modifies network filter rules **only on the disposable macOS runner**.
`DOWN` fails if root PF commands fail. The live-API reachability probe must
independently show actual failure; no test relies on status-bar Wi-Fi artwork.
The gate reverts automatically after 75 seconds, on explicit UP, signal or shutdown.
The runner additionally restores the configuration in an `always()` job step.

## Running and interpreting

The `iOS Extended Regression Tests` workflow has an iPhone and iPad device
matrix (serialized because both use one QA account), then a separate cross-device
iPhone writer / iPad reader job. All XCTest checks use
`-only-testing` without suppressing failures. A failing API response, lack of
moving decoded frames, unsupported PiP, missing notification or absent simulator
network capability **fails** its check.

Native tests can validate APIs, controls and clocks, but simulator output cannot
prove speakers are audible, headphone/Bluetooth routes behave correctly, or
Apple production APNs delivered a notification. Those require physical-device
manual testing in addition to this suite.

Artifacts are limited to Xcode result summaries and logs, excluding token-bearing
simulator app containers and QA account credentials.