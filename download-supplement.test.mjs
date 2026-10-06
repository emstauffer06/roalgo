import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';

// Dynamic import makes the initial RED state a clear missing-feature assertion.
let implementation;
try { implementation = await import('./download-supplement.mjs'); } catch {}
const credentials = {key:'PK000000000000000000',secret:'s'.repeat(40)};
const start='2021-10-04T04:00:00Z';
const end='2021-10-04T23:59:59Z';
const bar=(t='2021-10-04T08:00:00Z')=>({t,o:100,h:103,l:99,c:102,v:1000,n:20,vw:101});
const reply=(bars=[bar()],token=null,headers={})=>({ok:true,status:200,headers:new Headers(headers),json:async()=>({bars:{SPY:bars},next_page_token:token})});
const args=(extra={})=>({symbol:'SPY',timeframe:'5Min',start,end,credentials,sleep:async()=>{},...extra});
const implemented=()=>{assert.ok(implementation,'Supplemental downloader module must exist');return implementation;};

test('JOBS defines all eight requested series with exact frozen bounds',()=>{
  const {JOBS}=implemented();
  assert.deepEqual(JOBS.map(({id,symbols,timeframe,start,end})=>({id,symbols,timeframe,start,end})),[
    {id:'five-minute',symbols:['SPY','QQQ'],timeframe:'5Min',start:'2021-10-04T04:00:00Z',end:'2026-10-03T03:59:59Z'},
    {id:'hourly-earlier',symbols:['SPY','QQQ'],timeframe:'1Hour',start:'2016-01-01T05:00:00Z',end:'2021-10-04T03:59:59Z'},
    {id:'daily-context',symbols:['SPY','QQQ'],timeframe:'1Day',start:'2016-01-01T05:00:00Z',end:'2026-10-03T03:59:59Z'},
    {id:'hourly-context',symbols:['IWM','TLT'],timeframe:'1Hour',start:'2016-01-01T05:00:00Z',end:'2026-10-03T03:59:59Z'},
  ]);
});

test('paginates validated bars and sends credentials only to fixed GET endpoint headers',async()=>{
  const {fetchBars}=implemented(); const seen=[];const delays=[];const progress=[];
  const bars=await fetchBars(args({sleep:async ms=>delays.push(ms),onPage:p=>progress.push(p),fetchImpl:async(url,options)=>{
    const parsed=new URL(url);seen.push(parsed);
    assert.equal(parsed.origin,'https://data.alpaca.markets');assert.equal(parsed.pathname,'/v2/stocks/bars');
    assert.equal(options.method,'GET');assert.equal(options.redirect,'error');assert.equal(options.body,undefined);
    assert.deepEqual(options.headers,{'APCA-API-KEY-ID':credentials.key,'APCA-API-SECRET-KEY':credentials.secret});
    for(const [key,value] of Object.entries({symbols:'SPY',timeframe:'5Min',start,end,feed:'sip',adjustment:'raw',limit:'10000',sort:'asc'})) assert.equal(parsed.searchParams.get(key),value);
    assert.ok(!String(url).includes(credentials.key));assert.ok(!String(url).includes(credentials.secret));
    return seen.length===1?reply([bar()],'page-two',{'X-RateLimit-Limit':'200','X-RateLimit-Remaining':'199'}):reply([bar('2021-10-04T08:05:00Z')],null,{'X-RateLimit-Limit':'200','X-RateLimit-Remaining':'198'});
  }}));
  assert.equal(bars.length,2);assert.equal(seen[1].searchParams.get('page_token'),'page-two');
  assert.equal(progress[1].page,2);assert.equal(progress[1].requestCount,2);assert.equal(progress[1].total,2);
  assert.equal(progress[1].rateLimit.limit,200);assert.equal(progress[1].rateLimit.remaining,198);
  assert.ok(delays.every(ms=>ms>=450));assert.equal(delays.length,2);
  assert.ok(!JSON.stringify(progress).includes(credentials.secret));
});

