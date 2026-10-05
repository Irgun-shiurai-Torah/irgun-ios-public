// Exercise actual application functions with controlled async/media boundaries.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../src/main.js'), 'utf8');
function extract(start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  assert.ok(first >= 0 && last > first, `Missing source boundary: ${start}`);
  return source.slice(first, last);
}
const functions = [
  extract('function watchPlayerInitializationIsCurrent(', 'async function loadComments('),
  extract('function keepVideoPlayingOnBackground(', 'function restoreVideoAfterBackgroundAudio('),
  extract('async function openWatch(', 'function currentVideoClockForBackground(')
].join('\n');
function fixture() {
  const pending = [], observations = { handoffs:0, exits:0, uiRestores:0 };
  const video = { id:'A', duration:120, title:'Test', hasAudio:true };
  const frame = { isConnected:true };
  const state = {
    watchVideo:video, videoById:new Map([['A',video]]), watchMode:'video',
    watchVimeo:null, watchVimeoReady:false, watchVimeoGeneration:1,
    watchVimeoInitialization:null, watchResumeSeconds:30, watchVideoPlaying:false,
    watchPictureInPicture:false, pipBackgroundReturnPending:false,
    pipWasBackgrounded:false, pipResumeWanted:false, pipRestoreBusy:false, backgroundPipPending:false
  };
  const context = vm.createContext({
    state, console:{warn:()=>{}}, navigator:{}, audio:{paused:true}, IS_IOS:true,
    Capacitor:{isNativePlatform:()=>true},
    nativeBackgroundAudioAvailable:()=>false, stopNativeBackgroundAudio:()=>{}, prepareNativeBackgroundAudio:()=>{},
    document:{hidden:false, pictureInPictureElement:null, getElementById:()=>frame},
    // No real timers are needed for these controlled transitions.
    setTimeout:()=>0, clearTimeout:()=>{}, videoId:v=>v.id, hardStopHtmlAudioForVideo:()=>{},
    setVimeoHandoffMuted:async()=>{}, displayShiurTitle:x=>x, audioUrl:x=>x,
    mediaApiId:v=>v.id, syncNativeMediaSession:()=>{},
    currentVideoClockForBackground:()=>state.watchVimeo?.video?.currentTime || state.watchResumeSeconds,
    handoffPlayingVideoToBackgroundAudio:()=>{observations.handoffs++;},
    restoreWatchUiAfterSystemPip:()=>{observations.uiRestores++;},
    parkWatchUiForSystemPip:()=>{}, refreshPersistentMiniVideoChrome:()=>{},
    recordPublicView:()=>{},
    usageAnalytics:{event:()=>{},setMedia:()=>{}},
    saveCurrentAudioHistory:async()=>{}, preserveWatchTime:async()=>{}, saveHistory:async()=>{},
    clearPersistentVideoMount:()=>{}, cachedSavedPosition:()=>10,
    render:()=>{}, hostCurrentWatchOverlay:()=>{}, loadComments:()=>{},
    createIosWatchPlayer:(_v,_f,_s,auto)=>new Promise((resolve,reject)=>pending.push({auto,resolve,reject}))
  });
  vm.runInContext(functions, context);
  function player(name, playing=false) {
    const handlers = new Map();
    return {
      name, destroyed:false, handlers,
      video:{paused:!playing, ended:false, currentTime:30, webkitPresentationMode:'inline'},
      ready:async()=>{}, setCurrentTime:async function(x){this.video.currentTime=x;return x;},
      ensureVisualPlayback:async function(){this.video.paused=false;return true;},
      getPaused:async function(){return this.video.paused;},
      getCurrentTime:async function(){return this.video.currentTime;}, getDuration:async()=>120,
      on:(name,handler)=>handlers.set(name,handler),
      destroy:async function(){this.destroyed=true;this.video.paused=true;},
      exitPictureInPicture:async function(){observations.exits++;this.video.webkitPresentationMode='inline';}
    };
  }
  return {context,state,pending,player,observations,frame};
}
const flush = async () => { for(let i=0;i<12;i++) await Promise.resolve(); };

