# Irgun iOS V1.2.59 — Instant Video + Home Background Audio

This update is intentionally limited to the two real-device playback issues reported on V1.2.58.

## Audio -> Video: no Play tap
- Watch Audio -> Video and Main Audio -> Video now explicitly request a one-time iOS video-layer relatch.
- The direct HLS/MP4 player forces WKWebView back to inline presentation, rebuilds the visible compositor layer for one frame, nudges the timestamp by only 0.02 seconds, and resumes automatically.
- It verifies frame progress when WebKit exposes requestVideoFrameCallback / decoded-frame information.
- Normal video starts keep the existing behavior; the stronger relatch is targeted at Audio -> Video handoff.

## Home/background during Video -> Audio
- Native applicationWillResignActive now notifies the WebView before applicationDidEnterBackground, giving the handoff time before iOS suspends WebKit.
- The handoff checks the real HTMLVideoElement/player instead of relying only on watchVideoPlaying.
- The outgoing video is muted first, then the dedicated audio play request is issued at the same timestamp before the video DOM/player is destroyed.
- The watch page is left in Audio mode, so returning to the app matches what is actually playing.
- Existing Audio -> Home background playback is unchanged.
- Active system Picture in Picture is still excluded from this conversion.

No Android, website, Worker, paid-audio, schedule, authentication, or donation behavior is changed.
