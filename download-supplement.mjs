import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseCredentials } from './download.mjs';

const ENDPOINT='https://data.alpaca.markets/v2/stocks/bars';
const defaultSleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export const JOBS=Object.freeze([
  {id:'five-minute',symbols:['SPY','QQQ'],timeframe:'5Min',start:'2021-10-04T04:00:00Z',end:'2026-10-03T03:59:59Z'},
  {id:'hourly-earlier',symbols:['SPY','QQQ'],timeframe:'1Hour',start:'2016-01-01T05:00:00Z',end:'2021-10-04T03:59:59Z'},
  {id:'daily-context',symbols:['SPY','QQQ'],timeframe:'1Day',start:'2016-01-01T05:00:00Z',end:'2026-10-03T03:59:59Z'},
  {id:'hourly-context',symbols:['IWM','TLT'],timeframe:'1Hour',start:'2016-01-01T05:00:00Z',end:'2026-10-03T03:59:59Z'},
].map(job=>Object.freeze({...job,symbols:Object.freeze(job.symbols)})));

class SafeDownloadError extends Error {}
const fail=message=>{throw new SafeDownloadError(message);};

function integerHeader(headers,name) {
  const text=headers?.get?.(name);
  if(typeof text!=='string' || !/^\d{1,13}$/.test(text)) return null;
  const value=Number(text);
  return Number.isSafeInteger(value)?value:null;
}

function rateSnapshot(headers) {
  const reset=integerHeader(headers,'x-ratelimit-reset');
  return {
    limit:integerHeader(headers,'x-ratelimit-limit'),
    remaining:integerHeader(headers,'x-ratelimit-remaining'),
    resetAtUTC:reset!==null && reset>0 && reset<253402300799?new Date(reset*1000).toISOString():null,
  };
}

function nextDelay(headers,status,attempt) {
  const snapshot=rateSnapshot(headers);
  let delay=status===429 || status>=500?1000*(attempt+1):450;
  const retryAfter=headers?.get?.('retry-after');
  if(typeof retryAfter==='string') {
    if(/^\d+(\.\d+)?$/.test(retryAfter)) delay=Math.max(delay,Number(retryAfter)*1000);
    else if(Number.isFinite(Date.parse(retryAfter))) delay=Math.max(delay,Date.parse(retryAfter)-Date.now());
  }
  if((snapshot.remaining===0 || status===429) && snapshot.resetAtUTC) {
    delay=Math.max(delay,Date.parse(snapshot.resetAtUTC)-Date.now()+100);
  }
  // Timers cannot represent waits above 2^31-1 ms; do not silently hammer the API.
  if(!Number.isFinite(delay) || delay>2147483647) fail('Alpaca rate-limit wait is outside the supported timer range.');
  return Math.max(450,Math.ceil(delay));
}

function validateRequest({symbol,timeframe,start,end,credentials}) {
  const validDate=value=>typeof value==='string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value) && Number.isFinite(Date.parse(value));
  if(!['SPY','QQQ','IWM','TLT'].includes(symbol) || !['5Min','1Hour','1Day'].includes(timeframe) ||
      !validDate(start) || !validDate(end) || Date.parse(start)>=Date.parse(end) ||
      typeof credentials?.key!=='string' || !credentials.key || typeof credentials?.secret!=='string' || !credentials.secret) {
    fail('Invalid supplemental historical data request.');
  }
}

function validateBar(bar,startMillis,endMillis,previousMillis) {
  if(!bar || typeof bar!=='object' || typeof bar.t!=='string' || !bar.t.endsWith('Z')) fail('Invalid historical bar.');
  const stamp=Date.parse(bar.t);
  if(!Number.isFinite(stamp) || stamp<startMillis || stamp>endMillis || stamp<=previousMillis) fail('Historical bars contain invalid, duplicate, unordered or out-of-range timestamps.');
  for(const name of ['o','h','l','c','v','n','vw']) if(typeof bar[name]!=='number' || !Number.isFinite(bar[name])) fail('Historical bar has missing or invalid numeric fields.');
  if(bar.o<=0 || bar.h<=0 || bar.l<=0 || bar.c<=0 || bar.vw<=0 || bar.v<0 || bar.n<0 || !Number.isInteger(bar.n) ||
     bar.h<Math.max(bar.o,bar.l,bar.c) || bar.l>Math.min(bar.o,bar.h,bar.c)) fail('Historical bar violates OHLC or volume constraints.');
  return stamp;
}

