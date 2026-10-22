import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createIosUnifiedAVPlayer,createIosNativeVideoAdapter} from '../src/ios-native-avplayer.js';

// Execute the production Watch handlers, including native fallback selection.
const source=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
const between=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const closeStart=source.includes('let watchClosePromise = null;') ? 'let watchClosePromise = null;' : 'async function closeWatch(';
const handlers=[
  closeStart.startsWith('let') ? '' : 'let watchClosePromise = null;',
  between(closeStart,'\nfunction clearAudioMediaSessionHandlers'),
  between('async function createIosWatchPlayer(','\nasync function fallbackIosDirectVideoToVimeo'),
  between('function watchPlayerInitializationIsCurrent(','\nasync function loadComments'),
  between('async function openWatch(','\nfunction currentVideoClockForBackground')
].join('\n');
const factory=new Function('state','iosUnified','deps',`
  const {videoId,iosNativeActive,iosNativePosition,iosNativeDuration,saveHistory,
    clearPersistentVideoMount,syncIosVideoDisplay,render,stopNativeBackgroundAudio,
    preserveWatchTime,usageAnalytics,isIosVimeoOnlyLecture,iosVimeoWatchEngine,
    loadIosDirectVideoSources,displayShiurTitle,nativeVideoFrame,document,
    createIosNativeVideoAdapter,hardStopHtmlAudioForVideo,audioUrl,mediaApiId,API}=deps;
  ${handlers}
  return {closeWatch,openWatch,createIosWatchPlayer,initWatchVimeo,
    watchPlayerInitializationIsCurrent};
`);
const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};

function harness({loading=false,blockHistory=false,failHls=false,mode='video'}={}) {
  const frame={isConnected:true};
  const video={id:'1235946832',title:'Fixture shiur',hasDriveVideo:true};
  let lookups=0;
  const state={watchVideo:video,watchMode:mode,watchVimeoGeneration:1,
    watchVimeo:null,watchResumeSeconds:40,playbackSpeed:1,user:{id:1},
    videoById:{get(){lookups++;return undefined;}}};
  const openGate=deferred(),stopGate=deferred(),historyGate=deferred();
  const events={opens:[],stops:0,history:0};
  let nativeState={active:false},listeners={};
  const snap=()=>({...nativeState});
  const native={
    async addListener(name,callback){listeners[name]=callback;return {remove:async()=>{}};},
    async open(options){
      events.opens.push(options.url);
      nativeState={id:options.id,active:true,playing:true,mode:options.mode,
        position:40,duration:300,itemEpoch:events.opens.length};
      listeners.state(snap());
      if(loading && events.opens.length===1)return openGate.promise;
      if(failHls && events.opens.length===1)throw Error('HLS item is not playable');
      return snap();
    },
    async stop(){
      events.stops++;
      nativeState={active:false,id:'',playing:false};
      if(loading){openGate.reject(Error('Native media stopped'));await stopGate.promise;}
      return snap();
    }
  };
  const engine=createIosUnifiedAVPlayer({
    capacitor:{getPlatform:()=> 'ios',isNativePlatform:()=>true},registerPlugin:()=>native
  });
  const deps={videoId:v=>v.id,iosNativeActive:()=>engine.active,
    iosNativePosition:()=>40,iosNativeDuration:()=>300,
    saveHistory:async()=>{events.history++;if(blockHistory)await historyGate.promise;},
    clearPersistentVideoMount(){},syncIosVideoDisplay(){},render(){},
    stopNativeBackgroundAudio(){},preserveWatchTime:async()=>{},
    usageAnalytics:{setMedia(){}},isIosVimeoOnlyLecture:()=>false,
    iosVimeoWatchEngine:()=> 'native',
    loadIosDirectVideoSources:async()=>({hls:'https://fixture/master.m3u8',mp4:'https://fixture/video.mp4'}),
    displayShiurTitle:v=>v,nativeVideoFrame:()=>null,
    document:{getElementById:()=>frame},createIosNativeVideoAdapter,
    hardStopHtmlAudioForVideo(){},audioUrl:id=>'https://fixture/audio/'+id,
    mediaApiId:(_video,id)=>id,API:'https://fixture'};
  const api=factory(state,engine,deps);
  const initialization={generation:1,videoKey:video.id,frame};
  state.watchVimeoInitialization=initialization;
  const start=()=>api.createIosWatchPlayer(video,frame,40,true,
    ()=>api.watchPlayerInitializationIsCurrent(initialization));
  return {state,events,engine,api,start,historyGate,stopGate,
    get nativeActive(){return nativeState.active;},get lookups(){return lookups;}};
}

test('closing during native HLS loading cancels fallback before stop rejects the pending open',async()=>{
  const h=harness({loading:true});
  const opened=h.start().then(value=>({value}),error=>({error}));
  await flush();assert.equal(h.events.opens.length,1);
  const closing=h.api.closeWatch(false);
  await flush();
  assert.equal(h.events.stops,1);
  assert.equal(h.events.opens.length,1,'Closing must not launch the MP4/Vimeo fallback');
  h.stopGate.resolve();await closing;
  const result=await opened;
  assert.match(result.error?.message||'',/cancelled/);
  assert.equal(h.nativeActive,false);
  assert.equal(h.engine.active,false);
  assert.equal(h.state.watchVideo,null);
});

test('a genuine HLS failure still tries the working owned MP4 while Watch is current',async()=>{
  const h=harness({failHls:true});
  const result=await h.start();
  assert.equal(result.backend,'native');
  assert.deepEqual(h.events.opens,['https://fixture/master.m3u8','https://fixture/video.mp4']);
  assert.equal(h.nativeActive,true);
});

test('duplicate Close taps share one history write and native shutdown',async()=>{
  const h=harness({blockHistory:true});
  h.state.watchVimeo=(await h.start()).player;
  const first=h.api.closeWatch(),second=h.api.closeWatch();
  await flush();assert.equal(h.events.history,1);
  h.historyGate.resolve();await Promise.all([first,second]);
  assert.equal(h.events.stops,1);
  assert.equal(h.nativeActive,false);
});

test('new Watch navigation waits for the old shutdown before selecting its lecture',async()=>{
  const h=harness({blockHistory:true});
  h.state.watchVimeo=(await h.start()).player;
  const closing=h.api.closeWatch();
  const opening=h.api.openWatch('new-lecture');
  await flush();assert.equal(h.lookups,0);
  h.historyGate.resolve();await Promise.all([closing,opening]);
  assert.equal(h.lookups,1);
});

test('rendering while Close saves history cannot start another video initialization',async()=>{
  const h=harness({blockHistory:true});
  await h.start();
  const closing=h.api.closeWatch();await flush();
  await h.api.initWatchVimeo(true);
  assert.equal(h.events.opens.length,1);
  h.historyGate.resolve();await closing;
});

test('closing Watch Audio preserves the current native audio session',async()=>{
  const h=harness();
  // The shared native item keeps the video's ID during an Audio-mode handoff.
  h.state.watchVimeo=(await h.start()).player;
  h.state.watchMode='audio';
  await h.engine.native.open({id:'video:1235946832',mode:'audio',url:'https://fixture/master.m3u8'});
  await h.api.closeWatch(false);
  assert.equal(h.events.stops,0);
  assert.equal(h.nativeActive,true);
  assert.equal(h.state.current.native,true);
  assert.equal(h.state.watchVideo,null);
});
