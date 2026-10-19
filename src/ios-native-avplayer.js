// The ONE playback engine for the native iOS app. Every Video/Audio mode,
// fullscreen/Mini/PiP surface, and background session controls the same
// IrgunUnifiedPlayer Swift singleton and its AVPlayer (not a WKWebView media
// element or a second background AVPlayer).
export function createIosUnifiedAVPlayer({capacitor, registerPlugin, onState = () => {}, onEnded = () => {}, onMinimize = () => {}, onFullscreen = () => {}, onPiPUnavailable = () => {}, onPiPState = () => {}}) {
  if (capacitor?.getPlatform?.() !== 'ios' || !capacitor?.isNativePlatform?.()) return null;
  const native = registerPlugin('IrgunUnifiedPlayer');
  let current = null;
  let listenerPromise = null;
  const listeners = new Set();
  const keyOf = data => String(data?.id || '');
  const read = () => current;
  const emit = value => {
    if (!value) return;
    if (current?.active && value.id && value.id !== current.id) return;
    current = {...current,...value};
    try { onState(current); } catch (error) { console.warn('Native AVPlayer UI update failed',error); }
    for (const fn of listeners) {
      try { fn(current); } catch (error) { console.warn('Native AVPlayer observer failed',error); }
    }
  };
  const ready = async () => {
    if (!listenerPromise) {
      listenerPromise = Promise.all([
        native.addListener('state',emit),
        native.addListener('ended', value => {
          void Promise.resolve(onEnded(value)).catch(error => console.warn('Native audio completion failed', error));
        }),
        native.addListener('requestMinimize',onMinimize),
        native.addListener('requestFullscreen',onFullscreen),
        native.addListener('pipUnavailable',onPiPUnavailable),
        native.addListener('pipState',onPiPState)
      ]).catch(error => {
        listenerPromise = null;
        throw error;
      });
    }
    return listenerPromise;
  };
  const engine = {
    get active() { return Boolean(current?.active); },
    get state() { return current || {}; },
    get id() { return keyOf(current); },
    get native() { return native; },
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    async open({id,url,title,artist='',position=0,rate=1,mode='video',autoplay=true,rect=null}) {
      await ready();
      if (!id || !url) throw new Error('Native AVPlayer needs a lecture ID and stream URL');
      const safeRate = Math.min(2,Math.max(0.5,Number(rate)||1));
      const previous=current;
      // Same lecture and same source: never re-open the AVPlayerItem just to
      // switch Audio/Video or to show the player after a screen transition.
      if (previous?.active && previous.id===String(id) && previous.sourceUrl===String(url)) {
        if (previous.mode !== mode) await engine.mode(mode);
        if (position != null && Number.isFinite(Number(position)) && Math.abs(Number(position)-Number(previous.position||0))>3) await engine.seek(position);
        if (autoplay && !engine.state.playing) await engine.play();
        return current;
      }
      // Once source changes the SAME AVPlayer is reused with a new item.
      const snapshot=await native.open({id:String(id),url:String(url),title:String(title||'Shiur'),
        artist:String(artist||''),mode,autoplay:Boolean(autoplay),
        position:Math.max(0,Number(position)||0),rate:safeRate,rect:rect||{}});
      current={...snapshot,active:true,sourceUrl:String(url)};
      emit(current);
      return current;
    },
    async snapshot() {
      if (!current?.active) return current||{};
      emit(await native.getState());
      return current;
    },
    async play() { if (!current?.active) return; emit(await native.play()); return current; },
    async pause() { if (!current?.active) return; emit(await native.pause()); return current; },
    async seek(position) {
      if (!current?.active) return;
      emit(await native.seek({position:Math.max(0,Number(position)||0)}));
      return current;
    },
    async speed(rate) {
      if (!current?.active) return;
      emit(await native.setRate({rate:Number(rate)||1}));
      return current;
    },
    async mode(mode) {
      if (!current?.active) throw new Error('No native media loaded');
      if (!['audio','video'].includes(mode)) throw new Error('Invalid native playback mode');
      emit(await native.setMode({mode}));
      return current;
    },
    async layout(layout,rect={}) {
      if (!current?.active) return;
      emit(await native.setLayout({layout,rect}));
      return current;
    },
    async quality(height=0) {
      if (!current?.active) return;
      if (typeof native.setQuality !== 'function') throw new Error('Native video quality control not available');
      emit(await native.setQuality({height:Number(height)||0}));
      return current;
    },
    async exitPiP() { if (!current?.active) return; emit(await native.exitPiP()); return current; },
    async occlude(occluded) { if (!current?.active) return; emit(await native.setOverlayOccluded({occluded:Boolean(occluded)})); return current; },
    async pip() {
      if (!current?.active) return;
      if (typeof native.enterPiP !== 'function') throw new Error('Picture in Picture not available');
      emit(await native.enterPiP());
      return current;
    },
    async stop() {
      if (!current?.active) return;
      const last=current;
      await native.stop();
      current=null;
      return last;
    }
  };
  return engine;
}

export function nativeVideoFrame(document) {
  const stage=[...document.querySelectorAll('#watchVideoStage')].find(node=>{
    const r=node.getBoundingClientRect();
    return r.width>40&&r.height>30&&r.right>0&&r.bottom>0&&r.left<innerWidth&&r.top<innerHeight;
  });
  if (!stage) return null;
  const r=stage.getBoundingClientRect();
  return {x:r.x,y:r.y,width:r.width,height:r.height};
}

// Native adapters contain no video/audio elements and own no player. They
// forward all actions to the one Swift AVPlayer shared with normal audio.
export function createIosNativeVideoAdapter(engine,id) {
  const listeners=new Map();
  let lastPlay=null;
  const fire=(event,value)=>{for(const fn of listeners.get(event)||[])try{fn(value);}catch(error){console.warn('Native video event',event,error);}};
  const unsubscribe=engine.subscribe(s=>{
    if (String(s.id)!==String(id)) return;
    fire('timeupdate',{seconds:Number(s.position)||0,duration:Number(s.duration)||0});
    if (lastPlay!==Boolean(s.playing)) {
      lastPlay=Boolean(s.playing);
      fire(lastPlay?'play':'pause',{seconds:Number(s.position)||0,duration:Number(s.duration)||0});
    }
  });
  return {
    isIrgunUnifiedNativeAVPlayer:true, isNativeAVPlayer:true, video:null,
    on(name,fn){if(!listeners.has(name))listeners.set(name,new Set());listeners.get(name).add(fn);return this;},
    getCurrentTime:async()=>Number(engine.state.position)||0,
    getDuration:async()=>Number(engine.state.duration)||0,
    getPaused:async()=>!engine.state.playing,
    setCurrentTime:async value=>{await engine.seek(value);return Number(engine.state.position)||0;},
    play:()=>engine.play(),
    pause:()=>engine.pause(),
    setPlaybackRate:rate=>engine.speed(rate),
    setMuted:async()=>{}, setVolume:async()=>{},
    setMode:mode=>engine.mode(mode),
    setLayout:(layout,rect)=>engine.layout(layout,rect),
    requestPictureInPicture:()=>engine.pip(),
    preparePictureInPicture:()=>{},
    exitPictureInPicture:async()=>{},
    ready:async()=>true,
    async destroy(){unsubscribe();listeners.clear();}
  };
}
