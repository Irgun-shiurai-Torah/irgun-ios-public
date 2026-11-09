// Retry a native *read* only after the plugin has rejected and its partial
// file has been removed. Never retry HTTP/permission/storage errors or save
// an incomplete file as a successful offline shiur.
export async function downloadOfflineAudio({download, stat, removePartial,
  delay = ms => new Promise(resolve => setTimeout(resolve, ms))}) {
  let transfer;
  for (let attempt = 0; attempt < 2; attempt++) {
    await removePartial();
    try {
      transfer = await download();
      break;
    } catch (error) {
      const code = String(error?.code || '');
      const message = String(error?.message || '') + ' ' + String(error?.exception || '');
      const httpStatus = Number(error?.httpStatus || error?.statusCode || error?.responseCode) || 0;
      const transient = !httpStatus &&
        (/(?:^8$|-0008$)/.test(code) || /network connection was lost|connection reset|timed out/i.test(message));
      await removePartial();
      if (!transient || attempt > 0) throw error;
      await delay(1200);
    }
  }
  const info = await stat();
  const bytes = Number(info?.size) || 0;
  const responseCode = Number(transfer?.statusCode ?? transfer?.responseCode) || 0;
  if ((responseCode && (responseCode < 200 || responseCode >= 300)) || bytes < 8192) {
    await removePartial();
    throw new Error(`Offline audio response was not a usable lecture file (HTTP ${responseCode || 'unknown'}, ${bytes} bytes)`);
  }
  return {bytes};
}
