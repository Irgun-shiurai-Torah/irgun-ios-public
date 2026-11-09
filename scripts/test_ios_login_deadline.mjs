import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fetchLoginWithDeadline} from '../src/ios-login-deadline.js';
import {loginWithIosNativeFallback, normalizeNativeLoginResponse} from '../src/ios-native-login.js';

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
  assert.match(login,/loginWithIosNativeFallback\(/);
  assert.match(login,/fetchLoginWithDeadline\(async signal =>/);
  assert.match(login,/CapacitorHttp\.post\(/);
  assert.match(login,/await apiFetch\('\/login', \{/);
  assert.match(login,/signal\s*\n\s*\}\)/);
  assert.match(login,/finally\s*\{\s*state\.authBusy = false;/);
});


test('session restoration and optional startup never leave the app under a permanent spinner',()=>{
  const source=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
  const bootstrap=source.slice(source.indexOf('async function bootstrap(options'),source.indexOf('async function restoreSession()'));
  assert.match(bootstrap,/await restoreSession\(\)/);
  assert.doesNotMatch(bootstrap,/await Promise\.all\(\[loadSponsorRibbon\(\), loadScheduleData\(\), loadLiveStatus\(\)\]\)/);
  assert.match(bootstrap,/void loadSponsorRibbon\(\)/);
  assert.match(bootstrap,/void loadLiveStatus\(\)/);
  const restore=source.slice(source.indexOf('async function restoreSession()'),source.indexOf('async function loadUserCollections()'));
  assert.match(restore,/boundedAccountRead\('\/me', 12000\)/);
  assert.match(restore,/error\?\.status === 401/);
  assert.match(restore,/setToken\(''\)/);
  assert.match(restore,/Session restore deferred until the network recovers/);
  const collections=source.slice(source.indexOf('async function loadUserCollections()'),source.indexOf('async function checkAdminStatus('));
  for(const path of ['/my-like-ids','/watch-later','/follows','/history','/notification-settings','/custom-playlists']){
    assert.ok(collections.includes("boundedAccountRead('"+path+"')"),
      path+' must not be able to hang all other startup requests');
  }
});

test('session timeout can be reported distinctly from a sign-in timeout',async()=>{
  let deadline=()=>{};
  const promise=fetchLoginWithDeadline(()=>new Promise(()=>{}),{
    timeoutMs:12000,
    timeoutMessage:'Account connection timed out. Please try again.',
    setTimer:cb=>{deadline=cb;return 42;},
    clearTimer:()=>{}
  });
  deadline();
  await assert.rejects(promise,/Account connection timed out/);
});


test('only an unresolved WebKit transport falls back to a native iOS HTTP response',async()=>{
  let calls=0;
  const result=await loginWithIosNativeFallback(
    async()=>{throw Error('Sign-in timed out. Check your connection and try again.');},
    async()=>{calls++;return normalizeNativeLoginResponse({status:200,data:{sessionToken:'server-issued'}});},
    {enabled:true}
  );
  assert.equal(calls,1);
  assert.equal(result.data.sessionToken,'server-issued');
  assert.equal(result.response.ok,true);
});

test('a rejected password, rate limit or HTTP error never triggers duplicate credentials',async()=>{
  for(const error of [Error('Incorrect email or password'),Error('/login returned 401'),Error('429 Too Many Requests')]){
    let retries=0;
    await assert.rejects(loginWithIosNativeFallback(
      async()=>{throw error;},
      async()=>{retries++;return normalizeNativeLoginResponse({status:200,data:{}});},
      {enabled:true}
    ),{message:error.message});
    assert.equal(retries,0);
  }
});

test('native login response preserves real HTTP failures and parses JSON data',()=>{
  const fail=normalizeNativeLoginResponse({status:401,data:'{"error":"Incorrect email or password"}'});
  assert.equal(fail.response.ok,false);
  assert.equal(fail.response.status,401);
  assert.equal(fail.data.error,'Incorrect email or password');
  const rate=normalizeNativeLoginResponse({status:429,data:{error:'Rate limited'}});
  assert.equal(rate.response.status,429);
  assert.throws(()=>normalizeNativeLoginResponse({status:0,data:{sessionToken:'bad'}}),/valid HTTP response/);
});

test('non-iOS browsers never trigger native fallback',async()=>{
  let calls=0;
  await assert.rejects(loginWithIosNativeFallback(
    async()=>{throw Error('Load failed');},
    async()=>{calls++;return {response:{ok:true}};},
    {enabled:false}
  ),/Load failed/);
  assert.equal(calls,0);
});
