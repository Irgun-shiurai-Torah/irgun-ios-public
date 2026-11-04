import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createIosUnifiedAVPlayer,createIosNativeVideoAdapter,openNativeWithTransientTlsRetry} from '../src/ios-native-avplayer.js';

function testEngine({ios=true, nativeFail=false}={}){
  const calls=[],watchers={};let epoch=0,now=40,mode='video',playing=false,rate=1,id='',url='',sequence=0;
  const native={
    addListener:async(name,fn)=>{watchers[name]=fn;return {remove:async()=>{delete watchers[name];}};},
    open:async opts=>{
      calls.push(['open',opts]);
      if(nativeFail)throw Error('Native decoder refused URL');
      if(id!==opts.id||url!==opts.url)epoch++;
      id=opts.id;url=opts.url;now=opts.position;mode=opts.mode;
      playing=opts.autoplay;rate=opts.rate;return snap();
    },
    getState:async()=>snap(),
    setMode:async opts=>{calls.push(['mode',opts.mode]);mode=opts.mode;return snap();},
    setRate:async opts=>{calls.push(['rate',opts.rate]);rate=opts.rate;return snap();},
    setLayout:async opts=>{calls.push(['layout',opts.layout,opts.rect]);return snap();},
    setQuality:async opts=>{calls.push(['quality',opts.height]);return snap();},
    enterPiP:async()=>{calls.push(['pip']);return snap();},
    seek:async opts=>{calls.push(['seek',opts.position]);now=opts.position;return snap();},
    play:async()=>{calls.push(['play']);playing=true;return snap();},
    pause:async()=>{calls.push(['pause']);playing=false;return snap();},
    stop:async()=>{calls.push(['stop']);id='';url='';playing=false;return snap();}
  };
  function snap(){return {id,position:now,duration:3600,mode,playing,active:Boolean(id),rate,itemEpoch:epoch,sameItem:Boolean(id),stateSequence:++sequence};}
  const notifications=[];
  const engine=createIosUnifiedAVPlayer({
    capacitor:{getPlatform:()=>ios?'ios':'android',isNativePlatform:()=>true},
    registerPlugin:name=>{assert.equal(name,'IrgunUnifiedPlayer');return native;},
    onState:s=>notifications.push(s)
  });
  return {engine,calls,watchers,notifications,native};
}
const url='https://api.irgunshiuraitorah.com/media/123/master.m3u8';

test('single native iOS player is only registered for native iOS',()=>{
  assert.equal(testEngine({ios:false}).engine,null);
  assert.ok(testEngine().engine);
});
test('one AVPlayer survives Video, Audio, Mini, Full, quality and PiP',async()=>{
  const t=testEngine(),e=t.engine;
  await e.open({id:'video:123',url,position:40,rate:1,autoplay:true});
  const adapter=createIosNativeVideoAdapter(e,'video:123');
  assert.equal(await adapter.getCurrentTime(),40);
  await e.mode('audio');await e.layout('mini',{x:3,y:11,width:80,height:50});
  await e.seek(61);await e.speed(1.5);await e.mode('video');
  await e.layout('full',{x:0,y:0,width:320,height:640});await e.quality(720);await e.pip();
  assert.equal(t.calls.filter(x=>x[0]==='open').length,1,'No duplicate native players');
  assert.equal(e.state.itemEpoch,1,'Presentation changes alone must retain the current item');
  assert.equal(e.state.position,61);assert.equal(e.state.rate,1.5);
  await e.open({id:'video:123',url,position:null,rate:1.5,autoplay:true});
  assert.equal(t.calls.filter(x=>x[0]==='open').length,1,'Reopening same source cannot reload');
  await adapter.pause();assert.equal(await adapter.getPaused(),true);
  await adapter.play();assert.equal(await adapter.getPaused(),false);
  await adapter.destroy();
});
test('opening a different shiur replaces an item but never creates a second AVPlayer',async()=>{
  const t=testEngine(),e=t.engine;
  await e.open({id:'video:123',url,position:15});
  await e.open({id:'audio:other',url:'https://api.irgunshiuraitorah.com/audio/456',mode:'audio',position:0});
  assert.equal(t.calls.filter(x=>x[0]==='open').length,2,'A new media item must be opened');
  assert.equal(e.state.itemEpoch,2,'New item replaces old item on same AVPlayer');
  assert.equal(e.id,'audio:other');
  await e.stop();
  assert.equal(t.calls.filter(x=>x[0]==='stop').length,1);
});
test('failed native open never starts WebKit fallback or claims AVPlayer is active',async()=>{
  const t=testEngine({nativeFail:true});
  await assert.rejects(t.engine.open({id:'video:123',url}),/Native decoder refused URL/);
  assert.equal(t.engine.active,false);
  assert.equal(t.calls.filter(x=>x[0]==='open').length,1);
});
test('Android does not register or instantiate iOS native playback',()=>assert.equal(testEngine({ios:false}).engine,null));

