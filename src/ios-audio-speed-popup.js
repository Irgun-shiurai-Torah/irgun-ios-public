// Accessible compact speed menu for the existing full audio player.
export const IOS_AUDIO_SPEEDS = Object.freeze([0.75, 1, 1.25, 1.5, 1.75, 2]);

export function validIosAudioSpeed(value) {
  const rate = Number(value);
  return IOS_AUDIO_SPEEDS.includes(rate) ? rate : null;
}

export function compactIosAudioSpeedHtml(rate = 1, language = 'en') {
  const selected = validIosAudioSpeed(rate) ?? 1;
  const he = language === 'he';
  const title = he ? 'מהירות השמעה' : 'Playback speed';
  const options = IOS_AUDIO_SPEEDS.map(value =>
    `<button type="button" class="ios-speed-option${selected === value ? ' selected' : ''}" data-ios-speed-choice="${value}" role="menuitemradio" aria-checked="${selected === value}" tabindex="-1">${value}×</button>`
  ).join('');
  return `<div class="ios-speed-menu" data-ios-speed-menu>
    <button type="button" class="ios-speed-trigger" data-ios-speed-trigger aria-label="${title}: ${selected}×" aria-haspopup="menu" aria-expanded="false" aria-controls="iosAudioSpeedMenu" dir="ltr"><span data-ios-speed-current>${selected}×</span><span class="ios-speed-chevron" aria-hidden="true">▾</span></button>
    <div id="iosAudioSpeedMenu" class="ios-speed-popover" data-ios-speed-options role="menu" aria-label="${title}" dir="ltr" hidden>${options}</div>
  </div>`;
}

export function refreshIosAudioSpeedMenu(root, rate) {
  const selected = validIosAudioSpeed(rate) ?? 1;
  root.querySelectorAll('[data-ios-speed-current]').forEach(node => { node.textContent = `${selected}×`; });
  root.querySelectorAll('[data-ios-speed-trigger]').forEach(node => {
    node.setAttribute('aria-label', `${node.closest('[data-ios-speed-menu]')?.querySelector('[data-ios-speed-options]')?.getAttribute('aria-label') || 'Playback speed'}: ${selected}×`);
  });
  root.querySelectorAll('[data-ios-speed-choice]').forEach(button => {
    const active = Number(button.dataset.iosSpeedChoice) === selected;
    button.classList.toggle('selected', active);
    button.setAttribute('aria-checked', String(active));
  });
}

export function closeIosAudioSpeedMenu(menu) {
  if (!menu) return;
  menu.querySelector('[data-ios-speed-options]')?.setAttribute('hidden', '');
  menu.querySelector('[data-ios-speed-trigger]')?.setAttribute('aria-expanded', 'false');
}

export function toggleIosAudioSpeedMenu(menu) {
  const options = menu?.querySelector('[data-ios-speed-options]');
  const trigger = menu?.querySelector('[data-ios-speed-trigger]');
  if (!options || !trigger) return false;
  const opening = options.hasAttribute('hidden');
  if (opening) options.removeAttribute('hidden'); else options.setAttribute('hidden', '');
  trigger.setAttribute('aria-expanded', String(opening));
  return opening;
}
