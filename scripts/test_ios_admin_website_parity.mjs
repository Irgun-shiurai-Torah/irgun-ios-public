import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {parseAdminScheduleJson,parseAdminDateCsv,planAdminDateChanges,createWebsiteAdminParity} from '../src/admin-website-parity.js';

test('bulk schedule preview rejects invalid rows and preserves sourceId',()=>{
  const ok=parseAdminScheduleJson(JSON.stringify({sourceId:'2-cheshvan',events:[
    {date:'2026-10-19',startTime:'09:15',location:'Boro Park',speaker:'Rav Smith',title:'Halacha'}
  ]}));
  assert.equal(ok.sourceId,'2-cheshvan');assert.equal(ok.events.length,1);
  assert.throws(()=>parseAdminScheduleJson(''),/Paste schedule/);
  assert.throws(()=>parseAdminScheduleJson('{}'),/events array/);
  assert.throws(()=>parseAdminScheduleJson('not json'),/Invalid JSON/);
  assert.throws(()=>parseAdminScheduleJson(JSON.stringify({events:[{date:'2026-02-31',location:'X'}]})),/valid date/);
  assert.throws(()=>parseAdminScheduleJson(JSON.stringify({events:Array(101).fill(ok.events[0])})),/at most 100/);
});

test('date CSV handles quoted commas, embedded newlines, and BOM',()=>{
  const rows=parseAdminDateCsv('\ufeffVimeo ID,New Lecture Date,Irgun Title (DO NOT CHANGE)\r\n123,2026-10-19,"Topic, Subtopic"\r\n456,2026-10-20,"Two\nlines"\r\n');
  assert.equal(rows.length,3);
  assert.equal(rows[1][2],'Topic, Subtopic');assert.equal(rows[2][2],'Two\nlines');
});

test('date-only plan refuses changed titles, duplicates, missing IDs and impossible dates',()=>{
  const videos=[
    {id:'1',title:'One: Story',lectureDate:'2026-09-01'},
    {id:'2',title:'Second Shiur',lectureDate:'2026-10-10'},
    {id:'3',title:'Third Shiur',lectureDate:'2026-10-15'}
  ];
  const csv='Vimeo ID,New Lecture Date,Irgun Title (DO NOT CHANGE)\n'+
    '1,2026-10-19,One Story\n2,2026-10-10,Second Shiur\n'+
    '3,2026-10-20,Wrong Title\n4,2026-10-20,Other\n'+
    '1,2026-10-21,One Story\n3,2026-02-30,Third Shiur';
  const plan=planAdminDateChanges(csv,videos);
  assert.deepEqual(plan.items.map(x=>x.status),['ready','unchanged','review','missing','invalid','invalid']);
  assert.deepEqual(plan.counts,{ready:1,unchanged:1,review:1,missing:1,invalid:2});
  assert.deepEqual(Object.keys(plan.items[0]).sort(),
    ['id','newDate','csvTitle','currentTitle','currentDate','status'].sort());
  assert.throws(()=>planAdminDateChanges('foo,bar\na,b',videos),/Expected the Irgun/);
});

const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,ch=>({
  '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
}[ch]));

test('website admin panels require authenticated admin, escape data, and never leak between users',async()=>{
  let allowed=false,account='a',rerenders=0;
  const requests=[];
  const controller=createWebsiteAdminParity({
    apiJson:async p=>{requests.push(p);return {items:[{id:'x',text:'<script>',author:'<b>',videoId:'1'}],total:1,page:1,hasMore:false}},
    esc:escapeHtml,isAdmin:()=>allowed,isAdminMode:()=>true,userKey:()=>account,
    render:()=>{rerenders++},toast:()=>{},ask:()=>true
  });
  assert.equal(controller.html(),'');
  allowed=true;
  assert.match(controller.html(),/Comments Management/);
  assert.match(controller.html(),/Playback Routing/);
  const listeners={};
  const host={addEventListener:(name,handler)=>{listeners[name]=handler}};
  controller.bind({getElementById:id=>id==='websiteAdminParity'?host:null});
  assert.equal(typeof listeners.click,'function');
  const choice={dataset:{hubPanel:'comments'}};
  listeners.click({target:{closest:s=>s==='[data-hub-panel]'?choice:null}});
  await controller.loadOpened();
  assert.deepEqual(requests,['/admin/comments?page=1']);
  assert.match(controller.html(),/&lt;script&gt;/);
  assert.doesNotMatch(controller.html(),/<script>/);
  account='b';
  assert.doesNotMatch(controller.html(),/&lt;script&gt;/);
  assert.ok(rerenders>0);
});

