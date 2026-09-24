# Irgun iOS V1.2.54 — PiP + Single-Owner Switching + White Bar Cleanup

Built on V1.2.53.

## Real-device fixes

### Picture in Picture
- Starts/resumes the video synchronously from the PiP tap before requesting PiP.
- Prefers iOS WebKit presentation-mode PiP with the standards API as fallback.
- When PiP enters, the full watch UI moves off-screen while the same video element stays alive for system PiP.
- The large in-app player therefore no longer remains visibly playing behind the floating PiP window.
- PiP exit restores the full watch UI.

### Audio -> Video
- V1.2.53 already releases the audio engine before creating video.
- WKWebView now allows the user-initiated async handoff to resume playback after HLS discovery without a second tap.

### White title/speaker/X/play bar
- The bar was the watch-host-mini-chrome embedded in watchHtml().
- It is now globally hidden and shown only in the intentional mini-video host.
- Starting audio clears stale persistent watch DOM synchronously.
- The old watch-audio-parked path is disabled so Audio never keeps a hidden video player.
- The global audio mini-player is suppressed when the watch page already owns the same lecture in Audio mode.

## Preserved
- HLS -> MP4 -> Vimeo fallback.
- In-app mini video while staying in Video mode.
- Background audio while staying in Audio mode.
- History/resume timestamps.
- App Store-compliant external donation flow.
- StoreKit paid shiurim.
