# Irgun iOS V1.2.55 — Hard Audio Ownership Fence

Real-device build 111 still allowed audio to remain audible after Audio -> Video.

## Root causes addressed
- The old release function only removed the audio source when JavaScript state still matched a specific video-audio item.
- A stale/pending HTMLMediaElement play request or iOS Media Session action could therefore outlive the mode switch.
- Video initialization also called syncNativeMediaSession(), but the public iOS repository had no implementation of that function, allowing initialization to abort partway through after player startup.

## V1.2.55
- Video ownership hard-stops HTML audio unconditionally: pause, mute, volume 0, clear src, reload element, clear current item.
- Old audio Media Session action handlers are removed before Video starts.
- Any delayed audio 'play' event while Video mode owns playback is immediately killed.
- The same hard fence runs at Audio -> Video switch, openWatch from Audio, video initialization, and the video 'play' event.
- Starting Audio explicitly restores mute=false and volume=1.
- Adds a safe public-iOS syncNativeMediaSession() implementation using navigator.mediaSession only; it never starts audio.

Expected behavior: after switching Audio -> Video, there is physically no HTML audio source left to continue playing.
