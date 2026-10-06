// Authorized, read-only Alpaca historical bars downloader. Credentials stay in memory.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {parseCredentials} from '../download.mjs';
import {parseCSV} from './bridge.mjs';

const ROOT=path.dirname(fileURLToPath(import.meta.url));
export const SECTORS=Object.freeze(['XLK','XLF','XLE']);
const ENDPOINT='https://data.alpaca.markets/v2/stocks/bars';
const START='2021-10-01T04:00:00Z',END='2026-10-03T03:59:59Z';
const HEADER='timestamp_utc,timestamp_unix,open,high,low,close,volume,trade_count,vwap';
const hash=x=>createHash('sha256').update(x).digest('hex');
const defaultSleep=ms=>new Promise(r=>setTimeout(r,ms));
class SafeError extends Error {}
function fail(message,requestCount=0){const e=new SafeError(message);e.requestCount=requestCount;throw e;}
function csvRows(bars){return bars.map(b=>[new Date(b.t).toISOString(),Date.parse(b.t)/1000,b.o,b.h,b.l,b.c,b.v,b.n,b.vw].join(','));}
function safeHeader(headers,name){const v=headers?.get?.(name);return typeof v==='string'&&/^\d{1,13}$/.test(v)?Number(v):null;}
function rate(headers){const reset=safeHeader(headers,'x-ratelimit-reset');return {limit:safeHeader(headers,'x-ratelimit-limit'),remaining:safeHeader(headers,'x-ratelimit-remaining'),resetAtUTC:reset&&reset<253402300799?new Date(reset*1000).toISOString():null};}
function delay(headers,status,attempt){let ms=status===429||status>=500?1000*(attempt+1):500;const retry=headers?.get?.('retry-after'),r=rate(headers);if(retry&&/^\d+(\.\d+)?$/.test(retry))ms=Math.max(ms,Number(retry)*1000);if((r.remaining===0||status===429)&&r.resetAtUTC)ms=Math.max(ms,Date.parse(r.resetAtUTC)-Date.now()+100);if(!Number.isFinite(ms)||ms>2147483647)fail('Alpaca rate-limit wait is outside the supported range.');return Math.max(500,Math.ceil(ms));}

export async function fetchSectorBars({symbol,start=START,end=END,credentials,fetchImpl=fetch,sleep=defaultSleep,onPage=()=>{}}){
  const dateOk=x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(x)&&Number.isFinite(Date.parse(x));
  if(!SECTORS.includes(symbol)||!dateOk(start)||!dateOk(end)||Date.parse(start)>=Date.parse(end)||!credentials?.key||!credentials?.secret)fail('Invalid sector historical data request.');
  let token=null,previous=-Infinity,requestCount=0,pageCount=0,waitMs=500,lastRate=null;
  const bars=[],seen=new Set();
  do{
    const url=new URL(ENDPOINT);
    for(const[k,v]of Object.entries({symbols:symbol,timeframe:'1Hour',start,end,feed:'sip',adjustment:'raw',limit:'10000',sort:'asc'}))url.searchParams.set(k,v);
    if(token)url.searchParams.set('page_token',token);
    let response;
    for(let attempt=0;attempt<3;attempt++){
      await sleep(waitMs);requestCount++;
      try{response=await fetchImpl(url,{method:'GET',redirect:'error',headers:{'APCA-API-KEY-ID':credentials.key,'APCA-API-SECRET-KEY':credentials.secret},signal:AbortSignal.timeout(30000)});}
      catch{if(attempt===2)fail('Alpaca connection failed after three attempts.',requestCount);waitMs=1000*(attempt+1);continue;}
      if(response?.ok)break;
      const status=Number.isInteger(response?.status)?response.status:0;
      try{await response?.body?.cancel();}catch{}
      if((status===429||status>=500)&&attempt<2){waitMs=delay(response.headers,status,attempt);continue;}
      fail(`Alpaca historical bars request failed (HTTP ${status}).`,requestCount);
    }
    let raw,payload;
    try{raw=await response.text();payload=JSON.parse(raw);}catch{fail('Alpaca returned invalid JSON.',requestCount);}
    const batch=payload?.bars?.[symbol];
    if(!Array.isArray(batch)||!batch.length)fail('Alpaca returned an empty or invalid historical bars page.',requestCount);
    // Validate provider fields before CSV conversion; the shared parser enforces OHLCV and timestamp invariants.
    for(const b of batch){
      if(!b||typeof b.t!=='string'||!b.t.endsWith('Z')||!['o','h','l','c','v','n','vw'].every(k=>typeof b[k]==='number'&&Number.isFinite(b[k])))fail('Historical bar has invalid fields.',requestCount);
      const t=Date.parse(b.t);if(!Number.isFinite(t)||t<=previous||t<Date.parse(start)||t>Date.parse(end))fail('Historical bars contain duplicate, unordered or out-of-range timestamps.',requestCount);previous=t;
    }
    try{parseCSV(HEADER+'\n'+csvRows(batch).join('\n'));}catch{fail('Historical bar violates CSV timestamp or OHLCV constraints.',requestCount);}
    token=payload.next_page_token??null;
    if(token!==null){if(typeof token!=='string'||!token.length||token.length>8192||/[\u0000-\u0020\u007f]/.test(token)||seen.has(token))fail('Repeated or invalid pagination token.',requestCount);seen.add(token);}
    bars.push(...batch);pageCount++;lastRate=rate(response.headers);waitMs=delay(response.headers,response.status,0);
    await onPage({symbol,page:pageCount,received:batch.length,total:bars.length,requestCount,rateLimit:lastRate,raw,sha256:hash(raw)});
  }while(token!==null);
  return {bars,requestCount,pageCount,rateLimit:lastRate};
}

