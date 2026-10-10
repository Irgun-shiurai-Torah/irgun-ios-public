// Read-only observations appended to disposable debug builds; no credentials or UI setters.
window.__ISTAccountControlQueries = {
  account: '.bottom-nav [data-nav="account"]', shiurim: '.bottom-nav [data-nav="shiurim"]',
  library: '.bottom-nav [data-nav="library"]', email: '#authEmail', password: '#authPassword',
  login: '#authForm button[type="submit"]', logout: '[data-logout]',
  profile: '[data-account-section="profile"]', settings: '[data-account-section="settings"]',
  open: '[data-watch]', like: '.watch-actions [data-like],.watch-action[data-like]',
  save: '.watch-actions [data-open-playlist-picker],.watch-action[data-open-playlist-picker]',
  later: '.playlist-picker [data-save]', closePicker: '.playlist-picker-head [data-playlist-picker-close]',
  closeWatch: '[data-close-watch]', follow: '[data-follow-type="speaker"]',
  playlists: '[data-library-section="playlists"]', playlistName: '#libraryPlaylistCreateName',
  createPlaylist: '#libraryPlaylistCreateForm button[type="submit"]',
  testPlaylist: '[data-playlist-open]', deletePlaylist: '[data-playlist-delete]',
  history: '[data-library-section="history"]', likes: '[data-library-section="likes"]',
  saved: '[data-library-section="later"]', following: '[data-library-section="following"]'
};
if (!window.__ISTAccountClickObserverInstalled) {
  window.__ISTAccountClickObserverInstalled = true;
  window.__ISTAccountLastClick = { sequence:0, key:'', at:0 };
  document.addEventListener('click', event => {
    const target = event.target instanceof Element ? event.target : null;
    const match = Object.entries(window.__ISTAccountControlQueries).find(([, query]) => target?.closest?.(query));
    if (!match) return;
    window.__ISTAccountLastClick = {
      sequence:Number(window.__ISTAccountLastClick?.sequence || 0) + 1,
      key:match[0],
      at:Date.now()
    };
  }, true);
  // The click listener can observe a Login tap even if HTML constraint
  // validation prevents the form's submit event. Count submissions and
  // invalid fields without collecting email addresses or passwords.
  window.__ISTAccountLoginSubmissions = 0;
  window.__ISTAccountLastInvalidField = '';
  document.addEventListener('submit', event => {
    if (event.target?.id === 'authForm') window.__ISTAccountLoginSubmissions++;
  }, true);
  document.addEventListener('invalid', event => {
    if (event.target?.closest?.('#authForm')) {
      window.__ISTAccountLastInvalidField = String(event.target.id || '');
    }
  }, true);
}

// Observe only allowlisted collection requests in disposable debug builds.
// Preserve every original call/result and never retain headers, bodies or errors.
if (!window.__ISTAccountRequestObserverInstalled) {
  window.__ISTAccountRequestObserverInstalled = true;
  window.__ISTAccountRequests = [];
  const originalApiJson = apiJson;
  const allowed = new Set(['/like','/playlist/add','/playlist/remove','/follows/toggle','/follows','/my-like-ids','/watch-later','/history']);
  apiJson = async function(path, ...args) {
    // Only log the fact that a history write completed. Never capture the
    // request body, video identifier, account identity or authentication.
    if (!allowed.has(path) || (path === '/history' && String(args[0]?.method || 'GET').toUpperCase() !== 'POST')) {
      return originalApiJson(path, ...args);
    }
    const entry = {sequence:window.__ISTAccountRequests.length+1,path,startedAt:Date.now(),finishedAt:0,ok:false};
    window.__ISTAccountRequests.push(entry);
    try {
      const result = await originalApiJson(path, ...args);
      entry.ok = true;
      if (typeof result?.following === 'boolean') entry.following = result.following;
      if (typeof result?.liked === 'boolean') entry.liked = result.liked;
      return result;
    } catch (error) {
      entry.status = Number(error?.status)||0;
      throw error;
    } finally { entry.finishedAt = Date.now(); }
  };
}

