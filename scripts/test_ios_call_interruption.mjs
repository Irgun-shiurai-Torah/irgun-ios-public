import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const unified = readFileSync(new URL('./IrgunUnifiedPlayerPlugin.swift', import.meta.url), 'utf8');
const background = readFileSync(new URL('./IrgunBackgroundAudioPlugin.swift', import.meta.url), 'utf8');
const appDelegate = readFileSync(new URL('./prepare_ios_cloud.py', import.meta.url), 'utf8');

function between(text, begin, end) {
  const start = text.indexOf(begin);
  assert.notEqual(start, -1, 'missing section: ' + begin);
  const finish = text.indexOf(end, start + begin.length);
  assert.notEqual(finish, -1, 'missing section terminator: ' + end);
  return text.slice(start, finish);
}

test('unified iOS AVPlayer tracks both CallKit calls and audio session interruptions', () => {
  assert.match(unified, /import CallKit/);
  assert.match(unified, /CXCallObserverDelegate/);
  assert.match(unified, /systemCallObserver\.setDelegate\(self, queue: \.main\)/);
  assert.match(unified, /AVAudioSession\.interruptionNotification/);
  assert.match(unified, /audioSessionInterrupted \|\| systemCallObserver\.calls\.contains\(where:/);

  const interruption = between(unified, 'private func handleAudioSessionInterruption(', 'private func schedulePlaybackWatchdog()');
  assert.match(interruption, /case \.began:[\s\S]*audioSessionInterrupted = true[\s\S]*pauseForExternalInterruption\(\)/);
  assert.match(interruption, /case \.ended:[\s\S]*audioSessionInterrupted = false/);
  assert.match(interruption, /options\.contains\(\.shouldResume\)/);
  assert.match(interruption, /resumeAfterExternalInterruptionIfAppropriate\(\)/);
  assert.match(interruption, /playingWanted = false[\s\S]*pauseForExternalInterruption\(\)/);

  const calls = between(unified, 'public func callObserver(', 'private func schedulePlaybackWatchdog()');
  assert.match(calls, /if playbackIsBlockedByCall \{[\s\S]*pauseForExternalInterruption\(\)/);
  assert.match(calls, /\} else \{[\s\S]*resumeAfterExternalInterruptionIfAppropriate\(\)/);
});

test('every unified AVPlayer start passes through an active-call gate', () => {
  assert.equal((unified.match(/playImmediately\(atRate:/g) || []).length, 1,
    'all AVPlayer start sites must use playIfAllowed, not bypass it');
  const guardedStart = between(unified, 'private func playIfAllowed()', 'private func resumeAfterExternalInterruptionIfAppropriate()');
  assert.match(guardedStart, /guard active, playingWanted, !playbackIsBlockedByCall/);
  assert.match(guardedStart, /player\.pause\(\)/);
  assert.match(guardedStart, /player\.playImmediately\(atRate: playbackRate\)/);

  assert.match(between(unified, 'private func monitorPlaybackProgress()', 'private func schedulePlaybackRecoveryIfNeeded()'),
    /!playbackIsBlockedByCall/);
  const recovery = between(unified, 'private func schedulePlaybackRecoveryIfNeeded()', 'private func playableURL(');
  assert.match(recovery, /guard active, playingWanted, !playbackIsBlockedByCall/);
  assert.match(recovery, /guard self\.active, self\.playingWanted, !self\.playbackIsBlockedByCall/);
  assert.match(recovery, /!self\.playbackIsBlockedByCall/);
  assert.doesNotMatch(recovery, /playImmediately\(atRate:/);

  const session = between(unified, 'private func activateAudioSession() throws', 'private func installViewer()');
  assert.match(session, /guard !playbackIsBlockedByCall else \{ return \}/);
  const remote = between(unified, 'add(controls.playCommand)', 'add(controls.pauseCommand)');
  assert.match(remote, /guard !self\.playbackIsBlockedByCall/);
});

test('legacy iOS background audio also honors WhatsApp/CallKit call state', () => {
  assert.match(background, /CXCallObserverDelegate/);
  assert.match(background, /audioSessionInterrupted \|\| systemCallObserver\.calls\.contains/);
  assert.match(background, /systemCallObserver\.setDelegate\(self, queue: \.main\)/);
  assert.equal((background.match(/playImmediately\(atRate:/g) || []).length, 1);
  const guardedStart = between(background, 'private func playIfAllowed()', 'public func callObserver(');
  assert.match(guardedStart, /guard active, desiredPlaying, !playbackIsBlockedByCall/);
  assert.match(guardedStart, /player\?\.playImmediately\(atRate: speed\)/);
  const backgroundStart = between(background, 'private func startBackground()', 'private func activateSession()');
  assert.match(backgroundStart, /!playbackIsBlockedByCall/);
  assert.match(backgroundStart, /self\.playIfAllowed\(\)/);
  assert.match(between(background, 'private func activateSession()', '@objc public func getState'),
    /guard !playbackIsBlockedByCall else \{ return \}/);
});

test('AppDelegate does not steal an ongoing call audio session', () => {
  assert.match(appDelegate, /import CallKit/);
  assert.match(appDelegate, /guard !CXCallObserver\(\)\.calls\.contains\(where:/);
  const interruption = between(appDelegate, 'private func irgunHandleAudioSessionInterruption(', '@objc private func irgunHandleAudioRouteChange(');
  assert.match(interruption, /irgunNativeAudioInterruptionEndedShouldResume/);
  assert.doesNotMatch(interruption, /setActive\(true\)/);
});
