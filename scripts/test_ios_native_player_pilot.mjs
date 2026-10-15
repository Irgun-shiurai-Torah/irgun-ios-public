import test from 'node:test';
import assert from 'node:assert/strict';
import { createIosNativePlayerPilot, NATIVE_PILOT_STORAGE_KEY } from '../src/ios-native-player-pilot.js';

const ios = { getPlatform:() => 'ios', isNativePlatform:() => true };
const disabled = { getItem:() => null };
const enabled = { getItem:key => key === NATIVE_PILOT_STORAGE_KEY ? '1' : null };

function makePilot({ hls = 'https://api.irgunshiuraitorah.com/media/test/master.m3u8',
                     storage = enabled, brokenOpen = false } = {}) {
  const calls = [], effects = [];
  let clock = 45, playing = true, mode = 'video';
  let listener = null;
  const native = {
    async addListener(event, fn) {
      assert.equal(event, 'state');
      listener = fn;
      return { remove: async () => { listener = null; } };
    },
    async open(options) {
      calls.push(['open', options]);
      if (brokenOpen) throw new Error('AVPlayer failed');
      return {id:options.id,position:clock,playing,mode};
    },
    async getState() { return {position:clock,playing,mode}; },
    async stop() { calls.push(['stop']); playing = false; return {}; },
    async play() { calls.push(['play']); playing = true; return {position:clock,playing,mode}; },
    async pause() { calls.push(['pause']); playing = false; return {position:clock,playing,mode}; },
    async seek(args) { calls.push(['seek',args]); clock=args.position; return {position:clock,playing,mode}; },
    async setRate(args) { calls.push(['rate',args]); return {position:clock,playing,mode,rate:args.rate}; },
    async setMode(args) { calls.push(['mode',args]); mode=args.mode; return {position:clock,playing,mode}; },
    async setLayout(args) { calls.push(['layout',args]); return {position:clock,playing,mode}; }
  };
  const pilot = createIosNativePlayerPilot({
    capacitor:ios,
    registerPlugin:name => { assert.equal(name,'IrgunUnifiedPlayer'); return native; },
    storage,
    getCurrent:() => ({video:{id:'test',title:'Test shiur'},position:clock,rate:1}),
    loadVideoSources:async () => ({hls}),
    releaseLegacy:async () => { effects.push('legacy released'); },
    restoreLegacy:async s => { effects.push(['legacy restored',s]); },
    stageRect:() => ({x:0,y:120,width:360,height:203})
  });
  return {pilot,calls,effects,get listener(){return listener;}};
}

test('native player pilot is disabled for users by default', () => {
  assert.equal(makePilot({storage:disabled}).pilot,null);
  assert.equal(createIosNativePlayerPilot({
    capacitor:{getPlatform:()=> 'android',isNativePlatform:()=>true},
    registerPlugin:()=>{throw Error('Must not be called')},storage:enabled
  }),null);
});

test('native pilot opens HLS once and switches Audio/Video on same AVPlayer item',async () => {
  const {pilot,calls,effects}=makePilot();
  await pilot.openCurrent();
  assert.equal(pilot.active,true);
  assert.equal(calls.filter(x=>x[0]==='open').length,1);
  assert.ok(calls[0][1].url.endsWith('.m3u8'));
  assert.deepEqual(effects,['legacy released']);
  await pilot.mode('audio');
  assert.equal((await pilot.snapshot()).position,45);
  await pilot.mode('video');
  assert.equal((await pilot.snapshot()).position,45);
  assert.equal(calls.filter(x=>x[0]==='open').length,1,'Mode must not reload media');
  await pilot.seek(120);
  assert.equal((await pilot.snapshot()).position,120);
  await pilot.rate(1.5);
  await pilot.layout('mini',{x:200,y:600,width:160,height:90});
  await pilot.pause();
  await pilot.play();
  const finalState=await pilot.stop(true);
  assert.equal(finalState.position,120);
  assert.equal(pilot.active,false);
  assert.equal(effects[1][0],'legacy restored');
  assert.equal(effects[1][1].position,120);
});

test('HLS must exist before stopping legacy playback',async () => {
  const {pilot,calls,effects}=makePilot({hls:''});
  await assert.rejects(pilot.openCurrent(),/no HLS source/i);
  assert.deepEqual(effects,[]);
  assert.equal(calls.filter(x=>x[0]==='open').length,0);
});

test('failing native open restores legacy owner without masking failure',async () => {
  const {pilot,calls,effects}=makePilot({brokenOpen:true});
  await assert.rejects(pilot.openCurrent(),/AVPlayer failed/);
  assert.equal(pilot.active,false);
  assert.deepEqual(effects.map(x=>Array.isArray(x)?x[0]:x),
    ['legacy released','legacy restored']);
  assert.ok(calls.some(x=>x[0]==='stop'));
});

test('one active session cannot open a duplicate source',async () => {
  const {pilot,calls}=makePilot();
  await pilot.openCurrent();
  await pilot.openCurrent();
  assert.equal(calls.filter(x=>x[0]==='open').length,1);
  await pilot.stop(false);
});