window.ISTAccountTest = { snapshot() {
  const queries = {
    account: '.bottom-nav [data-nav="account"]', shiurim: '.bottom-nav [data-nav="shiurim"]',
    library: '.bottom-nav [data-nav="library"]', email: '#authEmail', password: '#authPassword',
    login: '#authForm button[type="submit"]', logout: '[data-logout]',
    profile: '[data-account-section="profile"]', settings: '[data-account-section="settings"]',
    open: '[data-watch]', like: '.watch-actions [data-like],.watch-action[data-like]',
    save: '.watch-actions [data-open-playlist-picker],.watch-action[data-open-playlist-picker]',
    later: '.playlist-picker [data-save]', closePicker: '.playlist-picker-head [data-playlist-picker-close]',
    closeWatch: '[data-close-watch]', follow: '[data-follow-type="speaker"]',
    playlists: '[data-library-section="playlists"]', playlistName: '#libraryPlaylistCreateName',
    createPlaylist: '#libraryPlaylistCreateForm button[type="submit"]',
    testPlaylist: '[data-playlist-open]', deletePlaylist: '[data-playlist-delete]',
    history: '[data-library-section="history"]', likes: '[data-library-section="likes"]',
    saved: '[data-library-section="later"]', following: '[data-library-section="following"]'
  };
  const controls = {}, controlRects = {}, controlScrollers = {};
  for (const [key, query] of Object.entries(queries)) {
    const candidates = [...document.querySelectorAll(query)];
    const element = candidates[0];
    if (element) {
      const r=element.getBoundingClientRect();
      controlRects[key]={x:r.left+r.width/2,y:r.top+r.height/2,width:r.width,height:r.height};
      const scroller=element.closest('.library-tabs-scroll');
      if(scroller && scroller.scrollWidth>scroller.clientWidth) {
        const box=scroller.getBoundingClientRect();
        const left=Math.max(0,box.left),right=Math.min(innerWidth,box.right);
        const top=Math.max(0,box.top),bottom=Math.min(innerHeight,box.bottom);
        const hit=document.elementFromPoint((left+right)/2,(top+bottom)/2);
        if(right-left>60 && bottom-top>10 && hit && scroller.contains(hit)) {
          controlScrollers[key]={left,right,top,bottom};
        }
      }
    }
    const chosen = candidates.find(e => {
      const r=e.getBoundingClientRect(), x=r.left+r.width/2,y=r.top+r.height/2;
      const h=document.elementFromPoint(x,y);
      return !e.disabled && r.width>0 && r.height>0 && x>0 && y>0 && x<innerWidth && y<innerHeight && h && (h===e||e.contains(h));
    });
    if(chosen){const r=chosen.getBoundingClientRect();controls[key]={x:r.left+r.width/2,y:r.top+r.height/2,label:chosen.innerText||chosen.getAttribute('aria-label')||'',active:chosen.classList.contains('active')};}
  }
  return {requests:(window.__ISTAccountRequests||[]).map(x=>({...x})),observedAt:Date.now(),width:innerWidth,height:innerHeight,controls,controlRects,controlScrollers,
    lastClickSequence:Number(window.__ISTAccountLastClick?.sequence||0),lastClickKey:String(window.__ISTAccountLastClick?.key||''),
    ready:state.libraryReady&&!state.loading,loggedIn:!!state.user,isAdmin:!!state.isAdmin,
    name:state.user?.name||'',accountEmail:state.user?.email||'',screen:state.screen,likes:[...state.myLikes],later:[...state.watchLater],
    follows:[...state.follows.keys()],history:state.history.map(x=>String(x.rawAudioId||x.videoId||x.id||x.vimeoId||'').replace(/^audio:/,'')),
    playlists:state.playlists.map(x=>({id:x.id,name:x.name,items:x.items.length})),
    watchId:state.watchVideo?String(videoId(state.watchVideo)):'',
    settingsVisible:!!document.querySelector('#appEmailToggle'),profileVisible:!!document.querySelector('#profileForm'),
    authBusy:!!state.authBusy,authFormPresent:!!document.querySelector('#authForm'),authFieldsEmpty:['#authEmail','#authPassword'].every(q=>!document.querySelector(q)?.value),authError:!!document.querySelector('.auth-card .form-message'),
    authEmailValid:!!document.querySelector('#authEmail')?.validity.valid,
    authPasswordValid:!!document.querySelector('#authPassword')?.validity.valid,
    authFormValid:[...document.querySelectorAll('#authForm input')].length>=2 && [...document.querySelectorAll('#authForm input')].every(input=>input.validity.valid),
    authEmailLength:document.querySelector('#authEmail')?.value.length||0,
    authPasswordLength:document.querySelector('#authPassword')?.value.length||0,
    authSubmitCount:window.__ISTAccountLoginSubmissions||0,
    authInvalidFieldKey:window.__ISTAccountLastInvalidField||'',
    playlistPickerOpen:!!document.querySelector('.playlist-picker-backdrop'),
    videoTime:Number(state.watchVimeo?.video?.currentTime)||0,videoPlaying:!!state.watchVimeo?.video&&!state.watchVimeo.video.paused};
}};
if(window.ISTSimulator){
  const original=window.ISTSimulator.snapshot.bind(window.ISTSimulator);
  // SimulatorProbe reads JSON text. Preserve that wire format and every
  // playback observation when adding the read-only account snapshot.
  window.ISTSimulator.snapshot=()=>JSON.stringify({
    ...JSON.parse(original()),account:window.ISTAccountTest.snapshot()
  });
}
