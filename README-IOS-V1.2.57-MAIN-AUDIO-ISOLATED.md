# Irgun iOS V1.2.57 — Main Audio Fix Isolated From Watch Audio

V1.2.56 introduced the immediate Main Audio Player -> Video ownership fence.
Before shipping it, V1.2.57 narrows that change so the already-working Watch Audio Player path is not modified by the Main Audio shutdown.

## Main Audio Player -> Video
- Capture timestamp/history.
- Mark Video as owner synchronously on the Watch tap.
- Destroy Main Audio immediately before navigation/fetch.
- Block delayed play, Media Session play, and audio error/offline recovery while Video owns playback.

## Watch Audio Player -> Video
- Continues through switchWatchMode('video') exactly as before.
- Its timestamp is captured before its own audio engine is released.
- No Main Audio pre-shutdown is applied to this path.

Expected: the Main Audio Player stops the instant Watch is tapped, while the Watch Audio Player behavior that was already working remains unchanged.
