// iOS persistent navigation. Never recreate its DOM on ordinary page/video
// renders: detaching it during a media handoff can swallow the user's tap.
const TABS = ['home', 'shiurim', 'live', 'library', 'account'];

export function iosNavigationRoot(screen, previous = 'home') {
  if (TABS.includes(screen)) return screen;
  if (String(screen).startsWith('live')) return 'live';
  if (screen === 'search') return 'shiurim';
  if (screen === 'schedule') return 'home';
  if (screen === 'paid') return 'library';
  return TABS.includes(previous) ? previous : 'home';
}

export function createIosBottomNavigation({ isIos, document, model, markup, navigate }) {
  let mount;
  let language;
  return () => {
    if (!isIos()) return;
    const state = model();
    if (!mount || !mount.isConnected) {
      mount = document.createElement('div');
      mount.id = 'iosBottomNavigationMount';
      document.body.appendChild(mount);
      mount.addEventListener('click', event => {
        const button = event.target.closest?.('.nav-btn[data-nav]');
        if (button && mount.contains(button)) void navigate(button);
      });
    }
    if (language !== state.language || !mount.firstElementChild) {
      mount.innerHTML = markup();
      language = state.language;
    }
    const nav = mount.querySelector('.bottom-nav');
    if (!nav) return;
    nav.style.setProperty('--nav-index', String(Math.max(0, TABS.indexOf(state.root))));
    for (const button of nav.querySelectorAll('[data-nav]')) {
      const active = button.dataset.nav === state.root;
      button.classList.toggle('active', active);
      if (active) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    }
  };
}

// A page tab changes only the PRESENTATION of a video or audio player.
// The current media source, position, speed, and pause intent are untouched.
export async function prepareIosTabNavigation({ state, exitFullscreen, minimizeVideo, closeAudioWatch }) {
  state.playerOpen = false;
  if (!state.watchVideo || state.watchPictureInPicture) return;
  if (state.watchMode === 'video' && !state.watchMinimized) {
    await exitFullscreen();
    await minimizeVideo();
  } else if (state.watchMode === 'audio') {
    await closeAudioWatch();
  }
}
