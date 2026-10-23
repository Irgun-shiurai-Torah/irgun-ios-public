import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fullAudioToVideoHandoff} from '../src/audio-to-video-handoff.js';

const native = (position, playing, id='1237352749') => ({
  active:true,mode:'audio',id:`audio:video-audio:${id}`,position,playing
});

test('iOS Full Audio → Watch uses native AVPlayer position, never parked HTML 0:00', () => {
  const result=fullAudioToVideoHandoff({
    videoId:'1237352749',useNative:true,nativeState:native(348.75,true),
    htmlPosition:0,htmlPaused:true
  });
  assert.deepEqual(result,{position:348.75,wasPlaying:true});
});

test('paused native Audio → Video preserves both timestamp and paused intent', () => {
  const result=fullAudioToVideoHandoff({
    videoId:'1237352749',useNative:true,nativeState:native(183.25,false),
    htmlPosition:0,htmlPaused:true
  });
  assert.deepEqual(result,{position:183.25,wasPlaying:false});
});

test('a different native lecture, ended item, or video mode cannot reset user progress', () => {
  const bad=[
    native(19,true,'different'),
    {...native(23,true),active:false},
    {...native(14,true),mode:'video'},
    null
  ];
  for(const snapshot of bad) assert.throws(
    ()=>fullAudioToVideoHandoff({
      videoId:'1237352749',useNative:true,nativeState:snapshot,htmlPosition:0
    }),/Native audio changed/
  );
});

test('HTML player still uses its own time; a pending seek takes priority', () => {
  assert.deepEqual(fullAudioToVideoHandoff({
    videoId:'1237352749',useNative:false,htmlPosition:72.5,htmlPaused:false
  }),{position:72.5,wasPlaying:true});
  assert.deepEqual(fullAudioToVideoHandoff({
    videoId:'1237352749',useNative:false,htmlPosition:72.5,
    pendingHtmlSeek:299,htmlPaused:true
  }),{position:299,wasPlaying:false});
});

test('zero and corrupted timestamps are safely clamped without switching sources', () => {
  assert.equal(fullAudioToVideoHandoff({
    videoId:'1237352749',useNative:true,nativeState:native(-15,false)
  }).position,0);
  assert.equal(fullAudioToVideoHandoff({
    videoId:'1237352749',useNative:true,nativeState:native(Infinity,true)
  }).position,0);
});

test('real Full Watch tap snapshots native position before relinquishing audio ownership',()=>{
  const source=readFileSync('src/main.js','utf8');
  const handler=source.slice(source.indexOf("document.querySelectorAll('[data-player-watch]')"),
    source.indexOf("const seek = document.getElementById('fullSeek')"));
  const snapshot=handler.indexOf('await iosUnified.snapshot()');
  const capture=handler.indexOf('fullAudioToVideoHandoff(');
  const release=handler.indexOf('hardStopHtmlAudioForVideo()');
  const start=handler.indexOf('await openWatch(id, handoff.position,');
  assert.ok(snapshot>0 && snapshot<capture && capture<release && release<start,
    'Capture fresh native clock/intent first; stop HTML ownership only after snapshot');
  assert.match(handler,/videoId:id, useNative:nativeAudio/);
  assert.match(handler,/fromAudio:true, wasPlaying:handoff.wasPlaying/);
  assert.match(source,/initWatchVimeo\(!fromAudio \|\| fromAudioWasPlaying, fromAudio\)/);
});
