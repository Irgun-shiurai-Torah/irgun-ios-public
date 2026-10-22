// Read-only observations appended to disposable debug builds; no credentials or UI setters.
window.__ISTAccountControlQueries = {
  account: '.bottom-nav [data-nav="account"]', shiurim: '.bottom-nav [data-nav="shiurim"]',
  library: '.bottom-nav [data-nav="library"]', email: '#authEmail', password: '#authPassword',
  login: '#authForm button[type="submit"]', logout: '[data-logout]',
  modeAudio: '[data-watch-mode="audio"]', modeVideo: '[data-watch-mode="video"]',
  commentText: '#commentText', commentPost: '#commentForm button[type="submit"]',
  commentEdit: '[data-edit-comment]', commentEditText: '[id^="editCommentText-"]',
  commentSave: '[data-save-comment]', commentDelete: '[data-delete-comment]',
  commentKeyboardDone: '[data-comment-keyboard-done]',
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
    const commentAttribute = {commentEdit:'editComment',commentSave:'saveComment',commentDelete:'deleteComment'}[match[0]];
    window.__ISTAccountLastClick = {
      sequence:Number(window.__ISTAccountLastClick?.sequence || 0) + 1,
      key:match[0],
      targetId:match[0] === 'open' ? String(target?.closest?.('[data-watch]')?.dataset.watch || '')
        : commentAttribute ? String(target?.closest?.(match[1])?.dataset[commentAttribute] || '') : '',
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
    // Identify only a disposable QA comment entered via native UI.
    if (event.target?.id === 'commentForm') {
      const match = /^IST iOS QA (\d{12,16}) created$/.exec(
        String(document.getElementById('commentText')?.value || '').trim()
      );
      if (match && state.user && state.watchVideo) {
        // Retain only the disposable marker and its scope in this debug build.
        // A real process restart must reload comments from the server while
        // still identifying exactly the comment this test created.
        const marker = { token:match[1], userId:String(state.user.id),
          videoId:String(videoId(state.watchVideo)) };
        window.__ISTAccountQaCommentMarker = marker;
        try { localStorage.setItem('istIOSQACommentMarker', JSON.stringify(marker)); } catch (_) {}
      }
    }
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
    const method = String(args[0]?.method || 'GET').toUpperCase();
    const isComment = path === '/comments' || path.startsWith('/comments?') ||
      path === '/comments/delete' || /^\/comments\/[^/?]+$/.test(path);
    // Never record URLs with comment or media IDs, bodies, account data or tokens.
    if ((!allowed.has(path) && !isComment) || (path === '/history' && method !== 'POST')) {
      return originalApiJson(path, ...args);
    }
    const safePath = !isComment ? path : path === '/comments/delete' ? '/comments/delete'
      : path.startsWith('/comments/') ? '/comments/edit' : '/comments';
    const entry = {sequence:window.__ISTAccountRequests.length+1,path:safePath,method,startedAt:Date.now(),finishedAt:0,ok:false};
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

// Observe HTTP outcomes for real login requests without retaining credentials.
if (!window.__ISTAccountLoginResponseObserverInstalled) {
  window.__ISTAccountLoginResponseObserverInstalled = true;
  const originalLoginFetch = apiFetch;
  apiFetch = async function(path, ...args) {
    if (path !== '/login') return originalLoginFetch(path, ...args);
    const entry = {sequence:window.__ISTAccountRequests.length+1,path:'/login',
      method:'POST',startedAt:Date.now(),finishedAt:0,ok:false,status:0};
    window.__ISTAccountRequests.push(entry);
    try {
      const response = await originalLoginFetch(path, ...args);
      entry.status = response.status;
      entry.ok = response.ok;
      return response;
    } finally { entry.finishedAt = Date.now(); }
  };
}

window.ISTAccountTest = { snapshot() {
  const queries = {
    account: '.bottom-nav [data-nav="account"]', shiurim: '.bottom-nav [data-nav="shiurim"]',
    library: '.bottom-nav [data-nav="library"]', email: '#authEmail', password: '#authPassword',
    login: '#authForm button[type="submit"]', logout: '[data-logout]',
  modeAudio: '[data-watch-mode="audio"]', modeVideo: '[data-watch-mode="video"]',
  commentText: '#commentText', commentPost: '#commentForm button[type="submit"]',
  commentEdit: '[data-edit-comment]', commentEditText: '[id^="editCommentText-"]',
  commentSave: '[data-save-comment]', commentDelete: '[data-delete-comment]',
  commentKeyboardDone: '[data-comment-keyboard-done]',
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
  let watchFixture = null;
  let qaMarker = window.__ISTAccountQaCommentMarker;
  if (!qaMarker) {
    try { qaMarker = JSON.parse(localStorage.getItem('istIOSQACommentMarker') || 'null'); } catch (_) {}
  }
  const markerInScope = qaMarker && state.user && state.watchVideo &&
    String(qaMarker.userId) === String(state.user.id) &&
    String(qaMarker.videoId) === String(videoId(state.watchVideo));
  const qaToken = markerInScope && /^\d{12,16}$/.test(String(qaMarker.token))
    ? String(qaMarker.token) : '';
  const qaDraftMatch = /^IST iOS QA (\d{12,16}) created$/.exec(
    String(document.getElementById('commentText')?.value || '').trim()
  );
  const qaDraftValid = Boolean(qaDraftMatch);
  let qaComment = null, qaCommentPhase = 'absent';
  let qaCommentReturned = false, qaCommentReturnedOwned = false;
  if (qaToken && state.user) {
    for (const comment of state.watchComments) {
      const match = /^IST iOS QA (\d{12,16}) (created|created updated)$/.exec(String(comment.text || ''));
      if (!match || match[1] !== qaToken) continue;
      qaCommentReturned = true;
      const isOwner = String(comment.user_id) === String(state.user.id);
      if (!isOwner) continue;
      qaCommentReturnedOwned = true;
      qaComment = comment;
      qaCommentPhase = match[2] === 'created' ? 'created' : 'edited';
      break;
    }
  }
  for (const [key, query] of Object.entries(queries)) {
    let candidates = [...document.querySelectorAll(query)];
    if (key === 'open' && state.screen === 'shiurim') {
      // Keep the same real backed-up lecture when the app is relaunched:
      // otherwise arbitrary recent Vimeo-only items can defeat these tests.
      const fixed = window.__ISTQAChooseWatchButton?.(candidates);
      candidates = fixed ? [fixed] : [];
    }
    if (['commentEdit','commentSave','commentDelete','commentEditText','commentKeyboardDone'].includes(key)) {
      if (!qaComment) candidates = [];
      else if (key === 'commentEditText') {
        candidates = candidates.filter(el => el.id === 'editCommentText-' + String(qaComment.id));
      } else {
        const attr = {commentEdit:'editComment',commentSave:'saveComment',commentDelete:'deleteComment',commentKeyboardDone:'commentKeyboardDone'}[key];
        candidates = candidates.filter(el => String(el.dataset[attr] || '') === String(qaComment.id));
      }
    }
    const element = candidates[0];
    if (key === 'open' && element) {
      watchFixture = {id:String(element.dataset.watch || ''), title:String(element.textContent || '').trim()};
    }
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
  const native = iosNativeActive() ? iosUnified.state : null;
  return {requests:(window.__ISTAccountRequests||[]).map(x=>({...x})),observedAt:Date.now(),width:innerWidth,height:innerHeight,controls,controlRects,controlScrollers,watchFixture,
    lastClickSequence:Number(window.__ISTAccountLastClick?.sequence||0),lastClickKey:String(window.__ISTAccountLastClick?.key||''),
    lastClickTargetId:String(window.__ISTAccountLastClick?.targetId||''),
    ready:state.libraryReady&&!state.loading,loggedIn:!!state.user,isAdmin:!!state.isAdmin,
    name:state.user?.name||'',accountEmail:state.user?.email||'',screen:state.screen,likes:[...state.myLikes],later:[...state.watchLater],
    follows:[...state.follows.keys()],history:state.history.map(x=>String(x.rawAudioId||x.videoId||x.id||x.vimeoId||'').replace(/^audio:/,'')),
    playlists:state.playlists.map(x=>({id:x.id,name:x.name,items:x.items.length})),
    watchId:state.watchVideo?String(videoId(state.watchVideo)):'',
    watchHasAudio:Boolean(state.watchVideo?.hasAudio),
    qaCommentId:qaComment ? String(qaComment.id) : '',
    qaCommentPhase,qaCommentVisible:Boolean(qaComment),qaDraftValid,
    qaDraftMarker:qaDraftMatch?.[1] || '',
    commentComposerFocused:document.activeElement?.id === 'commentText',
    commentEditorFocused:Boolean(qaComment && document.activeElement?.id === 'editCommentText-' + String(qaComment.id)),
    qaCommentMarker:qaToken,
    qaCommentReturned,qaCommentReturnedOwned,
    commentCount:state.watchComments.length,
    commentsLoading:Boolean(state.watchCommentsLoading),commentsError:Boolean(state.watchCommentsError),
    commentDraftEmpty:!document.getElementById('commentText')?.value,
    profileNameValue:document.getElementById('profileName')?.value || '',
    profileNameDisplayed:document.querySelector('.profile-line span')?.textContent?.trim() || '',
    settingsVisible:!!document.querySelector('#appEmailToggle'),profileVisible:!!document.querySelector('#profileForm'),
    authBusy:!!state.authBusy,authFormPresent:!!document.querySelector('#authForm'),authFieldsEmpty:['#authEmail','#authPassword'].every(q=>!document.querySelector(q)?.value),authError:!!document.querySelector('.auth-card .form-message'),
    authEmailValid:!!document.querySelector('#authEmail')?.validity.valid,
    authPasswordValid:!!document.querySelector('#authPassword')?.validity.valid,
    authEmailFocused:document.activeElement?.id === 'authEmail',
    authPasswordFocused:document.activeElement?.id === 'authPassword',
    authFormValid:[...document.querySelectorAll('#authForm input')].length>=2 && [...document.querySelectorAll('#authForm input')].every(input=>input.validity.valid),
    authEmailLength:document.querySelector('#authEmail')?.value.length||0,
    authPasswordLength:document.querySelector('#authPassword')?.value.length||0,
    authSubmitCount:window.__ISTAccountLoginSubmissions||0,
    authInvalidFieldKey:window.__ISTAccountLastInvalidField||'',
    playlistPickerOpen:!!document.querySelector('.playlist-picker-backdrop'),
    videoTime:native?.mode==='video' ? (Number(native.position)||0) : (Number(state.watchVimeo?.video?.currentTime)||0),
    videoPlaying:native?.mode==='video' ? native.playing===true : Boolean(state.watchVimeo?.video&&!state.watchVimeo.video.paused),
    audioTime:native?.mode==='audio' ? (Number(native.position)||0) : (Number(audio.currentTime)||0),
    audioPlaying:native?.mode==='audio' ? native.playing===true : Boolean(!audio.paused&&!audio.ended)};
}};
if(window.ISTSimulator){
  const original=window.ISTSimulator.snapshot.bind(window.ISTSimulator);
  // SimulatorProbe reads JSON text. Preserve that wire format and every
  // playback observation when adding the read-only account snapshot.
  window.ISTSimulator.snapshot=()=>JSON.stringify({
    ...JSON.parse(original()),account:window.ISTAccountTest.snapshot()
  });
}


