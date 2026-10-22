import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { selectIosAccountFixture } from '../.github/simulator/sample-selection.js';

// Execute the unmodified account observer in a read-only fake DOM. The test
// checks real selection semantics without touching login data or network APIs.
function snapshotFor({speakerAssigned=true,titleButton=false,clickId='',observer='account-tests',commentDraft='',focusedId='',commentClick=null,clickKeys=[],pointerKey='',covered=false,returnContext=false,apiJsonImpl=async()=>({})}={}) {
  class Element {}
  const listeners = new Map();
  const make = (id, y, title=false) => Object.assign(new Element(),{
    dataset:{watch:id},
    disabled:false,
    innerText:title ? `Test lecture ${id}` : `Watch ${id}`,
    textContent:title ? `Test lecture ${id}` : `Watch ${id}`,
    classList:{contains:name=>title && name==='media-title'},
    getBoundingClientRect:()=>({left:10,top:y,width:100,height:36}),
    closest(selector){return selector==='[data-watch]' ? this : null;},
    contains(other){return this===other;}
  });
  const first=make('new-unattributed',20);
  const second=make('1235946832',90);
  const account=make('account',155);
  const title=make('1235946832',220,true);
  const elements=[first,second,account,...(titleButton?[title]:[])];
  const document={
    addEventListener(name,callback){listeners.set(name,callback);},
    getElementById:id=>id==='commentText'?{value:commentDraft}:null,
    activeElement:focusedId?{id:focusedId}:null,
    querySelectorAll(query){
      if(query==='[data-watch]')return [first,second,...(titleButton?[title]:[])];
      if(query==='.bottom-nav [data-nav="account"]')return [account];
      return [];
    },
    querySelector:()=>null,
    elementFromPoint(x,y){return elements.find(element=>{
      if (covered) return false;
      const r=element.getBoundingClientRect();
      return x>=r.left&&x<=r.left+r.width&&y>=r.top&&y<=r.top+r.height;
    })||(covered?{tagName:'SECTION',closest:q=>q==='.playlist-picker-backdrop'?{}:null}:null);}
  };
  const state={
    videoById:new Map([
      ['new-unattributed',{hasAudio:false,_speakerIds:[]}],
      ['1235946832',{hasAudio:true,_speakerIds:speakerAssigned?['rav-tested']:[]}]
    ]),
    videos:[],libraryReady:true,loading:false,screen:'shiurim',
    myLikes:new Set(),watchLater:new Set(),follows:new Map(),history:[],playlists:[],
    user:null,isAdmin:false,watchVideo:null,watchVimeo:null,authBusy:false,watchComments:[]
  };
  const context={window:{},document,state,Element,apiJson:apiJsonImpl,apiFetch:async()=>({}),
    innerWidth:390,innerHeight:844,iosNativeActive:()=>false,audio:{currentTime:0,paused:true,ended:false},
    speakerLabel:id=>id==='rav-tested'?'Rav Tested':'',
    videoId:item=>String(item?.id||'')};
  context.window.__ISTQAChooseWatchButton = elements => selectIosAccountFixture(elements,state.videoById);
  vm.runInNewContext(readFileSync(new URL(`../.github/${observer}/${observer==='regression'?'account-observer':'observer'}.js`,import.meta.url),'utf8'),context);
  if(clickId) listeners.get('click')({target:make(clickId,320)});
  if(commentClick) {
    const attribute={commentSave:'saveComment',commentEdit:'editComment',commentDelete:'deleteComment'}[commentClick.kind];
    const selector={commentSave:'[data-save-comment]',commentEdit:'[data-edit-comment]',commentDelete:'[data-delete-comment]'}[commentClick.kind];
    const button=Object.assign(new Element(),{dataset:{[attribute]:commentClick.id},
      closest:query=>query===selector?button:null});
    // Real click listeners also receive clicks on a child inside the button.
    const child=Object.assign(new Element(),{closest:query=>button.closest(query)});
    listeners.get('click')({target:child});
  }
  for (const key of clickKeys) {
    const query=context.window.__ISTAccountControlQueries[key];
    const target=Object.assign(new Element(),{tagName:'BUTTON',
      closest:q=>q===query?target:null});
    listeners.get('click')({target});
  }
  if(pointerKey) {
    const query=context.window.__ISTAccountControlQueries[pointerKey];
    const target=Object.assign(new Element(),{tagName:'INPUT',value:'private input contents',
      closest:q=>q===query?target:null});
    listeners.get('pointerdown')({target,clientX:42,clientY:75});
  }
  return returnContext?context:context.window.ISTAccountTest.snapshot();
}
test('account UI test selects a real speaker Follow lecture, not newest unattributed video',()=>{
  const snapshot=snapshotFor();
  assert.equal(snapshot.controls.open?.label,'Watch 1235946832');
  assert.equal(snapshot.controlRects.open?.y,108);
  assert.equal(snapshot.controls.account?.label,'Watch account');
});
test('account observer refuses to invent Follow support for lectures without a speaker',()=>{
  const snapshot=snapshotFor({speakerAssigned:false});
  assert.equal(snapshot.controls.open,undefined);
  assert.equal(snapshot.controlRects.open,undefined);
  assert.ok(snapshot.controls.account,'Unrelated account navigation must remain present');
});

