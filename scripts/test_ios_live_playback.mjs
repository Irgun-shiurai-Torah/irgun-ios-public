import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const main=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
const code=main.slice(main.indexOf('let liveAnalyticsFrame = null;'),main.indexOf('\nfunction liveStreamHtml('));
const settle=async()=>{for(let i=0;i<12;i++) await Promise.resolve();};

function harness({ios=true,native=true,watchVideo=null}={}) {
  const calls=[],players=[],events={},windowEvents={};
  let frame={},failNext=false;
  let analytics={shiurId:''};
  const document={hidden:false,addEventListener:(name,fn)=>{events[name]=fn;}};
  const state={screen:'live-boro',watchVideo,watchMode:'video'};
  class Player {
    constructor(){this.handlers=new Map();this.paused=true;players.push(this);}
    on(name,fn){this.handlers.set(name,fn);}
    off(name){this.handlers.delete(name);}
    getPaused(){return this.pendingPaused || Promise.resolve(this.paused);}
    emit(name){this.handlers.get(name)?.();}
  }
  const context={IS_IOS:ios,Capacitor:{isNativePlatform:()=>native},document,state,
    app:{querySelector:()=>frame},console:{warn(){}},
    window:{Vimeo:{Player},addEventListener:(name,fn)=>{windowEvents[name]=fn;}},
    usageAnalytics:{state:()=>analytics,setMedia:value=>{analytics={...analytics,...value};}},
    IrgunVideoDisplay:{livePlayback:async ({playing})=>{
      calls.push(playing);
      if(failNext){failNext=false;throw Error('temporary bridge failure');}
    }}};
  vm.createContext(context);
  vm.runInContext(code,context);
  return {calls,players,document,state,events,windowEvents,
    attach:()=>context.syncLivePlaybackAnalytics(),
    sync:value=>context.syncLiveScreenAwake(value),
    replaceFrame:()=>{frame={};},removeFrame:()=>{frame=null;},
    failOnce:()=>{failNext=true;}};
}

test('actual live play keeps iOS awake and pause, end or error releases it',async()=>{
  const h=harness();h.attach();await settle();
  assert.deepEqual(h.calls,[],'A scheduled event alone does not hold the screen awake');
  for(const stop of ['pause','ended','error']){
    h.players[0].emit('play');h.players[0].emit('timeupdate');await settle();
    assert.equal(h.calls.at(-1),true);
    h.players[0].emit(stop);await settle();
    assert.equal(h.calls.at(-1),false);
  }
  assert.deepEqual(h.calls,[true,false,true,false,true,false]);
});

test('a retained paused recording does not prevent visible live playback keeping the screen awake',async()=>{
  const h=harness({watchVideo:{id:'retained-recording'}});
  h.attach();await settle();h.players[0].emit('playing');await settle();
  assert.deepEqual(h.calls,[true]);
});

test('hiding, returning and leaving live playback follows the real player state',async()=>{
  const h=harness();h.attach();await settle();
  const player=h.players[0];player.paused=false;player.emit('play');await settle();
  h.document.hidden=true;h.events.visibilitychange();await settle();
  h.document.hidden=false;h.events.visibilitychange();await settle();
  h.state.screen='home';h.removeFrame();h.attach();await settle();
  player.emit('timeupdate');await settle();
  assert.deepEqual(h.calls,[true,false,true,false]);
});

test('a late visibility response from the previous broadcast cannot wake the next paused broadcast',async()=>{
  const h=harness();h.attach();await settle();
  let resolve;
  h.players[0].pendingPaused=new Promise(done=>{resolve=done;});
  h.events.visibilitychange();
  h.replaceFrame();h.state.screen='live-flatbush';h.attach();await settle();
  resolve(false);await settle();
  assert.deepEqual(h.calls,[]);
});

test('a rejected native update is retried on the next actual playback event',async()=>{
  const h=harness();h.attach();await settle();h.failOnce();
  h.players[0].emit('play');await settle();
  h.players[0].emit('timeupdate');await settle();
  assert.deepEqual(h.calls,[true,true]);
});

test('web and Android live playback never call the iOS display plugin',async()=>{
  for(const options of [{ios:false},{native:false}]){
    const h=harness(options);h.attach();await settle();
    h.players[0].emit('playing');await settle();
    assert.deepEqual(h.calls,[]);
  }
});
