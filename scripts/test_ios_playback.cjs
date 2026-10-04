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
    document:{hidden:false, pictureInPictureElement:null, getElementById:()=>frame},
    // No real timers are needed for these controlled transitions.
    setTimeout:()=>0, videoId:v=>v.id, hardStopHtmlAudioForVideo:()=>{},
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
    clearTimeout:timer=>cleared.push(timer)
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
