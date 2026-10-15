import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { iosNavigationRoot, prepareIosTabNavigation, createIosBottomNavigation } from '../src/ios-bottom-navigation.js';

const app = readFileSync(new URL('../src/main.js', import.meta.url), 'utf8');
const direct = readFileSync(new URL('../src/direct-media.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../src/style.css', import.meta.url), 'utf8');
const iosNative = readFileSync(new URL('./IrgunVideoDisplayPlugin.swift', import.meta.url), 'utf8');
const cloud = readFileSync(new URL('./prepare_ios_cloud.py', import.meta.url), 'utf8');
const xcode = readFileSync(new URL('./patch_xcode_project.rb', import.meta.url), 'utf8');

test('iOS navigation retains the five tab roots on detail pages', () => {
  for (const tab of ['home','shiurim','live','library','account']) assert.equal(iosNavigationRoot(tab), tab);
  assert.equal(iosNavigationRoot('live-flatbush'), 'live');
  assert.equal(iosNavigationRoot('paid'), 'library');
  assert.equal(iosNavigationRoot('schedule'), 'home');
  assert.equal(iosNavigationRoot('privacy','account'), 'account');
  assert.equal(iosNavigationRoot('donate','library'), 'library');
});

test('iOS navigation moves existing Video into Mini without touching the playing element', async () => {
  const player = { position: 644, playing: true };
  const state = { watchVideo: {id:'x'}, watchVimeo:player, watchMode:'video',
    watchMinimized:false, watchPictureInPicture:false, playerOpen:true };
  const calls = [];
  await prepareIosTabNavigation({state,
    exitFullscreen:async()=>calls.push('exit'),
    minimizeVideo:async()=>{calls.push('mini');state.watchMinimized=true;},
    closeAudioWatch:async()=>assert.fail('Do not close video')});
  assert.deepEqual(calls,['exit','mini']);
  assert.equal(state.watchVimeo,player);
  assert.equal(player.position,644);
  assert.equal(player.playing,true);
  assert.equal(state.playerOpen,false);
});

test('audio tab navigation retains foreground HTML audio; PiP is never replaced', async () => {
  let closed = 0;
  const state = {watchVideo:{id:'y'}, watchMode:'audio', playerOpen:true};
  await prepareIosTabNavigation({state,
    exitFullscreen:()=>assert.fail('Do not fullscreen'),
    minimizeVideo:()=>assert.fail('Do not minimize audio'),
    closeAudioWatch:async()=>{closed++;}});
  assert.equal(closed,1);
  state.watchMode='video';
  state.watchPictureInPicture=true;
  await prepareIosTabNavigation({state, exitFullscreen:()=>assert.fail('Preserve PiP'),
    minimizeVideo:()=>assert.fail('Preserve PiP'), closeAudioWatch:()=>assert.fail('Preserve PiP')});
  assert.equal(closed,1);
});

test('iOS bottom nav has one stable DOM mount and stable tab identity across state renders',()=>{
  let created=0,markupCalls=0,navClicks=0;
  const buttons=['home','shiurim','live','library','account'].map(key=>({
    dataset:{nav:key}, active:false, attrs:{},
    classList:{toggle(_name,value){this.host.active=value;}},
    setAttribute(k,v){this.attrs[k]=v;},
    removeAttribute(k){delete this.attrs[k];}
  }));
  for(const button of buttons)button.classList.host=button;
  const nav={style:{setProperty(k,v){this[k]=v;}},querySelectorAll:()=>buttons};
  const mount={isConnected:true,innerHTML:'',querySelector:()=>nav,
    get firstElementChild(){return this.innerHTML ? nav : null;},
    addEventListener(_name,callback){this.onClick=callback;},
    contains:()=>true};
  const document={body:{appendChild(m){m.isConnected=true;}},createElement:()=>{created++;return mount;}};
  let state={language:'en',root:'home'};
  const sync=createIosBottomNavigation({isIos:()=>true,document,model:()=>state,
    markup:()=>{markupCalls++;return '<nav class="bottom-nav ios-floating-nav"></nav>';},
    navigate:()=>{navClicks++;}});
  sync();state.root='library';sync();sync();
  assert.equal(created,1);assert.equal(markupCalls,1);
  assert.equal(buttons.filter(x=>x.active).length,1);
  assert.equal(buttons[3].attrs['aria-current'],'page');
  assert.equal(nav.style['--nav-index'],'3');
  mount.onClick({target:{closest:()=>buttons[3]}});
  assert.equal(navClicks,1);
  state.language='he';sync();assert.equal(markupCalls,2);
});


