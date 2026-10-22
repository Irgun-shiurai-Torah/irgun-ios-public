// Appended to main.js ONLY in the unsigned simulator workflow.
// This exposes observations, not replacement playback behavior.
import {simulatorHlsSourceReady, selectIosAccountFixture} from '../.github/simulator/sample-selection.js';
const simulatorSampleId = __SIMULATOR_VIDEO_ID__;
let simulatorError = '';
let simulatorOpening = false;
let simulatorFrameVideo = null;
let simulatorFrames = 0;
let simulatorFrameTime = 0;
let simulatorLastFrameAt = 0;
let simulatorFrameRequest = 0;
const simulatorGestures = [];
const simulatorTabMotion = [];
// Observe after the app's root touchmove handler, while the finger is still
// down. A tab changing on release alone cannot satisfy this observation.
document.addEventListener('touchmove', () => {
  const content = document.querySelector('#app .app-shell > .content');
  const preview = document.querySelector('.ios-swipe-preview');
  if (!content || !preview) return;
  const dx = new DOMMatrixReadOnly(getComputedStyle(content).transform).m41;
  if (Math.abs(dx) < 2) return;
  simulatorTabMotion.push({at:Date.now(),screen:state.screen,dx,
    inert:preview.inert,media:preview.querySelectorAll('video,audio,iframe').length});
  if (simulatorTabMotion.length > 40) simulatorTabMotion.shift();
}, {passive:true});
const simulatorWarnings = [];
const simulatorOriginalWarn = console.warn.bind(console);
console.warn = (...args) => {
  if (/video|HLS|decoder|native background|Vimeo|picture.in.picture|PiP/i.test(String(args[0]||''))) {
    simulatorWarnings.push({at:Date.now(),message:String(args[0]||''),error:args.find(x=>x instanceof Error)?.message||''});
    if(simulatorWarnings.length>12)simulatorWarnings.shift();
  }
  simulatorOriginalWarn(...args);
};
for (const type of ['pointerdown','pointerup','pointercancel','touchstart','touchend','touchcancel']) {
  document.addEventListener(type,event=>{
    if(!event.target?.closest('#directMediaPlayer,.content,.watch-overlay,.watch-top'))return;
    const point=event.changedTouches?.[0]||event;
    simulatorGestures.push({type,at:Date.now(),x:point.clientX,y:point.clientY,target:event.target.id,screen:state.screen});
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

// Disposable simulator-only test selection. Real users still see the unmodified
// catalog. Choose an actual backed-up video with audio and a speaker, not the
// newest Vimeo-only upload. Remember its ID across real process relaunches.
window.__ISTQAChooseWatchButton = function(elements) {
  let saved = '';
  try { saved = localStorage.getItem('istIOSQABackedWatchId') || ''; } catch (_) {}
  // Share exactly the same fixture-selection rules with the Node unit tests.
  return selectIosAccountFixture(elements, state.videoById, saved);
};
document.addEventListener('click', event => {
  const element = event.target instanceof Element ? event.target.closest('[data-watch]') : null;
  const id = String(element?.dataset.watch || '');
  if (['1235946832','1235511026'].includes(id)) {
    try { localStorage.setItem('istIOSQABackedWatchId', id); } catch (_) {}
  }
}, true);

window.ISTSimulator = {
  storePage: '', storeReady: false, storeError: '', storeIndex: -1, selectedSampleId: '',
  reportedExpectedSource: '', reportedSources: null, reportedSelectedId: '',
  reportedVimeoKey: '', reportedEmbedPreview: '', reportedUnlistedPreview: '',
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
            if (iosNativeActive()
              ? (iosUnified.state.ready && iosUnified.state.mode === mode && (!state.watchVideo || state.watchVimeoReady))
              : (mode === 'audio' ? (state.current && audio.readyState >= 2 && !state.pendingAudioSeek) : (state.watchVimeoReady && state.watchVimeo?.video?.readyState >= 2))) resolve();
            else if (Date.now()-start>90000) reject(new Error('Screenshot video did not become ready'));
            else setTimeout(check,250);
          }; check();
        });
        if (page === 'audio-player') { state.screen='home'; state.playerOpen = true; render(); }
        else if (page === 'mini-player') { state.screen='home'; render(); await minimizeWatchToPersistent(); }
        else if (page === 'fullscreen') {
          if (state.watchMinimized) await expandPersistentWatch();
          if (iosNativeActive()) await iosUnified.layout('full', nativeVideoFrame(document)||{});
          else document.getElementById('dmFull')?.click();
        }
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
            if(iosNativeActive()
              ? (Number(iosUnified.state.decodedFrames)>0 && iosUnified.state.layerReady === true)
              : (simulatorFrames>0&&simulatorVisible(player?.v)&&!player?.loading&&player?.load?.hidden!==false))resolve();
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
  async openReportedShiur() {
    if (simulatorOpening) return;
    simulatorOpening = true; simulatorError = '';
    try {
      // IST-DL6067 was a genuine production regression, but catalog titles,
      // lengths and membership can change independently of app code. Prefer it
      // when still present; otherwise exercise another REAL backed-up lecture.
      // Never replace the media endpoint with a fixture or a mocked decoder.
      this.reportedSources = null;
      this.reportedExpectedSource = '';
      this.reportedSelectedId = '';
      this.reportedVimeoKey = '';
      this.reportedEmbedPreview = '';
      this.reportedUnlistedPreview = watchVimeoEmbedSrc({vimeoId:'1233236785:585d5d53db'},0);
      const originalId = '1233236785:585d5d53db';
      const eligible = video => video && !isIosVimeoOnlyLecture(video) &&
        /^\d+(?::[a-z0-9]+)?$/i.test(String(video.vimeoId || video.id || ''));
      const preferred = [
        state.videoById.get(originalId),
        state.videoById.get('1233236785'),
        state.videos.find(video => String(videoId(video)).startsWith('1233236785:')),
        state.videoById.get('1235946832'),
        ...state.videos.filter(video => eligible(video) && video.hasAudio).slice(0,24)
      ].filter(eligible);
      const unique = preferred.filter((video,index,list) =>
        list.findIndex(other => videoId(other) === videoId(video)) === index);
      for (const video of unique) {
        const sources = await loadIosDirectVideoSources(video);
        if (!sources?.hls && !sources?.mp4) continue;
        // Historical descriptors can outlive an incomplete/unreachable backup.
        // Use the same real playlist/segment probe as the normal sample path;
        // still require the actual decoder to use this owned source afterward.
        if (!await simulatorHlsSourceReady(sources.hls) &&
            !await simulatorHlsSourceReady(sources.mp4)) continue;
        const id=String(videoId(video));
        this.reportedSelectedId = id;
        this.reportedVimeoKey = String(video.vimeoId || video.id || '');
        this.reportedEmbedPreview = watchVimeoEmbedSrc(video,0);
        this.reportedSources = sources;
        this.reportedExpectedSource = sources.hls || sources.mp4;
        await openWatch(id, 0);
        return;
      }
      throw new Error('No cataloged Drive-backed lecture exposes real native HLS or MP4');
    } catch (error) { simulatorError = String(error.message || error); }
    finally { simulatorOpening = false; }
  },
  async openDirectAudioSample() {
    if (simulatorOpening) return;
    simulatorOpening = true;
    simulatorError = '';
    this.selectedSampleId = '';
    try {
      const preferred = state.videoById.get('1235946832');
      const candidates = [preferred,
        ...state.videos.filter(video => video.hasAudio && !isIosVimeoOnlyLecture(video)).slice(0,20)
      ].filter((video,index,list) => video && video.hasAudio &&
        list.findIndex(other => videoId(other) === videoId(video)) === index);
      for (const video of candidates) {
        const sources = await loadIosDirectVideoSources(video);
        if (!sources?.hls || !await simulatorHlsSourceReady(sources.hls)) continue;
        const id = String(videoId(video));
        this.selectedSampleId = id;
        // A direct Listen tap opens a new audio item, unlike the video-to-audio switch.
        await playVideoAudio(id, 0);
        if (!state.current || state.current.kind !== 'video-audio')
          throw new Error('Direct Listen failed to take audio ownership');
        return;
      }
      throw new Error('No real healthy backed-up audio lecture available to test');
    } catch (error) { simulatorError = String(error.message || error); }
    finally { simulatorOpening = false; }
  },
  async openSample() {
    if (simulatorOpening) return;
    simulatorOpening = true;
    simulatorError = '';
    try {
      const selected = simulatorSampleId || this.selectedSampleId;
      // This backed-up shiur decoded real HLS frames and continued background
      // audio in the last green native AVPlayer run. Never use a Vimeo-only
      // upload as the default simulator test sample.
      const verifiedHlsId = '1235946832';
      const candidates = selected
        ? [state.videoById.get(String(selected))].filter(Boolean)
        : [
            state.videoById.get(verifiedHlsId),
            ...state.videos.filter(video => video.hasAudio).slice(0, 12)
          ].filter((video, index, list) =>
            video && video.hasAudio &&
            list.findIndex(item => videoId(item) === videoId(video)) === index
          );
      if (!candidates.length) throw new Error('No sample available in the loaded library');
      for (const video of candidates) {
        let sources;
        for (let attempt=0;attempt<3;attempt++) {
          sources = await loadIosDirectVideoSources(video);
          if (sources?.hls) break;
          if (attempt<2) await new Promise(resolve=>setTimeout(resolve,1500));
        }
        if (!sources?.hls || !video.hasAudio || !await simulatorHlsSourceReady(sources.hls)) continue;
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
    // Production's single AVPlayer has no DOM video. Expose live bridge state
    // only; the simulator's Swift probe separately reads the actual AVPlayer.
    const native = iosNativeActive() ? iosUnified.state : null;
    const nativeVideo = Boolean(native && native.mode === 'video');
    const nativeVideoVisible = nativeVideo && native.layerReady === true &&
      native.overlayOccluded !== true && native.layout !== 'mini' && native.pipActive !== true;
    const videoBox = video?.getBoundingClientRect();
    const detailsHeading = document.querySelector('.watch-details h1');
    const detailsBox = detailsHeading?.getBoundingClientRect();
    const expand = [...document.querySelectorAll('[data-expand-watch]')].find(simulatorVisible);
    const expandBox = expand?.getBoundingClientRect();
    const contentRoot = document.querySelector('.content');
    const contentBox = contentRoot?.getBoundingClientRect();
    const renderedScreen = contentRoot?.dataset?.screen || '';
    const tabSwipeReady = renderedScreen === state.screen &&
      !state.iosNavPending && !state.loading && !state.error &&
      !state.playerOpen && !state.filterDialog &&
      (!state.watchVideo || state.watchMinimized) &&
      !document.querySelector('[aria-modal="true"], .admin-editor-backdrop, .sheet-backdrop');
    let tabSwipeY = 0;
    // Test only a genuinely rendered and gesture-eligible page. Avoid the
    // live section's title/header rows and any transient old DOM between tabs.
    for (let y = Math.max(220, (contentBox?.top || 0) + 48);
         tabSwipeReady && y < innerHeight - 140; y += 18) {
      const safe = [.2,.8].every(x => {
        const hit = document.elementFromPoint(innerWidth*x,y);
        if (!hit?.closest('.content') ||
            hit.closest('input,textarea,select,button,video,iframe,[role="dialog"],.direct-media-player,.watch-overlay,.mini-player,.sheet-backdrop,.bottom-nav')) return false;
        for(let node=hit;node && node.closest('.content');node=node.parentElement) {
          if (/auto|scroll/.test(getComputedStyle(node).overflowX) && node.scrollWidth>node.clientWidth+2) return false;
        }
        return true;
      });
      if(safe){tabSwipeY=y;break;}
    }
    const playerButtons = Object.fromEntries(['dmPlay','dmFull','watchMinimize'].map(id => {
      const el=id==='watchMinimize'?[...document.querySelectorAll('[data-minimize-watch]')].find(simulatorVisible):document.getElementById(id), b=el?.getBoundingClientRect();
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
      screen: state.screen, renderedScreen, tabSwipeReady,
      observedAt: Date.now(), tabSwipeY, pageLoading: Boolean(state.loading), playerButtons,
      gestures: simulatorGestures, tabMotion: simulatorTabMotion, warnings: simulatorWarnings,
      directFallbackId: String(state.watchDirectFallbackId||''),
      nativeRestoreBusy: Boolean(state.nativeBackgroundRestoreBusy),
      initializationFrameConnected: Boolean(state.watchVimeoInitialization?.frame?.isConnected),
      opening: simulatorOpening, error: simulatorError,
      storePage:this.storePage, storeReady:this.storeReady, storeError:this.storeError,
      id: state.watchVideo ? String(videoId(state.watchVideo)) : '',
      mode: state.watchMode, ready: Boolean(state.watchVimeoReady),
      backend: native ? (String(native.sourceUrl||'').includes('.m3u8')?'hls-native':'mp4') : (state.watchVimeo?.player?.backend || ''),
      videoSource: native?.sourceUrl || video?.currentSrc || video?.src || '',
      reportedExpectedSource: this.reportedExpectedSource, reportedSources: this.reportedSources,
      reportedSelectedId: this.reportedSelectedId, reportedVimeoKey: this.reportedVimeoKey,
      reportedEmbedPreview: this.reportedEmbedPreview, reportedUnlistedPreview: this.reportedUnlistedPreview,
      vimeoEmbed: document.getElementById('watchVimeoFrame')?.dataset?.vimeoSrc || '',
      fallbackBanner: Boolean(document.querySelector('.watch-hls-fallback-note')) || /HLS could not start.*Playing Vimeo/.test(document.body.innerText),
      sampleId: this.selectedSampleId,
      recoveryMP4: Boolean(state.watchVimeo?.player?.backend==='mp4' && state.watchVimeo?.player?.decoderReloads>0),
      playIntent: Boolean(state.watchVimeo?.player?.autoplayWanted),
      decoderReloads: Number(state.watchVimeo?.player?.decoderReloads) || 0,
      decoderLoading: Boolean(state.watchVimeo?.player?.loading),
      visualRecoveryPending: Boolean(state.watchVimeo?.player?.visualPlaybackPromise),
      playerCount: document.querySelectorAll('#directVideoElement').length,
      initializing: Boolean(state.watchVimeoInitialization),
      videoTime: native ? (Number(native.position)||0) : (Number(video?.currentTime)||0),
      videoPlaying: native ? (nativeVideo&&native.playing===true) : Boolean(video && !video.paused && !video.ended),
      videoVisible: native ? nativeVideoVisible : simulatorVisible(video),
      controlsVisible: native ? native.controlsVisible === true : simulatorVisible(document.getElementById('dmPlay')),
      detailsSwipeX: detailsBox ? detailsBox.left + detailsBox.width * 0.3 : 0,
      detailsSwipeY: detailsBox ? detailsBox.top + detailsBox.height * 0.5 : 0,
      detailsSwipeEndY: detailsBox ? Math.min(innerHeight - 130, detailsBox.top + detailsBox.height * 0.5 + 145) : 0,
      watchScrollTop: document.querySelector('.watch-scroll')?.scrollTop || 0,
      videoX:native?(Number(native.surfaceX)||0):(videoBox?.left||0),
      videoY:native?(Number(native.surfaceY)||0):(videoBox?.top||0),
      videoWidth:native?(Number(native.surfaceWidth)||0):(videoBox?.width||0),
      videoHeight:native?(Number(native.surfaceHeight)||0):(videoBox?.height||0),
      fullscreen:native ? native.layout === 'full' : Boolean(state.watchVimeo?.player?.customFullscreen || document.fullscreenElement),
      nativeBackgroundPending:Boolean(state.nativeBackgroundPending),
      frameApi: native ? Number(native.decodedFrames)>0 : Boolean(video?.requestVideoFrameCallback),
      frames: native ? (Number(native.decodedFrames)||0) : simulatorFrames,
      frameTime: native ? (Number(native.frameTime)||0) : simulatorFrameTime,
      decodedFrames: native ? (Number(native.decodedFrames)||0) : (Number(video?.webkitDecodedFrameCount)||0),
      mediaReadyState: Number(video?.readyState) || 0, seeking: Boolean(video?.seeking),
      audioTime: Number(audio.currentTime) || 0, audioPlaying: Boolean(!audio.paused && !audio.ended),
      nativeAudioTime: native?.mode==='audio' ? (Number(native.position)||0) : 0,
      nativeAudioPlaying: native?.mode==='audio' && native.playing === true,
      pendingSeek: Boolean(state.pendingAudioSeek), minimized: Boolean(state.watchMinimized),
      expandX: expandBox ? expandBox.left + expandBox.width / 2 : 0,
      expandY: expandBox ? expandBox.top + expandBox.height / 2 : 0,
      pip: native ? native.pipActive === true : Boolean(state.watchPictureInPicture || document.pictureInPictureElement === video || video?.webkitPresentationMode === 'picture-in-picture'),
      pipSupported: native ? (native.pipSupported === true && native.pipPossible === true) : Boolean(video && ((document.pictureInPictureEnabled && video.requestPictureInPicture) ||
        video.webkitSupportsPresentationMode?.('picture-in-picture'))),
      pipDiagnostic: (() => {
        const info=document.getElementById('dmPip')?.__irgunPipDiagnostic;
        return info ? {clicks:info.clicks,route:info.route,error:info.error,
          lastEvent:info.lastEvent,active:info.active,requested:info.requested,
          webkitMode:String(video?.webkitPresentationMode||'')} : null;
      })(),
      speed: native ? (Number(native.rate)||1) : Number(video?.playbackRate || audio.playbackRate),
      nativeItemEpoch: Number(native?.itemEpoch)||0,
      nativeLayerReady: native?.layerReady === true,
      hidden: document.hidden
    });
  }
};
