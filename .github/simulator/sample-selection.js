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

// The account regression suite must keep the same real backed-up lecture
// across relaunches. Missing or unusable fixtures are a test failure, not a
// reason to silently pick the newest (possibly Vimeo-only) catalog entry.
export const IOS_ACCOUNT_SAMPLE_IDS = Object.freeze(['1235946832', '1235511026']);

export function selectIosAccountFixture(elements, videosById, savedId = '') {
  const eligible = (elements || []).filter(element => {
    const lecture = videosById?.get(String(element.dataset.watch || ''));
    return lecture?.hasAudio === true && (lecture._speakerIds || []).length > 0;
  });
  for (const id of [savedId, ...IOS_ACCOUNT_SAMPLE_IDS]) {
    if (!IOS_ACCOUNT_SAMPLE_IDS.includes(String(id))) continue;
    const found = eligible.find(element => String(element.dataset.watch || '') === id);
    if (found) return found;
  }
  return null;
}