test('speaker filters omit unresolved metadata rather than render blank rows',()=>{
  const context=vm.createContext({state:{metadata:{topics:[]}},allLibraryItems:()=>[{_speakerIds:['missing','known','known']}],speakerLabel:id=>id==='known'?'Rabbi Name':'',uniqueOptions:()=>[]});
  vm.runInContext(extract('function availableFilters(', 'function locationFilterMatches('),context);
  assert.deepEqual(Array.from(context.availableFilters().speakers),['known']);
});

for (const renderFirst of [false,true]) test(`one startup owner, render first=${renderFirst}`, async()=>{
  const f=fixture();
  const init=f.context.initWatchVimeo(!renderFirst);
  await f.context.initWatchVimeo(renderFirst);
  assert.equal(f.pending.length,1);
  const p=f.player('only');
  f.pending[0].resolve({player:p,backend:'direct'}); await init;
  assert.equal(f.state.watchVimeo,p);
  assert.equal(p.video.paused,false);
  assert.equal(f.state.watchVimeoReady,true);
  assert.equal(f.state.watchVimeoInitialization,null);
});

test('late old load cannot replace a newer player',async()=>{
  const f=fixture(), old=f.context.initWatchVimeo(true);
  f.state.watchVimeoGeneration++;
  f.state.watchVideo={...f.state.watchVideo,id:'B'};
  const currentInit=f.context.initWatchVimeo(true), current=f.player('current'), stale=f.player('stale');
  f.pending[1].resolve({player:current,backend:'direct'}); await currentInit;
  f.pending[0].resolve({player:stale,backend:'direct'}); await old;
  assert.equal(f.state.watchVimeo,current);
  assert.equal(f.state.watchVimeoReady,true);
  assert.equal(stale.destroyed,true);
  assert.equal(current.destroyed,false);
});

test('switching to audio while loading destroys the cancelled result',async()=>{
  const f=fixture(), init=f.context.initWatchVimeo(true), stale=f.player('stale');
  f.state.watchMode='audio'; f.state.watchVimeoGeneration++;
  f.pending[0].resolve({player:stale,backend:'direct'}); await init;
  assert.equal(f.state.watchVimeo,null);
  assert.equal(stale.destroyed,true);
});

test('failed initialization releases its lock and can retry',async()=>{
  const f=fixture(), init=f.context.initWatchVimeo(true);
  f.pending[0].reject(new Error('network')); await init;
  assert.equal(f.state.watchVimeoInitialization,null);
  const retry=f.context.initWatchVimeo(true), p=f.player('retry');
  f.pending[1].resolve({player:p,backend:'direct'}); await retry;
  assert.equal(f.state.watchVimeo,p);
});

test('same shiur reopening keeps player, generation, readiness and live clock',async()=>{
  const f=fixture(), init=f.context.initWatchVimeo(true), p=f.player('live');
  f.pending[0].resolve({player:p,backend:'direct'}); await init;
  const generation=f.state.watchVimeoGeneration;
  p.video.currentTime=47;
  await f.context.openWatch('A');
  assert.equal(f.state.watchVimeo,p);
  assert.equal(f.state.watchVimeoReady,true);
  assert.equal(f.state.watchVimeoGeneration,generation);
  assert.equal(f.state.watchResumeSeconds,47);
  assert.equal(f.pending.length,1);
  p.handlers.get('timeupdate')({seconds:48,duration:120});
  assert.equal(f.state.watchResumeSeconds,48);
});

test('same shiur explicit timestamp seeks without rebuilding',async()=>{
  const f=fixture(), init=f.context.initWatchVimeo(true), p=f.player('live');
  f.pending[0].resolve({player:p,backend:'direct'}); await init;
  await f.context.openWatch('A',65);
  assert.equal(p.video.currentTime,65);
  assert.equal(f.pending.length,1);
});

