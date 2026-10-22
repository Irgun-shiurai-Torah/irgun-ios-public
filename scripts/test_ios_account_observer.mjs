import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { selectIosAccountFixture } from '../.github/simulator/sample-selection.js';

// Execute the unmodified account observer in a read-only fake DOM. The test
// checks real selection semantics without touching login data or network APIs.
function snapshotFor({speakerAssigned=true,titleButton=false,clickId='',observer='account-tests',commentDraft='',focusedId=''}={}) {
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
      const r=element.getBoundingClientRect();
      return x>=r.left&&x<=r.left+r.width&&y>=r.top&&y<=r.top+r.height;
    })||null;}
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
  const context={window:{},document,state,Element,apiJson:async()=>({}),apiFetch:async()=>({}),
    innerWidth:390,innerHeight:844,iosNativeActive:()=>false,audio:{currentTime:0,paused:true,ended:false},
    speakerLabel:id=>id==='rav-tested'?'Rav Tested':'',
    videoId:item=>String(item?.id||'')};
  context.window.__ISTQAChooseWatchButton = elements => selectIosAccountFixture(elements,state.videoById);
  vm.runInNewContext(readFileSync(new URL(`../.github/${observer}/${observer==='regression'?'account-observer':'observer'}.js`,import.meta.url),'utf8'),context);
  if(clickId) listeners.get('click')({target:make(clickId,320)});
  return context.window.ISTAccountTest.snapshot();
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
