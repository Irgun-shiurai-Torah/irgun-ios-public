# iOS simulator playback and App Store screenshots

The iOS Simulator Playback Tests workflow builds the actual application in
unsigned disposable iPhone Pro Max and 13-inch iPad Pro simulators. It runs on
relevant pull requests and main pushes; Run workflow can select a specific
HLS/audio shiur. All library/media content comes from the live public API.

Eleven UI tests check initial advancing video frames, Audio/Video clock handoff,
Home/reopen with native AVPlayer clock samples collected while UIApplication is
backgrounded, paused Home, fullscreen exit in playing/paused states, double-tap
15-second seeking, playing/paused swipe-down mini, mini expansion, same-shiur
links, PiP return, and clean screenshots. PiP skips only when unsupported.

Twenty-six clean screenshots cover all public top-level pages, location/speaker
filters, guest library tabs, registration, video, audio, audio player, mini and
fullscreen. Diagnostic UI is hidden for each capture. PNGs are exported without
cropping, overlays, synthetic account data or resizing; five smaller downloadable
artifacts per device contain the original screenshots. Signed-in account pages
and admin tools require a separate authenticated session and are not fabricated.

The full simulator artifact includes xcresult, logs, screenshots and observations.
State is read through a simulator-only loopback TCP channel; real UI actions
still use XCTest taps and swipes. This avoids intermittent stale accessibility
snapshots of the diagnostic label. The listener binds only to 127.0.0.1.
Release builds do not inject the simulator bridge or diagnostic panel. Native
background clock samples establish AVPlayer progress in simulator suspension;
they do not measure audible output on physical devices. Real push delivery,
offline downloads, purchases, login, older iPadOS runtimes and physical audio
route/interruption behavior still require their own tests.