test('reopening during discovery promotes Play and preserves requested seek',async()=>{
  const f=fixture(), init=f.context.initWatchVimeo(false), p=f.player('loading');
  await f.context.openWatch('A',65);
  f.pending[0].resolve({player:p,backend:'direct'}); await init;
  assert.equal(p.video.currentTime,65);
  assert.equal(p.video.paused,false);
  assert.equal(f.pending.length,1);
});

test('absence of video is never mistaken for PiP',()=>{
  const f=fixture();
  f.context.keepVideoPlayingOnBackground('home');
  assert.equal(f.state.watchPictureInPicture,false);
  assert.equal(f.observations.handoffs,1);
  f.state.watchMode='audio';
  f.context.keepVideoPlayingOnBackground('pagehide-after-handoff');
  assert.equal(f.state.watchPictureInPicture,false);
  assert.equal(f.observations.handoffs,1);
});

test('PiP return restores UI and playback even if system paused video',async()=>{
  const f=fixture(), p=f.player('pip',true);
  f.state.watchVimeo=p;
  p.video.webkitPresentationMode='picture-in-picture';
  f.context.document.hidden=true;
  f.context.keepVideoPlayingOnBackground('home');
  assert.equal(f.state.pipWasBackgrounded,true);
  assert.equal(f.observations.handoffs,0);
  p.video.paused=true;
  f.context.document.hidden=false;
  f.context.restoreVideoAfterSystemPip(); await flush();
  assert.equal(f.observations.exits,1);
  assert.equal(f.observations.uiRestores,1);
  assert.equal(f.state.watchPictureInPicture,false);
  assert.equal(p.video.paused,false);
});

test('paused PiP is not automatically resumed',async()=>{
  const f=fixture(), p=f.player('paused');
  f.state.watchVimeo=p;
  p.video.webkitPresentationMode='picture-in-picture';
  f.context.document.hidden=true;
  f.context.keepVideoPlayingOnBackground('home');
  f.context.document.hidden=false;
  f.context.restoreVideoAfterSystemPip(); await flush();
  assert.equal(f.observations.uiRestores,1);
  assert.equal(p.video.paused,true);
});

test('cancelled discovery cannot construct a player or alter fallback',async()=>{
  const f=fixture();
  let resolveSources, constructions=0, current=true;
  f.context.loadIosDirectVideoSources=()=>new Promise(resolve=>{resolveSources=resolve;});
  f.context.window={ISTDirectMediaPlayer:true};
  f.context.IosDirectVideoAdapter=function(){constructions++;};
  vm.runInContext(extract('async function createIosWatchPlayer(', 'async function fallbackIosDirectVideoToVimeo('),f.context);
  const init=f.context.createIosWatchPlayer(f.state.watchVideo,f.frame,30,true,()=>current);
  current=false; resolveSources({hls:'https://example.test/master.m3u8'});
  await assert.rejects(init,/cancelled/);
  assert.equal(constructions,0);
  assert.equal(f.state.watchDirectFallbackId,undefined);
});

test('older navigation cannot reopen a shiur after a newer request',async()=>{
  const f=fixture();
  f.state.watchVimeo=f.player('A',true);
  for (const id of ['B','C']) f.state.videoById.set(id,{...f.state.watchVideo,id});
  const waits=[];
  f.context.preserveWatchTime=()=>new Promise(resolve=>waits.push(resolve));
  const older=f.context.openWatch('B',35), newer=f.context.openWatch('C',40);
  waits[1](); await newer;
  assert.equal(f.state.watchVideo.id,'C');
  const current=f.player('C');
  f.pending[0].resolve({player:current,backend:'direct'}); await flush();
  waits[0](); await older;
  assert.equal(f.state.watchVideo.id,'C');
  assert.equal(f.state.watchVimeo,current);
  assert.equal(f.pending.length,1);
});

