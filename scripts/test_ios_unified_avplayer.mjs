import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createIosUnifiedAVPlayer,createIosNativeVideoAdapter} from '../src/ios-native-avplayer.js';

function testEngine({ios=true, nativeFail=false}={}){
  const calls=[],watchers={};let epoch=0,now=40,mode='video',playing=false,rate=1,id='',url='';
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
  function snap(){return {id,position:now,duration:3600,mode,playing,active:Boolean(id),rate,itemEpoch:epoch,sameItem:Boolean(id)};}
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
  assert.match(swift,/player\.playImmediately\(atRate: self\.playbackRate\)/);
  assert.match(swift,/targetHeight = waiting\.targetHeight|qualityHeight = waiting\.targetHeight/);
  assert.doesNotMatch(swift,/preferredMaximumResolution = CGSize\(/);
});
