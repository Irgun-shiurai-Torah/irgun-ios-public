(function(){
'use strict';
const IRGUN_DIRECT_HOSTS=new Set(['test.irgunshiuraitorah.com','irgunshiuraitorah.com','www.irgunshiuraitorah.com','localhost']);
const IRGUN_DIRECT_PROTOCOL=String(location.protocol||'').toLowerCase();
if(!IRGUN_DIRECT_HOSTS.has(String(location.hostname||'').toLowerCase())&&!['capacitor:','ionic:'].includes(IRGUN_DIRECT_PROTOCOL)) return;
let hlsPromise=null;
const SPEEDS=[.75,1,1.25,1.5,1.75,2];
const fmt=s=>{s=Math.max(0,Math.floor(Number(s)||0));const h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=s%60;return h?`${h}:${String(m).padStart(2,'0')}:${String(x).padStart(2,'0')}`:`${m}:${String(x).padStart(2,'0')}`};
function loadHls(api){if(window.Hls)return Promise.resolve(window.Hls);if(hlsPromise)return hlsPromise;hlsPromise=new Promise((resolve,reject)=>{const s=document.createElement('script');s.src=`${api}/media-player/hls.js`;s.async=true;const t=setTimeout(()=>{s.remove();hlsPromise=null;reject(new Error('HLS library timed out'))},12000);s.onload=()=>{clearTimeout(t);window.Hls?resolve(window.Hls):reject(new Error('HLS library unavailable'))};s.onerror=()=>{clearTimeout(t);hlsPromise=null;reject(new Error('HLS library failed to load'))};document.head.appendChild(s)});return hlsPromise}
class Player{
 constructor(o={}){this.c=o.container;this.iframe=o.iframe;this.api=String(o.apiBase||'').replace(/\/$/,'');this.cb=o;this.hls=null;this.backend='none';this.url='';this.sources={};this.loading=false;this.token=0;this.autoplayWanted=false;this.destroyed=false;this.hlsFatalRetries=0;this.hlsRetryTimer=null;this.hlsStableTimer=null;this.bufferTimer=null;this.lastProgressPosition=0;this.nativeVariants=[];this.build();if(o.poster)this.v.poster=String(o.poster);this.startFrameHealthMonitor()}
 build(){const r=document.createElement('div');r.id='directMediaPlayer';r.className='direct-media-player';r.hidden=true;r.innerHTML=`<video id="directVideoElement" class="direct-media-video" playsinline webkit-playsinline="true" preload="metadata"></video><div id="dmLoading" class="direct-media-loading" hidden><span class="direct-media-spinner"></span><span>Loading video...</span></div><div id="dmError" class="direct-media-error" hidden><span id="dmErrorText"></span><button id="dmRetry" type="button">Try Again</button></div><div class="direct-media-controls"><button id="dmPlay" class="direct-media-icon-button" type="button"><i class="fa-solid fa-play"></i></button><span id="dmNow" class="direct-media-time">0:00</span><input id="dmSeek" class="direct-media-seek" type="range" min="0" max="1000" value="0"><span id="dmDur" class="direct-media-time">0:00</span><button id="dmMute" class="direct-media-icon-button" type="button"><i class="fa-solid fa-volume-high"></i></button><input id="dmVol" class="direct-media-volume" type="range" min="0" max="1" step=".05" value="1"><select id="dmSpeed" class="direct-media-select">${SPEEDS.map(x=>`<option value="${x}"${x===1?' selected':''}>${x}x</option>`).join('')}</select><select id="dmQuality" class="direct-media-select" hidden><option value="-1">Auto</option></select><button id="dmPip" class="direct-media-icon-button" type="button" aria-label="Picture in Picture" title="Picture in Picture"><i class="fa-solid fa-window-restore"></i></button><button id="dmFull" class="direct-media-icon-button" type="button" aria-label="Fullscreen" title="Fullscreen"><i class="fa-solid fa-expand"></i></button></div>`;this.c.appendChild(r);this.r=r;this.v=r.querySelector('video');this.load=r.querySelector('#dmLoading');this.err=r.querySelector('#dmError');this.errText=r.querySelector('#dmErrorText');this.playBtn=r.querySelector('#dmPlay');this.seek=r.querySelector('#dmSeek');this.now=r.querySelector('#dmNow');this.dur=r.querySelector('#dmDur');this.vol=r.querySelector('#dmVol');this.mute=r.querySelector('#dmMute');this.speed=r.querySelector('#dmSpeed');this.v.defaultPlaybackRate=1;this.v.playbackRate=1;this.speed.value='1';this.quality=r.querySelector('#dmQuality');this.pipBtn=r.querySelector('#dmPip');this.bind()}
 bind(){const v=this.v;this.playBtn.onclick=()=>v.paused?this.playFromControl().catch(()=>{}):this.pause();this.bindVideoGestures();v.onplay=()=>{this.loading=false;this.load.hidden=true;this.err.hidden=true;this.icons();if(this.backend.startsWith('hls')){clearTimeout(this.hlsStableTimer);this.hlsStableTimer=setTimeout(()=>{this.hlsFatalRetries=0},5000)}this.cb.onPlay?.(this.state())};v.onpause=()=>{clearTimeout(this.bufferTimer);if(!this.loading)this.load.hidden=true;this.icons();if(!this.loading&&!v.ended)this.cb.onPause?.(this.state())};v.ontimeupdate=()=>{const position=this.current();if(Math.abs(position-this.lastProgressPosition)>.05){clearTimeout(this.bufferTimer);if(!this.loading)this.load.hidden=true}this.lastProgressPosition=position;this.timeline();this.cb.onTimeUpdate?.(this.state())};v.ondurationchange=()=>this.timeline();v.onended=()=>this.cb.onEnded?.(this.state());v.onwaiting=v.onstalled=()=>{clearTimeout(this.bufferTimer);const at=this.current();this.bufferTimer=setTimeout(()=>{if(!this.loading&&!v.paused&&!v.ended&&v.readyState<3&&this.current()<=at+.05)this.load.hidden=false},800)};v.onplaying=v.oncanplay=()=>{clearTimeout(this.bufferTimer);this.load.hidden=true};this.bindMediaError(v);const seekFromPointer=e=>{const d=this.duration();if(!d)return;const rect=this.seek.getBoundingClientRect();if(!rect.width)return;const clientX=Number(e.clientX);if(!Number.isFinite(clientX))return;const x=Math.max(0,Math.min(rect.width,clientX-rect.left));const ratio=x/rect.width;this.seek.value=String(Math.round(ratio*1000));this.now.textContent=fmt(d*ratio);void this.seekTo(d*ratio)};this.seek.onpointerdown=e=>{if(e.pointerType!=="touch"&&typeof e.button==="number"&&e.button!==0)return;seekFromPointer(e)};this.seek.onclick=seekFromPointer;this.seek.oninput=()=>{const d=this.duration();this.now.textContent=fmt(d*Number(this.seek.value)/1000)};this.seek.onchange=()=>this.seekTo(this.duration()*Number(this.seek.value)/1000);this.mute.onclick=()=>v.muted=!v.muted;this.vol.oninput=()=>{v.volume=Number(this.vol.value);if(v.volume)v.muted=false};v.onvolumechange=()=>this.volumeUI();this.speed.onchange=()=>this.setPlaybackRate(Number(this.speed.value));this.quality.onchange=()=>{if(this.hls)this.hls.currentLevel=Number(this.quality.value);else if(this.backend==='hls-native')this.selectNativeQuality(this.quality.value).catch(e=>this.notify(e))};rpip(this.pipBtn,v,active=>this.cb.onPipIntent?.(active));this.bindFullscreen(this.r.querySelector('#dmFull'));this.r.querySelector('#dmRetry').onclick=()=>this.activate(this.sources,this.current(),!v.paused,true).catch(e=>this.notify(e));this.icons();this.volumeUI();this.observeVideoFrames(v)}
 // Observe actual presented frames, not just currentTime. WKWebView can keep
 // advancing the media clock while iOS displays a frozen video frame.
 observeVideoFrames(video){
  if(!video||this.frameObservedVideo===video)return;
  this.frameObservedVideo=video;
  this.lastPresentedFrameAt=Date.now();
  this.frameHealthPreviousTime=null;
  this.frameHealthPreviousAt=0;
  if(typeof video.requestVideoFrameCallback!=='function')return;
  const onFrame=(_now,meta)=>{
   if(this.destroyed||this.v!==video)return;
   this.lastPresentedFrameAt=Date.now();
   this.lastFrameMediaTime=Number(meta?.mediaTime)||0;
   try{video.requestVideoFrameCallback(onFrame)}catch(_){}
  };
  try{video.requestVideoFrameCallback(onFrame)}catch(_){}
 }
 startFrameHealthMonitor(){
  // Restrict this recovery to native iOS WKWebView, not web or Android.
  if(!['capacitor:','ionic:'].includes(String(location.protocol||'').toLowerCase()))return;
  if(!this.frameHealthTimer)this.frameHealthTimer=setInterval(()=>this.checkVisualFrameHealth(),2000);
 }
 checkVisualFrameHealth(){
  const v=this.v,now=Date.now();
  if(this.destroyed||!v||typeof v.requestVideoFrameCallback!=='function'||
     document.hidden||!this.autoplayWanted||this.explicitlyPaused||
     v.paused||v.ended||v.seeking||v.readyState<2||this.loading||
     this.visualPlaybackPromise||this.decoderReloadPromise||
     v.webkitPresentationMode==='picture-in-picture'){
   this.frameHealthPreviousTime=null;this.frameHealthPreviousAt=0;return;
  }
  if(this.frameObservedVideo!==v){this.observeVideoFrames(v);return}
  const position=this.current();
  if(now-(this.lastPresentedFrameAt||now)<6500){
   this.frameHealthPreviousTime=position;this.frameHealthPreviousAt=now;return;
  }
  // Only recover when playback clock continues without a decoded frame.
  // Buffering and an intentionally paused or backgrounded player are untouched.
  if(this.frameHealthPreviousTime==null){
   this.frameHealthPreviousTime=position;this.frameHealthPreviousAt=now;return;
  }
  if(position-this.frameHealthPreviousTime<2)return;
  if(now-(this.lastVisualRecoveryAt||0)<12000)return;
  this.lastVisualRecoveryAt=now;
  this.frameHealthPreviousTime=position;this.frameHealthPreviousAt=now;
  void this.ensureVisualPlayback(true).catch(e=>console.warn('Frozen iOS video frame recovery failed',e));
 }
 bindMediaError(v){
  v.onerror=()=>{
   const token=this.token,error=v.error;
   if(this.loading||!error)return;
   setTimeout(()=>{
    // A Home handoff or decoder replacement can leave an error queued by the
    // previous source. It must never tear down the newly recovered player.
    if(this.destroyed||this.v!==v||this.token!==token||this.loading||this.backgroundReturnPending||v.error!==error)return;
    this.fatal(new Error('Direct video playback failed'));
   },0);
  };
 }
 bindVideoGestures(){
  const v=this.v;
  v.style.touchAction='none';
  // WKWebView can cancel pointer events when recognizing a double tap.
  // Touch releases remain the authoritative taps; pointers still drive swipes.
  v.ontouchstart=e=>{
   if(e.touches.length!==1){this.videoTouch=null;return}
   const t=e.touches[0];this.videoTouch={id:t.identifier,x:t.clientX,y:t.clientY};
  };
  v.ontouchcancel=()=>{this.videoTouch=null};
  v.ontouchend=e=>{
   const start=this.videoTouch;this.videoTouch=null;
   if(!start||e.touches.length)return;
   const t=Array.from(e.changedTouches).find(t=>t.identifier===start.id);
   if(!t||Math.hypot(t.clientX-start.x,t.clientY-start.y)>20)return;
   this.videoIgnoreClickUntil=Date.now()+500;this.handleVideoTap(t.clientX);
  };
  v.onpointerdown=e=>{
   if(e.isPrimary===false||(e.pointerType==='mouse'&&e.button!==0))return;
   this.videoPointer={id:e.pointerId,x:e.clientX,y:e.clientY,at:Date.now()};
   try{v.setPointerCapture(e.pointerId)}catch(_){}
  };
  v.onpointercancel=()=>{this.videoPointer=null};
  const minimizeFromSwipe=e=>{
   const start=this.videoPointer;if(!start||start.id!==e.pointerId)return false;
   const dx=e.clientX-start.x,dy=e.clientY-start.y;
   if(dy<65||dy<=Math.abs(dx)*1.4)return false;
   // Commit while moving: WebKit can cancel or delay the release during a drag.
   this.videoPointer=null;this.videoTouch=null;
   clearTimeout(this.videoTapTimer);this.videoLastTap=null;this.videoIgnoreClickUntil=Date.now()+500;
   try{v.releasePointerCapture?.(e.pointerId)}catch(_){}
   this.exitFullscreen();this.cb.onMinimize?.();e.preventDefault();return true;
  };
  v.onpointermove=e=>{minimizeFromSwipe(e)};
  v.onpointerup=e=>{
   if(minimizeFromSwipe(e))return;
   const start=this.videoPointer;this.videoPointer=null;
   if(!start||start.id!==e.pointerId)return;
   const dx=e.clientX-start.x,dy=e.clientY-start.y;
   if(Math.hypot(dx,dy)>20){
    clearTimeout(this.videoTapTimer);this.videoLastTap=null;this.videoIgnoreClickUntil=Date.now()+500;
   }else{
    // Touch clicks can be coalesced by WKWebView's double-tap recognizer.
    // Count physical releases, then ignore their compatibility click events.
    this.videoIgnoreClickUntil=Date.now()+500;
    if(e.pointerType!=='touch')this.handleVideoTap(e.clientX);
   }
  };
  v.onclick=e=>{
   if(Date.now()<(this.videoIgnoreClickUntil||0))return;
   this.handleVideoTap(e.clientX);
  };
  v.ondblclick=e=>e.preventDefault();
 }
 handleVideoTap(clientX){
  const box=this.v.getBoundingClientRect(),ratio=(clientX-box.left)/box.width;
  const side=ratio<.45?-1:ratio>.55?1:0,previous=this.videoLastTap;
  clearTimeout(this.videoTapTimer);
  if(side&&previous?.side===side&&Date.now()-previous.at<=450){
   this.videoLastTap=null;void this.seekBy(side*15);return;
  }
  this.videoLastTap={side,at:Date.now()};
  this.videoTapTimer=setTimeout(()=>{this.videoLastTap=null;if(!this.destroyed)this.playBtn.onclick()},450);
 }
 async seekBy(seconds){
  const wanted=this.autoplayWanted,token=this.token;
  await this.seekTo(this.current()+seconds);
  if(this.destroyed||token!==this.token)return;
  // Seek without changing Pause/Play intent; some iOS seeks pause temporarily.
  if(wanted&&this.autoplayWanted&&this.v.paused)await this.play().catch(()=>{});
  // Native HLS may keep playing audio after a seek while its video frames stop.
  // Verify the visual decoder too, without restarting an explicitly paused item.
  if(wanted&&this.autoplayWanted)await this.ensureVisualPlayback().catch(()=>{});
  this.showSeekFeedback(seconds);
 }
 showSeekFeedback(seconds){
  if(!this.seekFeedback){this.seekFeedback=document.createElement('div');this.seekFeedback.className='direct-media-seek-feedback';this.seekFeedback.setAttribute('aria-live','polite');this.r.appendChild(this.seekFeedback)}
  this.seekFeedback.textContent=seconds<0?'↶ 15 seconds':'15 seconds ↷';
  this.seekFeedback.style.left=seconds<0?'25%':'75%';this.seekFeedback.hidden=false;
  clearTimeout(this.seekFeedbackTimer);this.seekFeedbackTimer=setTimeout(()=>{if(this.seekFeedback)this.seekFeedback.hidden=true},700);
 }
 bindFullscreen(btn){
  if(this.fullscreenListener)document.removeEventListener('fullscreenchange',this.fullscreenListener);
  this.fullscreenButton=btn;
  this.fullscreenListener=()=>{
   const active=document.fullscreenElement===this.r;
   if(this.standardFullscreen&&!active){this.standardFullscreen=false;this.fullscreenResumeWanted=this.autoplayWanted&&!this.v.ended;this.fullscreenChanged(false);this.recoverFullscreenExit()}
  };
  document.addEventListener('fullscreenchange',this.fullscreenListener);
  btn.onclick=()=>{
   if(this.customFullscreen||document.fullscreenElement===this.r){this.exitFullscreen();return}
   this.fullscreenResumeWanted=!this.v.paused&&!this.v.ended;
   // Keep our controls and gestures available on iOS. AVKit's separate native
   // fullscreen surface pauses on Done and cannot receive web touch gestures.
   const nativeIos=['capacitor:','ionic:'].includes(String(location.protocol||'').toLowerCase());
   if(!nativeIos&&this.r.requestFullscreen){this.standardFullscreen=true;this.r.requestFullscreen().then(()=>this.fullscreenChanged(true)).catch(()=>{this.standardFullscreen=false;this.enterCustomFullscreen()})}
   else this.enterCustomFullscreen();
  };
 }
 enterCustomFullscreen(){
  if(this.destroyed||this.customFullscreen)return;
  this.fullscreenPlaceholder=document.createComment('video-fullscreen-home');
  this.r.parentNode.insertBefore(this.fullscreenPlaceholder,this.r);
  document.body.appendChild(this.r);this.r.classList.add('direct-media-fullscreen');
  this.customFullscreen=true;this.fullscreenChanged(true);
  if(this.fullscreenResumeWanted)this.recoverFullscreenExit();
 }
 exitFullscreen(resume=true){
  if(resume&&(this.customFullscreen||this.standardFullscreen))this.fullscreenResumeWanted=this.autoplayWanted&&!this.v.ended;
  if(this.customFullscreen){
   this.customFullscreen=false;this.r.classList.remove('direct-media-fullscreen');
   if(this.fullscreenPlaceholder?.parentNode){this.fullscreenPlaceholder.parentNode.insertBefore(this.r,this.fullscreenPlaceholder);this.fullscreenPlaceholder.remove()}
   this.fullscreenPlaceholder=null;this.fullscreenChanged(false);
   if(resume)this.recoverFullscreenExit();
  }else if(this.standardFullscreen&&document.fullscreenElement===this.r){void document.exitFullscreen?.()}
 }
 fullscreenChanged(active){
  this.fullscreenButton?.setAttribute('aria-label',active?'Exit Fullscreen':'Fullscreen');
  if(this.fullscreenButton)this.fullscreenButton.innerHTML=`<i class="fa-solid fa-${active?'compress':'expand'}"></i>`;
  this.cb.onFullscreen?.(active);
 }
 recoverFullscreenExit(){
  for(const timer of this.fullscreenRecoveryTimers||[])clearTimeout(timer);
  if(!this.fullscreenResumeWanted)return;
  this.fullscreenRecoveryTimers=[0,250,1000].map(delay=>setTimeout(()=>{
   if(this.destroyed||document.hidden||!this.autoplayWanted||this.v.ended)return;
   if(this.v.paused)void this.ensureVisualPlayback(false).catch(()=>{});
  },delay));
 }
 icons(){this.playBtn.setAttribute('aria-label',!this.v.paused&&!this.v.ended?'Pause video':'Play video');this.playBtn.innerHTML=`<i class="fa-solid fa-${!this.v.paused&&!this.v.ended?'pause':'play'}"></i>`}
 volumeUI(){const m=this.v.muted||this.v.volume===0;this.vol.value=String(this.v.volume);this.mute.innerHTML=`<i class="fa-solid fa-${m?'volume-xmark':this.v.volume<.5?'volume-low':'volume-high'}"></i>`}
 timeline(){const d=this.duration(),c=this.current();this.now.textContent=fmt(c);this.dur.textContent=fmt(d);this.seek.value=d?String(Math.round(c/d*1000)):'0'}
 clear(){clearTimeout(this.bufferTimer);this.lastProgressPosition=0;if(this.hls){try{this.hls.destroy()}catch(_){}this.hls=null}try{this.v.pause()}catch(_){}this.v.removeAttribute('src');try{this.v.load()}catch(_){}this.backend='none';this.url='';this.nativeVariants=[];this.quality.hidden=true;this.quality.innerHTML='<option value="-1">Auto</option>'}
 meta(token,ms=12000){if(this.v.readyState>=1)return Promise.resolve();return new Promise((res,rej)=>{const done=()=>{cl();token===this.token?res():rej(new Error('source replaced'))},bad=()=>{cl();rej(new Error('video metadata failed'))},cl=()=>{clearTimeout(t);this.v.removeEventListener('loadedmetadata',done);this.v.removeEventListener('error',bad)},t=setTimeout(()=>{cl();rej(new Error('video metadata timed out'))},ms);this.v.addEventListener('loadedmetadata',done,{once:true});this.v.addEventListener('error',bad,{once:true})})}
 async mp4(url,pos,auto){auto=Boolean(auto&&!this.explicitlyPaused);this.autoplayWanted=auto;const token=++this.token;this.loading=true;this.load.hidden=false;this.err.hidden=true;this.clear();this.backend='mp4';this.url=url;this.v.src=url;this.v.load();await this.meta(token);await this.seekTo(pos);this.loading=false;this.load.hidden=true;if(auto&&this.autoplayWanted)await this.play().catch(()=>{});return this.backend}
 async hlsLoad(url,pos,auto){if(this.destroyed)throw new Error('Video player destroyed');auto=Boolean(auto&&!this.explicitlyPaused);const token=++this.token;this.loading=true;this.load.hidden=false;this.err.hidden=true;this.autoplayWanted=Boolean(auto);this.clear();const nativeShell=['capacitor:','ionic:'].includes(String(location.protocol||'').toLowerCase()),nativeHls=Boolean(this.v.canPlayType('application/vnd.apple.mpegurl'));if(nativeShell&&nativeHls){this.backend='hls-native';this.url=url;try{this.v.preload='auto';this.v.playsInline=true;this.v.setAttribute('playsinline','');this.v.setAttribute('webkit-playsinline','true');if(auto){this.v.autoplay=true;this.v.setAttribute('autoplay','')}}catch(_){}this.v.src=url;this.v.load();await this.meta(token);if(token!==this.token)throw new Error('source replaced');await this.seekTo(pos);this.loading=false;this.load.hidden=true;void this.loadNativeQualities(url,token);if(auto&&this.autoplayWanted)await this.play();return this.backend}let H=null;try{H=await loadHls(this.api)}catch(_){}if(H?.isSupported?.()){const h=new H({enableWorker:true,lowLatencyMode:false,backBufferLength:60,maxBufferLength:30,maxMaxBufferLength:60,startPosition:Math.max(0,Number(pos)||0),capLevelToPlayerSize:true});this.hls=h;this.backend='hls-js';this.url=url;await new Promise((res,rej)=>{let done=false;const t=setTimeout(()=>finish(new Error('HLS manifest timeout')),12000),finish=e=>{if(done)return;done=true;clearTimeout(t);e?rej(e):res()};h.on(H.Events.MANIFEST_PARSED,()=>finish());h.on(H.Events.ERROR,(_e,d)=>{if(d?.fatal){if(!done)finish(new Error(`HLS failed: ${d.details||'fatal error'}`));else if(token===this.token)this.fatal(new Error(`HLS playback failed: ${d.details||'fatal error'}`))}});h.attachMedia(this.v);h.loadSource(url)});if(token!==this.token)throw new Error('source replaced');this.quality.innerHTML='<option value="-1">Auto</option>';for(const [i,l] of (h.levels||[]).entries()){const o=document.createElement('option');o.value=String(i);o.textContent=l.height?`${l.height}p`:`Quality ${i+1}`;this.quality.appendChild(o)}this.quality.hidden=(h.levels||[]).length<=1;await this.meta(token).catch(()=>{});await this.seekTo(pos);this.loading=false;this.load.hidden=true;if(auto&&this.autoplayWanted)await this.play().catch(()=>{});return this.backend}if(nativeHls){this.backend='hls-native';this.url=url;try{if(auto){this.v.autoplay=true;this.v.setAttribute('autoplay','')}}catch(_){}this.v.src=url;this.v.load();await this.meta(token);if(token!==this.token)throw new Error('source replaced');await this.seekTo(pos);this.loading=false;this.load.hidden=true;void this.loadNativeQualities(url,token);if(auto&&this.autoplayWanted)await this.play();return this.backend}throw new Error('HLS unsupported')}
 async activate(src={},pos=0,auto=false,force=false){if(this.destroyed)throw new Error('Video player destroyed');this.sources={hls:String(src.hls||''),mp4:String(src.mp4||'')};if(auto)this.explicitlyPaused=false;this.autoplayWanted=Boolean(auto);if(!force)this.hlsFatalRetries=0;this.show();const same=!force&&((this.sources.hls&&this.url===this.sources.hls&&this.backend.startsWith('hls'))||(this.sources.mp4&&this.url===this.sources.mp4&&this.backend==='mp4'));if(same){await this.seekTo(pos);if(auto&&this.autoplayWanted)await this.play().catch(()=>{});return{backend:this.backend}}let he;if(this.sources.hls){try{return{backend:await this.hlsLoad(this.sources.hls,pos,auto)}}catch(e){he=e}}if(this.sources.mp4){try{return{backend:await this.mp4(this.sources.mp4,pos,auto)}}catch(e){throw new Error(`Direct video failed${he?`; HLS: ${he.message}`:''}; MP4: ${e.message}`)}}throw he||new Error('No direct video source')}
 async loadNativeQualities(master,token){
  // Native iOS HLS adapts automatically, but its HTML video API does not expose
  // the rendition list. Read the multivariant playlist for the same choices.
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),7000);
  try{
   const response=await fetch(master,{credentials:'omit',signal:controller.signal});
   if(!response.ok)throw new Error('HLS playlist unavailable');
   const lines=(await response.text()).split(/\r?\n/),base=new URL(master),variants=[];
   for(let i=0;i<lines.length;i++){
    if(!lines[i].startsWith('#EXT-X-STREAM-INF:'))continue;
    const resolution=lines[i].match(/(?:^|,)RESOLUTION=\d+x(\d+)/i);
    const next=lines.slice(i+1).find(line=>line.trim()&&!line.startsWith('#'))?.trim();
    if(!resolution||!next)continue;
    const url=new URL(next,base);
    if(url.origin!==base.origin)continue;
    if(!variants.some(item=>item.height===Number(resolution[1])))variants.push({height:Number(resolution[1]),url:url.href});
   }
   if(token!==this.token||this.backend!=='hls-native'||this.url!==master)return;
   this.nativeVariants=variants.sort((a,b)=>a.height-b.height);
   this.quality.innerHTML='<option value="-1">Auto</option>';
   for(const variant of this.nativeVariants){const option=document.createElement('option');option.value=String(variant.height);option.textContent=`${variant.height}p`;this.quality.appendChild(option)}
   this.quality.hidden=this.nativeVariants.length<=1;
  }catch(error){if(error.name!=='AbortError')console.warn('Native HLS quality list unavailable',error)}
  finally{clearTimeout(timer)}
 }
 async selectNativeQuality(value){
  const target=String(value)==='-1'?this.url:this.nativeVariants.find(item=>String(item.height)===String(value))?.url;
  if(!target||this.backend!=='hls-native'||this.v.currentSrc===target)return;
  const token=++this.token,position=this.current(),playing=!this.v.paused,rate=this.v.playbackRate;
  this.loading=true;this.load.hidden=false;
  this.v.autoplay=playing;
  if(playing)this.v.setAttribute('autoplay','');else this.v.removeAttribute('autoplay');
  this.v.src=target;this.v.load();
  try{
   await this.meta(token);
   if(token!==this.token)return;
   await this.seekTo(position);
   this.v.playbackRate=rate;
   if(playing)await this.play();
  }catch(error){
   if(token!==this.token||target===this.url)throw error;
   // A single rendition can fail even when the adaptive master still works.
   this.quality.value='-1';
   this.v.src=this.url;this.v.load();
   await this.meta(token);await this.seekTo(position);
   this.v.playbackRate=rate;
   if(playing)await this.play();
  }finally{if(token===this.token){this.loading=false;this.load.hidden=true}}
 }
 destroy(){if(this.destroyed)return;this.destroyed=true;clearInterval(this.frameHealthTimer);clearTimeout(this.videoTapTimer);clearTimeout(this.seekFeedbackTimer);for(const timer of this.fullscreenRecoveryTimers||[])clearTimeout(timer);this.exitFullscreen(false);if(this.fullscreenListener)document.removeEventListener('fullscreenchange',this.fullscreenListener);++this.token;clearTimeout(this.hlsRetryTimer);clearTimeout(this.hlsStableTimer);this.clear()}
 fatal(e){
  if(this.destroyed)return;
  if(this.backend.startsWith('hls')&&this.sources.hls&&this.hlsFatalRetries<2){
   const p=this.current(),a=Boolean(this.autoplayWanted||!this.v.paused),attempt=++this.hlsFatalRetries;
   const failedToken=this.token,failedVideo=this.v;
   clearTimeout(this.hlsRetryTimer);this.loading=true;this.load.hidden=false;
   this.hlsRetryTimer=setTimeout(()=>{
    if(this.destroyed||this.token!==failedToken||this.v!==failedVideo)return;
    const pending=this.hlsLoad(this.sources.hls,p,a),retryToken=this.token;
    const current=()=>!this.destroyed&&this.token===retryToken&&this.v===failedVideo;
    pending.then(()=>{if(current()&&a)return this.ensureVisualPlayback(false)}).catch(x=>{if(current())this.fatal(x)});
   },250*attempt);return;
  }
  if(this.backend.startsWith('hls')&&this.sources.mp4){
   const p=this.current(),a=Boolean(this.autoplayWanted||!this.v.paused);
   const pending=this.mp4(this.sources.mp4,p,a),token=this.token,video=this.v;
   pending.catch(x=>{if(!this.destroyed&&this.token===token&&this.v===video)this.notify(x)});return;
  }
  this.notify(e);
 }
 notify(e){this.load.hidden=true;this.err.hidden=false;this.errText.textContent=String(e?.message||e||'Video failed');this.cb.onFatal?.({error:e,position:this.current(),autoplay:!this.v.paused,backend:this.backend})}
 current(){return Math.max(0,Number(this.v?.currentTime)||0)} duration(){const d=Number(this.v?.duration);return Number.isFinite(d)&&d>0?d:0} state(){return{position:this.current(),duration:this.duration(),paused:this.v.paused,ended:this.v.ended,playbackRate:this.v.playbackRate,backend:this.backend}}
 async seekTo(x){
  let n=Math.max(0,Number(x)||0),d=this.duration();if(d)n=Math.min(n,Math.max(0,d-.25));
  const v=this.v,token=this.token,sequence=this.seekSequence=(this.seekSequence||0)+1;
  if(n<=1){try{v.currentTime=n}catch(_){}this.timeline();return this.current()}
  // WKWebView can accept a currentTime assignment before native HLS is seekable,
  // then reset it to zero as the first segment arrives. Confirm the actual clock.
  return new Promise(resolve=>{
   let done=false,timer=null;
   const finish=()=>{if(done)return;done=true;clearTimeout(timer);clearInterval(retry);for(const event of events)v.removeEventListener(event,attempt);this.timeline();resolve(this.current())};
   const attempt=()=>{
    if(done)return;
    if(token!==this.token||sequence!==this.seekSequence){finish();return}
    const target=this.duration()?Math.min(n,Math.max(0,this.duration()-.25)):n;
    if(Math.abs(this.current()-target)<=1){if(!v.seeking&&v.readyState>=2)finish();return}
    try{v.currentTime=target}catch(_){}
    if(Math.abs(this.current()-target)<=1&&!v.seeking&&v.readyState>=2)finish();
   };
   const events=['loadedmetadata','loadeddata','canplay','seeked','durationchange','timeupdate'];
   for(const event of events)v.addEventListener(event,attempt);
   const retry=setInterval(attempt,300);
   timer=setTimeout(finish,7000);
   attempt();
  });
 }
 wakeVideoLayer(){const v=this.v;if(!v)return;try{v.playsInline=true;v.setAttribute('playsinline','');v.setAttribute('webkit-playsinline','true');v.style.display='block';v.style.visibility='visible';v.style.opacity='1';v.style.willChange='transform,opacity';v.style.webkitBackfaceVisibility='hidden';v.style.backfaceVisibility='hidden';if(typeof v.webkitSetPresentationMode==='function'&&v.webkitPresentationMode!=='picture-in-picture')try{v.webkitSetPresentationMode('inline')}catch(_){}v.style.webkitTransform='translate3d(0,0,0)';v.style.transform='translate3d(0,0,0)';void v.offsetWidth;try{v.getBoundingClientRect()}catch(_){}requestAnimationFrame(()=>{try{v.style.webkitTransform='translate3d(0,0,.001px)';v.style.transform='translate3d(0,0,.001px)';requestAnimationFrame(()=>{v.style.webkitTransform='translate3d(0,0,0)';v.style.transform='translate3d(0,0,0)'})}catch(_){}})}catch(_){}}
 async waitForVisualFrame(timeout=1100){
  const v=this.v;if(!v||v.paused)return false;
  if(typeof v.requestVideoFrameCallback==='function')return await new Promise(resolve=>{
   let done=false,first=null;
   const finish=x=>{if(done)return;done=true;clearTimeout(timer);resolve(Boolean(x))};
   const timer=setTimeout(()=>finish(false),timeout);
   const frame=(_now,meta)=>{
    if(done||v.paused){finish(false);return}
    if(first&&(meta?.presentedFrames>first.presentedFrames||meta?.mediaTime>first.mediaTime+.02)){finish(true);return}
    first=meta||{presentedFrames:0,mediaTime:this.current()};
    try{v.requestVideoFrameCallback(frame)}catch(_){finish(false)}
   };
   try{v.requestVideoFrameCallback(frame)}catch(_){finish(false)}
  });
  const beforeFrames=Number(v.webkitDecodedFrameCount),beforeTime=this.current();
  await new Promise(resolve=>setTimeout(resolve,Math.min(timeout,500)));
  const afterFrames=Number(v.webkitDecodedFrameCount);
  const decoded=Number.isFinite(beforeFrames)&&Number.isFinite(afterFrames)&&afterFrames>beforeFrames;
  // Older WebKit may not expose decoded-frame counts. Its advancing media clock
  // is the best available signal, but never accept a single initial still frame.
  const hasDecodeCounter=Number.isFinite(beforeFrames)&&Number.isFinite(afterFrames);
  return Boolean(!v.paused&&v.readyState>=2&&(decoded||(!hasDecodeCounter&&this.current()>beforeTime+.15)));
 }
 async relatchInlineVideoLayer(){const v=this.v;if(!v)return false;const at=this.current(),d=this.duration();try{v.playsInline=true;v.setAttribute('playsinline','');v.setAttribute('webkit-playsinline','true');if(typeof v.webkitSetPresentationMode==='function'&&v.webkitPresentationMode!=='picture-in-picture')v.webkitSetPresentationMode('inline')}catch(_){}try{v.style.display='block';v.style.visibility='visible';v.style.opacity='1';v.style.willChange='transform,opacity';v.style.webkitBackfaceVisibility='hidden';v.style.backfaceVisibility='hidden';v.style.webkitTransform='translate3d(0,0,.001px)';v.style.transform='translate3d(0,0,.001px)';void v.offsetWidth;try{v.getBoundingClientRect()}catch(_){}}catch(_){}const target=d>0?Math.min(Math.max(0,at+.02),Math.max(0,d-.15)):Math.max(0,at+.02);try{if(v.readyState>=1)v.currentTime=target}catch(_){}if(this.hls?.startLoad)try{this.hls.startLoad(target)}catch(_){}if(v.paused&&this.autoplayWanted&&!this.destroyed)try{await this.playForRecovery()}catch(_){}await new Promise(resolve=>requestAnimationFrame(resolve));try{v.style.webkitTransform='translate3d(0,0,0)';v.style.transform='translate3d(0,0,0)'}catch(_){}if(this.destroyed||!this.autoplayWanted)return false;if(v.paused){await new Promise(resolve=>setTimeout(resolve,80));if(this.autoplayWanted&&!this.destroyed)try{await this.playForRecovery()}catch(_){}}this.wakeVideoLayer();return !v.paused}
 async play(){if(this.destroyed)throw new Error('Video player destroyed');this.explicitlyPaused=false;this.autoplayWanted=true;this.show();this.wakeVideoLayer();if(this.hls?.startLoad)try{this.hls.startLoad(this.current())}catch(_){}const v=this.v,token=this.token;await v.play();if(this.destroyed||this.v!==v||this.token!==token||!this.autoplayWanted)return false;this.wakeVideoLayer();return true}
 async playForRecovery(timeout=2200){
  if(this.destroyed||!this.autoplayWanted)return false;
  const v=this.v,token=this.token;let timer;
  try{
   // WebKit can leave play() pending forever on a stuck native HLS seek.
   // Keep recovery bounded so frame checks and the alternate decoder can run.
   const played=await Promise.race([
    Promise.resolve(this.play()).then(()=>true,()=>false),
    new Promise(resolve=>{timer=setTimeout(()=>resolve(false),timeout)})
   ]);
   return played&&!this.destroyed&&this.v===v&&this.token===token&&this.autoplayWanted&&!v.paused;
  }finally{clearTimeout(timer)}
 }
 async playFromControl(){
  const token=this.token;
  await this.play();
  if(this.destroyed||token!==this.token||!this.autoplayWanted)return false;
  // A paused HLS seek can freeze the decoder until the next explicit Play.
  // Verify frames here too; low-level play() stays separate to avoid recursive
  // recovery while rebuilding a decoder. Working video keeps its source.
  return await this.ensureVisualPlayback();
 }
 async reloadInlineVideo(allowSourceFallback=false){
  if(this.decoderReloadPromise)return this.decoderReloadPromise;
  const pending=(async()=>{
   const saved={at:this.current(),rate:this.v.playbackRate,muted:this.v.muted,volume:this.v.volume};
   const rebuilding=this.rebuildInlineVideo(),token=this.token;
   let frames=false;
   try{frames=await rebuilding}catch(error){console.warn('Native video decoder rebuild failed',error)}
   if(token!==this.token)return false;
   if(frames||!allowSourceFallback||this.backend!=='hls-native'||!this.sources?.mp4||this.destroyed||document.hidden||!this.autoplayWanted)return frames;
   // A native HLS item can keep advancing audio with no decoded
   // video even after replacement. Recover using the same shiur's alternate
   // direct video source, preserving the current clock and user's Play intent.
   try{return await this.rebuildInlineVideo(this.sources.mp4,{...saved,at:Math.max(saved.at,this.current())})}catch(error){console.warn('Alternate video source recovery failed',error);return false}
  })();this.decoderReloadPromise=pending;
  try{return await pending}finally{if(this.decoderReloadPromise===pending)this.decoderReloadPromise=null}
 }
 async rebuildInlineVideo(alternateSource='',saved=null){
  if(this.destroyed||document.hidden||this.v.webkitPresentationMode==='picture-in-picture')return false;
  let v=this.v;
  const at=saved?.at??this.current(),rate=saved?.rate??v.playbackRate,muted=saved?.muted??v.muted,volume=saved?.volume??v.volume,source=alternateSource||v.src,token=++this.token;
  clearTimeout(this.hlsRetryTimer);
  this.loading=true;this.load.hidden=false;
  try{
   // A suspended WebKit video surface can stay frozen across load() calls.
   // Replace that surface while keeping the player, controls and live clock.
   v.autoplay=false;v.removeAttribute('autoplay');v.muted=true;
   if(source&&this.backend!=='hls-js'){
    const old=v,next=old.cloneNode(false);
    next.removeAttribute('src');next.removeAttribute('autoplay');next.autoplay=false;
    next.muted=true;next.volume=volume;
    clearTimeout(this.videoTapTimer);this.videoLastTap=null;this.videoPointer=null;this.videoTouch=null;
    for(const name of ['onplay','onpause','ontimeupdate','ondurationchange','onended','onwaiting','onstalled','onplaying','oncanplay','onerror','onvolumechange','onpointerdown','onpointermove','onpointerup','onpointercancel','ontouchstart','ontouchend','ontouchcancel','onclick','ondblclick'])old[name]=null;
    old.pause();old.removeAttribute('src');old.load();
    old.parentNode.replaceChild(next,old);this.v=v=next;
    this.bind();this.cb?.onVideoElementReplaced?.(old,next);
    this.decoderReloads=(this.decoderReloads||0)+1;
    if(alternateSource){this.backend='mp4';this.url=alternateSource;this.nativeVariants=[];this.quality.hidden=true;this.quality.innerHTML='<option value="-1">Auto</option>'}
    v.src=source;
   }
   v.load();
   await this.meta(token);
   if(this.destroyed||token!==this.token)return false;
   await this.seekTo(at);
   if(this.destroyed||token!==this.token)return false;
   v.playbackRate=rate;v.muted=muted;
   if(!this.autoplayWanted){v.autoplay=false;v.removeAttribute('autoplay');v.pause();return false}
   v.autoplay=true;v.setAttribute('autoplay','');
   if(this.backend==='hls-native'&&!this.nativeVariants?.length)void this.loadNativeQualities(this.url,this.token);
   this.loading=false;await this.playForRecovery();
   if(this.destroyed||token!==this.token||!this.autoplayWanted)return false;
   return await this.waitForVisualFrame(2200);
  }finally{
   if(!this.destroyed&&token===this.token){v.muted=muted;this.loading=false;this.load.hidden=true}
  }
 }
 async ensureVisualPlayback(forceRelatch=false){
  if(this.destroyed||!this.autoplayWanted)return false;
  if(this.visualPlaybackPromise)return this.visualPlaybackPromise;
  const pending=this.recoverVisualPlayback(forceRelatch);
  this.visualPlaybackPromise=pending;
  try{return await pending}finally{if(this.visualPlaybackPromise===pending)this.visualPlaybackPromise=null}
 }
 async recoverVisualPlayback(forceRelatch=false){
  if(this.destroyed||!this.autoplayWanted)return false;
  this.show();this.wakeVideoLayer();
  try{this.v.autoplay=true;this.v.setAttribute('autoplay','')}catch(_){}
  if(this.v.paused)try{await this.playForRecovery()}catch(_){}
  if(document.hidden||this.v.webkitPresentationMode==='picture-in-picture')return !this.v.paused;
  const nativeShell=['capacitor:','ionic:'].includes(String(location.protocol||'').toLowerCase());
  let frameSeen=await this.waitForVisualFrame();
  if(this.destroyed||!this.autoplayWanted)return false;
  if(document.hidden||this.v.webkitPresentationMode==='picture-in-picture')return !this.v.paused;
  if(forceRelatch||(!frameSeen&&nativeShell)){
   await this.relatchInlineVideoLayer();
   frameSeen=await this.waitForVisualFrame();
   if(this.destroyed||!this.autoplayWanted)return false;
  }
  if(!frameSeen&&nativeShell&&this.v.readyState>=2&&!document.hidden&&this.v.webkitPresentationMode!=='picture-in-picture'){
   // On a fresh iOS HLS item the audio clock can run against a frozen video
   // layer. Moving the same node, as mini/PiP does, rebuilds its WebKit layer.
   const at=this.current();
   try{this.v.pause()}catch(_){}
   (this.customFullscreen?document.body:this.c).appendChild(this.r);
   await new Promise(resolve=>requestAnimationFrame(resolve));
   if(this.destroyed||!this.autoplayWanted)return false;
   try{if(at>0)this.v.currentTime=at}catch(_){}
   try{await this.playForRecovery()}catch(_){}
   frameSeen=await this.waitForVisualFrame();
   if(this.destroyed||!this.autoplayWanted)return false;
  }
  if(!frameSeen&&nativeShell&&!document.hidden&&!this.destroyed&&this.v.webkitPresentationMode!=='picture-in-picture'){
   try{frameSeen=await this.reloadInlineVideo(true)}catch(error){console.warn('Native video decoder reload failed',error)}
  }
  if(this.destroyed||!this.autoplayWanted)return false;
  if(this.v.paused){
   if(this.hls?.startLoad)try{this.hls.startLoad(this.current())}catch(_){}
   try{await this.playForRecovery()}catch(_){}
  }
  this.wakeVideoLayer();
  return !this.v.paused&&(!nativeShell||frameSeen);
 }
 pause(stop=true){if(stop){this.explicitlyPaused=true;this.autoplayWanted=false;this.v.autoplay=false;this.v.removeAttribute?.('autoplay')}this.v.pause();if(stop&&this.hls?.stopLoad)try{this.hls.stopLoad()}catch(_){}} setPlaybackRate(x){x=SPEEDS.includes(Number(x))?Number(x):1;this.v.playbackRate=x;this.speed.value=String(x)} show(){this.r.hidden=false;if(this.iframe)this.iframe.style.display='none'} showVimeo(){this.pause(true);this.r.hidden=true;if(this.iframe)this.iframe.style.display='block'}
}
function rpip(btn,v,onIntent){
 if(!btn)return;
 const standard=()=>Boolean(document.pictureInPictureEnabled&&typeof v.requestPictureInPicture==='function');
 const webkit=()=>{try{return typeof v.webkitSetPresentationMode==='function'&&typeof v.webkitSupportsPresentationMode==='function'&&v.webkitSupportsPresentationMode('picture-in-picture')}catch(_){return false}};
 const supported=standard()||webkit();
 btn.hidden=!supported;
 if(!supported)return;
 const active=()=>document.pictureInPictureElement===v||v.webkitPresentationMode==='picture-in-picture';
 // Diagnostic state is available to disposable simulator observations, but it
 // never contains user or media content.
 const diagnostic=btn.__irgunPipDiagnostic={clicks:0,route:'',error:'',lastEvent:'',requested:false};
 const update=()=>{
  const on=active();
  diagnostic.active=on;
  btn.classList.toggle('active',on);
  btn.setAttribute('aria-label',on?'Exit Picture in Picture':'Picture in Picture');
  btn.title=on?'Exit Picture in Picture':'Picture in Picture';
  btn.innerHTML=`<i class="fa-solid fa-${on?'arrow-right-from-bracket':'window-restore'}"></i>`;
 };
 btn.onclick=async()=>{
  const opening=!active();
  diagnostic.clicks+=1;
  diagnostic.requested=opening;
  diagnostic.error='';
  onIntent?.(opening);
  try {
   if(!opening){
    if(document.pictureInPictureElement===v&&document.exitPictureInPicture){
     diagnostic.route='standard-exit';
     await document.exitPictureInPicture();
    }else if(webkit()){
     diagnostic.route='webkit-exit';
     v.webkitSetPresentationMode('inline');
    }
   }else if(webkit()){
    // WKWebView on iOS provides WebKit's presentation-mode API. Prefer it to
    // the standard API: the latter can exist while native PiP is unavailable.
    diagnostic.route='webkit';
    try{
     v.webkitSetPresentationMode('picture-in-picture');
    }catch(error){
     if(!standard())throw error;
     diagnostic.route='webkit-to-standard';
     await v.requestPictureInPicture();
    }
   }else if(standard()){
    diagnostic.route='standard';
    await v.requestPictureInPicture();
   }else throw new Error('Picture-in-Picture is unavailable');
  }catch(error){
   diagnostic.error=String(error?.name||'Error')+': '+String(error?.message||error||'Unknown failure');
   onIntent?.(false);
   console.warn('Picture-in-Picture failed',error);
  }
  update();
 };
 for(const type of ['enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged']){
  v.addEventListener(type,()=>{
   diagnostic.lastEvent=type;
   update();
  });
 }
 update();
}
window.ISTDirectMediaPlayer=Player;
})();
