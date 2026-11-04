import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fetchLoginWithDeadline} from '../src/ios-login-deadline.js';

test('a timely actual login response is returned and its deadline is cleared',async()=>{
  let clearCount=0,abortSignal=null;
  const result=await fetchLoginWithDeadline(async signal=>{
    abortSignal=signal;
    return {sessionToken:'fixture', user:{name:'Fixture'}};
  },{setTimer:()=>12,clearTimer:id=>{assert.equal(id,12);clearCount++;}});
  assert.equal(result.user.name,'Fixture');
  assert.equal(clearCount,1);
  assert.equal(abortSignal.aborted,false);
});

test('an unresolved WebKit login cannot keep Login disabled indefinitely',async()=>{
  let deadline,clearCount=0,signal;
  const pending=fetchLoginWithDeadline(async givenSignal=>{
    signal=givenSignal;
    return new Promise(()=>{}); // reproduces a network request that never settles
  },{setTimer:callback=>{deadline=callback;return 1;},clearTimer:id=>{assert.equal(id,1);clearCount++;}});
  await Promise.resolve();
  deadline();
  await assert.rejects(pending,/Sign-in timed out/);
  assert.equal(signal.aborted,true);
  assert.equal(clearCount,1);
});

test('the real login keeps server errors and does not retry credential POSTs',async()=>{
  let tries=0;
  await assert.rejects(fetchLoginWithDeadline(async()=>{
    tries++;
    throw Error('Incorrect email or password');
  },{setTimer:()=>5,clearTimer:()=>{}}),/Incorrect email or password/);
  assert.equal(tries,1);
});

test('production login uses the deadline and still clears authBusy',()=>{
  const source=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
  const start=source.indexOf('async function login(email, password)');
  const end=source.indexOf('async function finishSocialLogin(',start);
  assert.ok(start>=0&&end>start);
  const login=source.slice(start,end);
  assert.match(login,/fetchLoginWithDeadline\(async signal =>/);
  assert.match(login,/await apiFetch\('\/login', \{/);
  assert.match(login,/signal\s*\n\s*\}\)/);
  assert.match(login,/finally\s*\{\s*state\.authBusy = false;/);
});
