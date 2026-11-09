// Resolve the currently displayed textarea after asynchronous posting.
// Players can re-render their watch overlay while a request is in flight,
// replacing the original textarea. Comparing element identity misses that case.
export function clearCommentComposerAfterPost({ document, currentVideoId, postedVideoId, postedText }) {
  if (!postedVideoId || String(currentVideoId || '') !== String(postedVideoId)) return false;
  const field = document?.getElementById?.('commentText');
  if (!field || String(field.value || '').trim() !== String(postedText || '').trim()) return false;
  // Finish any mobile keyboard composition before resetting the visible value.
  if (typeof field.blur === 'function') field.blur();
  // Blurring can itself re-render the player on some mobile WebViews.
  const visible = document.getElementById('commentText');
  if (!visible || String(visible.value || '').trim() !== String(postedText || '').trim()) return false;
  visible.value = '';
  return true;
}
// Drafts belong to an account and a lecture, not to a particular textarea.
// Watch can be rebuilt by a background refresh while the mobile keyboard is
// closing. Keeping the only copy in that DOM node loses the unsent comment.
export function commentDraftScope(userId, videoId) {
  return JSON.stringify([String(userId || ''), String(videoId || '')]);
}
export function createCommentDraftStore() {
  const drafts = new Map();
  const bound = new WeakMap();
  return {
    read(scope) { return drafts.get(scope) || ''; },
    bind(field, scope) {
      if (!field) return;
      const existing = bound.get(field);
      if (existing) {
        if (existing.scope !== scope) {
          existing.scope = scope;
          field.value = drafts.get(scope) || '';
        }
        return;
      }
      const binding = {scope};
      bound.set(field, binding);
      if (drafts.has(scope)) field.value = drafts.get(scope);
      const remember = () => {
        const value = String(field.value || '');
        if (value) drafts.set(binding.scope, value);
        else drafts.delete(binding.scope);
      };
      field.addEventListener('input', remember);
      field.addEventListener('change', remember);
      field.addEventListener('blur', remember);
    },
    clearIfUnchanged(scope, submittedText) {
      if (this.read(scope).trim() !== String(submittedText || '').trim()) return false;
      drafts.delete(scope);
      return true;
    },
    clear(field) {
      drafts.clear();
      if (field) field.value = '';
    }
  };
}