test('main app integrates the admin panel without weakening Worker authorization or changing public controls',()=>{
  const main=readFileSync('src/main.js','utf8');
  const mod=readFileSync('src/admin-website-parity.js','utf8');
  assert.match(main,/import \{ createWebsiteAdminParity \} from '\.\/admin-website-parity\.js';/);
  assert.match(main,/isAdmin:\(\)=>Boolean\(state\.user\s*&&\s*state\.isAdmin\)/);
  assert.match(main,/apiJson,esc/);
  assert.match(main,/websiteAdminParity\.html\(\)/);
  assert.match(main,/websiteAdminParity\.bind\(document\)/);
  for(const url of ['/admin/contact-messages','/admin/comments','/admin/playback-routing',
    '/admin/city-admins','/admin/drive-video-cities','/admin/analytics/live',
    '/admin/analytics/history','/admin/video','/admin/schedule'])
    assert.ok(mod.includes(url),'Missing protected endpoint '+url);
  assert.match(mod,/confirmAdminMode/);
  assert.doesNotMatch(mod,/localStorage\.(setItem|getItem)/,'No admin data cached in localStorage');
  assert.doesNotMatch(mod,/Authorization.*Bearer/,'Never assemble or expose an account token in admin panel HTML');
});


test('City Admin upload and edit are protected and reuse the iOS authenticated API',async()=>{
  const {createCityAdminController,cityAdminPanelHtml}=await import('../src/admin-city-panel.js');
  const markup=cityAdminPanelHtml();
  for(const id of ['cityAdminCitySelect','cityUploadMediaKind','cityUploadFile',
    'cityAdminUploadForm','cityAdminEditorForm','cityAdminShiurList','cityEditTitle',
    'cityEditLectureDate','cityEditShiurCode'])
    assert.ok(markup.includes('id="'+id+'"'), 'Missing city upload/edit control '+id);
  const controller=createCityAdminController({apiJson:async()=>({}),apiFetch:async()=>({ok:true})});
  assert.equal(typeof controller.bind,'function');
  assert.equal(typeof controller.loadCityAdminPanel,'function');
  controller.reset();
  const src=readFileSync('src/admin-city-panel.js','utf8');
  assert.match(src,/apiJson\(path,\{\.\.\.options,headers\}\)/);
  assert.match(src,/apiFetch\(endpoint,\s*\{/);
  assert.match(src,/city-admin\/upload\/start/);
  assert.match(src,/city-admin\/upload\/complete/);
  assert.match(src,/city-admin\/upload\/.*\/publish/);
  assert.match(src,/city-admin\/shiurim\?city=/);
  assert.match(src,/city-admin\/shiur\/.*DELETE/);
  assert.doesNotMatch(src,/window\.API/,'Do not bypass the native Bearer auth bridge');
  const main=readFileSync('src/main.js','utf8');
  assert.match(main,/apiJson\('\/city-admin\/status'\)/);
  assert.match(main,/state\.isCityAdmin=Array\.isArray\(data\.cities\)\s*&&\s*data\.cities\.length>0/);
  assert.match(main,/state\.accountSection === 'city-admin' && state\.isCityAdmin/);
  assert.match(main,/cityAdminController\.bind\(\)/);
  assert.match(main,/cityAdminController\.reset\(\)/);
});

test('Paid buyers and code discounts keep explicit admin authorization and do not remove untouched promos',()=>{
  const src=readFileSync('src/main.js','utf8');
  assert.match(src,/if\(!state\.isAdmin\|\|state\.adminPaidBuyersLoading\)return/);
  assert.match(src,/apiJson\('\/admin\/paid-purchases'\)/);
  assert.match(src,/data-admin-buyers-refresh/);
  assert.match(src,/adminPaidPromoCode/);
  assert.match(src,/adminPaidPromoType/);
  assert.match(src,/adminPaidPromoMaxUses/);
  assert.match(src,/adminPaidPromoOnePerUser/);
  assert.match(src,/adminPaidPromoDelete/);
  assert.match(src,/if\(state\.adminPaidPromoDirty\)/);
  assert.match(src,/body\.promo=\{/);
  assert.match(src,/previousCode:String\(previous\?\.code\|\|''\)/);
  assert.match(src,/action:'upsert',item/);
  assert.match(src,/state\.adminPaidBuyers = \[\]/,'Buyers must clear on logout');
});

test('Apple public audio library never gains payment controls from website-admin parity',()=>{
  const main=readFileSync('src/main.js','utf8');
  assert.match(main,/!IS_IOS && state\.isAdmin && state\.adminMode/,
    'Public iOS audio catalog should not show editable purchase cards');
  assert.match(main,/data-admin-catalog-load="1"/,
    'Audio product edits are available from protected Admin only');
  assert.match(main,/state\.isAdmin \? accountAdminHtml\(\)/,
    'Full admin panel is gated by verified account permissions');
  assert.match(main,/state\.isCityAdmin \? cityAdminPanelHtml\(\)/,
    'Limited city administration has its own authorization gate');
  assert.doesNotMatch(readFileSync('src/admin-website-parity.js','utf8'),/createCheckout|data-paid-purchase/,
    'No purchase call-to-action may be added by admin modules');
});

test('Admin parity UI includes all eight website-only management groups',()=>{
  const src=readFileSync('src/admin-website-parity.js','utf8');
  for (const label of ['Contact Messages','Comments Management','Playback Routing','Bulk Schedule JSON',
    'Lecture Date CSV','City Admins','Video City Names','Analytics Dashboard']) {
    assert.ok(src.includes(label), 'Missing '+label);
  }
  const css=readFileSync('src/admin-website-parity.css','utf8');
  assert.match(css,/\.admin-parity-menu\{/);
  assert.match(css,/\.admin-parity-row\{/);
  assert.match(css,/\.admin-parity-metrics\{/);
});

test('City Admin roles and buyer data reset before checking permissions after both login methods',()=>{
  const main=readFileSync('src/main.js','utf8');
  const occurrences=(main.match(/state\.cityAdminChecked = false;\s*cityAdminController\.reset\(\);\s*websiteAdminParity\.reset\(\)/g)||[]);
  assert.equal(occurrences.length,2,'Email and social login must reset account-scoped privileges');
  assert.match(main,/state\.isCityAdmin = false;\s*state\.cityAdminChecked = false;/);
  assert.match(main,/await checkAdminStatus\(true\);/);
  assert.match(main,/state\.adminPaidBuyersLoaded = false;/);
});


test('iOS homepage matches the approved iPad screenshot layout',()=>{
  const main=readFileSync('src/main.js','utf8');
  const css=readFileSync('src/style.css','utf8');
  const begin=main.indexOf('function homeHtml() {');
  const end=main.indexOf('\nfunction liveHtml()',begin);
  assert.ok(begin>=0 && end>begin,'Live homepage renderer must exist');
  const home=main.slice(begin,end);
  const discover=main.slice(main.indexOf('function homeDiscoveryHtml() {'),
    main.indexOf('function promiseWithTimeout('));
  assert.match(home,/const heroTitle = IS_IOS \? tr\('Torah, wherever you are\.'\)/);
  assert.match(home,/const heroTagline = tr\('Live shiurim, thousands of recordings, and your personal Torah library—all in one app\.'\)/);
  const headline=home.indexOf("<h1>' + heroTitle + '</h1>'");
  const subtitle=home.indexOf("'<p class=\"hero-subtitle\">' + heroTagline");
  assert.ok(headline>0 && subtitle>headline,
    'The short Torah statement must be the heading, and the longer message its subtitle');
  assert.match(discover,/ios-home-stacked-heading/);
  assert.match(discover,/\+ historyButton \+ '<\/div>'/);
  assert.doesNotMatch(discover,/IS_IOS \? '<div class="home-section-footer">'\s*\+ historyButton/);
  assert.match(home,/ios-home-inline-heading/);
  assert.match(home,/<h2>Live Now<\/h2><button class="section-link" data-nav="live">View live page/);
  assert.match(home,/IS_IOS \? '' : '<span class="section-kicker">COMING UP<\/span>'/);
  assert.match(home,/const upcomingBlock =[^\n]*ios-home-stacked-heading[^\n]*\+ fullScheduleButton \+ '<\/div>'/);
  assert.match(home,/const latestBlock =[^\n]*ios-home-stacked-heading[^\n]*\+ browseAllButton \+ '<\/div>'/);
  assert.doesNotMatch(home,/IS_IOS \? '<div class="home-section-footer">'\s*\+ (fullScheduleButton|browseAllButton)/);
  assert.match(css,/body\.irgun-ios \.ios-home-inline-heading \{/,
    'Keep the Live Now link beside its title');
  assert.match(css,/body\.irgun-ios \.ios-home-stacked-heading \{[^}]*flex-direction:column/,
    'Move History, Full Schedule and Browse All directly below their titles');
  assert.match(css,/body\.irgun-ios \.pro-hero h1 \{[^}]*font-size:clamp\(32px,4vw,44px\)/);
});