test('account fixture prioritizes a saved verified backup and rejects unusable sources',()=> {
  const make = id => ({dataset:{watch:id}});
  const primary = make('1235946832');
  const second = make('1235511026');
  const items = [primary,second];
  const videos = new Map([
    ['1235946832',{hasAudio:true,_speakerIds:['rav-a']}],
    ['1235511026',{hasAudio:true,_speakerIds:['rav-b']}]
  ]);
  assert.equal(selectIosAccountFixture(items,videos,'1235511026'),second);
  assert.equal(selectIosAccountFixture(items,videos,'not-a-verified-fixture'),primary);
  videos.set('1235511026',{hasAudio:false,_speakerIds:['rav-b']});
  assert.equal(selectIosAccountFixture(items,videos,'1235511026'),primary);
  videos.set('1235946832',{hasAudio:true,_speakerIds:[]});
  assert.equal(selectIosAccountFixture(items,videos),null);
});

for (const observer of ['account-tests','regression']) {
  test(`${observer} chooses the lecture title rather than the generic Watch cover`,()=> {
    const snapshot=snapshotFor({titleButton:true,observer});
    assert.equal(snapshot.controls.open.label,'Test lecture 1235946832');
    assert.equal(snapshot.watchFixture.id,'1235946832');
    assert.equal(snapshot.watchFixture.title,'Test lecture 1235946832');
    assert.equal(snapshot.controlRects.open.y,238);
  });
  test(`${observer} reports the actual clicked lecture ID, including a wrong neighbour`,()=> {
    const correct=snapshotFor({titleButton:true,clickId:'1235946832',observer});
    assert.equal(correct.lastClickSequence,1);
    assert.equal(correct.lastClickKey,'open');
    assert.equal(correct.lastClickTargetId,correct.watchFixture.id);
    const wrong=snapshotFor({titleButton:true,clickId:'1235142515',observer});
    assert.equal(wrong.lastClickKey,'open');
    assert.equal(wrong.lastClickTargetId,'1235142515');
    assert.notEqual(wrong.lastClickTargetId,wrong.watchFixture.id,
      'A generic open click must not prove that the saved fixture was reopened');
  });
}