export async function runSectorDownload({outputDir=path.join(ROOT,'data','sector-hourly-sip'),credentials,start=START,end=END,fetchImpl=fetch,sleep=defaultSleep,log=x=>console.log(JSON.stringify(x))}={}){
  outputDir=path.resolve(outputDir);
  try{if((await fs.readdir(outputDir)).length)fail('Sector output directory must be empty; existing cache files are preserved.');}catch(e){if(e instanceof SafeError)throw e;if(e.code!=='ENOENT')fail('Could not inspect sector output directory.');}
  await fs.mkdir(path.join(outputDir,'raw'),{recursive:true});
  const manifest={schemaVersion:3,status:'in-progress',provider:'Alpaca Market Data API',endpoint:ENDPOINT,timeframe:'1Hour',feed:'sip',adjustment:'raw',requestedStart:start,requestedEnd:end,startedAtUTC:new Date().toISOString(),includesExtendedHours:true,regularSessionOnly:false,timestampMeaning:'Provider-native UTC bar start; availableT=start+3600.',volumeMeaning:'ETF traded volume, not total volume of the underlying index constituents.',missingPolicy:'Unavailable series stay absent; no synthetic prices or filled candles.',symbols:{},requestCount:0,pageCount:0};
  const write=(file,bytes)=>fs.writeFile(path.join(outputDir,file),bytes,{encoding:'utf8',flag:'wx'});
  let lastRate=null;
  for(const symbol of SECTORS){
    const pages=[];
    if(lastRate?.remaining===0&&lastRate.resetAtUTC)await sleep(Math.max(500,Date.parse(lastRate.resetAtUTC)-Date.now()+100));
    try{
      const r=await fetchSectorBars({symbol,start,end,credentials,fetchImpl,sleep,onPage:async p=>{
        const file=`raw/${symbol}-${String(p.page).padStart(4,'0')}.json`;await write(file,p.raw);
        pages.push({file,sha256:p.sha256,bytes:Buffer.byteLength(p.raw),received:p.received,requestCount:p.requestCount,rateLimit:p.rateLimit});
        lastRate=p.rateLimit;if(p.page===1||p.page%20===0)log({symbol,page:p.page,rows:p.total,requestCount:p.requestCount});
      }});
      const csv=HEADER+'\n'+csvRows(r.bars).join('\n')+'\n',csvPath=symbol+'.csv';await write(csvPath,csv);
      manifest.symbols[symbol]={available:true,status:'complete',count:r.bars.length,first:r.bars[0].t,last:r.bars.at(-1).t,csvPath,sha256:hash(csv),requestCount:r.requestCount,pageCount:r.pageCount,rateLimit:r.rateLimit,pages};
      log({symbol,status:'complete',count:r.bars.length,first:r.bars[0].t,last:r.bars.at(-1).t});
    }catch(e){manifest.symbols[symbol]={available:false,status:'unavailable',reason:e instanceof SafeError?e.message:'Could not persist sector cache.',requestCount:e.requestCount??pages.at(-1)?.requestCount??0,pageCount:pages.length,pages};log({symbol,status:'unavailable',reason:manifest.symbols[symbol].reason});}
    manifest.requestCount+=manifest.symbols[symbol].requestCount;manifest.pageCount+=manifest.symbols[symbol].pageCount;
  }
  manifest.status=SECTORS.every(s=>manifest.symbols[s].available)?'complete':SECTORS.some(s=>manifest.symbols[s].available)?'partial':'unavailable';manifest.completedAtUTC=new Date().toISOString();
  await write('manifest.json',JSON.stringify(manifest,null,2)+'\n');return manifest;
}

async function main(){
  const[credentialPath,outputDir,...extra]=process.argv.slice(2);if(!credentialPath||extra.length)fail('Usage: node fetch-sector-context.mjs <local-credentials-file> [new-output-directory]');
  let credentials;try{credentials=parseCredentials(await fs.readFile(credentialPath,'utf8'));}catch{fail('Could not read one valid Alpaca key and secret from the specified file.');}
  const m=await runSectorDownload({credentials,outputDir});console.log(JSON.stringify({status:m.status,requestCount:m.requestCount,pageCount:m.pageCount}));if(m.status!=='complete')process.exitCode=1;
}
if(process.argv[1]&&pathToFileURL(path.resolve(process.argv[1])).href===import.meta.url)main().catch(e=>{console.error(e instanceof SafeError?e.message:'Sector download failed; preserved partial files.');process.exitCode=1;});
