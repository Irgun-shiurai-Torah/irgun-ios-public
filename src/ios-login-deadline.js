// A stalled WebKit fetch must never leave the Sign In button disabled forever.
// Abort the real request and also settle the JS promise: a few WebKit versions
// can delay reporting AbortError even after the abort signal has fired.
export async function fetchLoginWithDeadline(fetchLogin, {
  timeoutMs = 25000,
  controller = new AbortController(),
  setTimer = setTimeout,
  clearTimer = clearTimeout
} = {}) {
  let timeoutId;
  const expired = new Promise((_, reject) => {
    timeoutId = setTimer(() => {
      const error = new Error('Sign-in timed out. Check your connection and try again.');
      error.name = 'AbortError';
      try { controller.abort(); } catch (_) {}
      reject(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([Promise.resolve().then(() => fetchLogin(controller.signal)), expired]);
  } catch (error) {
    if (controller.signal.aborted && error?.name === 'AbortError') {
      throw new Error('Sign-in timed out. Check your connection and try again.');
    }
    throw error;
  } finally {
    if (timeoutId !== undefined) clearTimer(timeoutId);
  }
}
