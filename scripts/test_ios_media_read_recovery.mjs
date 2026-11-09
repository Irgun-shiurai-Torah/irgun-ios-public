import test from 'node:test';
import assert from 'node:assert/strict';
import {openFirstPlayableIosAudio} from '../src/ios-audio-start.js';
import {downloadOfflineAudio} from '../src/offline-audio-download.js';

test('Direct Listen recovers a lost connection once on the same source', async () => {
  const calls=[];
  const source='https://fixture/audio/lecture-a';
  const result=await openFirstPlayableIosAudio([source],async url=>{
    calls.push(url);
    if(calls.length===1) throw Error('The network connection was lost.');
    return {playing:true,position:45};
  },()=>true,()=>assert.fail('The original source is still playable'),{delay:async()=>{}});
  assert.deepEqual(calls,[source,source]);
  assert.equal(result.snapshot.position,45);
});

test('a second lost connection is reported and cancelled audio cannot restart', async () => {
  let calls=0;
  await assert.rejects(openFirstPlayableIosAudio(['https://fixture/audio'],async()=>{
    calls++;throw Error('The network connection was lost.');
  },()=>true,()=>{},{delay:async()=>{}}),/network connection was lost/);
  assert.equal(calls,2);
  let current=true;
  calls=0;
  await assert.rejects(openFirstPlayableIosAudio(['https://fixture/audio'],async()=>{
    calls++;throw Error('The network connection was lost.');
  },()=>current,()=>{},{delay:async()=>{current=false;}}),/superseded/);
  assert.equal(calls,1);
});

test('a rejected offline connection cleans its partial file before one retry', async () => {
  const operations=[];let calls=0,bytes=0;
  const result=await downloadOfflineAudio({
    removePartial:async()=>{operations.push('remove');bytes=0;},
    download:async()=>{
      operations.push('download');calls++;
      assert.equal(bytes,0,'A retry starts with no partial file');
      if(calls===1){bytes=1024;throw Object.assign(Error('Failed to connect to server.'),{code:'OS-PLUG-FLTR-0008'});}
      bytes=90000;return {path:'/real/native/file.mp3'};
    },
    stat:async()=>({size:bytes}),
    delay:async()=>operations.push('wait')
  });
  assert.deepEqual(operations,['remove','download','remove','wait','remove','download']);
  assert.equal(result.bytes,90000);
});

test('offline HTTP/permission errors are not blindly retried', async () => {
  for(const error of [Object.assign(Error('Forbidden'),{httpStatus:403}),
    Object.assign(Error('No storage permission'),{code:'OS-PLUG-FLTR-0004'})]){
    let calls=0;
    await assert.rejects(downloadOfflineAudio({
      download:async()=>{calls++;throw error;},stat:async()=>assert.fail('No file was downloaded'),
      removePartial:async()=>{},delay:async()=>assert.fail('Permanent errors must not retry')
    }),e=>e===error);
    assert.equal(calls,1);
  }
});

test('offline transfer cannot claim success from progress or a tiny/missing native file', async () => {
  for(const size of [0,1024]){
    let removed=0;
    await assert.rejects(downloadOfflineAudio({
      download:async()=>({size:80000000}),stat:async()=>({size}),
      removePartial:async()=>{removed++;}
    }),/not a usable lecture file/);
    assert.equal(removed,2,'Remove an unusable file after checking actual Filesystem.stat');
  }
});

test('persistent native connection failure stays failed after the bounded retry', async () => {
  let calls=0;
  await assert.rejects(downloadOfflineAudio({
    download:async()=>{calls++;throw Object.assign(Error('The network connection was lost.'),{code:8});},
    stat:async()=>assert.fail('No successful native transfer'),
    removePartial:async()=>{},delay:async()=>{}
  }),/connection was lost/);
  assert.equal(calls,2);
});
