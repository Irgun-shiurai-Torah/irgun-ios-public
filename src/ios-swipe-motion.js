// Only the page content moves. Navigation and the single native AVPlayer stay
// mounted. Previews are inert markup; they never bind handlers or load media.
export function sanitizeTabPreview(document, html) {
  const template = document.createElement('template');
  template.innerHTML = html;
  template.content.querySelectorAll('script,style,iframe,video,audio,source,track,object,embed,link,meta').forEach(node => node.remove());
  let nodes = 0, images = 0;
  for (const node of template.content.querySelectorAll('*')) {
    if (++nodes > 650) { node.remove(); continue; }
    for (const attribute of [...node.attributes]) {
      if (/^(id|name|for|form|autofocus|srcset|srcdoc|href|action|style)$/i.test(attribute.name) ||
          /^(on|data-)/i.test(attribute.name)) node.removeAttribute(attribute.name);
    }
    if (node.matches('input,textarea,select,button')) {
      node.removeAttribute('value');
      if (node.matches('textarea')) node.textContent = '';
      node.setAttribute('tabindex', '-1');
    }
    if (node.matches('img') && (++images > 8 || !/^(https?:\/\/|\/)/i.test(node.getAttribute('src') || ''))) node.remove();
  }
  return template.innerHTML;
}

export function createIosSwipeMotion({document, view = document.defaultView, renderPreview,
  contextKey, schedule = (fn, delay) => setTimeout(fn, delay), duration = 180}) {
  const snapshots = new Map();
  let context = '', active = null;
  const refreshContext = () => {
    const next = contextKey();
    if (context !== next) { snapshots.clear(); context = next; }
  };
  const capture = tab => {
    refreshContext();
    const content = document.querySelector('#app .app-shell > .content');
    if (content && ['home','shiurim','live','library','account'].includes(tab))
      snapshots.set(tab, sanitizeTabPreview(document, content.innerHTML));
  };
  const cleanup = () => {
    if (!active) return;
    const {content, preview, original} = active;
    Object.assign(content.style, original);
    preview.remove();
    document.body.classList.remove('ios-swipe-motion');
    active = null;
  };
  const position = dx => {
    if (!active) return;
    const x = Math.max(-active.width, Math.min(active.width, Number(dx) || 0));
    active.content.style.transform = `translate3d(${Math.round(x)}px,0,0)`;
    active.preview.style.transform = `translate3d(${Math.round(active.side * active.width + x)}px,0,0)`;
  };
  const drag = ({from,to,dx}) => {
    if (!to || !dx) { cleanup(); return; }
    if (!active || active.from !== from || active.to !== to) {
      cleanup();
      refreshContext();
      const content = document.querySelector('#app .app-shell > .content');
      const header = document.querySelector('#app .app-shell > .topbar');
      if (!content || !header) return;
      capture(from);
      if (!snapshots.has(to)) snapshots.set(to, sanitizeTabPreview(document, renderPreview(to)));
      const preview = document.createElement('div');
      preview.className = 'ios-swipe-preview';
      preview.setAttribute('aria-hidden', 'true');
      preview.setAttribute('dir', document.documentElement.dir || 'ltr');
      preview.inert = true;
      preview.style.top = `${Math.max(0, header.getBoundingClientRect().bottom)}px`;
      preview.innerHTML = `<div class="ios-swipe-preview-content">${snapshots.get(to)}</div>`;
      const original = {transform:content.style.transform, transition:content.style.transition,
        willChange:content.style.willChange};
      // Keep the preview inside the app's clipping boundary, above the page
      // background but below the persistent navigation and mini player.
      document.getElementById('app').appendChild(preview);
      document.body.classList.add('ios-swipe-motion');
      active = {from,to,content,preview,original,side:dx < 0 ? 1 : -1,
        width:Math.max(1,view.innerWidth || 360)};
      content.style.transition = 'none';
      content.style.willChange = 'transform';
    }
    position(dx);
  };
  const release = ({committed}) => {
    if (!active) return Promise.resolve();
    const time = view.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches || document.hidden ? 0 : duration;
    const transition = `transform ${time}ms cubic-bezier(.22,.72,.24,1)`;
    active.content.style.transition = transition;
    active.preview.style.transition = transition;
    void active.preview.offsetWidth;
    position(committed ? -active.side * active.width : 0);
    return time ? new Promise(resolve => schedule(resolve, time + 25)) : Promise.resolve();
  };
  return {capture,drag,release,cleanup};
}
