// Disposable iOS simulator observations only. Do not ship in release builds.
// Read real DOM, server-backed account state, media state and native offline files;
// test code never sets app state or manufactures playback successes.
(() => {
  const keys = {
    language: '[data-language-toggle]',
    account: '.bottom-nav [data-nav="account"]',
    shiurim: '.bottom-nav [data-nav="shiurim"]',
    library: '.bottom-nav [data-nav="library"]',
    open: '[data-watch]',
    loginEmail: '#authEmail', loginPassword: '#authPassword',
    loginSubmit: '#authForm button[type="submit"]',
    profileName: '#profileName', profileSave: '#profileForm button[type="submit"]',
    profileSection: '[data-account-section="profile"]',
    logout: '[data-logout]',
    like: '.watch-actions [data-like],.watch-action[data-like]',
    follow: '[data-follow-type="speaker"]',
    watchAudio: '[data-watch-mode="audio"]',
    watchVideo: '[data-watch-mode="video"]',
    offlineSave: '.watch-actions [data-save-offline-kind="video"]',
    downloads: '[data-library-section="downloads"]',
    offlinePlay: '[data-offline-play]',
    closeWatch: '[data-close-watch]',
    watchFromAudio: '[data-player-watch]',
    playFull: '[data-open-player]',
    audioSpeed15: '[data-speed-choice="1.5"]',
    videoSpeed: '#dmSpeed',
    videoSpeedToggle: '#dmSpeedToggle',
    videoSpeed15: '#dmSpeedMenu [data-dm-rate="1.5"]',
    videoSpeed10: '#dmSpeedMenu [data-dm-rate="1"]',
    mini: '[data-minimize-watch]',
    expand: '[data-expand-watch]',
    pip: '#dmPip',
    full: '#dmFull',
    playlistName: '#libraryPlaylistCreateName',
    playlists: '[data-library-section="playlists"]',
    createPlaylist: '#libraryPlaylistCreateForm button[type="submit"]',
    deletePlaylist: '[data-playlist-delete]',
    invalidateQA: '#ist-qa-invalidate-session',
  };
  let network = {online:false,at:0,error:false};
  let pushActions = 0;
  let pushWatchTarget = false;
  let serverRevoked = false;
  // A debug-only control performs a REAL Worker /logout without clearing the
  // local token. It models an expired/revoked server session; after relaunch the
  // production /me restoration path must notice the 401 and sign the user out.
  // It is NOT part of release builds and is never called by production UI.
  const invalidation = document.createElement('button');
  invalidation.id='ist-qa-invalidate-session';
  invalidation.textContent='Invalidate QA session on server';
  invalidation.style.cssText='position:fixed;right:12px;bottom:92px;z-index:2147483000;padding:10px;background:#fff;border:2px solid #222;border-radius:7px;color:#222';
  invalidation.addEventListener('click', async () => {
    try {
      await apiJson('/logout',{method:'POST'});
      serverRevoked = true;
      invalidation.textContent='Server session invalidated';
    } catch (_) { serverRevoked = false; invalidation.textContent='Revocation failed'; }
  });
  const insertInvalidate = () => {
    if (state.user && state.screen === 'account' && state.accountSection === 'profile') {
      if (!invalidation.isConnected) document.body.appendChild(invalidation);
    } else if (invalidation.isConnected) invalidation.remove();
  };
  new MutationObserver(insertInvalidate).observe(document.body,{childList:true,subtree:true});
  insertInvalidate();
  const alive = () => !document.hidden;
  // Different cache-busting URL each time: don't mistake a ServiceWorker/local
  // cache entry or navigator.onLine for actual API connectivity.
  const checkNetwork = async () => {
    const at = Date.now();
    try {
      const response = await Promise.race([
        fetch(API + '/auth-config?ist_regression_probe=' + at,
          {cache:'no-store',credentials:'omit'}),
        new Promise((_,reject)=>setTimeout(()=>reject(new Error('timeout')),3500))
      ]);
      network = {online:response.ok,at,error:!response.ok};
    } catch (_) { network = {online:false,at,error:true}; }
  };
  checkNetwork();
  setInterval(() => { if (alive()) void checkNetwork(); }, 4000);
  try {
    if (typeof FirebaseMessaging !== 'undefined' && IS_IOS) {
      FirebaseMessaging.addListener('notificationActionPerformed', event => {
        pushActions += 1;
        const url = String(event?.notification?.data?.url || event?.notification?.data?.link || '');
        pushWatchTarget = url.includes('/watch.html') && url.includes('?v=');
      }).catch(() => {});
    }
  } catch (_) {}
  const previous = window.ISTSimulator.snapshot.bind(window.ISTSimulator);
  window.ISTSimulator.snapshot = () => {
    const base = JSON.parse(previous());
    const selectors = {}, hitRects = {};
    for (const [key,selector] of Object.entries(keys)) {
      const elements = [...document.querySelectorAll(selector)];
      let matches = elements;
      if (key === 'open') {
        const audioMatches = elements.filter(e=>state.videoById?.get(String(e.dataset.watch||''))?.hasAudio);
        if (audioMatches.length) matches=audioMatches;
      }
      const el = matches.find(e=>{
        const r=e.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;
        const hit=document.elementFromPoint(x,y);
        return !e.disabled && r.width>0 && r.height>0 &&
          x>=0 && y>=0 && x<innerWidth && y<innerHeight &&
          hit && (e===hit || e.contains(hit));
      });
      const target=el||matches[0];
      if (!target) continue;
      const r=target.getBoundingClientRect();
      hitRects[key]={x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height};
      if (el) selectors[key]={x:r.left+r.width/2,y:r.top+r.height/2};
    }
    const videoIdValue=state.watchVideo?String(videoId(state.watchVideo)):'';
    const offlineKey=state.watchVideo?offlineKeyFor('video',videoIdValue):'';
    const offlineRecord=state.offlineDownloads.get(offlineKey);
    const record=[...state.offlineDownloads.values()].find(v=>v.kind==='video');
    const download=offlineRecord||record;
    const buttons=[...document.querySelectorAll('.bottom-nav [data-nav]')].map(e=>{
      const r=e.getBoundingClientRect();
      return {key:e.dataset.nav||'',label:e.textContent?.trim()||'',
        x:r.left,w:r.width,within:r.left>=-1&&r.right<=innerWidth+1};
    });
    const readName=String(state.user?.name||'');
    const tabs=document.querySelector('.library-tabs-scroll');
    const bounds=tabs?.getBoundingClientRect();
    const libraryTabsRect=bounds?{x:bounds.left,y:bounds.top,w:bounds.width,h:bounds.height}:null;
    const videoSpeed=document.getElementById('dmSpeed');
    return JSON.stringify({...base,regression:{
      controls:selectors,rects:hitRects,libraryTabsRect,
      libraryTabsScrollLeft:Number(tabs?.scrollLeft)||0,
      language:currentLanguage(),documentDir:document.documentElement.dir,
      documentLang:document.documentElement.lang||'',
      bottomNav:buttons,rtlToggleLabel:document.querySelector('[data-language-toggle]')?.textContent?.trim()||'',
      online:network.online,networkCheckedAt:network.at,networkProbeFailed:network.error,
      pushActions,pushWatchTarget,serverRevoked,
      loggedIn:Boolean(state.user),isAdmin:Boolean(state.isAdmin),
      namePresent:readName.length>0,accountName:readName,
      accountEmailMatchesSecret:undefined, // Test runner compares authenticated email privately.
      profileName:document.getElementById('profileName')?.value||'',
      profileNameShown:document.querySelector('.profile-line span')?.textContent?.trim()||'',
      loginForm:Boolean(document.getElementById('authForm')),
      loginError:Boolean(state.authMessage)&&!state.user,
      loginBusy:Boolean(state.authBusy),
      originalVideoId:videoIdValue,hasAudio:Boolean(state.watchVideo?.hasAudio),
      audioOwned:Boolean(state.current),
      offlineSaved:Boolean(download&&Number(download.bytes)>0),
      offlineBytes:Number(download?.bytes)||0,
      offlineCurrent:Boolean(state.current?.offline),
      offlineMediaSource:String(audio.currentSrc||'').startsWith('file:') ||
        String(audio.currentSrc||'').startsWith('capacitor:') ||
        String(audio.currentSrc||'').startsWith('ionic:'),
      offlineJobs:state.offlineJobs.size,
      videoSpeedChoice:Number(videoSpeed?.value)||0,
      videoRate:Number(state.watchVimeo?.video?.playbackRate)||0,
      configuredAudioRate:Number(state.playbackSpeed)||1,
      audioRate:Number(audio.playbackRate)||0,
      playingAudio:!audio.paused&&!audio.ended,
      audioSeconds:Number(audio.currentTime)||0,
      playingVideo:Boolean(state.watchVimeo?.video&&!state.watchVimeo.video.paused),
      videoSeconds:Number(state.watchVimeo?.video?.currentTime)||0,
      videoCount:document.querySelectorAll('#directVideoElement').length,
      activeSpeakerFollows:[...state.follows.keys()].length,
      likedCurrent:videoIdValue?state.myLikes.has(videoIdValue):false,
      speakerFollowActive:Boolean(document.querySelector('[data-follow-type="speaker"].active')),
      syncPlaylistNames:state.playlists.filter(p=>String(p.name||'').startsWith('IST-IOS-SYNC-')).map(p=>String(p.name||'')),
      currentId:videoIdValue,
      qaSyncPlaylistPresent:state.playlists.some(p=>String(p.name||'').startsWith('IST-IOS-SYNC-')),
      accountTokenPresent:Boolean(state.token),
      authenticatedProfile:Boolean(state.user&&document.getElementById('profileForm')),
      modalPlayer:Boolean(state.playerOpen),
    }});
  };
})();