test('stale ready rejection cleans only its own player',async()=>{
  const f=fixture(), oldInit=f.context.initWatchVimeo(true), stale=f.player('old');
  let rejectReady;
  stale.ready=()=>new Promise((_resolve,reject)=>{rejectReady=reject;});
  f.pending[0].resolve({player:stale,backend:'vimeo'}); await flush();
  f.state.watchVimeoGeneration++;
  const newInit=f.context.initWatchVimeo(true), current=f.player('current');
  f.pending[1].resolve({player:current,backend:'direct'}); await newInit;
  rejectReady(new Error('old iframe removed')); await oldInit;
  assert.equal(stale.destroyed,true);
  assert.equal(f.state.watchVimeo,current);
  assert.equal(f.state.watchVimeoReady,true);
});

test('destroyed direct players cancel retries and reject new playback',async()=>{
  const directSource=fs.readFileSync(path.join(__dirname,'../src/direct-media.js'),'utf8');
  const cleared=[];
  const c=vm.createContext({
    window:{}, location:{protocol:'capacitor:',hostname:'localhost'},
    clearTimeout:timer=>cleared.push(timer), document:{fullscreenElement:null}
  });
  vm.runInContext(directSource,c);
  const p=Object.create(c.window.ISTDirectMediaPlayer.prototype);
  Object.assign(p,{destroyed:false,token:7,hlsRetryTimer:11,hlsStableTimer:12,bufferTimer:13,
    v:{pause:()=>{},removeAttribute:()=>{},load:()=>{}}, quality:{}, hls:null});
  p.destroy();
  assert.equal(p.token,8);
  assert.ok(cleared.includes(11)&&cleared.includes(12)&&cleared.includes(13));
  await assert.rejects(p.play(),/destroyed/);
  await assert.rejects(p.activate({hls:'https://example.test/master.m3u8'},30,true),/destroyed/);
  p.fatal(new Error('delayed media error')); // must not schedule another load
  p.destroy();
  assert.equal(p.token,8);
});

test('delayed Play callback cannot overwrite a newer shiur position',async()=>{
  const f=fixture(), init=f.context.initWatchVimeo(true), old=f.player('old');
  f.pending[0].resolve({player:old,backend:'direct'}); await init;
  let resolveTime;
  old.getCurrentTime=()=>new Promise(resolve=>{resolveTime=resolve;});
  const callback=old.handlers.get('play')(); await flush();
  f.state.watchVimeoGeneration++;
  f.state.watchVimeo=f.player('new');
  f.state.watchResumeSeconds=88;
  resolveTime(31); await callback;
  assert.equal(f.state.watchResumeSeconds,88);
});

function directPrototype(overrides = {}) {
  const c=vm.createContext({window:{},location:{protocol:'capacitor:',hostname:'localhost'},
    document:{hidden:false},requestAnimationFrame:callback=>callback(),setTimeout,clearTimeout,console,...overrides});
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../src/direct-media.js'),'utf8'),c);
  return c.window.ISTDirectMediaPlayer.prototype;
}

