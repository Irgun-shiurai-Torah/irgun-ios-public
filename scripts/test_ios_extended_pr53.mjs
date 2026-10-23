import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read = path => readFileSync(path,'utf8');
const workflow=read('.github/workflows/ios-extended-regressions.yml');
const runner=read('.github/regression/run_ui.sh');
const prep=read('.github/regression/prepare.py');
const swift=read('.github/regression/tests.swift');
const observer=read('.github/regression/observer.js');

test('extended QA automatically triggers on PR53 review-branch updates and retains manual runs',()=>{
  assert.match(workflow,/workflow_dispatch:/);
  assert.match(workflow,/push:\s*\n\s*branches:\s*\n\s*- fix\/ios-direct-audio-compact-speed-preview-20261023/);
  for(const path of ["'.github/regression/**'","'src/**'","'scripts/**'"]) assert.ok(workflow.includes(path));
  assert.match(workflow,/cancel-in-progress: false/);
  assert.match(workflow,/IRGUN_TEST_EMAIL_2/);
  assert.match(workflow,/IRGUN_TEST_EMAIL_3/);
});

for(const method of ['testRegressionDirectListenAndOriginalFullPlayer','testRegressionWatchOptionThreePopupAndNativeSpeed']) {
  test('native extended suite compiles and actually requests '+method,()=>{
    assert.match(swift,new RegExp('func '+method+'\\(\\) throws'));
    assert.ok(runner.includes(method),'Must select this genuine XCTest in run_ui.sh, not silently run zero tests');
    assert.ok(prep.includes(method),'Must assert native test was injected into Xcode target');
  });
}

test('extended suite enumerates 14 real test methods (including cross-device)',()=>{
  assert.match(prep,/assert count==14/);
  assert.equal((swift.match(/func testRegression/g)||[]).length,13);
  assert.equal((read('.github/regression/account-regressions.swift').match(/func testRegression/g)||[]).length,1);
});

test('direct Listen QA taps the actual library button from a cold player',()=>{
  assert.match(observer,/listenVideo: '#shiurimResults \[data-listen-video\]'/);
  assert.match(observer,/const selected = window\.__ISTQAChooseWatchButton\?\./);
  assert.match(observer,/listenFixture,/);
  assert.match(swift,/XCTAssertFalse\(initialNative\["active"\]/);
  assert.match(swift,/regressionTap\("listenVideo"\)/);
  assert.match(swift,/Direct Listen must advance the actual AVPlayer audio clock/);
  assert.match(swift,/fullSpeedChoiceCount/);
  assert.match(swift,/fullSpeedPopupCount/);
});

test('Watch UI QA verifies actual capsule and original transport on a real native item',()=>{
  assert.match(observer,/audioSpeedOpen: '\.watch-audio-panel \[data-ios-speed-trigger\]'/);
  assert.match(observer,/fullSpeed15: '\.player-sheet \[data-speed-choice="1.5"\]'/);
  assert.match(observer,/watchArtwork: '\.watch-audio-panel \.audio-cover.large'/);
  for(const name of ['watchArtworkPresent','watchSeekPresent','watchTimePresent','watchTransportCount','watchCapsuleOverlapsSkip','watchSpeedPopupOpen','watchSpeedChoiceCount','watchSpeedSelected']) assert.ok(observer.includes(name),name);
  for(const action of ['audioSpeedOpen','audioSpeed15','watchArtwork','audioSpeed10','watchVideo']) assert.ok(swift.includes('regressionTap("'+action+'")'),action);
  assert.match(swift,/itemEpoch"\) == epoch/);
});

test('full-player Watch tap uses existing DOM recorder name rather than duplicate selector', () => {
  const directTest = swift.slice(
    swift.indexOf('func testRegressionDirectListenAndOriginalFullPlayer'),
    swift.indexOf('func testRegressionWatchOptionThreePopupAndNativeSpeed')
  );
  assert.ok(directTest.includes('controls["fullWatch"] != nil'));
  assert.ok(directTest.includes('try regressionTap("watchFromAudio")'));
  assert.ok(!directTest.includes('try regressionTap("fullWatch")'));
  assert.ok(observer.includes("watchFromAudio: '[data-player-watch]'"));
  assert.ok(observer.includes("fullWatch: '.player-sheet [data-player-watch]'"));
});
