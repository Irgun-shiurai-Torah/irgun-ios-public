import test from 'node:test';
import assert from 'node:assert/strict';
import {simulatorHlsSourceReady} from '../.github/simulator/sample-selection.js';

test('test sample requires a real master, media playlist, and available first fragment',async()=>{
  const urls=[];
  const request=async url=>{
    urls.push(url);
    if(url.endsWith('master.m3u8'))return new Response('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\n720/index.m3u8');
    if(url.endsWith('index.m3u8'))return new Response('#EXTM3U\n#EXTINF:6,\nfirst.ts');
    return new Response(new Uint8Array([0x47,1,2]),{headers:{'Content-Type':'video/mp2t'}});
  };
  assert.equal(await simulatorHlsSourceReady('https://example.test/master.m3u8',request),true);
  assert.deepEqual(urls,['https://example.test/master.m3u8','https://example.test/720/index.m3u8','https://example.test/720/first.ts']);
});

for(const failure of ['playlist404','segment404','html','empty','network'])test('unfinished/unavailable sample is rejected: '+failure,async()=>{
  const request=async url=>{
    if(failure==='network')throw Error('offline');
    if(url.endsWith('.m3u8'))return failure==='playlist404'?new Response('',{status:404}):new Response('#EXTM3U\n#EXTINF:6,\nfirst.ts');
    if(failure==='segment404')return new Response('',{status:404});
    if(failure==='html')return new Response('<html>not video</html>',{headers:{'Content-Type':'text/html'}});
    return new Response(new Uint8Array());
  };
  assert.equal(await simulatorHlsSourceReady('https://example.test/master.m3u8',request),false);
});
