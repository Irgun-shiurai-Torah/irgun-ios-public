# Irgun iOS V1.2.58 — Visible Video Autostart + Background Video-to-Audio

## Visible Video automatic start
Real-device report from build 114 showed the media clock/audio advancing while the visible video picture stayed frozen until Play was tapped.

V1.2.58:
- makes iOS inline-video attributes explicit;
- forces the direct video element into its visible compositor layer before and after play();
- verifies an actual rendered video frame with requestVideoFrameCallback when available;
- if the clock is playing but no frame is rendered, automatically performs one internal pause/repaint/resume cycle at the same timestamp;
- no user Play tap should be required.

## Background video -> audio
When a playing video leaves the foreground (Home, app switch, screen lock/background):
- capture the current video clock;
- do not interfere with active system PiP;
- pause/destroy the visual video player;
- switch the watch page to Audio mode;
- start the dedicated audio stream at the same timestamp;
- keep background audio running under the existing iOS Background Audio capability.

Both native AppDelegate background lifecycle events and document visibility/pagehide are used, with a duplicate-handoff guard.

Force-quitting/swiping the app away is intentionally not treated as background playback because iOS terminates the app.
