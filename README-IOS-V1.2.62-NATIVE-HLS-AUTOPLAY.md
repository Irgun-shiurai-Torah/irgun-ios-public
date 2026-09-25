# Irgun iOS V1.2.62 — Stable Native HLS + Playing Audio-to-Video Handoff

- iOS/Capacitor now prefers Apple's native HLS engine for valid `.m3u8` video.
- HLS.js remains available when native HLS is unavailable.
- Runtime HLS failures are retried twice at the current timestamp before MP4/Vimeo fallback.
- Initial direct-player startup is retried once from a fresh player before Vimeo fallback.
- Audio -> Video passes autoplay into the first direct-player load, seeks to the captured audio timestamp, and verifies that video is actually playing.
- If the first visible-video start resolves but remains paused, the app makes one explicit play retry.
- Existing Video -> Home/background Audio handoff is unchanged.
- Android, website, and Worker are unchanged by this commit.