function decoderFixture(){
  const p=Object.create(directPrototype());
  const loaded=[],replaced=[];let bindings=0;
  const parent={child:null,replaceChild(next,old){assert.equal(this.child,old);this.child=next;next.parentNode=this;old.parentNode=null;}};
  const make=src=>({currentTime:0,playbackRate:1,volume:.7,muted:false,paused:true,webkitPresentationMode:'inline',src,
    removeAttribute(name){if(name==='src')this.src='';},setAttribute:()=>{},
    cloneNode(){return make(this.src);},pause(){this.paused=true;},
    load(){loaded.push(this.src);this.currentTime=0;this.paused=true;}});
  const v=make('https://example.test/720p.m3u8');v.currentTime=62;v.playbackRate=1.5;v.paused=false;v.parentNode=parent;parent.child=v;
  Object.assign(p,{v,token:1,backend:'hls-native',destroyed:false,autoplayWanted:true,load:{},meta:async()=>{},loadNativeQualities:async()=>{},
    cb:{onVideoElementReplaced:(old,next)=>replaced.push([old,next])},bind:()=>{bindings++;},
    current:()=>p.v.currentTime,seekTo:async x=>{p.v.currentTime=x;},
    play:async()=>{p.v.paused=false;},waitForVisualFrame:async()=>true});
  return {p,v,parent,loaded,replaced,bindings:()=>bindings};
}
test('decoder reload replaces the frozen surface and preserves live clock, source and speed',async()=>{
  const {p,v,parent,loaded,replaced,bindings}=decoderFixture();
  assert.equal(await p.reloadInlineVideo(),true);
  assert.notEqual(p.v,v);assert.equal(parent.child,p.v);assert.equal(v.parentNode,null);
  assert.equal(v.paused,true);assert.equal(v.src,'');
  assert.deepEqual(replaced,[[v,p.v]]);assert.equal(bindings(),1);
  assert.equal(p.v.currentTime,62);
  assert.equal(p.v.src,'https://example.test/720p.m3u8');
  assert.deepEqual(loaded,['','https://example.test/720p.m3u8']);
  assert.equal(p.v.playbackRate,1.5);assert.equal(p.v.volume,.7);
  assert.equal(p.v.muted,false);assert.equal(p.decoderReloads,1);
});

test('missing frames trigger exactly one decoder reload after layer recovery',async()=>{
  const p=Object.create(directPrototype());
  let reloads=0;
  const v={paused:false,readyState:4,webkitPresentationMode:'inline',setAttribute:()=>{},pause(){this.paused=true;}};
  Object.assign(p,{v,autoplayWanted:true,destroyed:false,c:{appendChild:()=>{}},r:{},
    show:()=>{},wakeVideoLayer:()=>{},current:()=>62,waitForVisualFrame:async()=>false,
    relatchInlineVideoLayer:async()=>true,play:async()=>{v.paused=false;},
    reloadInlineVideo:async()=>{reloads++;return true;}});
  assert.equal(await p.ensureVisualPlayback(),true);
  assert.equal(reloads,1);
});

test('overlapping frame recovery shares one operation',async()=>{
  const p=Object.create(directPrototype());
  p.autoplayWanted=true;
  let resolve,calls=0;
  p.recoverVisualPlayback=()=>{calls++;return new Promise(done=>{resolve=done;});};
  const first=p.ensureVisualPlayback(), second=p.ensureVisualPlayback(true);
  assert.equal(calls,1);
  resolve(true);
  assert.equal(await first,true);
  assert.equal(await second,true);
  assert.equal(p.visualPlaybackPromise,null);
});

test('late PiP pause is recovered, but an explicit Pause cancels recovery',async()=>{
  const f=fixture(), p=f.player('pip');
  const tasks=[];
  let recoveries=0;
  f.context.setTimeout=task=>{tasks.push(task);return tasks.length;};
  p.player={autoplayWanted:true};
  p.ensureVisualPlayback=async()=>{recoveries++;p.video.paused=false;};
  f.state.watchVimeo=p;
  f.context.scheduleInlineVideoRecovery(p);
  assert.equal(tasks.length,3);
  p.video.paused=true; // native pause arriving after foreground restoration
  tasks[1](); await flush();
  assert.equal(p.video.paused,false);
  assert.equal(recoveries,1);
  p.player.autoplayWanted=false;
  p.video.paused=true;
  tasks[2](); await flush();
  assert.equal(p.video.paused,true);
  assert.equal(recoveries,1);
});

