# Irgun iOS V1.2.61 — Default Video Speed 1x

This is a focused playback-control correction on top of V1.2.60.

- Direct HLS/MP4 video now opens with the speed selector explicitly on **1x**.
- The HTML video element is explicitly initialized with defaultPlaybackRate=1 and playbackRate=1.
- 0.75x remains available when the listener chooses it.
- Existing Audio -> Video autoplay and Video -> Home/background Audio handoff behavior is unchanged.
- Audio playback-speed preference behavior is unchanged.
