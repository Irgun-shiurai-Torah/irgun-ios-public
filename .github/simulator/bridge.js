// Appended to main.js ONLY in the unsigned simulator workflow.
// This exposes observations, not replacement playback behavior.
const simulatorSampleId = __SIMULATOR_VIDEO_ID__;
let simulatorError = '';
let simulatorOpening = false;
let simulatorFrameVideo = null;
let simulatorFrames = 0;
let simulatorFrameTime = 0;
window.addEventListener('error', event => { simulatorError = String(event.message || 'JavaScript error'); });
window.addEventListener('unhandledrejection', event => { simulatorError = String(event.reason?.message || event.reason); });

function simulatorVisible(element) {
  if (!element) return false;
  const box = element.getBoundingClientRect();
  if (box.width <= 0 || box.height <= 0 || box.bottom <= 0 || box.right <= 0 ||
      box.top >= innerHeight || box.left >= innerWidth) return false;
  for (let node = element; node instanceof Element; node = node.parentElement) {
    const css = getComputedStyle(node);
    if (node.hidden || css.display === 'none' || css.visibility === 'hidden' || Number(css.opacity) < .01) return false;
  }
  return true;
}

window.ISTSimulator = {
  reopenCurrent() {
    if (!state.watchVideo) return;
    openPushDestination(`/watch.html?v=${encodeURIComponent(videoId(state.watchVideo))}`);
  },
  async openSample() {
    if (simulatorOpening) return;
    simulatorOpening = true;
    simulatorError = '';
    try {
      const candidates = simulatorSampleId
        ? [state.videoById.get(String(simulatorSampleId))].filter(Boolean)
        : state.videos.filter(video => video.hasAudio).slice(0, 12);
      if (!candidates.length) throw new Error('No sample available in the loaded library');
      for (const video of candidates) {
        const sources = await loadIosDirectVideoSources(video);
        if (!sources?.hls || !video.hasAudio) continue;
        await openWatch(videoId(video), 30);
        return;
      }
      throw new Error('No HLS video with audio found; supply video_id when running the workflow');
    } catch (error) {
      simulatorError = String(error.message || error);
    } finally {
      simulatorOpening = false;
    }
  },
  snapshot() {
    const video = state.watchVimeo?.video;
    const expand = [...document.querySelectorAll('[data-expand-watch]')].find(simulatorVisible);
    const expandBox = expand?.getBoundingClientRect();
    if (video !== simulatorFrameVideo) {
      simulatorFrameVideo = video;
      simulatorFrames = 0;
      simulatorFrameTime = 0;
      if (video?.requestVideoFrameCallback) {
        const track = (_now, metadata) => {
          if (simulatorFrameVideo !== video) return;
          simulatorFrames += 1;
          simulatorFrameTime = Number(metadata.mediaTime) || 0;
          video.requestVideoFrameCallback(track);
        };
        video.requestVideoFrameCallback(track);
      }
    }
    return JSON.stringify({
      libraryReady: Boolean(state.libraryReady), libraryCount: state.videos.length,
      opening: simulatorOpening, error: simulatorError,
      id: state.watchVideo ? String(videoId(state.watchVideo)) : '',
      mode: state.watchMode, ready: Boolean(state.watchVimeoReady),
      backend: state.watchVimeo?.player?.backend || '',
      playerCount: document.querySelectorAll('#directVideoElement').length,
      initializing: Boolean(state.watchVimeoInitialization),
      videoTime: Number(video?.currentTime) || 0, videoPlaying: Boolean(video && !video.paused && !video.ended),
      videoVisible: simulatorVisible(video), controlsVisible: simulatorVisible(document.getElementById('dmPlay')),
      frameApi: Boolean(video?.requestVideoFrameCallback), frames: simulatorFrames, frameTime: simulatorFrameTime,
      audioTime: Number(audio.currentTime) || 0, audioPlaying: Boolean(!audio.paused && !audio.ended),
      pendingSeek: Boolean(state.pendingAudioSeek), minimized: Boolean(state.watchMinimized),
      expandX: expandBox ? expandBox.left + expandBox.width / 2 : 0,
      expandY: expandBox ? expandBox.top + expandBox.height / 2 : 0,
      pip: Boolean(state.watchPictureInPicture || video?.webkitPresentationMode === 'picture-in-picture'),
      pipSupported: Boolean(video && ((document.pictureInPictureEnabled && video.requestPictureInPicture) ||
        video.webkitSupportsPresentationMode?.('picture-in-picture'))),
      speed: Number(video?.playbackRate || audio.playbackRate), hidden: document.hidden
    });
  }
};
