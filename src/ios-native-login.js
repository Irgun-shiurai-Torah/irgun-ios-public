// Native iOS fallback for a genuinely failed WebKit login transport.
// A completed HTTP response (including 401/429/500) is not retried: only a
// timeout/connection error may use the native Capacitor HTTP transport.
export function isIosLoginTransportError(error) {
  const message = String(error?.message || '');
  return /sign-in timed out|network connection (?:was )?lost|network request failed|failed to fetch|load failed|internet connection appears to be offline|could not connect to the server/i.test(message);
}

export async function loginWithIosNativeFallback(webLogin, nativeLogin, {enabled = false} = {}) {
  try {
    return await webLogin();
  } catch (error) {
    if (!enabled || !isIosLoginTransportError(error)) throw error;
    return nativeLogin();
  }
}

export function normalizeNativeLoginResponse(raw) {
  const status = Number(raw?.status) || 0;
  let data = raw?.data;
  if (typeof data === 'string') {
    try { data = JSON.parse(data); }
    catch (_) { data = {}; }
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) data = {};
  if (status < 100 || status > 599) throw new Error('Native sign-in received no valid HTTP response.');
  return {response:{status,ok:status >= 200 && status < 300},data};
}
