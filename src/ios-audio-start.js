// Prefer the same owned video sources that already work in native Video -> Audio.
// Canonical video IDs precede legacy IST aliases on the MP3 fallback path.
export function iosDirectAudioCandidates(item, ownedSources = null, audioUrlForId = null) {
  const urls = [];
  const seen = new Set();
  const add = value => {
    const url = String(value || '').trim();
    if (!url || seen.has(url) || !/^(https:\/\/|file:\/\/)/i.test(url)) return;
    seen.add(url); urls.push(url);
  };
  if (item?.offline) add(item.url);
  if (item?.kind === 'video-audio') {
    add(ownedSources?.hls);
    add(ownedSources?.mp4);
    if (typeof audioUrlForId === 'function' && item.id) add(audioUrlForId(item.id));
  }
  add(item?.networkUrl);
  add(item?.url);
  return urls;
}

export async function openFirstPlayableIosAudio(urls, open, isCurrent = () => true, onFallback = () => {}) {
  if (!Array.isArray(urls) || !urls.length) throw new Error('No native audio stream is available');
  let lastError = null;
  for (let i = 0; i < urls.length; i += 1) {
    if (!isCurrent()) throw new Error('Native audio request was superseded');
    try {
      const snapshot = await open(urls[i]);
      if (!isCurrent()) throw new Error('Native audio request was superseded');
      return {url:urls[i],snapshot};
    } catch (error) {
      if (!isCurrent()) throw new Error('Native audio request was superseded');
      lastError = error;
      if (i < urls.length - 1) onFallback(error, urls[i]);
    }
  }
  throw lastError || new Error('All native audio sources failed');
}
