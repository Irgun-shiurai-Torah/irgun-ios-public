import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(path, 'utf8');
const account = read('.github/regression/account-regressions.swift');
const observer = read('.github/regression/account-observer.js');
const push = read('.github/regression/tests.swift');
const probe = read('.github/simulator/SimulatorProbe.swift');
const runner = read('.github/regression/run_ui.sh');

test('owned comment scrolls inside the actual Watch viewport, not across video', () => {
  assert.match(observer, /watchScrollRect:/);
  assert.match(observer, /watchScrollTop:/);
  assert.match(account, /func swipeOwnedComment\(/);
  assert.match(account, /height\*0\.46/);
  assert.match(account, /watchScrollRect/);
  assert.match(account, /if key\.hasPrefix\("comment"\)/);
  assert.match(account, /swipeOwnedComment\(fullState,towardUp:directionUp\)/);
  assert.match(account, /click\["targetId"\] as\? String == id/);
});

test('native push permission test requires a real button action and OS settings', () => {
  assert.match(probe, /nativePushRequestCount \+= 1/);
  assert.match(probe, /UNUserNotificationCenter\.current\(\)\.requestAuthorization/);
  assert.match(probe, /UNUserNotificationCenter\.current\(\)\.getNotificationSettings/);
  assert.match(probe, /nativePushAuthorized = settings\.authorizationStatus == \.authorized/);
  assert.match(probe, /state\["nativePushRequestCount"\]/);
  assert.match(probe, /state\["nativePushAuthorizationStatus"\]/);
  assert.match(push, /number\(snapshot\(\),"nativePushRequestCount"\) > previousRequests/);
  assert.match(push, /systemAllow|for host in \[app,springboard\]/);
  assert.match(push, /nativePushAuthorized"\] as\? Bool == true/);
  assert.match(push, /nativePushAuthorizationStatus/);
  assert.match(push, /notification\.tap\(\)/);
});

test('simulator notification permissions are reset only for the disposable push test', () => {
  const pushCase = runner.split('  push)')[1]?.split('    ;;')[0];
  assert.ok(pushCase, 'push case exists');
  assert.match(pushCase, /simctl uninstall "\$udid" "\$BUNDLE_ID"/);
  assert.match(pushCase, /push_sender\.py/);
  assert.doesNotMatch(runner.split('  core)')[1]?.split('    ;;')[0] || '', /simctl uninstall/);
});
