// Loopback cached historical research transport. No account, broker or download API.
import http from 'node:http';
import {readFileSync,readdirSync,existsSync,mkdirSync,writeFileSync,statSync} from 'node:fs';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {dirname,join} from 'node:path';
import {createHash} from 'node:crypto';
export const ROOT=dirname(fileURLToPath(import.meta.url));
const DATA=join(ROOT,'../data/alpaca-supplement-2016-01-01_2026-10-02');
const SECTOR_DATA=join(ROOT,'data','sector-hourly-sip');
const hash=x=>createHash('sha256').update(x).digest('hex');
const fmt=new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
// Explicit NYSE calendar audit for the target cache interval 2021-10-04..2026-10-02.
// NYSE yearly trading calendars: https://www.nyse.com/markets/hours-calendars
export const EARLY_CLOSE=new Set(['2021-11-26','2022-11-25','2023-07-03','2023-11-24','2024-07-03','2024-11-29','2024-12-24','2025-07-03','2025-11-28','2025-12-24']);
const CLOSED=new Set(`2021-11-25 2021-12-24 2022-01-17 2022-02-21 2022-04-15 2022-05-30 2022-06-20 2022-07-04 2022-09-05 2022-11-24 2022-12-26 2023-01-02 2023-01-16 2023-02-20 2023-04-07 2023-05-29 2023-06-19 2023-07-04 2023-09-04 2023-11-23 2023-12-25 2024-01-01 2024-01-15 2024-02-19 2024-03-29 2024-05-27 2024-06-19 2024-07-04 2024-09-02 2024-11-28 2024-12-25 2025-01-01 2025-01-09 2025-01-20 2025-02-17 2025-04-18 2025-05-26 2025-06-19 2025-07-04 2025-09-01 2025-11-27 2025-12-25 2026-01-01 2026-01-19 2026-02-16 2026-04-03 2026-05-25 2026-06-19 2026-07-03 2026-09-07`.split(' '));
export function nyTime(t){const p=Object.fromEntries(fmt.formatToParts(new Date(t*1000)).map(x=>[x.type,x.value]));return {day:`${p.year}-${p.month}-${p.day}`,minute:+p.hour*60+(+p.minute),clock:`${p.hour}:${p.minute}`};}
export function isRegular(t){const x=nyTime(t),w=new Date(x.day+'T12:00:00Z').getUTCDay();return w>0&&w<6&&!CLOSED.has(x.day)&&x.minute>=570&&x.minute<(EARLY_CLOSE.has(x.day)?780:960);}
export function parseCSV(text){
  const lines=text.trim().split(/\r?\n/);if(lines.shift()!=='timestamp_utc,timestamp_unix,open,high,low,close,volume,trade_count,vwap')throw Error('Unexpected CSV schema');
  let prev=-Infinity;return lines.filter(Boolean).map((line,i)=>{const x=line.split(','),[t,o,h,l,c,v,n,vwap]=x.slice(1).map(Number);
    if(x.length!==9||x.some(s=>s.trim()==='')||![t,o,h,l,c,v,n,vwap].every(Number.isFinite)||t<=prev||!Number.isInteger(t)||Date.parse(x[0])/1000!==t||t%300!==0)throw Error('Invalid timestamp/order/value at '+i);
    if(Math.min(o,h,l,c,vwap)<=0||h<Math.max(o,l,c)||l>Math.min(o,h,c)||v<0||n<0||!Number.isInteger(n))throw Error('Invalid OHLCV/activity at '+i);
    prev=t;return {t,o,h,l,c,v,n,vwap};});
}
export function validateQuery(q){
  for(const k of q.keys())if(!['symbol','train','validation','test','end'].includes(k)||q.getAll(k).length!==1)throw Error('Unknown or duplicate query');
  const symbol=q.get('symbol')??'SPY',train=Number(q.get('train')??20),validation=Number(q.get('validation')??5),test=Number(q.get('test')??5),end=q.get('end')??'2024-12-31';
  if(!['SPY','QQQ'].includes(symbol)||![train,validation,test].every(x=>Number.isInteger(x)&&x>=1)||train+validation+test>1000)throw Error('Invalid symbol or split sessions (total <=1000)');
  if(!/^\d{4}-\d{2}-\d{2}$/.test(end)||!Number.isFinite(Date.parse(end))||new Date(end).toISOString().slice(0,10)!==end||end<'2021-10-04'||end>'2026-10-02')throw Error('Invalid historical cutoff');
  return {symbol,train,validation,test,end};
}
export function validateFoldQuery(q){
  for(const k of q.keys())if(!['symbol','train','validation','test','end','count','stride'].includes(k)||q.getAll(k).length!==1)throw Error('Unknown or duplicate fold query');
  const base=new URLSearchParams(q);base.delete('count');base.delete('stride');const o=validateQuery(base),count=Number(q.get('count')??3),stride=Number(q.get('stride')??60);
  if(!Number.isInteger(count)||count<1||count>20)throw Error('Invalid fold count (1..20)');
  if(!Number.isInteger(stride)||stride<o.test||stride>1000)throw Error('Invalid stride: trading-session stride must be >= test and <=1000');
  return {...o,count,stride};
}
export function buildFolds(sessionDays,input={}){
  const o=validateFoldQuery(new URLSearchParams(Object.entries(input)));
  if(sessionDays.some((d,i)=>!/^\d{4}-\d{2}-\d{2}$/.test(d)||(i&&d<=sessionDays[i-1])))throw Error('Session days must be unique and chronological');
  const days=sessionDays.filter(d=>d<=o.end),total=o.train+o.validation+o.test;
  if(days.length<total+(o.count-1)*o.stride)throw Error('Insufficient cached sessions for all requested folds');
  const folds=[];
  for(let i=0;i<o.count;i++){
    const stop=days.length-(o.count-1-i)*o.stride,sessions=days.slice(stop-total,stop),endDate=sessions.at(-1);
    folds.push({id:`fold${String(i+1).padStart(2,'0')}_${endDate}`,symbol:o.symbol,endDate,end:endDate,train:o.train,validation:o.validation,test:o.test,stride:o.stride,
      datasetQuery:{symbol:o.symbol,train:o.train,validation:o.validation,test:o.test,end:endDate},sessions,
      trainSessions:sessions.slice(0,o.train),validationSessions:sessions.slice(o.train,o.train+o.validation),testSessions:sessions.slice(o.train+o.validation),
      firstDate:sessions[0],trainEndDate:sessions[o.train-1],validationStartDate:sessions[o.train],validationEndDate:sessions[o.train+o.validation-1],testStartDate:sessions[o.train+o.validation],testEndDate:endDate});
  }
  return {folds,metadata:{schemaVersion:3,app:'RoAlgo Market Lab',requested:o,count:folds.length,strideUnit:'trading sessions',chronological:true,testWindowsNonoverlapping:true,scope:'Historical exploratory research; prior inspected dates are not an untouched project holdout',equityConvention:'Each fold restarts equity; results are independent fold outcomes, not a continuously funded portfolio'}};
}
const rawCache=new Map(),manifestCache=new Map(),datasetCache=new Map();
const signature=p=>{if(!existsSync(p))return 'missing';const s=statSync(p);return s.size+':'+s.mtimeMs;};
function manifestAt(path){const stamp=signature(path);if(stamp==='missing')return {value:null,sha256:null};const old=manifestCache.get(path);if(old?.stamp===stamp)return old;const source=readFileSync(path);const value=JSON.parse(source);const result={value,sha256:hash(source),stamp};manifestCache.set(path,result);return result;}
function raw(group,symbol){
  const sector=group==='hourly-sector',base=sector?SECTOR_DATA:join(DATA,group),path=join(base,symbol+'.csv'),manifest=manifestAt(join(base,'manifest.json')),entry=manifest.value?.symbols?.[symbol];
  const key=group+'/'+symbol,stamp=signature(path)+':'+manifest.sha256;if(rawCache.get(key)?.stamp===stamp)return rawCache.get(key);
  if(sector&&(!entry?.available||!existsSync(path))){const result={bars:[],sha256:null,stamp,available:false,reason:entry?.reason??'Sector cache not available',provenance:{feed:manifest.value?.feed??'sip',adjustment:manifest.value?.adjustment??'raw',manifestSha256:manifest.sha256,status:entry?.status??'unavailable'}};rawCache.set(key,result);return result;}
  const source=readFileSync(path),sha256=hash(source);
  if(sector&&entry.sha256!==sha256)throw Error('Sector cache hash mismatch: '+symbol);
  const bars=parseCSV(source.toString());for(const b of bars){const x=nyTime(b.t);b.day=x.day;b.label=`${x.day} ${x.clock} ET`;b.minute=x.minute;b.availableT=b.t+(group==='daily-context'?93600:group==='five-minute'?300:3600);}
  const series=manifest.value?.series?.find(s=>s.symbol===symbol);
  const result={bars,sha256,stamp,available:bars.length>0,provenance:{provider:manifest.value?.provider??'Alpaca Market Data API',feed:manifest.value?.feed??'sip',adjustment:manifest.value?.adjustment??'raw',manifestSha256:manifest.sha256,requestedStart:manifest.value?.requestedStart,requestedEnd:manifest.value?.requestedEnd,first:bars[0]?.t,last:bars.at(-1)?.t,count:bars.length,rawSourceSha256:series?.sha256??null,rawPageHashes:entry?.pages?.map(p=>({file:p.file,sha256:p.sha256}))??[],status:'available'}};
  rawCache.set(key,result);return result;
}
export function completedContextJoin(rows,group){
  let previous=-Infinity,previousAvailable=-Infinity;
  for(const c of rows){if(!Number.isFinite(c.t)||!Number.isFinite(c.availableT)||c.t<=previous||c.availableT<previousAvailable)throw Error('Context timestamps contain duplicate or invalid order');previous=c.t;previousAvailable=c.availableT;}
  let i=-1;return b=>{
    const decision=b.t+300;while(i+1<rows.length&&rows[i+1].availableT<=decision)i++;
    if(i<0)return undefined;const c=rows[i];
    const accepted=group==='daily-context'?c.day<b.day&&c.availableT>=c.t+93600:group==='five-minute'?c.t===b.t&&c.availableT>=c.t+300:c.availableT>=c.t+3600&&decision-c.availableT<=7200;
    return accepted?c:undefined;
  };
}
export function loadFolds(input={}){
  const o=validateFoldQuery(new URLSearchParams(Object.entries(input))),target=raw('five-minute',o.symbol),all=target.bars.filter(b=>b.day<=o.end&&isRegular(b.t));
  const days=[...new Set(all.map(b=>b.day))],result=buildFolds(days,o),firstByDay=new Map(),lastByDay=new Map();
  for(const b of all){if(!firstByDay.has(b.day))firstByDay.set(b.day,b.t);lastByDay.set(b.day,b.t);}
  for(const f of result.folds){f.firstT=firstByDay.get(f.firstDate);f.trainEndT=firstByDay.get(f.validationStartDate);f.validationEndT=firstByDay.get(f.testStartDate);f.testStartT=f.validationEndT;f.testEndT=lastByDay.get(f.endDate)+300;}
  result.metadata.sourceHashes={['five-minute/'+o.symbol]:target.sha256};result.metadata.foldHash=hash(JSON.stringify({folds:result.folds,sourceHashes:result.metadata.sourceHashes}));return result;
}
export function sourceTree(){const files=[];for(const dir of ['src','tests'])if(existsSync(join(ROOT,dir)))for(const name of readdirSync(join(ROOT,dir)).sort()){if(!name.endsWith('.luau')||name.includes('.spec.')||name.includes('generated'))continue;const source=readFileSync(join(ROOT,dir,name),'utf8');files.push({path:dir+'/'+name.slice(0,-5),source,sha256:hash(source),className:'ModuleScript'});}return files;}
export function loadDataset(input={}){
  const o=validateQuery(new URLSearchParams(Object.entries(input)));
  const sourceCodeHashes=Object.fromEntries(sourceTree().map(f=>[f.path,f.sha256]));sourceCodeHashes.bridge=hash(readFileSync(fileURLToPath(import.meta.url)));
  const specs=[['peerFive','five-minute',o.symbol==='SPY'?'QQQ':'SPY'],['spyHour','hourly-combined','SPY'],['qqqHour','hourly-combined','QQQ'],['iwmHour','hourly-context','IWM'],['tltHour','hourly-context','TLT'],['xlkHour','hourly-sector','XLK'],['xlfHour','hourly-sector','XLF'],['xleHour','hourly-sector','XLE'],['spyDaily','daily-context','SPY'],['qqqDaily','daily-context','QQQ']];
  const sourceRecords=specs.map(([name,group,symbol])=>({name,group,symbol,source:raw(group,symbol)}));
  const key=hash(JSON.stringify({schemaVersion:3,o,sourceCodeHashes,sourceStamps:sourceRecords.map(r=>r.source.stamp),targetStamp:raw('five-minute',o.symbol).stamp}));if(datasetCache.has(key))return datasetCache.get(key);
  const target=raw('five-minute',o.symbol),all=target.bars.filter(b=>b.day<=o.end&&isRegular(b.t)),sessions=[...new Set(all.map(b=>b.day))].slice(-(o.train+o.validation+o.test));
  if(sessions.length!==o.train+o.validation+o.test)throw Error('Insufficient cached whole sessions');
  const selected=new Set(sessions),bars=all.filter(b=>selected.has(b.day)).map(b=>({...b,contexts:{}})),sourceHashes={['five-minute/'+o.symbol]:target.sha256};
  const contextStatus={},sourceProvenance={['five-minute/'+o.symbol]:target.provenance};
  for(const {name,group,symbol,source:r}of sourceRecords){if(r.sha256)sourceHashes[group+'/'+symbol]=r.sha256;sourceProvenance[group+'/'+symbol]=r.provenance;const lookup=completedContextJoin(r.bars,group);let present=0;for(const b of bars){const c=lookup(b);if(c){b.contexts[name]=c;present++;}}contextStatus[name]={available:r.available,status:r.available?'available':'unavailable',reason:r.reason??null,present,missing:bars.length-present,sourceCount:r.bars.length,sourceFirstT:r.bars[0]?.t??null,sourceLastT:r.bars.at(-1)?.t??null};}
  const daily=raw('daily-context',o.symbol),prehistory={targetDaily:daily.bars.filter(b=>b.day<bars[0].day&&b.availableT<=bars[0].t)};
  const counts=Object.fromEntries(sessions.map(s=>[s,bars.filter(b=>b.day===s).length]));let gaps=0;bars.forEach((b,i)=>{if(i&&b.day===bars[i-1].day&&b.t-bars[i-1].t!==300)gaps++;});
  const split={trainEndT:bars.find(b=>b.day===sessions[o.train]).t,validationEndT:bars.find(b=>b.day===sessions[o.train+o.validation]).t,testStartT:bars.find(b=>b.day===sessions[o.train+o.validation]).t};
  const metadata={schemaVersion:3,app:'RoAlgo Market Lab',symbol:o.symbol,requestedSplits:o,sessionCount:sessions.length,sessions,counts,intradayGaps:gaps,bars:bars.length,first:bars[0].label,last:bars.at(-1).label,prehistoryCount:prehistory.targetDaily.length,prehistoryFirst:prehistory.targetDaily[0]?.day,prehistoryLast:prehistory.targetDaily.at(-1)?.day,timeframeSeconds:300,adjustment:'raw',feed:'Alpaca SIP local cache',scope:'Historical exploratory research; earlier date ranges have already been inspected',sourceHashes,sourceCodeHashes,sourceProvenance,contextStatus,configHash:hash(JSON.stringify({schemaVersion:3,o})),dataHash:hash(JSON.stringify({sourceHashes,sourceProvenance,split,o})),cacheKey:hash(JSON.stringify({schemaVersion:3,sourceHashes,sourceCodeHashes,sourceProvenance,split,o})),contextAvailability:'5min start+300; hourly start+3600 including extended hours, maximum age7200 seconds since completion; daily start+93600, strictly prior NY date; absent context stays missing',hourlyMaxAgeSeconds:7200,volumeMeaning:'ETF volume, not total underlying index volume',excludedContexts:['VIX'],calendarAudit:'Explicit NYSE 2021-10-04..2026-10-02 holidays and 13:00 early closes, including 2025-01-09 Carter funeral',earlyCloseDays:sessions.filter(s=>EARLY_CLOSE.has(s))};
  const output={bars,prehistory,split,metadata};datasetCache.set(key,output);return output;
}
const MAX=64*1024*1024;
function send(res,status,data){res.writeHead(status,{'content-type':'application/json','cache-control':'no-store'});res.end(JSON.stringify(data));}
async function body(req){if(Number(req.headers['content-length'])>MAX){const e=Error('Result exceeds64 MiB');e.status=413;throw e;}let n=0;const chunks=[];for await(const c of req){n+=c.length;if(n>MAX){const e=Error('Result exceeds64 MiB');e.status=413;throw e;}chunks.push(c);}return JSON.parse(Buffer.concat(chunks).toString());}
export function createServer({load=loadDataset,resultDir=join(ROOT,'results')}={}){return http.createServer(async(req,res)=>{try{
  const host=req.headers.host??'',origin=req.headers.origin;if(!/^127\.0\.0\.1(?::\d+)?$/.test(host)||(origin!==undefined&&origin!==`http://${host}`))return send(res,403,{error:'Loopback host/origin required'});
  if(!/^\/(?:health|tree|dataset|folds|result|saved)(?:\?.*)?$/.test(req.url??''))return send(res,404,{error:'Unknown route'});
  const u=new URL(req.url,'http://127.0.0.1');if(req.method==='GET'&&u.pathname==='/health')return send(res,200,{ok:true,app:'RoAlgo Market Lab',schemaVersion:3,root:ROOT});
  if(req.method==='GET'&&u.pathname==='/tree')return send(res,200,{files:sourceTree()});
  if(req.method==='GET'&&u.pathname==='/dataset')return send(res,200,load(validateQuery(u.searchParams)));
  if(req.method==='GET'&&u.pathname==='/folds')return send(res,200,loadFolds(validateFoldQuery(u.searchParams)));
  if(req.method==='GET'&&u.pathname==='/saved'){const name=u.searchParams.get('name')??'',expected=u.searchParams.get('sha256');if(!/^[A-Za-z0-9_-]{1,100}\.json$/.test(name)||u.searchParams.getAll('name').length!==1||[...u.searchParams.keys()].some(k=>!['name','sha256'].includes(k))||(expected!==null&&(!/^[a-f0-9]{64}$/.test(expected)||u.searchParams.getAll('sha256').length!==1)))throw Error('Invalid saved result name/hash');const path=join(resultDir,name);if(!existsSync(path))return send(res,404,{error:'Result not found'});const bytes=readFileSync(path);if(expected!==null&&hash(bytes)!==expected)return send(res,409,{error:'Saved result hash mismatch'});return send(res,200,JSON.parse(bytes.toString('utf8')));}
  if(req.method==='POST'&&u.pathname==='/result'){if(!/^application\/json(?:;|$)/i.test(req.headers['content-type']??''))throw Error('JSON content type required');const data=await body(req);if(!/^[A-Za-z0-9_-]{1,100}$/.test(data.name??'')||/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i.test(data.name)||typeof data.result!=='object'||!data.result||Array.isArray(data.result))throw Error('Invalid result name/payload');mkdirSync(resultDir,{recursive:true});const path=join(resultDir,data.name+'.json'),json=JSON.stringify(data.result,null,2)+'\n';writeFileSync(path,json,{flag:'wx'});return send(res,201,{ok:true,path,sha256:hash(json)});}
  return send(res,404,{error:'Unknown route'});
}catch(e){return send(res,e.status??(e.code==='EEXIST'?409:400),{error:e.message});}});}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url)createServer().listen(47624,'127.0.0.1',()=>console.log('RoAlgo Market Lab bridge http://127.0.0.1:47624'));
