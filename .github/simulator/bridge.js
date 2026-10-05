// Appended to main.js ONLY in the unsigned simulator workflow.
// This exposes observations, not replacement playback behavior.
const simulatorSampleId = __SIMULATOR_VIDEO_ID__;
let simulatorError = '';
let simulatorOpening = false;
let simulatorFrameVideo = null;
let simulatorFrames = 0;
let simulatorFrameTime = 0;
let simulatorLastFrameAt = 0;
let simulatorFrameRequest = 0;
const simulatorGestures = [];
const simulatorWarnings = [];
const simulatorOriginalWarn = console.warn.bind(console);
console.warn = (...args) => {
  if (/video|HLS|decoder|native background|Vimeo/i.test(String(args[0]||''))) {
    simulatorWarnings.push({at:Date.now(),message:String(args[0]||''),error:args.find(x=>x instanceof Error)?.message||''});
    if(simulatorWarnings.length>12)simulatorWarnings.shift();
  }
  simulatorOriginalWarn(...args);
};
for (const type of ['pointerdown','pointerup','pointercancel','touchstart','touchend','touchcancel']) {
  document.addEventListener(type,event=>{
    if(!event.target?.closest('#directMediaPlayer'))return;
    const point=event.changedTouches?.[0]||event;
    simulatorGestures.push({type,at:Date.now(),x:point.clientX,y:point.clientY,target:event.target.id});
    if(simulatorGestures.length>20)simulatorGestures.shift();
  },{capture:true,passive:true});
}
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
  storePage: '', storeReady: false, storeError: '', storeIndex: -1, selectedSampleId: '',
  storePages: ['home','shiurim','filter-location','filter-speaker','live','live-boro','live-flatbush','schedule','paid','donate','contact','account','register','library-likes','library-later','library-history','library-playlists','library-downloads','library-purchased','library-following','privacy','watch-video','watch-audio','audio-player','mini-player','fullscreen'],
  async nextStorePage() {
    this.storeReady = false; this.storeError = '';
    const page = this.storePages[++this.storeIndex];
    if (!page) { this.storePage = 'done'; this.storeReady = true; return; }
    const mediaPage = name => name.startsWith('watch-') || ['audio-player','mini-player','fullscreen'].includes(name);
    const reuseMedia = mediaPage(page) && mediaPage(this.storePage) && Boolean(state.watchVideo);
    this.storePage = page;
    try {
      if (state.watchVideo && !reuseMedia) await closeWatch(false);
      if (!reuseMedia) { audio.pause(); state.current = null; }
      state.playerOpen = false; state.filterDialog = ''; state.authMode = 'login';
      if (mediaPage(page)) {
        if (!state.watchVideo) {
          await this.openSample();
          if (simulatorError) throw new Error(simulatorError);
        }
        const mode = page === 'watch-audio' || page === 'audio-player' ? 'audio' : 'video';
        if (state.watchMode !== mode) await switchWatchMode(mode);
        await new Promise((resolve,reject) => {
          const start = Date.now(), check = () => {
            if (mode === 'audio' ? (state.current && audio.readyState >= 2 && !state.pendingAudioSeek) : (state.watchVimeoReady && state.watchVimeo?.video?.readyState >= 2)) resolve();
            else if (Date.now()-start>90000) reject(new Error('Screenshot video did not become ready'));
            else setTimeout(check,250);
          }; check();
        });
        if (page === 'audio-player') { state.screen='home'; state.playerOpen = true; render(); }
        else if (page === 'mini-player') { state.screen='home'; render(); await minimizeWatchToPersistent(); }
        else if (page === 'fullscreen') { if (state.watchMinimized) await expandPersistentWatch(); document.getElementById('dmFull')?.click(); }
      } else {
        state.screen = page.startsWith('library-') ? 'library' : page.startsWith('filter-') ? 'shiurim' : page === 'register' ? 'account' : page;
        if (page.startsWith('library-')) state.librarySection = page.slice(8);
        if (page === 'register') state.authMode = 'register';
        render(); window.scrollTo(0,0);
        if (page.startsWith('filter-')) document.querySelector(`[data-open-filter="${page.slice(7)}"]`)?.click();
      }
      // Real API content and decoded images only; no invented account/history.
      await new Promise(resolve=>setTimeout(resolve,3000));
      if (page.startsWith('library-')) document.querySelector('.library-tabs .active')?.scrollIntoView({block:'nearest',inline:'center'});
      if (['home','live','live-boro','live-flatbush','schedule'].includes(page)) {
        const start=Date.now();
        while (state.scheduleDataLoading && Date.now()-start<15000) await new Promise(resolve=>setTimeout(resolve,250));
      }
      // decode() can stay pending when a reactive render replaces an image.
      // Bound observation so one image cannot stop every remaining capture.
      await Promise.race([
        Promise.allSettled([...document.images].filter(simulatorVisible).map(image=>image.decode?.())),
        new Promise(resolve=>setTimeout(resolve,8000))
      ]);
      if (['watch-video','fullscreen'].includes(page)) {
        await new Promise((resolve,reject)=>{
          const start=Date.now(),check=()=>{
            this.snapshot();
            const player=state.watchVimeo?.player;
            if(simulatorFrames>0&&simulatorVisible(player?.v)&&!player?.loading&&player?.load?.hidden!==false)resolve();
            else if(Date.now()-start>30000)reject(new Error('Screenshot video has no presented frame or is still loading'));
            else setTimeout(check,250);
          };check();
        });
      }
      this.storeReady = true;
    } catch(error) { this.storeError=String(error.message||error); }
  },
  reopenCurrent() {
    if (!state.watchVideo) return;
    openPushDestination(`/watch.html?v=${encodeURIComponent(videoId(state.watchVideo))}`);
  },
  async openSample() {
    if (simulatorOpening) return;
    simulatorOpening = true;
    simulatorError = '';
    try {
      const selected = simulatorSampleId || this.selectedSampleId;
      const candidates = selected
        ? [state.videoById.get(String(selected))].filter(Boolean)
        : state.videos.filter(video => video.hasAudio).slice(0, 12);
      if (!candidates.length) throw new Error('No sample available in the loaded library');
      for (const video of candidates) {
        let sources;
        for (let attempt=0;attempt<3;attempt++) {
          sources = await loadIosDirectVideoSources(video);
          if (sources?.hls) break;
          if (attempt<2) await new Promise(resolve=>setTimeout(resolve,1500));
        }
        if (!sources?.hls || !video.hasAudio) continue;
        this.selectedSampleId = String(videoId(video));
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
    const videoBox = video?.getBoundingClientRect();
    const expand = [...document.querySelectorAll('[data-expand-watch]')].find(simulatorVisible);
    const expandBox = expand?.getBoundingClientRect();
    const contentBox = document.querySelector('.content')?.getBoundingClientRect();
    let tabSwipeY = 0;
    // Pick a real content row after layout; refuse header, input and carousel hits.
    for (let y = Math.max(180, contentBox?.top + 24 || 180); y < innerHeight - 140; y += 20) {
      const safe = [.2,.8].every(x => {
        const hit = document.elementFromPoint(innerWidth*x,y);
        if (!hit?.closest('.content') || hit.closest('input,textarea,select,button,video,iframe,[role="dialog"]')) return false;
        for(let node=hit;node && node.closest('.content');node=node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowX) && node.scrollWidth>node.clientWidth+2) return false;
        }
        return true;
      });
      if(safe){tabSwipeY=y;break;}
    }
    const playerButtons = Object.fromEntries(['dmPlay','dmFull'].map(id => {
      const el=document.getElementById(id), b=el?.getBoundingClientRect();
      const x=b?b.left+b.width/2:0,y=b?b.top+b.height/2:0;
      return [id,{label:el?.getAttribute('aria-label')||'',x,y,
        hittable:simulatorVisible(el)&&Boolean(el?.contains(document.elementFromPoint(x,y)))}];
    }));
    if (video !== simulatorFrameVideo) {
      simulatorFrameVideo = video;
      simulatorFrames = 0;
      simulatorFrameTime = 0;
      simulatorLastFrameAt = 0;
      simulatorFrameRequest += 1;
    }
    if (video?.requestVideoFrameCallback && Date.now() - simulatorLastFrameAt > 2000) {
      // Re-arm observation after load/seek/presentation changes. Continue to
      // require advancing frame mediaTime; a moving audio clock is insufficient.
      const request = ++simulatorFrameRequest;
      simulatorLastFrameAt = Date.now();
      const track = (_now, metadata) => {
        if (simulatorFrameVideo !== video || request !== simulatorFrameRequest) return;
        simulatorFrames += 1;
        simulatorFrameTime = Number(metadata.mediaTime) || 0;
        simulatorLastFrameAt = Date.now();
        video.requestVideoFrameCallback(track);
      };
      video.requestVideoFrameCallback(track);
    }
    return JSON.stringify({
      libraryReady: Boolean(state.libraryReady), libraryCount: state.videos.length,
      screen: state.screen,
      observedAt: Date.now(), tabSwipeY, pageLoading: Boolean(state.loading), playerButtons,
      gestures: simulatorGestures, warnings: simulatorWarnings,
      directFallbackId: String(state.watchDirectFallbackId||''),
      nativeRestoreBusy: Boolean(state.nativeBackgroundRestoreBusy),
      initializationFrameConnected: Boolean(state.watchVimeoInitialization?.frame?.isConnected),
      opening: simulatorOpening, error: simulatorError,
      storePage:this.storePage, storeReady:this.storeReady, storeError:this.storeError,
      id: state.watchVideo ? String(videoId(state.watchVideo)) : '',
      mode: state.watchMode, ready: Boolean(state.watchVimeoReady),
      backend: state.watchVimeo?.player?.backend || '',
      sampleId: this.selectedSampleId,
      recoveryMP4: Boolean(state.watchVimeo?.player?.backend==='mp4' && state.watchVimeo?.player?.decoderReloads>0),
      playIntent: Boolean(state.watchVimeo?.player?.autoplayWanted),
      decoderReloads: Number(state.watchVimeo?.player?.decoderReloads) || 0,
      decoderLoading: Boolean(state.watchVimeo?.player?.loading),
      visualRecoveryPending: Boolean(state.watchVimeo?.player?.visualPlaybackPromise),
      playerCount: document.querySelectorAll('#directVideoElement').length,
      initializing: Boolean(state.watchVimeoInitialization),
      videoTime: Number(video?.currentTime) || 0, videoPlaying: Boolean(video && !video.paused && !video.ended),
      videoVisible: simulatorVisible(video), controlsVisible: simulatorVisible(document.getElementById('dmPlay')),
      videoX:videoBox?.left || 0, videoY:videoBox?.top || 0, videoWidth:videoBox?.width || 0, videoHeight:videoBox?.height || 0,
      fullscreen:Boolean(state.watchVimeo?.player?.customFullscreen || document.fullscreenElement),
      nativeBackgroundPending:Boolean(state.nativeBackgroundPending),
      frameApi: Boolean(video?.requestVideoFrameCallback), frames: simulatorFrames, frameTime: simulatorFrameTime,
      decodedFrames: Number(video?.webkitDecodedFrameCount) || 0,
      mediaReadyState: Number(video?.readyState) || 0, seeking: Boolean(video?.seeking),
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
