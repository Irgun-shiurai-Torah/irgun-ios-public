// Probe test samples using their real playlists and first media segment. A URL
// merely appearing in the catalog does not prove its backup finished copying.
export async function simulatorHlsSourceReady(url, request = fetch, depth = 0) {
  if (!url || depth > 3) return false;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 7000);
  try {
    const response = await request(url, {signal:controller.signal, headers:{Range:'bytes=0-8191'}});
    if (!response.ok) return false;
    const type = response.headers.get('content-type') || '';
    if (/\.m3u8(?:\?|$)/i.test(url) || /mpegurl/i.test(type)) {
      const text = await response.text();
      if (!text.trimStart().startsWith('#EXTM3U')) return false;
      const child = text.split(/\r?\n/).map(line=>line.trim()).find(line=>line && !line.startsWith('#'));
      return child ? await simulatorHlsSourceReady(new URL(child,url).href, request, depth+1) : false;
    }
    if (/html|json|text\//i.test(type)) return false;
    const reader = response.body?.getReader?.();
    if (!reader) return false;
    const first = await reader.read();
    await reader.cancel();
    return Boolean(first.value?.length);
  } catch (_) { return false; }
  finally { clearTimeout(timer); }
}

// A real catalog card, with audio and an associated speaker, must be chosen
// for account playback tests. Keep the same selected lecture across restarts.
// The historic fixtures still have priority if displayed; a current backed-up
// lecture is a valid fallback when those older IDs are no longer on the first
// page. NEVER substitute a different ID once one has actually been selected.
export const IOS_ACCOUNT_SAMPLE_IDS = Object.freeze(['1235946832', '1235511026']);

export function selectIosAccountFixture(elements, videosById, savedId = '') {
  const eligible = (elements || []).filter(element => {
    const lecture = videosById?.get(String(element?.dataset?.watch || ''));
    return lecture?.hasAudio === true && (lecture._speakerIds || []).length > 0;
  });
  const bestTitle = id => eligible.find(element =>
    String(element.dataset.watch || '') === id &&
    element.classList?.contains('media-title')) ||
    eligible.find(element => String(element.dataset.watch || '') === id) || null;

  if (savedId) return bestTitle(String(savedId));
  for (const id of IOS_ACCOUNT_SAMPLE_IDS) {
    const found = bestTitle(id);
    if (found) return found;
  }
  // Only choose an actual Drive-backed video/audio shiur. Selecting an
  // arbitrary recent Vimeo-only recording would make the test dependent on
  // Vimeo privacy settings, rather than verifying account and history state.
  const backed = eligible.filter(element => {
    const lecture = videosById?.get(String(element.dataset.watch || ''));
    return lecture?.hasDriveVideo === true || lecture?.directVideo === true ||
      ['drive-library','city-drive'].includes(lecture?.sourceType);
  });
  return backed.find(element => element.classList?.contains('media-title')) ||
    backed[0] || null;
}