export async function fetchBars({symbol,timeframe,start,end,credentials,fetchImpl=fetch,sleep=defaultSleep,onPage=()=>{}}) {
  validateRequest({symbol,timeframe,start,end,credentials});
  const bars=[];const seenTokens=new Set();
  let token=null;let page=0;let requestCount=0;let waitMs=450;let previousMillis=-Infinity;
  const startMillis=Date.parse(start);const endMillis=Date.parse(end);
  do {
    const url=new URL(ENDPOINT);
    for(const [key,value] of Object.entries({symbols:symbol,timeframe,start,end,feed:'sip',adjustment:'raw',limit:'10000',sort:'asc'})) url.searchParams.set(key,value);
    if(token!==null) url.searchParams.set('page_token',token);
    let response;
    for(let attempt=0;attempt<3;attempt++) {
      await sleep(waitMs);
      requestCount++;
      try {
        response=await fetchImpl(url,{method:'GET',redirect:'error',
          headers:{'APCA-API-KEY-ID':credentials.key,'APCA-API-SECRET-KEY':credentials.secret},
          signal:AbortSignal.timeout(30000)});
      } catch {
        if(attempt===2) fail('Alpaca connection failed after three attempts.');
        waitMs=1000*(attempt+1);continue;
      }
      if(response?.ok) break;
      const status=Number.isInteger(response?.status)?response.status:0;
      // The response body can contain credentials or request details; never read it.
      try {await response?.body?.cancel();} catch {}
      if((status===429 || status>=500) && attempt<2) {
        waitMs=nextDelay(response.headers,status,attempt);continue;
      }
      fail(`Alpaca historical bars request failed (HTTP ${status}).`);
    }
    let payload;
    try {payload=await response.json();} catch {fail('Alpaca returned invalid JSON.');}
    if(!payload || !payload.bars || typeof payload.bars!=='object' || Array.isArray(payload.bars)) fail('Alpaca response has no valid bars object.');
    const batch=payload.bars[symbol];
    if(!Array.isArray(batch)) fail('Alpaca returned an invalid bars array.');
    for(const item of batch) {
      previousMillis=validateBar(item,startMillis,endMillis,previousMillis);
      bars.push(item);
    }
    token=payload.next_page_token;
    if(token!==undefined && token!==null) {
      if(typeof token!=='string' || token.length===0 || token.length>8192 || /[\u0000-\u0020\u007f]/.test(token) || seenTokens.has(token)) fail('Repeated or invalid pagination token.');
      seenTokens.add(token);
    } else token=null;
    if(batch.length===0) fail('Alpaca returned an empty historical bars series or page.');
    waitMs=nextDelay(response.headers,response.status??200,0);
    onPage({symbol,timeframe,page:++page,received:batch.length,total:bars.length,requestCount,rateLimit:rateSnapshot(response.headers)});
  } while(token!==null);
  return bars;
}

async function writeExclusive(file,value) {
  // Partial output is deliberately preserved on failure, and refused on rerun.
  // No existing source, export, or previously completed download is overwritten.
  try {await fs.writeFile(file,value,{encoding:'utf8',flag:'wx'});}
  catch {fail('Could not write a new supplemental output file exclusively. Existing files were not replaced.');}
}

