import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {
  normalizeIosVimeoMode,isIosVimeoOnlyLecture,visibleIosLectureCatalog,
  iosVimeoWatchEngine,iosVideoDescriptorPath,IOS_VIDEO_CATALOG_PATH
} from '../src/ios-vimeo-mode.js';

const vimeo={id:'1237352749',hasDriveVideo:false,sourceType:''};
const unlisted={id:'1233236785:585d5d53db',hasDriveVideo:false,sourceType:''};
const drive={id:'123123',hasDriveVideo:true,sourceType:''};
const direct={id:'city-2026',hasDriveVideo:true,sourceType:'city-drive',directVideo:true};
const purchased={id:'paid-track-123',sourceType:'drive-library',hasDriveVideo:true};

test('Apple setting is independent and defaults to Vimeo Player',()=>{
  assert.equal(normalizeIosVimeoMode({vimeoOnlyIosMode:'vimeo',vimeoOnlyAppMode:'our-player',vimeoOnlyWebsiteMode:'off'}),'vimeo');
  assert.equal(normalizeIosVimeoMode({vimeoOnlyIosMode:'off',vimeoOnlyAppMode:'our-player'}),'off');
  assert.equal(normalizeIosVimeoMode({vimeoOnlyIosMode:'our-player',vimeoOnlyAppMode:'off'}),'our-player');
  assert.equal(normalizeIosVimeoMode({vimeoOnlyAppMode:'off',vimeoOnlyWebsiteMode:'off'}),'vimeo');
  assert.equal(normalizeIosVimeoMode({showVimeoOnlyIos:false,vimeoOnlyAppMode:'our-player'}),'off');
  assert.equal(normalizeIosVimeoMode('invalid'),'vimeo');
});

test('Apple Off removes Vimeo-only lectures, not Drive-backed lectures or purchases',()=>{
  assert.ok(isIosVimeoOnlyLecture(vimeo));
  assert.ok(isIosVimeoOnlyLecture(unlisted));
  assert.equal(isIosVimeoOnlyLecture(drive),false);
  assert.equal(isIosVimeoOnlyLecture(direct),false);
  assert.equal(isIosVimeoOnlyLecture(purchased),false);
  const items=[vimeo,unlisted,drive,direct,purchased];
  assert.deepEqual(visibleIosLectureCatalog(items,'off').map(x=>x.id),['123123','city-2026','paid-track-123']);
  assert.deepEqual(visibleIosLectureCatalog(items,'vimeo'),items);
  assert.deepEqual(visibleIosLectureCatalog(items,'our-player'),items);
  assert.deepEqual(visibleIosLectureCatalog(null,'off'),[]);
});

test('Each Apple Vimeo mode chooses correct engine; Drive always stays native',()=>{
  assert.equal(iosVimeoWatchEngine(vimeo,'off',true),'hidden');
  assert.equal(iosVimeoWatchEngine(vimeo,'vimeo',true),'vimeo');
  assert.equal(iosVimeoWatchEngine(vimeo,'our-player',true),'native');
  assert.equal(iosVimeoWatchEngine(vimeo,'our-player',false),'legacy-direct');
  assert.equal(iosVimeoWatchEngine(drive,'off',true),'native');
  assert.equal(iosVimeoWatchEngine(drive,'vimeo',true),'native');
  assert.equal(iosVimeoWatchEngine(direct,'off',true),'native');
  assert.equal(iosVimeoWatchEngine(purchased,'off',true),'native');
});

test('Native Apple requests explicitly identify client=ios, including privacy suffixes',()=>{
  assert.equal(IOS_VIDEO_CATALOG_PATH,'/video-map?driveLibrary=1&client=ios');
  assert.equal(iosVideoDescriptorPath(vimeo.id),'/media/1237352749/source.json?client=ios');
  assert.equal(iosVideoDescriptorPath(unlisted.id),'/media/1233236785%3A585d5d53db/source.json?client=ios');
});

test('App routes only Vimeo-only lectures through mode; Our Player does not silently embed Vimeo',()=>{
  const main=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
  assert.match(main,/await loadIosVimeoOnlyMode\(\);[\s\S]*?bootstrapJson\(IOS_VIDEO_CATALOG_PATH\)/);
  assert.match(main,/visibleIosLectureCatalog\(\(Array\.isArray\(videos\)/);
  assert.match(main,/const engine = iosVimeoWatchEngine\(video,state\.vimeoOnlyIosMode,Boolean\(iosUnified\)\)/);
  assert.match(main,/if \(engine==='vimeo'\)/);
  assert.match(main,/if \(vimeoOnly && state\.vimeoOnlyIosMode==='our-player'\)/);
  assert.match(main,/const sources = await loadIosDirectVideoSources\(video\)/);
  assert.match(main,/iosUnified\.open/);
  assert.match(main,/refreshIosVimeoModeOnReturn\(\)/);
});

test('Swift AVPlayer permits only signed Vimeo recorded-video routes, preserving existing owned sources',()=>{
  const swift=readFileSync(new URL('./IrgunUnifiedPlayerPlugin.swift',import.meta.url),'utf8');
  assert.match(swift,/host == "player\.vimeo\.com"/);
  assert.match(swift,/path\.hasPrefix\("\/play\/"\)/);
  assert.match(swift,/path\.hasPrefix\("\/progressive_redirect\/"\)/);
  assert.match(swift,/host\.hasSuffix\("\.vimeocdn\.com"\)/);
  assert.match(swift,/guard url\.user == nil && url\.password == nil/);
  assert.match(swift,/host == "api\.irgunshiuraitorah\.com"/);
  assert.match(swift,/let url = self\.playableURL\(source\)/);
});

test('Apple Admin can update exactly one of three platform modes',()=>{
  const admin=readFileSync(new URL('../src/admin-website-parity.js',import.meta.url),'utf8');
  for (const key of ['vimeoOnlyWebsiteMode','vimeoOnlyAppMode','vimeoOnlyIosMode'])
    assert.ok(admin.includes(key),'Missing admin control: '+key);
  assert.match(admin,/\{\[key\]:mode\}/);
  assert.match(admin,/formName==='vimeo-ios'/);
  assert.match(admin,/onIosVimeoVisibilityChanged\(mode\)/);
});