for(const update of [{symbol:'AAPL'},{timeframe:'1Min'},{start:'bad-date'},{end:start},{start:'2021-10-04'},{credentials:{key:'',secret:''}}]) {
  test(`rejects invalid request ${Object.keys(update).join(',')} before calling fetch`,async()=>{
    const {fetchBars}=implemented();let count=0;
    await assert.rejects(fetchBars(args({...update,fetchImpl:async()=>{count++;return reply();}})),/Invalid/);
    assert.equal(count,0);
  });
}

for(const token of ['repeat',42,'',{},'unsafe\ntoken']) {
  test(`rejects invalid or repeated pagination token ${JSON.stringify(token)}`,async()=>{
    const {fetchBars}=implemented();let count=0;
    await assert.rejects(fetchBars(args({fetchImpl:async()=>reply([bar(`2021-10-04T08:${String(count++*5).padStart(2,'0')}:00Z`)],token)})),/pagination/);
    assert.ok(count<=2);
  });
}

for(const [label,bars] of [
  ['empty',[]],['null',null],['duplicate',[bar(),bar()]],['out of order',[bar('2021-10-04T08:05:00Z'),bar()]],
  ['missing field',[{...bar(),vw:undefined}]],['nonfinite',[{...bar(),c:NaN}]],['OHLC',[{...bar(),h:99}]],
  ['negative volume',[{...bar(),v:-1}]],['outside bounds',[bar('2021-10-03T08:00:00Z')]],
]) {
  test(`rejects ${label} series without accepting malformed data`,async()=>{
    const {fetchBars}=implemented();await assert.rejects(fetchBars(args({fetchImpl:async()=>reply(bars)})),/bars|bar|series/);
  });
}

test('does not read provider error bodies and retries network/429 responses with cadence',async()=>{
  const {fetchBars}=implemented();let count=0;const delays=[];let cancelled=0;const progress=[];
  const result=await fetchBars(args({sleep:async ms=>delays.push(ms),onPage:p=>progress.push(p),fetchImpl:async()=>{
    count++;if(count===1) throw Error(credentials.secret);
    if(count===2) return {ok:false,status:429,headers:new Headers({'Retry-After':'2','X-RateLimit-Remaining':'0'}),body:{cancel:async()=>cancelled++},json:async()=>{throw Error('Must never read error body');}};
    return reply();
  }}));
  assert.equal(count,3);assert.equal(cancelled,1);assert.equal(result.length,1);assert.ok(delays.some(ms=>ms>=2000));
  assert.equal(progress[0].requestCount,3);
});

test('honors exhausted successful response reset before the next page',async()=>{
  const {fetchBars}=implemented();const delays=[];let calls=0;const reset=Math.ceil(Date.now()/1000)+3;
  await fetchBars(args({sleep:async ms=>delays.push(ms),fetchImpl:async()=>++calls===1?reply([bar()],'next',{'X-RateLimit-Limit':'200','X-RateLimit-Remaining':'0','X-RateLimit-Reset':String(reset)}):reply([bar('2021-10-04T08:05:00Z')])}));
  assert.ok(delays[1]>=2500);assert.ok(delays[1]<5000);
});

for(const status of [401,403,500,503]) {
  test(`HTTP ${status} fails safely after bounded attempts`,async()=>{
    const {fetchBars}=implemented();let count=0;
    await assert.rejects(fetchBars(args({fetchImpl:async()=>{count++;return {ok:false,status,headers:new Headers(),body:{cancel:async()=>{}},json:async()=>{throw Error(credentials.secret);}};}})),error=>{assert.ok(!error.message.includes(credentials.secret));return /HTTP/.test(error.message);});
    assert.equal(count,status>=500?3:1);
  });
}

test('network and invalid JSON failures never surface exception credential contents',async()=>{
  const {fetchBars}=implemented();let count=0;
  await assert.rejects(fetchBars(args({fetchImpl:async()=>{count++;throw Error(credentials.secret);}})),error=>{assert.ok(!error.message.includes(credentials.secret));return /connection/.test(error.message);});
  assert.equal(count,3);
  await assert.rejects(fetchBars(args({fetchImpl:async()=>({...reply(),json:async()=>{throw Error(credentials.key);}})})),error=>{assert.ok(!error.message.includes(credentials.key));return /JSON/.test(error.message);});
});

