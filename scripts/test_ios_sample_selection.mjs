import test from 'node:test';
import assert from 'node:assert/strict';
import {simulatorHlsSourceReady} from '../.github/simulator/sample-selection.js';
import {readFileSync} from 'node:fs';

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

function reportedSelection(readyIds) {
  const bridge=readFileSync(new URL('../.github/simulator/bridge.js',import.meta.url),'utf8');
  const start=bridge.indexOf('async openReportedShiur()');
  const end=bridge.indexOf('\n  async openSample()',start);
  const method=bridge.slice(start,end).trim().replace(/^async openReportedShiur\(\)/,'async function()').replace(/,$/,'');
  const original={id:'1233236785',hasAudio:true}, backup={id:'1235946832',hasAudio:true};
  const state={videoById:new Map([[original.id,original],[backup.id,backup]]),videos:[original,backup]};
  const opened=[],probed=[];
  const factory=new Function('state','isIosVimeoOnlyLecture','videoId','loadIosDirectVideoSources',
    'watchVimeoEmbedSrc','simulatorHlsSourceReady','openWatch',
    `let simulatorOpening=false,simulatorError='';return {open:(${method}),getError:()=>simulatorError};`);
  const h=factory(state,()=>false,v=>v.id,async v=>({hls:`https://fixture/${v.id}/master.m3u8`,mp4:`https://fixture/${v.id}/video.mp4`}),
    v=>'https://player.vimeo.com/video/'+v.id,async url=>{
      probed.push(url);return readyIds.some(id=>String(url).includes('/'+id+'/'));
    },async id=>{opened.push(id);});
  return {h,opened,probed};
}
test('reported regression selects another actual owned lecture when the historical backup is unavailable',async()=>{
  const t=reportedSelection(['1235946832']);await t.h.open();
  assert.deepEqual(t.opened,['1235946832']);
  assert.equal(t.h.reportedSelectedId,'1235946832');
  assert.ok(t.probed.includes('https://fixture/1233236785/video.mp4'));
  assert.equal(t.h.getError(),'');
});
test('reported regression retains the historical lecture when its real owned media is ready',async()=>{
  const t=reportedSelection(['1233236785']);await t.h.open();
  assert.deepEqual(t.opened,['1233236785']);
});
test('reported regression fails without opening Vimeo when no owned sample is reachable',async()=>{
  const t=reportedSelection([]);await t.h.open();
  assert.deepEqual(t.opened,[]);
  assert.match(t.h.getError(),/No cataloged Drive-backed lecture/);
});