test('explicit Pause during layer recovery is respected',async()=>{
  let plays=0,p;
  const v={paused:false,readyState:2,webkitPresentationMode:'inline',style:{},
    setAttribute:()=>{},getBoundingClientRect:()=>({}),play:async()=>{plays++;}};
  p=Object.create(directPrototype({requestAnimationFrame:callback=>{
    p.autoplayWanted=false;v.paused=true;callback();
  }}));
  Object.assign(p,{v,autoplayWanted:true,current:()=>30,duration:()=>120,wakeVideoLayer:()=>{}});
  assert.equal(await p.relatchInlineVideoLayer(),false);
  assert.equal(plays,0);
});

test('Home uses native ownership without destroying video or starting HTML audio',async()=>{
  const f=fixture(),p=f.player('native',true);let starts=0,pauses=0;
  p.player={autoplayWanted:true,pause:stop=>{assert.equal(stop,false);pauses++;}};
  p.setMuted=async value=>{p.video.muted=value;};
  f.state.watchVimeo=p;f.context.nativeBackgroundAudioAvailable=()=>true;
  f.context.IrgunBackgroundAudio={beginBackground:async()=>{starts++;}};
  f.context.keepVideoPlayingOnBackground('home');await flush();
  assert.equal(starts,1);assert.equal(pauses,1);assert.equal(p.video.muted,true);
  assert.equal(f.state.watchVimeo,p);assert.equal(p.destroyed,false);assert.equal(f.observations.handoffs,0);
});

test('Home does not start native audio after explicit Pause',async()=>{
  const f=fixture(),p=f.player('paused');p.player={autoplayWanted:false};f.state.watchVimeo=p;
  f.context.nativeBackgroundAudioAvailable=()=>true;
  f.context.IrgunBackgroundAudio={beginBackground:()=>{throw new Error('must not start');}};
  f.context.keepVideoPlayingOnBackground('home');assert.equal(f.state.nativeBackgroundPending,undefined);
});

function nativeFixture(){
  const f=fixture(),calls=[];
  f.context.Capacitor.isPluginAvailable=()=>true;
  f.context.IrgunBackgroundAudio={prepare:async x=>{calls.push(['prepare',x]);},stop:async x=>{calls.push(['stop',x]);},getState:async()=>({id:'A',active:true,playing:true,position:80})};
  vm.runInContext(extract("let nativeBackgroundLastSync =",'function setupMediaSession('),f.context);
  const p=f.player('native',true);p.player={autoplayWanted:true,v:p.video,sources:{hls:'https://example.test/master.m3u8'}};
  p.setMuted=async x=>{calls.push(['mute',x]);p.video.muted=x;};
  f.state.watchVimeo=p;return {...f,p,calls};
}
test('native return uses actual native clock and stops audio before unmuting video',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=true;f.p.video.muted=true;
  await f.context.restoreNativeBackgroundVideo();
  assert.equal(f.p.video.currentTime,80);assert.equal(f.p.video.paused,false);
  assert.deepEqual(f.calls.map(x=>x[0]),['stop','mute']);assert.equal(f.p.video.muted,false);
  assert.equal(f.state.nativeBackgroundPending,false);
});
test('Home return rebuilds the video decoder after releasing native audio',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=true;f.p.video.muted=true;
  f.p.player.reloadInlineVideo=async()=>{assert.equal(f.calls[0][0],'stop');assert.equal(f.calls[0][1].clear,true);assert.equal(f.p.video.muted,true);assert.equal(f.p.video.currentTime,80);f.calls.push(['reload']);return true;};
  await f.context.restoreNativeBackgroundVideo();
  assert.deepEqual(f.calls.map(x=>x[0]),['stop','reload','mute']);
});

test('Pause during decoder reload keeps the saved clock without restarting',async()=>{
  const {p}=decoderFixture();let plays=0;
  p.meta=async()=>{p.pause();};p.play=async()=>{plays++;};
  assert.equal(await p.reloadInlineVideo(),false);assert.equal(p.v.currentTime,62);assert.equal(p.v.paused,true);assert.equal(plays,0);
});

