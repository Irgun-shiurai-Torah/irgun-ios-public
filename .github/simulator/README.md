# iOS simulator playback tests

The **iOS Simulator Playback Tests** Actions workflow runs unsigned, disposable
builds on one installed iPhone and one installed iPad simulator. It runs after
relevant pushes and pull requests, and can also be started with **Run workflow**.
Optionally supply a shiur `video_id` that has both HLS video and audio; otherwise
the test chooses an HLS-ready shiur from the first twelve audio-enabled library
entries. Network/library failures fail the tests and are recorded in diagnostics.

The five UI tests check fresh moving video frames, Audio/Video position, Home and
reopen, mini-player expansion, and PiP return. PiP is reported as skipped when
the simulator runtime declares that it is unsupported. A test failure may be a
playback regression, API/media outage, or simulator limitation; inspect the
attachments and logs before attributing it to a particular cause.

Each job saves an artifact with screenshots, playback observations as JSON,
the `.xcresult` bundle, exported attachments, Xcode output, and simulator logs.
The original app's playback functions and buttons are used; the test bridge
only selects a sample and observes the player. The diagnostic panel appears
only in these test builds. The release workflow never invokes these injectors.

This setup exercises native WKWebView playback, but it does not establish audio
output throughout real-device suspension or test notification delivery, login,
offline downloads, App Store purchases, or iPadOS 15 compatibility. Those need
additional tests on the relevant devices/runtime.
