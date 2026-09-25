# Irgun iOS V1.2.56 — Main Audio Player -> Video Immediate Takeover

Real-device report after build 112:
- Watch Audio Player switching is working.
- Main Audio Player -> Watch opens the video page, but Main Audio can continue until Video Play is pressed.

## Fix
- The Watch button now transfers playback ownership to Video synchronously in the click handler, before render/navigation/fetch.
- Main Audio history is captured first, then the HTML audio element is destroyed immediately.
- A new videoOwnsPlayback fence blocks delayed HTML audio play events and Media Session play commands during the entire video transition and while Video mode owns playback.
- Audio error/offline recovery is blocked during video ownership so clearing the source cannot accidentally restart streaming.
- hardStopHtmlAudioForVideo now clears state.current before media mutations and uses removeAttribute('src') + load() without assigning src='', avoiding WebKit recovery races.
- Starting Audio explicitly releases Video ownership and restores preload/volume/mute.
- Closing Video releases Video ownership.

Expected behavior:
Tap Watch in the Main Audio Player -> audio stops immediately, the video page opens at the same timestamp, and audio cannot resume underneath even if the video is still paused/loading.