test('recovery never starts an explicitly paused video',async()=>{
  const p=Object.create(directPrototype());let calls=0;
  Object.assign(p,{destroyed:false,autoplayWanted:false,show:()=>{calls++;},play:async()=>{calls++;}});
  assert.equal(await p.ensureVisualPlayback(true),false);
  assert.equal(await p.recoverVisualPlayback(true),false);assert.equal(calls,0);
});
test('concurrent decoder reloads replace the surface only once',async()=>{
  const {p}=decoderFixture();let finish;
  p.meta=()=>new Promise(done=>{finish=done;});
  const first=p.reloadInlineVideo(),second=p.reloadInlineVideo();
  assert.equal(p.decoderReloads,1);finish();
  assert.equal(await first,true);assert.equal(await second,true);assert.equal(p.decoderReloads,1);
});
test('adapter transfers PiP events to the replacement video',()=>{
  const c=vm.createContext({console});
  vm.runInContext(extract('class IosDirectVideoAdapter {','async function createIosWatchPlayer(')+'\nthis.Adapter=IosDirectVideoAdapter;',c);
  const adapter=Object.create(c.Adapter.prototype);let enters=0;
  adapter.onEnterPip=()=>enters++;adapter.onLeavePip=()=>{};adapter.onWebkitPresentationModeChanged=()=>{};
  const video=()=>({handlers:new Map(),addEventListener(name,fn){this.handlers.set(name,fn);},removeEventListener(name){this.handlers.delete(name);}});
  const old=video(),next=video();adapter.setVideoElement(old);adapter.setVideoElement(next);
  assert.equal(adapter.video,next);assert.equal(old.handlers.size,0);assert.equal(next.handlers.size,3);
  next.handlers.get('enterpictureinpicture')();assert.equal(enters,1);
});
test('native remote Pause is preserved on return',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=true;
  f.context.IrgunBackgroundAudio.getState=async()=>({id:'A',active:true,playing:false,position:80});
  f.p.pause=async()=>{f.p.video.paused=true;f.p.player.autoplayWanted=false;};
  await f.context.restoreNativeBackgroundVideo();assert.equal(f.p.video.paused,true);assert.equal(f.p.video.currentTime,80);
});
test('native Home return works when JS background event was suspended',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=false;f.p.video.muted=false;
  await f.context.restoreNativeBackgroundVideo();
  assert.equal(f.p.video.currentTime,80);assert.equal(f.p.video.paused,false);
  assert.deepEqual(f.calls.map(x=>x[0]),['mute','stop','mute']);
  assert.equal(f.calls[0][1],true);assert.equal(f.calls[2][1],false);
});
test('closing playback cancels an outstanding native-state request',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=true;let resolve;
  f.context.IrgunBackgroundAudio.getState=()=>new Promise(done=>{resolve=done;});
  const returning=f.context.restoreNativeBackgroundVideo();f.context.stopNativeBackgroundAudio();
  resolve({id:'A',active:true,playing:true,position:80});await returning;
  assert.equal(f.p.video.currentTime,30);assert.deepEqual(f.calls.map(x=>x[0]),['stop']);
});
test('native return preserves a previously muted video',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=true;f.state.nativeBackgroundMuted=true;
  await f.context.restoreNativeBackgroundVideo();assert.equal(f.p.video.muted,true);
});
test('late native return cannot seek or stop a newer shiur',async()=>{
  const f=nativeFixture();f.state.nativeBackgroundPending=true;let resolve;
  f.context.IrgunBackgroundAudio.getState=()=>new Promise(done=>{resolve=done;});
  const returning=f.context.restoreNativeBackgroundVideo();f.state.watchVimeo=f.player('new');f.state.watchVimeoGeneration++;
  resolve({id:'A',active:true,playing:true,position:80});await returning;
  assert.equal(f.p.video.currentTime,30);assert.equal(f.calls.length,0);
});

