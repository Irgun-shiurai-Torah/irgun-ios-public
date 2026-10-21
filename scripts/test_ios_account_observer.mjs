import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { selectIosAccountFixture } from '../.github/simulator/sample-selection.js';

// Execute the unmodified account observer in a read-only fake DOM. The test
// checks real selection semantics without touching login data or network APIs.
function snapshotFor({speakerAssigned=true}={}) {
  const make = (id, y) => ({
    dataset:{watch:id},
    disabled:false,
    innerText:`Watch ${id}`,
    classList:{contains:()=>false},
    getBoundingClientRect:()=>({left:10,top:y,width:100,height:36}),
    closest:()=>null,
    contains(other){return this===other;}
  });
  const first=make('new-unattributed',20);
  const second=make('1235946832',90);
  const account=make('account',155);
  const elements=[first,second,account];
  const document={
    addEventListener(){},
    querySelectorAll(query){
      if(query==='[data-watch]')return [first,second];
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
    user:null,isAdmin:false,watchVideo:null,watchVimeo:null,authBusy:false
  };
  const context={window:{},document,state,apiJson:async()=>({}),
    innerWidth:390,innerHeight:844,iosNativeActive:()=>false,
    speakerLabel:id=>id==='rav-tested'?'Rav Tested':'',
    videoId:item=>String(item?.id||'')};
  context.window.__ISTQAChooseWatchButton = elements => selectIosAccountFixture(elements,state.videoById);
  vm.runInNewContext(readFileSync(new URL('../.github/account-tests/observer.js',import.meta.url),'utf8'),context);
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
