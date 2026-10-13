# iOS unified AVPlayer pilot (draft, off by default)

## What exists today

Production iOS playback uses a direct HTML5 HLS/MP4 player in WKWebView with Vimeo fallback. HTML audio is a separate owner in Audio mode. IrgunBackgroundAudioPlugin.swift already starts its own native AVPlayer for Home/background audio. This is **not** a single-owner playback system.

## Experimental design

- The draft adds \`IrgunUnifiedPlayerPlugin\`: one native \`AVPlayer\` and one \`AVPlayerViewController\`.
- \`open\` creates an AVPlayerItem from one HTTPS Irgun HLS/MP4 URL. Reopening the same lecture uses the same player item.
- \`setMode('audio'|'video')\` changes the visual presentation only; it never changes the URL, calls \`replaceCurrentItem\`, or seeks.
- \`setLayout\` repositions the same native player view for inline/mini/large presentation.
- \`play\`, \`pause\`, \`seek\`, \`setRate\`, \`getState\`, \`stop\` operate on that one player.
- AVKit provides native full-screen and PiP controls. The playback audio session has the \`.playback\` category and the existing app target already enables the \`audio\` background mode.
- The pilot JavaScript first releases the legacy video/audio owners before opening the native item. On test failure, it restores the original player instead of pretending the transition worked.

## Opt in ONLY on a disposable simulator / developer build

Nothing calls the pilot in normal sessions. To test using Safari Web Inspector, on a developer device/simulator:

1. Execute \`localStorage.setItem('istNativeAvPlayerPilotV1', '1'); location.reload();\`
2. Open a normal video shiur which has a direct HLS source.
3. Execute \`await window.ISTNativePlayerPilot.openCurrent()\` to transfer from the WebView player.
4. Test \`await window.ISTNativePlayerPilot.mode('audio')\`, then \`mode('video')\`. Check \`snapshot()\` before and after; item ID, position and playback rate must remain consistent.
5. Test \`seek(120)\`, \`rate(1.5)\`, \`layout('mini', {x:180,y:550,width:170,height:100})\`, \`layout('inline', {x:0,y:140,width:390,height:220})\`.
6. Test the system PiP/fullscreen buttons, press Home, reopen, and use Control Centre/media controls. Repeat at 1× and 1.5×.
7. Execute \`await window.ISTNativePlayerPilot.stop()\` to release AVPlayer and restore the legacy playback screen.
8. Remove the flag with \`localStorage.removeItem('istNativeAvPlayerPilotV1'); location.reload();\` when finished.

For a reproducible QA run, use a fixture whose \`/media/{id}/source.json\` advertises a master HLS URL containing **both video and playable audio**. Verify actual player time advancement, muted/unmuted behavior and cellular network data before declaring success. Never assume an MP4 or MP3 is the same media clock. The default app will not switch to native playback.

## Automated checks

- \`node --test scripts/test_ios_native_player_pilot.mjs\` verifies the opt-in gate, once-only open, same-item mode switches, seek/speed, safe failure behavior and no duplicate open.
- iPhone and iPad simulator workflows must compile the Swift plugin, install the app and pass existing playback/account tests.
- Follow with real native simulator tests validating new PiP, Home, mini/full and audio/video transitions. **This draft does not yet claim those behavioral checks pass.**

## Constraints before production migration

- Native view positioning relative to WKWebView scroll, PiP return and iPhone/iPad orientations needs stress testing.
- The pilot does not yet use AVAssetDownloadURLSession, nor does it convert the regular app's Audio UI to use native state.
- Audio-only presentation with the same HLS asset **does not guarantee audio-only bandwidth**.
- Resolve stream authorization, mixed Vimeo/Drive media availability, remote command arbitration and locked-device restoration.
- Keep this PR separate from PR #27 (iOS Reader App / In-App Purchase changes).
- No changes to the Android repository. No merge into main until true end-to-end playback is demonstrated.
