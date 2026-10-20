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
  and moving decoded frames. Unsupported simulator PiP is an explicit XCTest skip, **not** proof that PiP works. Physical iPhone/iPad PiP verification is required.
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

## Integration staging after PR #45

This single draft PR combines PR #25's authenticated comments, edit/delete, profile-name
persistence and video/audio handoff scenario with PR #26's comprehensive iOS
regression suite. The separate account scenario is loaded from
`.github/regression/account-regressions.swift` alongside the 11 extended scenarios.

PR #45 and PR #47 have merged into main. The extended suite is now eligible to run against the current native player.
The workflow is normally manual-only. A **temporary branch-scoped `push` trigger** runs this staging suite after the PR #47 merge; remove it before PR #46 merges. The branch was refreshed with the merged main playback sources before running
both iPhone and iPad simulator regressions. Leave the draft PR unmerged until the new run is genuinely green.

All old `src/main.js`, `src/direct-media.js`, style and native player changes
from PRs #25/#26 were deliberately excluded. They would overwrite modern
app logic. If tests reveal functional bugs, prepare focused fixes independently.

**Previously known old-branch failures requiring investigation after PR #45:**
simulator PiP unsupported, pause after simulated notification reopening,
edited QA profile name not reflected, and intermittent playback/double-tap.
Do not hide, suppress, or mark these assertions successful. PiP, genuine APNs,
audio audibility and network hardware must also receive physical-device checks.

The suite uses only a dedicated non-admin QA account through Actions secrets;
comment markers are run-specific, and report artifacts must remain credential-free.


## Latest PR46 staging notes

The first iPhone run exposed a native AVPlayer observation mismatch, asynchronous session-restoration race, and tests expecting controls to remain visible after their intended auto-hide timeout. The test harness has been corrected for these cases and now includes a simulator-only notification-permission control.

PR #47 has merged after all four automated CI workflows passed. PR #46 remains a draft while its extended simulator tests run. Physical-device PiP verification is still required.
