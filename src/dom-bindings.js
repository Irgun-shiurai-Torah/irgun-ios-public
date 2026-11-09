// Watch nodes live outside #app while native video plays. Re-rendering the
// surrounding app must not attach another copy of their click handlers.
export function createClickBinder(root) {
  const bound = new WeakMap();
  return function bindClickOnce(selector, handler) {
    for (const element of root.querySelectorAll(selector)) {
      let selectors = bound.get(element);
      if (!selectors) { selectors = new Set(); bound.set(element, selectors); }
      if (selectors.has(selector)) continue;
      selectors.add(selector);
      element.addEventListener('click', event => handler(element, event));
    }
  };
}