test('a delayed layout reply cannot overwrite a newer native speed selection',async()=>{
  const t=testEngine();await t.engine.open({id:'video:123',url});
  let finish;
  const old={...t.engine.state};
  t.native.setLayout=()=>new Promise(resolve=>{finish=resolve;});
  const layout=t.engine.layout('inline',{});
  await t.engine.speed(1.5);
  const notifications=t.notifications.length;
  finish(old);await layout;
  assert.equal(t.engine.state.rate,1.5);
  assert.equal(t.notifications.length,notifications,'Do not persist or publish the old speed again');
});
test('out-of-order native events cannot roll back playback intent or rate',async()=>{
  const t=testEngine();await t.engine.open({id:'video:123',url,autoplay:true});
  const old={...t.engine.state};
  await t.engine.speed(1.5);await t.engine.pause();
  t.watchers.state(old);
  assert.equal(t.engine.state.playing,false);
  assert.equal(t.engine.state.rate,1.5);
});
test('a queued active event from before stop cannot resurrect the stopped player',async()=>{
  const t=testEngine();await t.engine.open({id:'video:123',url,autoplay:true});
  const old={...t.engine.state};await t.engine.stop();
  t.watchers.state(old);assert.equal(t.engine.active,false);
});
test('an older open reply cannot rename a newer source for the same lecture',async()=>{
  const t=testEngine();await t.engine.open({id:'video:123',url});
  let finishFirst;const base=t.engine.state.stateSequence;
  t.native.open=options=> options.url.endsWith('first.mp4')
    ? new Promise(resolve=>{finishFirst=()=>resolve({...t.engine.state,stateSequence:base+1});})
    : Promise.resolve({...t.engine.state,stateSequence:base+2});
  const first=t.engine.open({id:'video:123',url:'https://fixture/first.mp4'});
  await Promise.resolve();
  await t.engine.open({id:'video:123',url:'https://fixture/newest.mp4'});
  finishFirst();await first;
  assert.equal(t.engine.state.sourceUrl,'https://fixture/newest.mp4');
});
test('native playback toolbar receives direct callbacks and does not allocate a player',async()=>{
  const calls=[];
  const t=testEngine(),engine=createIosUnifiedAVPlayer({
    capacitor:{getPlatform:()=> 'ios',isNativePlatform:()=>true},
    registerPlugin:()=>t.native,
    onMinimize:()=>calls.push('mini'),
    onFullscreen:value=>calls.push(Boolean(value.fullscreen)?'full':'inline'),
    onPiPUnavailable:()=>calls.push('pip-unavailable')
  });
  await engine.open({id:'video:123',url,position:0});
  t.watchers.requestMinimize({});
  t.watchers.requestFullscreen({fullscreen:true});
  t.watchers.pipUnavailable({});
  assert.deepEqual(calls,['mini','full','pip-unavailable']);
  assert.equal(t.calls.filter(x=>x[0]==='open').length,1);
});