test('fullscreen late pauses resume only when playback intent remains Play',async()=>{
  const tasks=[],p=Object.create(directPrototype({setTimeout:fn=>{tasks.push(fn);return tasks.length;},clearTimeout:()=>{}}));
  let recovered=0;Object.assign(p,{fullscreenResumeWanted:true,autoplayWanted:true,v:{paused:true,ended:false},ensureVisualPlayback:async()=>{recovered++;}});
  p.recoverFullscreenExit();tasks[1]();await flush();assert.equal(recovered,1);
  p.autoplayWanted=false;tasks[2]();await flush();assert.equal(recovered,1);
});

test('double tap seeks without a single-tap Pause and swipe cancels its pending tap',async()=>{
  const tasks=[],cancelled=new Set(),p=Object.create(directPrototype({setTimeout:fn=>{tasks.push(fn);return tasks.length;},clearTimeout:id=>cancelled.add(id)}));
  const seeks=[];let toggles=0,minimized=0,exits=0;
  const v={style:{},getBoundingClientRect:()=>({left:0,width:400}),setPointerCapture:()=>{}};
  Object.assign(p,{v,playBtn:{onclick:()=>toggles++},seekBy:x=>{seeks.push(x);},exitFullscreen:()=>exits++,cb:{onMinimize:()=>minimized++}});
  p.bindVideoGestures();v.onclick({clientX:320});v.onclick({clientX:320});
  assert.deepEqual(seeks,[15]);assert.ok(cancelled.has(1));assert.equal(toggles,0);
  v.onclick({clientX:80});v.onclick({clientX:80});assert.deepEqual(seeks,[15,-15]);
  v.onclick({clientX:200});v.onpointerdown({pointerId:1,clientX:200,clientY:0});
  v.onpointerup({pointerId:1,clientX:200,clientY:90,preventDefault:()=>{}});
  assert.equal(minimized,1);assert.equal(exits,1);assert.ok(cancelled.has(tasks.length));
  v.onclick({clientX:200});assert.equal(toggles,0);
});

test('touch double taps seek even when WebKit coalesces compatibility clicks',async()=>{
  const tasks=[],cancelled=new Set(),p=Object.create(directPrototype({setTimeout:fn=>{tasks.push(fn);return tasks.length;},clearTimeout:id=>cancelled.add(id)}));
  const seeks=[];let toggles=0;
  const v={style:{},getBoundingClientRect:()=>({left:0,width:400}),setPointerCapture:()=>{}};
  Object.assign(p,{v,playBtn:{onclick:()=>toggles++},seekBy:x=>seeks.push(x),cb:{}});
  p.bindVideoGestures();
  const tap=x=>{v.onpointerdown({pointerId:1,pointerType:'touch',clientX:x,clientY:50});v.onpointerup({pointerId:1,clientX:x,clientY:50});};
  tap(320);v.onclick({clientX:320});tap(320);v.ondblclick({preventDefault:()=>{}});
  tap(80);tap(80);v.onclick({clientX:80});
  assert.deepEqual(seeks,[15,-15]);assert.equal(toggles,0);
  tasks.forEach((task,i)=>{if(!cancelled.has(i+1))task();});assert.equal(toggles,0);
});

test('explicit Pause prevents native autoplay from restarting a buffered seek',async()=>{
  const p=Object.create(directPrototype());let time=30,plays=0;
  const v={autoplay:true,paused:false,pause(){this.paused=true;},removeAttribute:()=>{}};
  Object.assign(p,{v,autoplayWanted:true,token:1,current:()=>time,seekTo:async x=>{time=x;if(v.autoplay)v.paused=false;},play:async()=>{plays++;v.paused=false;},showSeekFeedback:()=>{}});
  p.pause();await p.seekBy(-15);
  assert.equal(time,15);assert.equal(v.paused,true);assert.equal(plays,0);
});