test('comment observer reports actual composer focus independently of draft validity',()=> {
  const draft='IST iOS QA 1792660000123 created';
  const unfocused=snapshotFor({observer:'regression',commentDraft:draft});
  assert.equal(unfocused.qaDraftValid,true);
  assert.equal(unfocused.qaDraftMarker,'1792660000123');
  assert.equal(unfocused.commentComposerFocused,false);
  const focused=snapshotFor({observer:'regression',commentDraft:draft,focusedId:'commentText'});
  assert.equal(focused.commentComposerFocused,true);
  assert.equal(focused.qaDraftMarker,'1792660000123');
});
test('comment observer cannot accept a different disposable marker as the intended draft',()=> {
  const observed=snapshotFor({observer:'regression',
    commentDraft:'IST iOS QA 1792660000999 created',focusedId:'commentText'});
  assert.equal(observed.commentComposerFocused,true);
  assert.equal(observed.qaDraftValid,true);
  assert.notEqual(observed.qaDraftMarker,'1792660000123');
});
test('comment observer exposes no arbitrary draft text or marker for an unrelated draft',()=> {
  const draft='A private unrelated comment draft';
  const observed=snapshotFor({observer:'regression',commentDraft:draft,focusedId:'commentText'});
  assert.equal(observed.commentComposerFocused,true);
  assert.equal(observed.qaDraftValid,false);
  assert.equal(observed.qaDraftMarker,'');
  assert.ok(!JSON.stringify(observed).includes(draft));
});

for (const kind of ['commentSave','commentEdit','commentDelete']) {
  test(`comment observer captures the actual ${kind} target ID, including a wrong comment`,()=>{
    const observed=snapshotFor({observer:'regression',commentClick:{kind,id:'owned-qa-comment'}});
    assert.equal(observed.lastClickKey,kind);
    assert.equal(observed.lastClickTargetId,'owned-qa-comment');
    const wrong=snapshotFor({observer:'regression',commentClick:{kind,id:'another-comment'}});
    assert.equal(wrong.lastClickKey,kind);
    assert.notEqual(wrong.lastClickTargetId,observed.lastClickTargetId);
  });
}

for (const [language,name] of [['en','New playlist name'],['he','שם רשימה חדשה']]) {
  test(`playlist creation field has an explicit native accessible name in ${language}`,()=>{
    const source=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
    const start=source.indexOf('function playlistLibraryHtml()');
    const end=source.indexOf('\nfunction downloadsLibraryHtml()',start);
    const render=new Function('state','currentLanguage','esc',source.slice(start,end)+'\nreturn playlistLibraryHtml();');
    const html=render({playlists:[],activePlaylistId:''},()=>language,String);
    const input=html.match(/<input\b[^>]*id="libraryPlaylistCreateName"[^>]*>/)?.[0];
    assert.ok(input,'The real playlist form must contain its name input');
    assert.ok(input.includes(`aria-label="${name}"`));
    assert.ok(input.includes(`placeholder="${name}"`));
  });
}

test('a captured Save click remains provable after a later unrelated click',()=>{
  const before=snapshotFor({observer:'regression'});
  assert.equal(before.clicks.save,undefined,'A rendered picker or button cannot invent a click');
  const observed=snapshotFor({observer:'regression',clickKeys:['save','like']});
  assert.equal(observed.lastClickKey,'like');
  assert.equal(observed.clicks.save.key,'save');
  assert.equal(observed.clicks.save.sequence,1);
  assert.equal(observed.clicks.like.sequence,2);
  assert.ok(observed.clicks.save.sequence>before.lastClickSequence,
    'Late delivery must be checked against the original call baseline');
  const onlyOther=snapshotFor({observer:'regression',clickKeys:['like']});
  assert.equal(onlyOther.clicks.save,undefined,'A different real click must not confirm Save');
});
test('retained comment clicks still identify the exact server comment',()=>{
  const observed=snapshotFor({observer:'regression',
    commentClick:{kind:'commentSave',id:'another-comment'},clickKeys:['like']});
  assert.equal(observed.lastClickKey,'like');
  assert.equal(observed.clicks.commentSave.targetId,'another-comment');
  assert.notEqual(observed.clicks.commentSave.targetId,'intended-comment');
});
test('hit-test evidence distinguishes a covered control from a missing DOM control',()=>{
  const observed=snapshotFor({observer:'regression',covered:true});
  assert.ok(observed.controlRects.account);
  assert.equal(observed.controls.account,undefined);
  assert.equal(observed.controlHitTests.account.targetHit,false);
  assert.equal(observed.controlHitTests.account.inSaveDialog,true);
  assert.equal(observed.controlHitTests.account.tag,'SECTION');
});
test('native pointer evidence records delivery without recording field contents',()=>{
  const observed=snapshotFor({observer:'regression',pointerKey:'password'});
  assert.equal(observed.lastPointer.key,'password');
  assert.equal(observed.lastPointer.x,42);
  assert.equal(observed.lastPointer.y,75);
  assert.equal(observed.clicks.password,undefined,'Pointer delivery is not a confirmed click');
  assert.ok(!JSON.stringify(observed).includes('private input contents'));
});

