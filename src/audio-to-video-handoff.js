// Snapshot the *real* playback clock before a Full Audio -> Watch Video handoff.
// iOS uses AVPlayer, so the hidden HTMLAudioElement is normally parked at 0:00.
export function fullAudioToVideoHandoff({
  videoId, useNative, nativeState, htmlPosition = 0, htmlPaused = true, pendingHtmlSeek = null
}) {
  const id = String(videoId || '').trim();
  if (!id) throw new Error('Cannot hand off audio without a lecture ID');
  const clampPosition = raw => {
    const value = Number(raw);
    return Number.isFinite(value) ? Math.max(0, value) : 0;
  };
  if (useNative) {
    // Never copy time from an unrelated/stale AVPlayerItem.
    const expected = `audio:video-audio:${id}`;
    if (!nativeState?.active || nativeState.mode !== 'audio' ||
        String(nativeState.id || '') !== expected) {
      throw new Error('Native audio changed while opening video');
    }
    return {
      position: clampPosition(nativeState.position),
      wasPlaying: nativeState.playing === true
    };
  }
  const seek = Number(pendingHtmlSeek);
  const pending = pendingHtmlSeek != null && Number.isFinite(seek) && seek >= 0;
  return {
    position: pending ? clampPosition(seek) : clampPosition(htmlPosition),
    wasPlaying: htmlPaused === false
  };
}
