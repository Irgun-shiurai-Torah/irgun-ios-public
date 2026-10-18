import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {buildPaidFolderTree, nextPaidTrackInFolder, paidFolderKey, BELSKY_VOL1_ID,
  paidFolderPath, parseBelskyIndex, findBelskyQuestions} from '../src/paid-collections.js';
import {paidFolderTreeHtml, paidQuestionResultsHtml} from '../src/paid-catalog-ui.js';
import {verifiedPurchasedIds, mergeVerifiedPaidCatalog} from '../src/paid-entitlements.js';
import {createPaidQuestionController} from '../src/paid-index-controller.js';

const main = readFileSync(new URL('../src/main.js', import.meta.url), 'utf8');
function appFunction(name) {
  const start = main.search(new RegExp('^(async )?function '+name+'\\(', 'm'));
  assert.ok(start >= 0, name);
  const tail = main.slice(start);
  const next = tail.slice(1).search(/^(?:async )?function /m);
  return next < 0 ? tail : tail.slice(0, next + 1);
}
const esc = text => String(text ?? '').replace(/[&<>"']/g, value => `&#${value.charCodeAt(0)};`);
const tracks = [
  {id:'10',title:'10 — Story',folders:['Volume 1','Stories']},
  {id:'2',title:'2 — Story',folders:['Volume 1','Stories']},
  {id:'1',title:'1 — Story',folders:['Volume 1','Stories']},
  {id:'other',title:'3 — Halacha',folders:['Volume 1','Halacha']}
];

test('owned folders preserve nested Drive paths and natural track order', () => {
  const tree = buildPaidFolderTree(tracks, 'stories');
  assert.equal(tree.count, 4);
  const folder = tree.folders[0].folders.find(node => node.name === 'Stories');
  assert.deepEqual(folder.tracks.map(entry => entry.track.id), ['1','2','10']);
  const html = paidFolderTreeHtml({id:'stories',owned:true,tracks}, {esc,
    openFolders:new Set([paidFolderKey('stories',['Volume 1','Stories'])])});
  assert.match(html, /<details[^>]* open>/);
  assert.ok(html.indexOf('data-paid-track="1"') < html.indexOf('data-paid-track="2"'));
  assert.ok(html.indexOf('data-paid-track="2"') < html.indexOf('data-paid-track="10"'));
  assert.equal(nextPaidTrackInFolder(tracks,'1').id,'2');
  assert.equal(nextPaidTrackInFolder(tracks,'10'),null);
});

test('public folder previews contain only names/counts even if private tracks were supplied', () => {
  const html = paidFolderTreeHtml({id:'stories',owned:false,tracks,
    folderPreview:[{folders:['Volume 1','Stories'],trackCount:3}]}, {esc});
  assert.match(html,/Stories/);
  assert.match(html,/3 tracks/);
  assert.doesNotMatch(html,/data-paid-track|playbackUrl|requires? (a )?purchase|buy|checkout/i);
});

test('seven album names and searchable questions match Android without payment links', () => {
  assert.deepEqual(paidFolderPath(BELSKY_VOL1_ID,['RB-01-07']), ['Album 2 — Sessions 07–11','Session 07']);
  const sessions = parseBelskyIndex({sessions:Array.from({length:35},(_,i)=>({
    disc:1,session:i+1,topics:[{num:String(i+1),text:i===0?'Milk and meat':'Another topic'}]
  }))});
  assert.equal(findBelskyQuestions(sessions,'milk meat').length,1);
  const {html} = paidQuestionResultsHtml({sessions,search:'milk meat',esc});
  assert.match(html,/Milk and meat/);
  assert.doesNotMatch(html,/data-paid-track|buy|checkout|https?:/i);
});

test('restored ownership uses only authenticated server entitlements', () => {
  const ids = verifiedPurchasedIds({items:[{id:'owned',accessOwned:true},
    {id:'pending',owned:true},{id:'local',accessOwned:'true'}]});
  const items = mergeVerifiedPaidCatalog([{id:'owned',owned:false},{id:'pending',owned:false}],ids);
  assert.equal(items[0].owned,true);
  assert.equal(items[1].owned,false);
  assert.equal(items[0].tracks,undefined,'Display restoration does not invent playable media');
});

test('the question index opens from Library and Account purchase cards', () => {
  for (const screen of ['library','account','paid']) {
    const state={screen,paidQuestionIndexLoaded:true};
    const controller=createPaidQuestionController({state,esc,isHebrew:()=>false,render:()=>{}});
    controller.open();
    assert.equal(state.screen,'paid');
    assert.equal(state.paidQuestionIndexOpen,true);
    controller.close();
    assert.equal(state.paidQuestionIndexOpen,false);
  }
});

function completionRig({sleep='off',last=false,owned=true}={}) {
  const current = {kind:'paid-audio',id:`stories:${last?'10':'1'}`,paidAudioId:'stories',trackId:last?'10':'1'};
  const state = {current,paidPlaybackGeneration:0,sleepMode:sleep,paidCatalog:[{id:'stories',owned,tracks}]};
  const plays = [], timers = [], saves = [];
  const context = vm.createContext({state,nextPaidTrackInFolder,iosEndedItemKey:'',
    saveCurrentAudioHistory:async(...args)=>saves.push(args), updatePlayerUi:()=>{},
    setSleepTimer:value=>timers.push(value), advanceQueue:()=>assert.fail('Paid folder cannot use unrelated queue'),
    playPaidTrack:async(...args)=>plays.push(args)});
  vm.runInContext(appFunction('onIosUnifiedEnded'),context);
  const event = {active:true,mode:'audio',id:`audio:paid-audio:${current.id}`,itemEpoch:1};
  return {context,state,plays,timers,saves,event,finish:()=>context.onIosUnifiedEnded(event)};
}

test('a native completion advances exactly once to the next track in this folder', async () => {
  const t=completionRig();
  await t.finish(); await t.finish();
  assert.equal(t.plays.length,1);
  assert.equal(t.plays[0][1],'2');
  assert.equal(t.plays[0][2].fromAutoAdvance,true);
  assert.equal(t.plays[0][2].expectedCurrent,t.state.current);
  assert.deepEqual(t.saves,[[true,true]]);
});

for (const options of [{last:true},{owned:false},{sleep:'end'}]) {
  test('completion stops at folder end, revoked access or end sleep timer: '+JSON.stringify(options),async()=>{
    const t=completionRig(options); await t.finish(); assert.equal(t.plays.length,0);
    if(options.sleep)assert.deepEqual(t.timers,['off']);
  });
}

test('stale native item events cannot advance; a slow progress POST does not delay the next track',async()=>{
  const t=completionRig();
  await t.context.onIosUnifiedEnded({...t.event,id:'audio:paid-audio:old'});
  assert.equal(t.saves.length,0);
  t.context.saveCurrentAudioHistory=()=>new Promise(()=>{});
  await t.finish();
  assert.equal(t.plays.length,1);
});

test('auto-advanced signed audio starts at zero, while a manual choice retains progress',async()=>{
  for(const fromAutoAdvance of [false,true]){
    const starts=[];
    const state={user:{id:'u'},current:{id:'old'},paidPlaybackGeneration:0,
      paidCatalog:[{id:'stories',owned:true,tracks}],paidPlaySessionCache:new Map()};
    const context=vm.createContext({state,audio:{},render:()=>{},setToast:()=>{},alert:assert.fail,
      currentPaidCatalogOwnerKey:()=> 'account:u',paidPlaySessionKey:()=> 'key',
      requestPaidPlaySession:async()=>({playbackUrl:'https://example.test/signed',progress:{positionSeconds:500}}),
      startAudio:async(item,position)=>starts.push({item,position}),paidProductTitle:()=> 'Stories',apiUrl:x=>x,
      nextPaidTrackInFolder,prefetchPaidTrack:()=>{}});
    vm.runInContext(appFunction('playPaidTrack'),context);
    await context.playPaidTrack('stories','2',{fromAutoAdvance,expectedCurrent:fromAutoAdvance?state.current:null});
    assert.equal(starts[0].position,fromAutoAdvance?0:500);
  }
});

test('an old signed-URL response cannot override a newer selection',async()=>{
  const starts=[]; let finish;
  const state={user:{id:'u'},paidPlaybackGeneration:0,paidCatalog:[{id:'stories',owned:true,tracks}],paidPlaySessionCache:new Map()};
  const context=vm.createContext({state,audio:{},render:()=>{},setToast:()=>{},alert:assert.fail,
    currentPaidCatalogOwnerKey:()=> 'account:u',paidPlaySessionKey:()=> 'key',
    requestPaidPlaySession:()=>new Promise(resolve=>finish=resolve),startAudio:async item=>starts.push(item)});
  vm.runInContext(appFunction('playPaidTrack'),context);
  const pending=context.playPaidTrack('stories','1');
  state.paidPlaybackGeneration++;
  finish({playbackUrl:'https://example.test/old'}); await pending;
  assert.equal(starts.length,0);
});