async function tempRoot(t) {
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'alpaca-supplement-test-'));
  t.after(async()=>{assert.equal(path.dirname(path.resolve(dir)),path.resolve(os.tmpdir()));assert.ok(path.basename(dir).startsWith('alpaca-supplement-test-'));await fs.rm(dir,{recursive:true,force:true});});
  return dir;
}

test('runDownload writes all requested files, matching hashes, metadata and request report',async t=>{
  const {runDownload,JOBS}=implemented();const outputDir=path.join(await tempRoot(t),'output');let calls=0;const logs=[];
  const report=await runDownload({outputDir,credentials,sleep:async()=>{},log:entry=>logs.push(entry),fetchImpl:async url=>{
    calls++;const u=new URL(url);const symbol=u.searchParams.get('symbols');const first=new Date(Date.parse(u.searchParams.get('start'))+24*3600*1000).toISOString();
    return {...reply(),headers:new Headers({'X-RateLimit-Limit':'200','X-RateLimit-Remaining':String(200-calls)}),json:async()=>({bars:{[symbol]:[bar(first)]},next_page_token:null})};
  }});
  assert.equal(calls,8);assert.equal(report.requestCount,8);assert.equal(report.pageCount,8);assert.equal(report.finalRateLimit.remaining,192);
  assert.equal(report.status,'complete');assert.equal(report.groups.length,4);
  for(const job of JOBS) {
    const meta=JSON.parse(await fs.readFile(path.join(outputDir,job.id,'source-metadata.json'),'utf8'));
    assert.equal(meta.requestedStart,job.start);assert.equal(meta.requestedEnd,job.end);assert.equal(meta.feed,'sip');assert.equal(meta.adjustment,'raw');
    assert.equal(meta.series.length,2);
    for(const series of meta.series) {
      const bytes=await fs.readFile(path.join(outputDir,job.id,series.file));
      assert.equal(createHash('sha256').update(bytes).digest('hex'),series.sha256);
      assert.equal(JSON.parse(bytes).length,series.count);assert.equal(series.count,1);
    }
  }
  assert.equal(JSON.parse(await fs.readFile(path.join(outputDir,'download-report.json'),'utf8')).requestCount,8);
  const text=JSON.stringify([report,logs]);assert.ok(!text.includes(credentials.key));assert.ok(!text.includes(credentials.secret));
});

test('runDownload refuses any existing nonempty output root before network or overwrites',async t=>{
  const {runDownload}=implemented();const outputDir=await tempRoot(t);const sentinel=path.join(outputDir,'keep.txt');await fs.writeFile(sentinel,'unchanged');let calls=0;
  await assert.rejects(runDownload({outputDir,credentials,sleep:async()=>{},log:()=>{},fetchImpl:async()=>{calls++;return reply();}}),/empty|nonempty|partial/);
  assert.equal(calls,0);assert.equal(await fs.readFile(sentinel,'utf8'),'unchanged');
});

test('runDownload honors a final-page reset when the next symbol starts',async t=>{
  const {runDownload}=implemented();const outputDir=path.join(await tempRoot(t),'output');const delays=[];let calls=0;let delayedBeforeSecondSymbol=false;
  const reset=Math.ceil(Date.now()/1000)+3;
  await runDownload({outputDir,credentials,sleep:async ms=>delays.push(ms),log:()=>{},fetchImpl:async url=>{
    calls++;const u=new URL(url);const symbol=u.searchParams.get('symbols');const stamp=new Date(Date.parse(u.searchParams.get('start'))+24*3600*1000).toISOString();
    if(calls===2) delayedBeforeSecondSymbol=delays.some(ms=>ms>=2500);
    return {...reply(),headers:new Headers(calls===1?{'X-RateLimit-Limit':'200','X-RateLimit-Remaining':'0','X-RateLimit-Reset':String(reset)}:{}),json:async()=>({bars:{[symbol]:[bar(stamp)]},next_page_token:null})};
  }});
  assert.equal(calls,8);assert.ok(delayedBeforeSecondSymbol,'Next symbol must honor the previous response reset');
});
