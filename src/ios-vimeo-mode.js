// Independent iOS Vimeo-only routing. Website and Android are not coupled to
// this setting. Only recordings without a Drive copy are affected.
export const IOS_VIMEO_MODE_STORAGE_KEY = 'istIosVimeoOnlyMode';

export function normalizeIosVimeoMode(settings, fallback = 'vimeo') {
  const candidate = typeof settings === 'string' ? settings : settings?.vimeoOnlyIosMode;
  if (candidate === 'off' || candidate === 'vimeo' || candidate === 'our-player') return candidate;
  if (settings && typeof settings === 'object' && settings.showVimeoOnlyIos === false) return 'off';
  return ['off','vimeo','our-player'].includes(fallback) ? fallback : 'vimeo';
}

export function isIosVimeoOnlyLecture(video) {
  if (!video || typeof video !== 'object') return false;
  return video.hasDriveVideo === false && video.sourceType !== 'drive-library'
    && video.sourceType !== 'city-drive' && !video.directVideo;
}

export function visibleIosLectureCatalog(videos, mode) {
  if (!Array.isArray(videos)) return [];
  return mode === 'off' ? videos.filter(video => !isIosVimeoOnlyLecture(video)) : videos;
}

export function iosVimeoWatchEngine(video, mode, nativeAvailable) {
  if (!isIosVimeoOnlyLecture(video)) return nativeAvailable ? 'native' : 'legacy';
  const normalized = normalizeIosVimeoMode(mode);
  if (normalized === 'off') return 'hidden';
  if (normalized === 'vimeo') return 'vimeo';
  return nativeAvailable ? 'native' : 'legacy-direct';
}

export function iosVideoDescriptorPath(id) {
  return '/media/' + encodeURIComponent(String(id || '')) + '/source.json?client=ios';
}

export const IOS_VIDEO_CATALOG_PATH = '/video-map?driveLibrary=1&client=ios';