test('manual HLS resolution uses a narrowed source and restores the original master on Auto',()=>{
  const swift=readFileSync(new URL('./IrgunUnifiedPlayerPlugin.swift',import.meta.url),'utf8');
  assert.match(swift,/class IrgunFixedHLSManifest/);
  assert.match(swift,/let narrowed = IrgunFixedHLSManifest\(master: master/);
  assert.match(swift,/AVPlayerItem\(asset: narrowed\.makeAsset\(\)\)/);
  assert.match(swift,/nextItem = AVPlayerItem\(url: original\)/);
  assert.match(swift,/player\.replaceCurrentItem\(with: nextItem\)/);
  assert.match(swift,/desiredPosition: previousPosition/);
  assert.match(swift,/player\.seek\(to: CMTime\(seconds: change\.desiredPosition/);
  assert.match(swift,/if self\.playingWanted \{ self\.playIfAllowed\(\) \}/);
  assert.match(swift,/targetHeight = waiting\.targetHeight|qualityHeight = waiting\.targetHeight/);
  assert.doesNotMatch(swift,/preferredMaximumResolution = CGSize\(/);
});


test('native HLS waiting is not misreported as Pause, but calls and user pauses still are',async()=>{
  const t=testEngine(),e=t.engine;
  await e.open({id:'video:123',url,autoplay:true});
  const adapter=createIosNativeVideoAdapter(e,'video:123');
  const events=[];
  for(const name of ['play','pause','waiting'])adapter.on(name,()=>events.push(name));
  const publish = value => t.watchers.state({...e.state,...value,
    stateSequence:(Number(e.state.stateSequence)||0)+1});
  publish({playing:true,playRequested:true,interrupted:false,failed:false});
  assert.deepEqual(events,['play']);
  publish({playing:false,playRequested:true,interrupted:false,failed:false});
  assert.deepEqual(events,['play','waiting'],
    'temporary buffering must not generate an explicit Pause event');
  publish({playing:true,playRequested:true,interrupted:false,failed:false});
  assert.deepEqual(events,['play','waiting'],
    'resuming from a buffer must not double-count an uninterrupted play');
  publish({playing:false,playRequested:true,interrupted:true,failed:false});
  assert.deepEqual(events,['play','waiting','pause'],
    'a genuine phone/WhatsApp interruption must remain a pause');
  publish({playing:true,playRequested:true,interrupted:false,failed:false});
  assert.deepEqual(events,['play','waiting','pause','play']);
  publish({playing:false,playRequested:false,interrupted:false,failed:false});
  assert.deepEqual(events,['play','waiting','pause','play','pause']);
  await adapter.destroy();
});

test('native iOS awake policy survives HLS buffering but respects calls, pauses and failures',()=>{
  const main=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
  const start=main.indexOf('let iosVideoDisplayKey =');
  const end=main.indexOf('let iosVideoOrientationListenerAttached =',start);
  assert.ok(start>=0 && end>start,'Expected iOS awake-policy implementation');
  const policy=main.slice(start,end);
  const calls=[];
  const state={watchVideo:{id:'123'},watchMode:'video',watchVideoPlaying:false,
    watchMinimized:false,watchPictureInPicture:false,watchVimeo:null};
  const iosUnified={active:true,state:{mode:'video',playing:false,
    playRequested:true,interrupted:false,failed:false}};
  const display={playback:params=>{calls.push(params);return Promise.resolve();}};
  const sync=new Function('IS_IOS','Capacitor','state','iosUnified',
    'iosNativeActive','IrgunVideoDisplay',
    policy+'\nreturn syncIosVideoDisplay;'
  )(true,{isNativePlatform:()=>true},state,iosUnified,()=>iosUnified.active,display);
  sync();
  assert.equal(calls.at(-1).playing,true,
    'temporary HLS buffering must not enable the automatic screen lock');
  iosUnified.state.interrupted=true;
  sync();
  assert.equal(calls.at(-1).playing,false,
    'the screen must not be kept awake by a paused phone/WhatsApp call');
  iosUnified.state.interrupted=false;
  iosUnified.state.playRequested=false;
  sync();
  assert.equal(calls.at(-1).playing,false,'user Pause remains paused');
  iosUnified.state.playRequested=true;
  iosUnified.state.failed=true;
  sync();
  assert.equal(calls.at(-1).playing,false,'failed media cannot hold the screen awake');
  iosUnified.state.failed=false;
  sync();
  assert.equal(calls.at(-1).playing,true,'a new Play request restores the awake policy');
  state.watchMode='audio';
  sync();
  assert.equal(calls.at(-1).active,false,'audio mode does not claim video screen awake');
  const swift=readFileSync(new URL('./IrgunUnifiedPlayerPlugin.swift',import.meta.url),'utf8');
  assert.match(swift,/"interrupted": playbackIsBlockedByCall/);
});


test('native TLS handshake retries exactly once without changing the lecture',async()=>{
  let calls=0,waits=0;
  const result=await openNativeWithTransientTlsRetry(async()=>{
    calls++;
    if(calls===1)throw Error('Native media is not playable: A TLS error caused the secure connection to fail.');
    return {id:'video:123',position:42,playing:true};
  },{delay:async ms=>{assert.equal(ms,1200);waits++}});
  assert.equal(calls,2);
  assert.equal(waits,1);
  assert.deepEqual(result,{id:'video:123',position:42,playing:true});
});

test('native persistent TLS and non-network media failures never fake a player',async()=>{
  let calls=0;
  await assert.rejects(openNativeWithTransientTlsRetry(async()=>{
    calls++;throw Error('A TLS error caused the secure connection to fail.');
  },{delay:async()=>{}}),/TLS error/);
  assert.equal(calls,2,'Persistent TLS failure must remain a real failure after one retry');
  calls=0;
  await assert.rejects(openNativeWithTransientTlsRetry(async()=>{
    calls++;throw Error('AVPlayer unsupported codec');
  },{delay:async()=>{}}),/unsupported codec/);
  assert.equal(calls,1,'Codec failures must not be treated as temporary network errors');
});

test('native transient retry cancels when the Watch lecture was replaced',async()=>{
  let calls=0,active=true;
  await assert.rejects(openNativeWithTransientTlsRetry(async()=>{
    calls++;throw Error('TLS error');
  },{isCurrent:()=>active,delay:async()=>{active=false}}),/cancelled/);
  assert.equal(calls,1,'Retry cannot reopen a superseded lecture');
});

test('the real simulator UI taps an onscreen UIKit speed action and verifies the native rate',()=>{
  const swift=readFileSync(new URL('./IrgunUnifiedPlayerPlugin.swift',import.meta.url),'utf8');
  const tests=readFileSync(new URL('../.github/regression/tests.swift',import.meta.url),'utf8');
  assert.match(swift,/data\["speedMenuChoices"\] = nativeSpeedMenuChoices/);
  assert.match(swift,/findActionLabels\(in: alert\.view\)/);
  assert.match(tests,/app\.coordinate\(withNormalizedOffset: \.zero\)/);
  assert.match(tests,/Native speed popover closed after real menu selection/);
  assert.doesNotMatch(tests,/app\.popovers\.buttons\[title\]/,
    'Avoid iOS 26 iPad accessibility snapshot hangs while querying the menu');
});
