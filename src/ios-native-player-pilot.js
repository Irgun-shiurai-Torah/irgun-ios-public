// Deliberately disabled by default and separate from the existing production
// audio/video engine. For a disposable developer build, enable
// localStorage.setItem('istNativeAvPlayerPilotV1','1') and reload, then start a
// video normally and call window.ISTNativePlayerPilot.openCurrent().
// This is NOT a replacement for the production player yet.
export const NATIVE_PILOT_STORAGE_KEY = 'istNativeAvPlayerPilotV1';

export function createIosNativePlayerPilot({
  capacitor, registerPlugin, storage,
  getCurrent, loadVideoSources, releaseLegacy, restoreLegacy, stageRect
}) {
  if (capacitor?.getPlatform?.() !== 'ios' ||
      !capacitor?.isNativePlatform?.() ||
      storage?.getItem?.(NATIVE_PILOT_STORAGE_KEY) !== '1') return null;

  const native = registerPlugin('IrgunUnifiedPlayer');
  let active = false;
  let busy = false;
  let lastState = null;
  let lastId = '';
  let stopListening = null;

  const safeRect = () => {
    const r = stageRect?.() || {};
    return {
      x: Math.max(0, Number(r.x) || 0),
      y: Math.max(0, Number(r.y) || 0),
      width: Math.max(0, Number(r.width) || 0),
      height: Math.max(0, Number(r.height) || 0)
    };
  };

  const pilot = {
    get active() { return active; },
    get state() { return lastState; },
    get id() { return lastId; },

    async openCurrent() {
      if (busy) throw new Error('Native playback transition already in progress');
      if (active) return native.getState();
      busy = true;
      let released = false;
      try {
        const current = getCurrent();
        if (!current?.video?.id) throw new Error('Open a shiur before starting the native pilot');
        const sources = await loadVideoSources(current.video);
        // No MP3 substitution. Verify the actual HLS asset before experimenting.
        if (!sources?.hls) throw new Error('This shiur has no HLS source for the native pilot');
        active = true;
        await releaseLegacy();
        released = true;
        const handle = await native.addListener('state', next => {
          if (active && (!lastId || next?.id === lastId)) lastState = next;
        });
        stopListening = async () => handle.remove();
        lastId = String(current.video.id);
        lastState = await native.open({
          id: lastId,
          url: sources.hls,
          title: current.video.title || 'Shiur',
          artist: current.video.artist || 'Irgun Shiurai Torah',
          position: Math.max(0, Number(current.position) || 0),
          rate: Math.max(0.5, Math.min(2, Number(current.rate) || 1)),
          mode: 'video',
          autoplay: true,
          rect: safeRect()
        });
        return lastState;
      } catch (error) {
        active = false;
        lastId = '';
        lastState = null;
        await stopListening?.().catch(() => {});
        stopListening = null;
        await native.stop().catch(() => {});
        if (released) await restoreLegacy({ autoplay: false, position: Number(getCurrent()?.position) || 0 });
        throw error;
      } finally { busy = false; }
    },

    async mode(mode) {
      if (!active) throw new Error('Native pilot is not active');
      if (!['audio','video'].includes(mode)) throw new Error('Invalid mode');
      lastState = await native.setMode({ mode });
      return lastState;
    },

    async seek(position) {
      if (!active) throw new Error('Native pilot is not active');
      lastState = await native.seek({ position: Math.max(0, Number(position) || 0) });
      return lastState;
    },

    async rate(rate) {
      if (!active) throw new Error('Native pilot is not active');
      lastState = await native.setRate({ rate: Number(rate) || 1 });
      return lastState;
    },

    async layout(layout, rect = null) {
      if (!active) throw new Error('Native pilot is not active');
      if (!['inline','mini','full'].includes(layout)) throw new Error('Invalid layout');
      lastState = await native.setLayout({ layout, rect: rect || safeRect() });
      return lastState;
    },

    async play() {
      if (!active) throw new Error('Native pilot is not active');
      lastState = await native.play();
      return lastState;
    },

    async pause() {
      if (!active) throw new Error('Native pilot is not active');
      lastState = await native.pause();
      return lastState;
    },

    async snapshot() { return native.getState(); },

    async stop(resumeLegacy = true) {
      if (!active) return null;
      active = false;
      let finalState = null;
      try { finalState = await native.getState(); }
      catch (_) { finalState = lastState; }
      try { await native.stop(); }
      finally {
        await stopListening?.().catch(() => {});
        stopListening = null;
        lastState = null;
        lastId = '';
        if (resumeLegacy) await restoreLegacy({
          autoplay: Boolean(finalState?.playing),
          position: Number(finalState?.position) || 0
        });
      }
      return finalState;
    }
  };
  if (typeof window !== 'undefined') window.ISTNativePlayerPilot = pilot;
  return pilot;
}