test('iOS swipe publishes a tab only after media handoff and the matching DOM render', () => {
  const start = app.indexOf('async function navigateIosBottomTab(button)');
  const end = app.indexOf('\nfunction bind() {', start);
  assert.ok(start >= 0 && end > start, 'Native iOS tab navigation must exist');
  const navigate = app.slice(start, end);
  const awaitPreparation = navigate.indexOf('await prepareIosTabNavigation(');
  const commitScreen = navigate.indexOf('state.screen = next;');
  assert.ok(awaitPreparation > 0 && commitScreen > awaitPreparation,
    'Do not advertise a new tab in state until its asynchronous media handoff is finished');
  assert.ok(navigate.indexOf('state.iosNavPending = next;') < awaitPreparation,
    'Highlight the pending destination without changing the active content');
  assert.ok(navigate.indexOf("state.iosNavPending = '';") > commitScreen,
    'Clear pending state only after the tab identity has been committed');
  assert.match(app,/data-screen="\$\{esc\(state\.screen\)\}"/,
    'Real content must expose which screen it actually rendered');
  assert.match(app,/canNavigate: \(\) => !state\.iosNavPending/,
    'Prevent a second swipe while a tab is being prepared');
  const observer = readFileSync(new URL('../.github/simulator/bridge.js',import.meta.url),'utf8');
  assert.match(observer,/renderedScreen === state\.screen/,
    'iOS UI tests must reject snapshots where state and rendered DOM disagree');
  assert.match(observer,/tabSwipeReady && y < innerHeight/,
    'The simulator must not use a stale hit-test row during a tab transition');
});

test('Android control layout is mirrored without replacing video/audio decoders',()=>{
  for(const id of ['dmMini','dmPip','dmQuality','dmSpeed','dmFull','dmBack','dmPlay','dmForward','dmSeek','dmNow','dmDur']) {
    assert.ok(direct.includes('id="'+id+'"'),'Missing player control '+id);
  }
  assert.match(direct,/direct-media-top-controls/);
  assert.match(direct,/direct-media-center-controls/);
  assert.match(direct,/direct-media-time-row/);
  assert.match(css,/\.direct-media-time-row\s*\{[^}]*justify-content:space-between/);
  assert.match(css,/body\.irgun-ios #dmNow \{ text-align:left; \}/);
  assert.match(css,/body\.irgun-ios #dmDur \{ text-align:right; \}/);
  assert.match(css,/\.ios-floating-nav \.nav-active-indicator/);
  assert.match(app,/syncIosBottomNavigation\(\);/);
  assert.match(app,/onSpeedChange: rate =>/);
  assert.match(app,/state\.playbackSpeed = speed/);
  assert.match(app,/function navigateIosBottomTab/);
  assert.match(app,/state\.librarySection = 'downloads'/);
  assert.equal(direct.includes('IrgunNativeVideo'),false,'Never port Android ExoPlayer onto iOS');
});

test('iOS device-motion fullscreen and idle lock are presentation-only',()=>{
  assert.match(iosNative,/import CoreMotion/);
  assert.match(iosNative,/motion\.startDeviceMotionUpdates/);
  assert.match(iosNative,/UIApplication\.shared\.isIdleTimerDisabled/);
  assert.match(iosNative,/notifyListeners\("orientation"/);
  assert.equal(iosNative.includes('AVPlayer('),false,'Native display must not create audio or video');
  assert.match(cloud,/UISupportedInterfaceOrientations~ipad/);
  assert.match(cloud,/registerPluginInstance\(IrgunVideoDisplayPlugin\(\)\)/);
  assert.match(xcode,/IrgunVideoDisplayPlugin\.swift/);
});
