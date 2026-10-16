import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {lectureFollowTargets,fallbackSpeakerFollowKey,followVerb,isFollowTargetActive,VALID_FOLLOW_KEY} from '../src/follow-controls.js';

const rav={id:'he-123abc',nameEn:'Avraham Cohen',nameHe:'אברהם כהן',displayEn:'Rav Avraham Cohen',displayHe:'הרב אברהם כהן'};
const metadata={speakerById:new Map([[rav.id,rav]]),topicById:new Map([['halacha',{en:'Halacha',he:'הלכה'}]]),speakerAliasToId:new Map([['avraham cohen',rav.id],['אברהם כהן',rav.id]])};

test('lecture speaker and topic have Follow targets in Hebrew',()=>{
  const targets=lectureFollowTargets({_speakerIds:[rav.id],_topicId:'halacha'},metadata);
  assert.equal(targets.length,2);
  assert.equal(targets[0].key,rav.id);
  assert.equal(targets[0].labelHe,'הרב אברהם כהן');
  assert.equal(targets[1].labelHe,'הלכה');
});
test('Hebrew-only speaker is Follow-able even without bundled speaker metadata',()=>{
  const targets=lectureFollowTargets({speakerHe:'הרב יעקב ישראל לוי',_speakerIds:[]},metadata);
  assert.equal(targets.length,1);
  assert.ok(VALID_FOLLOW_KEY.test(targets[0].key));
  assert.equal(targets[0].labelHe,'הרב יעקב ישראל לוי');
});
test('known speaker aliases reuse official metadata IDs',()=>{
  assert.equal(lectureFollowTargets({speaker:'Rav Avraham Cohen'},metadata)[0].key,rav.id);
});
test('old auto-speaker colon keys are converted to valid API keys',()=>{
  const t=lectureFollowTargets({_speakerIds:['auto-speaker:יעקב ישראל'],_speakerLabel:'הרב יעקב ישראל'},metadata)[0];
  assert.equal(t.key,fallbackSpeakerFollowKey('יעקב ישראל'));
  assert.ok(VALID_FOLLOW_KEY.test(t.key));
});
test('Hebrew and English Follow/Following text',()=>{
  assert.equal(followVerb(false,true),'עקוב'); assert.equal(followVerb(true,true),'במעקב');
  assert.equal(followVerb(false,false),'Follow'); assert.equal(followVerb(true,false),'Following');
});
test('fallback IDs recognize server canonicalized follows by speaker label',()=>{
  const target=lectureFollowTargets({speakerHe:'הרב אברהם כהן'})[0];
  assert.ok(isFollowTargetActive(target,new Map([['speaker:he-123abc',{type:'speaker',key:rav.id,labelEn:rav.displayEn,labelHe:rav.displayHe}]])));
  assert.equal(isFollowTargetActive(target,new Map()),false);
});
test('does not manufacture a speaker without any real speaker or topic',()=>{
  assert.deepEqual(lectureFollowTargets({title:'Weekly Shiur'}),[]);
});
test('video watch and audio sheet use Follow controls and refresh locale',()=>{
  const app=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
  assert.match(app,/function currentFollowButtons\(video\)/);
  assert.match(app,/const followButtons = currentFollowButtons\(v\)/);
  assert.match(app,/const followButtons = currentFollowButtons\(sourceItem\)/);
  assert.match(app,/data-follow-label-he/);
  // Follow buttons compute the locale once and pass that flag to followVerb.
  assert.match(app,/const he\s*=\s*currentLanguage\(\)\s*===\s*'he'/);
  assert.match(app,/followVerb\(following,\s*he\)/);
  assert.match(app,/WEBSITE \+ 'library-metadata\.json'/);
});
