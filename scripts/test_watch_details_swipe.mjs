import test from 'node:test';
import assert from 'node:assert/strict';
import { bindWatchDetailsSwipeToMini } from '../src/watch-details-swipe.js';

function rig({ scrollTop = 0, interactive = false, nested = false, playing = true } = {}) {
  let allowed = true, clock = 0, minimized = 0, prevented = 0;
  const player = { position: 463.5, rate: 1.25, playing, itemEpoch: 7 };
  const handlers = {};
  const scroller = { scrollTop, addEventListener(name, fn) { handlers[name] = fn; } };
  const target = { closest: () => interactive, parentElement: scroller,
    scrollWidth: nested ? 600 : 300, clientWidth: 300, scrollHeight: 80, clientHeight: 80 };
  const overlay = { querySelector: () => scroller };
  const options = { canMinimize: () => allowed, now: () => clock,
    minimize: () => { minimized++; allowed = false; } };
  bindWatchDetailsSwipeToMini(overlay, options);
  function event(type, x, y, { fingers = 1, elapsed = 10 } = {}) {
    clock += elapsed;
    const touches = Array.from({ length: fingers }, () => ({ clientX: x, clientY: y }));
    handlers[type]({ target, touches, preventDefault() { prevented++; } });
  }
  return { player, scroller, overlay, options, event, handlers,
    get minimized() { return minimized; }, get prevented() { return prevented; },
    set allowed(value) { allowed = value; } };
}

for (const playing of [true, false]) {
  test(`pull below video minimizes ${playing ? 'playing' : 'paused'} item without changing playback`, () => {
    const r = rig({ playing }), before = { ...r.player };
    r.event('touchstart', 150, 320);
    r.event('touchmove', 155, 445, { elapsed: 250 });
    r.event('touchend', 155, 445);
    r.event('touchend', 155, 445);
    assert.equal(r.minimized, 1);
    assert.equal(r.prevented, 1);
    assert.deepEqual(r.player, before);
  });
}

test('fast downward flick matches Android minimum distance and speed', () => {
  const r = rig();
  r.event('touchstart', 100, 300);
  r.event('touchmove', 100, 372, { elapsed: 70 });
  r.event('touchend', 100, 372);
  assert.equal(r.minimized, 1);
});

for (const config of [{ scrollTop: 80 }, { interactive: true }, { nested: true }]) {
  test(`scroll, interactive and nested content retain their touches ${JSON.stringify(config)}`, () => {
    const r = rig(config);
    r.event('touchstart', 100, 300);
    r.event('touchmove', 100, 450);
    r.event('touchend', 100, 450);
    assert.equal(r.minimized, 0);
    assert.equal(r.prevented, 0);
  });
}

test('upward scrolling and horizontal movement cancel pull detection', () => {
  for (const [x, y] of [[100, 270], [200, 330]]) {
    const r = rig();
    r.event('touchstart', 100, 300);
    r.event('touchmove', x, y);
    r.event('touchmove', 100, 450);
    r.event('touchend', 100, 450);
    assert.equal(r.minimized, 0);
    assert.equal(r.prevented, 0);
  }
});

test('short pulls, touchcancel and multitouch never minimize', () => {
  for (const cancellation of ['short', 'touchcancel', 'multitouch']) {
    const r = rig();
    r.event('touchstart', 100, 300);
    r.event('touchmove', 100, cancellation === 'short' ? 355 : 440, { elapsed: 500 });
    if (cancellation === 'touchcancel') r.event('touchcancel', 100, 440);
    if (cancellation === 'multitouch') r.event('touchmove', 100, 440, { fingers: 2 });
    r.event('touchend', 100, 440);
    assert.equal(r.minimized, 0);
  }
});

test('opening a modal or scrolling away from top cancels an in-flight pull', () => {
  for (const change of ['modal', 'scroll']) {
    const r = rig();
    r.event('touchstart', 100, 300);
    if (change === 'modal') r.allowed = false;
    else r.scroller.scrollTop = 12;
    r.event('touchmove', 100, 450);
    r.event('touchend', 100, 450);
    assert.equal(r.minimized, 0);
    assert.equal(r.prevented, 0);
  }
});

test('iOS negative top overscroll is accepted; rebinding adds no handlers', () => {
  const r = rig({ scrollTop: -4 }), before = { ...r.handlers };
  bindWatchDetailsSwipeToMini(r.overlay, r.options);
  assert.deepEqual(r.handlers, before);
  r.event('touchstart', 100, 300);
  r.event('touchmove', 100, 450);
  r.event('touchend', 100, 450);
  assert.equal(r.minimized, 1);
});
