import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createClickBinder} from '../src/dom-bindings.js';

test('persistent controls keep one click handler through surrounding screen refreshes',()=>{
  const button=new EventTarget();
  let current=button, clicks=0;
  const bind=createClickBinder({querySelectorAll:()=>[current]});
  for(let render=0;render<20;render++) bind('[data-like]',()=>clicks++);
  button.dispatchEvent(new Event('click'));
  assert.equal(clicks,1);
  current=new EventTarget();
  bind('[data-like]',()=>clicks++);
  current.dispatchEvent(new Event('click'));
  assert.equal(clicks,2,'A new DOM button must acquire its own handler');
});

test('each distinct control binding remains independent on a shared element',()=>{
  const button=new EventTarget(),calls=[];
  const bind=createClickBinder({querySelectorAll:()=>[button]});
  bind('[data-action]',()=>calls.push('action'));
  bind('[data-observe]',()=>calls.push('observe'));
  bind('[data-action]',()=>calls.push('duplicate'));
  button.dispatchEvent(new Event('click'));
  assert.deepEqual(calls,['action','observe']);
});

const main=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
test('actual Like and Watch/Listen bindings issue one action after repeated persistent Watch renders',async()=>{
  const selector='[data-like]';
  const like=Object.assign(new EventTarget(),{dataset:{like:'lecture-a'}});
  const mode=Object.assign(new EventTarget(),{dataset:{watchMode:'audio'}});
  const elements=new Map([[selector,[like]],['[data-watch-mode]',[mode]]]);
  const bind=createClickBinder({querySelectorAll:key=>elements.get(key)||[]});
  const likeStart=main.indexOf("  bindClickOnce('[data-like]'");
  const likeEnd=main.indexOf("  bindClickOnce('[data-save]'",likeStart);
  const modeStart=main.indexOf("  bindClickOnce('[data-watch-mode]'");
  const modeEnd=main.indexOf("  bindClickOnce('[data-switch-audio]'",modeStart);
  assert.ok(likeStart>=0&&likeEnd>likeStart&&modeStart>=0&&modeEnd>modeStart);
  const renderBindings=new Function('bindClickOnce','preserveWatchTime','toggleLike','switchWatchMode',
    main.slice(likeStart,likeEnd)+main.slice(modeStart,modeEnd));
  const likes=[],modes=[];
  for(let render=0;render<20;render++) renderBindings(bind,async()=>{},id=>likes.push(id),value=>modes.push(value));
  like.dispatchEvent(new Event('click'));
  mode.dispatchEvent(new Event('click'));
  await Promise.resolve();
  assert.deepEqual(likes,['lecture-a']);
  assert.deepEqual(modes,['audio']);
});