const startupPaths=['/me','/my-like-ids','/watch-later','/follows','/history','/notification-settings','/custom-playlists'];
test('cold startup requires completed real GETs, not an optimistic session or elapsed time',async()=>{
  let releaseHistory;
  const pending=new Promise(resolve=>{releaseHistory=resolve;});
  const context=snapshotFor({returnContext:true,apiJsonImpl:path=>path==='/history'?pending:Promise.resolve({})});
  context.state.user={id:'qa-account'};
  const observe=()=>context.window.ISTAccountTest.snapshot().startup;
  assert.equal(observe().ready,false);
  await Promise.all(startupPaths.filter(path=>path!='/history').map(path=>context.apiJson(path)));
  const history=context.apiJson('/history');
  assert.equal(observe().ready,false);
  assert.deepEqual(Array.from(observe().pendingPaths),['/history']);
  releaseHistory({items:[]});await history;
  assert.equal(observe().ready,true);
  context.state.loading=true;
  assert.equal(observe().ready,false,'Fresh account data cannot conceal unfinished app bootstrap');
  context.state.loading=false;context.state.user=null;
  assert.equal(observe().ready,false,'Completed reads cannot invent a restored session');
});
test('a successful write cannot substitute for a failed collection reload',async()=>{
  const context=snapshotFor({returnContext:true,apiJsonImpl:async(path,options)=>{
    if(path==='/watch-later' && !options?.method)throw Object.assign(new Error('private error payload'),{status:503});
    return {};
  }});
  context.state.user={id:'qa-account'};
  await Promise.all(startupPaths.map(path=>context.apiJson(path).catch(()=>{})));
  await context.apiJson('/watch-later',{method:'POST',body:'private body'});
  const observed=context.window.ISTAccountTest.snapshot();
  assert.equal(observed.startup.ready,false);
  assert.deepEqual(Array.from(observed.startup.missingReadPaths),['/watch-later']);
  assert.equal(observed.requests.find(row=>row.path==='/watch-later' && row.method==='GET').status,503);
  assert.ok(!JSON.stringify(observed).includes('private error payload'));
  assert.ok(!JSON.stringify(observed).includes('private body'));
});
test('startup request observation preserves real results and excludes unapproved endpoints',async()=>{
  const reply={loggedIn:true,user:{id:'private user'}};
  const calls=[];
  const context=snapshotFor({returnContext:true,apiJsonImpl:async(...args)=>{calls.push(args);return reply;}});
  const options={headers:{Authorization:'private credential'},body:'private body'};
  assert.equal(await context.apiJson('/me',options),reply);
  assert.equal(calls[0][1],options);
  await context.apiJson('/unapproved?private-query');
  const requests=context.window.ISTAccountTest.snapshot().requests;
  assert.equal(requests.length,1);
  assert.equal(requests[0].path,'/me');
  assert.equal(requests[0].ok,true);
  assert.ok(requests[0].finishedAt>=requests[0].startedAt);
  assert.ok(!JSON.stringify(requests).includes('private'));
});