export async function runDownload({outputDir,credentials,fetchImpl=fetch,sleep=defaultSleep,log=entry=>console.log(JSON.stringify(entry))}) {
  if(typeof outputDir!=='string' || !outputDir) fail('A new supplemental output directory is required.');
  outputDir=path.resolve(outputDir);
  try {
    const entries=await fs.readdir(outputDir);
    if(entries.length) fail('Supplemental output root must be empty; partial and completed downloads are not overwritten. Choose a new output root.');
  } catch(error) {
    if(error instanceof SafeDownloadError) throw error;
    if(error.code!=='ENOENT') fail('Could not inspect supplemental output directory.');
  }
  await fs.mkdir(outputDir,{recursive:true});
  const report={status:'in-progress',provider:'Alpaca Market Data API',endpoint:ENDPOINT,startedAtUTC:new Date().toISOString(),
    feed:'sip',adjustment:'raw',requestCount:0,pageCount:0,finalRateLimit:null,groups:[]};
  for(const job of JOBS) {
    const groupDir=path.join(outputDir,job.id);
    await fs.mkdir(path.join(groupDir,'raw'),{recursive:true});
    const series=[];
    for(const symbol of job.symbols) {
      // A pagination chain ending does not end the account's rate-limit window.
      if(report.finalRateLimit?.remaining===0 && report.finalRateLimit.resetAtUTC) {
        const wait=Math.max(0,Date.parse(report.finalRateLimit.resetAtUTC)-Date.now()+100);
        if(wait>2147483647) fail('Alpaca rate-limit wait is outside the supported timer range.');
        if(wait>0) await sleep(wait);
      }
      let latestProgress;
      const bars=await fetchBars({...job,symbol,credentials,fetchImpl,sleep,onPage:info=>{latestProgress=info;log({group:job.id,...info});}});
      const file=`raw/${symbol}-${job.timeframe}.json`;
      const bytes=JSON.stringify(bars);
      await writeExclusive(path.join(groupDir,file),bytes);
      const entry={symbol,file,count:bars.length,first:bars[0].t,last:bars.at(-1).t,
        sha256:createHash('sha256').update(bytes).digest('hex'),requestCount:latestProgress.requestCount,
        pageCount:latestProgress.page,rateLimit:latestProgress.rateLimit};
      series.push(entry);
      report.requestCount+=entry.requestCount;report.pageCount+=entry.pageCount;report.finalRateLimit=entry.rateLimit;
      log({saved:symbol,group:job.id,count:entry.count,first:entry.first,last:entry.last});
    }
    const metadata={provider:report.provider,endpoint:ENDPOINT,group:job.id,timeframe:job.timeframe,
      feed:'sip',adjustment:'raw',symbols:job.symbols,requestedStart:job.start,requestedEnd:job.end,
      retrievedAtUTC:new Date().toISOString(),timestamps:'Provider-native UTC bar-start timestamps, ascending, with market gaps left unfilled.',
      sessionPolicy:job.timeframe==='1Day'?'Provider-native daily bars; a completed daily bar must only be used after its full aggregation window is available.':'Provider-native bars across available sessions, including extended hours; not regular-session-only.',
      forecastWarning:'Supplementary source data only. Align by completed-bar availability, never row index; no missing candles are fabricated. Raw prices retain corporate-action effects.',
      series};
    await writeExclusive(path.join(groupDir,'source-metadata.json'),JSON.stringify(metadata,null,2)+'\n');
    report.groups.push({id:job.id,timeframe:job.timeframe,symbols:job.symbols,requestedStart:job.start,requestedEnd:job.end,series});
  }
  report.status='complete';report.completedAtUTC=new Date().toISOString();
  await writeExclusive(path.join(outputDir,'download-report.json'),JSON.stringify(report,null,2)+'\n');
  return report;
}

async function main() {
  const [credentialsPath,outputDir,...rest]=process.argv.slice(2);
  if(!credentialsPath || !outputDir || rest.length) fail('Usage: node download-supplement.mjs <local-credentials-file> <new-output-directory>');
  let text;
  try {text=await fs.readFile(credentialsPath,'utf8');} catch {fail('Could not read the specified local credential file.');}
  let credentials;
  try {credentials=parseCredentials(text);} catch {fail('Credential file must contain one valid Alpaca key ID and one secret.');}
  text='';
  const report=await runDownload({credentials,outputDir});
  console.log(JSON.stringify({status:report.status,requestCount:report.requestCount,pageCount:report.pageCount,finalRateLimit:report.finalRateLimit}));
}

if(process.argv[1] && import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error=>{
    // Restrict console output to explicitly authored safe messages, never arbitrary exceptions.
    console.error(error instanceof SafeDownloadError?error.message:'Supplemental download failed. Saved partial files remain unchanged; use a new empty output directory for a retry.');
    process.exitCode=1;
  });
}
