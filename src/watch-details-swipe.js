const boundScrollers = new WeakSet();

// Match Android's pull-to-mini below the native picture. Playback remains
// owned by the existing player; this gesture only changes its presentation.
export function bindWatchDetailsSwipeToMini(overlay, { canMinimize, minimize, now = () => performance.now() }) {
  const scroller = overlay?.querySelector('.watch-scroll');
  if (!scroller || boundScrollers.has(scroller)) return;
  boundScrollers.add(scroller);
  let startX = 0, startY = 0, startAt = 0, down = 0, tracking = false;
  const reset = () => { tracking = false; down = 0; };
  const interactive = 'button, a, input, select, textarea, [contenteditable], [role="button"], .watch-player-card, .watch-audio-panel';
  scroller.addEventListener('touchstart', event => {
    reset();
    if (!canMinimize() || event.touches.length !== 1 || scroller.scrollTop > 3 ||
        event.target.closest(interactive)) return;
    // A nested scrolling list owns its touches in either direction.
    for (let node = event.target; node && node !== scroller; node = node.parentElement) {
      if (node.scrollWidth > node.clientWidth + 2 ||
          node.scrollHeight > node.clientHeight + 2 && /auto|scroll/.test(getComputedStyle(node).overflowY)) return;
    }
    const touch = event.touches[0];
    startX = touch.clientX; startY = touch.clientY; startAt = now();
    tracking = true;
  }, { passive: true });
  scroller.addEventListener('touchmove', event => {
    if (!tracking) return;
    if (event.touches.length !== 1 || !canMinimize() || scroller.scrollTop > 3) return reset();
    const touch = event.touches[0], dy = touch.clientY - startY, dx = Math.abs(touch.clientX - startX);
    if (dy < 0 || dx > Math.max(26, dy * 0.75)) return reset();
    if (dy < 18) return;
    down = dy;
    // iOS rubber-band scrolling can report negative scrollTop at the top.
    // Only an intentional downward pull is consumed; ordinary scroll is free.
    event.preventDefault();
  }, { passive: false });
  scroller.addEventListener('touchend', () => {
    if (tracking && canMinimize()) {
      const velocity = down / Math.max(1, now() - startAt);
      if (down >= 110 || down >= 68 && velocity >= 0.7) {
        reset();
        void minimize();
        return;
      }
    }
    reset();
  }, { passive: true });
  scroller.addEventListener('touchcancel', reset, { passive: true });
}
