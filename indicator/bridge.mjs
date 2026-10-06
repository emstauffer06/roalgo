// RoAlgo local transport. No brokerage API, account keys, orders or external dependencies.
import http from 'node:http';
import {readFileSync,readdirSync,existsSync,mkdirSync,writeFileSync} from 'node:fs';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {dirname,join} from 'node:path';
import {createHash} from 'node:crypto';

export const ROOT=dirname(fileURLToPath(import.meta.url));
const DATA=join(ROOT,'../data/alpaca-supplement-2016-01-01_2026-10-02/five-minute');
const hash=x=>createHash('sha256').update(x).digest('hex');
const formatter=new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
// NYSE published early-close schedules, fixed to the explicitly supported 2021–2024 period.
// https://ir.theice.com/press/news-details/2020/NYSE-Group-Announces-2021-2022-and-2023-Holiday-and-Early-Closings-Calendar/default.aspx
// https://www.nyse.com/publicdocs/ICE_NYSE_2024_Yearly_Trading_Calendar.pdf
const EARLY_CLOSE=new Set(['2021-11-26','2022-11-25','2023-07-03','2023-11-24','2024-07-03','2024-11-29','2024-12-24']);
export function nyTime(t) {
  const p=Object.fromEntries(formatter.formatToParts(new Date(t*1000)).map(x=>[x.type,x.value]));
  return {day:`${p.year}-${p.month}-${p.day}`,minute:Number(p.hour)*60+Number(p.minute),clock:`${p.hour}:${p.minute}`};
}
export function parseCSV(text) {
  const lines=text.trim().split(/\r?\n/);
  if(lines.shift()!=='timestamp_utc,timestamp_unix,open,high,low,close,volume,trade_count,vwap') throw Error('Unexpected CSV schema');
  let previous=-Infinity;
  return lines.filter(Boolean).map((line,i)=>{
    const x=line.split(','); const [t,o,h,l,c,v]=x.slice(1,7).map(Number);
    if(x.length!==9||![t,o,h,l,c,v].every(Number.isFinite)||t<=previous) throw Error('Invalid timestamp order or duplicate at '+i);
    if(!Number.isInteger(t)||Date.parse(x[0])/1000!==t||t%300!==0) throw Error('Invalid timestamp at '+i);
    if(Math.min(o,h,l,c)<=0||h<Math.max(o,c,l)||l>Math.min(o,c,h)) throw Error('Invalid OHLC at '+i);
    if(v<0) throw Error('Invalid volume at '+i);
    previous=t; return {t,o,h,l,c,v};
  });
}
export function validateQuery(query) {
  const symbol=query.get('symbol')??'SPY';
  const days=Number(query.get('days')??5);
  const end=query.get('end')??'2024-12-31';
  if(!['SPY','QQQ'].includes(symbol)) throw Error('Symbol must be SPY or QQQ');
  if(![5,20,60].includes(days)) throw Error('Session count must be 5, 20 or 60');
  if(!/^\d{4}-\d{2}-\d{2}$/.test(end)||!Number.isFinite(Date.parse(end+'T00:00:00Z'))||new Date(end+'T00:00:00Z').toISOString().slice(0,10)!==end||end<'2021-10-04'||end>'2024-12-31') throw Error('Use an exploratory historical cutoff from 2021-10-04 through 2024-12-31');
  return {symbol,days,end};
}
export function selectBars(rows,{symbol,days,end}) {
  const regular=[]; const sessions=new Set();
  for(const r of rows) {
    // UTC date rejects almost all irrelevant bars before the more expensive timezone conversion.
    if(new Date(r.t*1000).toISOString().slice(0,10)>end) continue;
    const local=nyTime(r.t);
    if(local.day>end||local.minute<570||local.minute>=(EARLY_CLOSE.has(local.day)?780:960)) continue;
    regular.push({...r,day:local.day,label:`${local.day} ${local.clock} ET`}); sessions.add(local.day);
  }
  const selected=[...sessions].slice(-days), chosen=new Set(selected);
  const bars=regular.filter(r=>chosen.has(r.day));
  const counts=Object.fromEntries(selected.map(d=>[d,0]));
  let gaps=0;
  bars.forEach((b,i)=>{counts[b.day]++;if(i&&b.day===bars[i-1].day&&b.t-bars[i-1].t!==300) gaps++;});
  return {bars,metadata:{symbol,requestedSessions:days,sessionCount:selected.length,sessions:selected,counts,intradayGaps:gaps,timeframeSeconds:300,feed:'Alpaca SIP cached OHLCV',adjustment:'raw',session:'NYSE regular hours, 09:30–16:00 America/New_York; published early closes at13:00',earlyCloseDays:selected.filter(d=>EARLY_CLOSE.has(d)),cutoff:end,scope:'Historical exploratory research; not live and not an untouched holdout',first:bars[0]?.label,last:bars.at(-1)?.label}};
}
const cache=new Map();
export function loadBars(options) {
  const key=JSON.stringify(options);
  if(cache.has(key)) return cache.get(key);
  const source=readFileSync(join(DATA,options.symbol+'.csv'));
  const output=selectBars(parseCSV(source.toString('utf8')),options);
  output.metadata.sourceSHA256=hash(source);
  cache.set(key,output); return output;
}
export function sourceTree() {
  const files=[];
  for(const dir of ['src','tests']) {
    if(!existsSync(join(ROOT,dir))) continue;
    for(const name of readdirSync(join(ROOT,dir)).sort()) {
      if(!name.endsWith('.luau')||name.includes('.spec.')||name.includes('generated')) continue;
      const source=readFileSync(join(ROOT,dir,name),'utf8');
      files.push({path:dir+'/'+name.replace(/\.luau$/,''),source,sha256:hash(source),className:'ModuleScript'});
    }
  }
  return files;
}
function send(res,status,value) {res.writeHead(status,{'content-type':'application/json','cache-control':'no-store'});res.end(JSON.stringify(value));}
async function body(req) {
  const chunks=[]; let bytes=0;
  for await(const chunk of req){bytes+=chunk.length;if(bytes>32*1024*1024)throw Error('Result exceeds 32 MiB');chunks.push(chunk);}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
export function createServer({load=loadBars}={}) {
  return http.createServer(async(req,res)=>{
    try {
      if(req.headers.origin||!/^127\.0\.0\.1(?::\d+)?$/.test(req.headers.host??'')) return send(res,403,{error:'Loopback Studio client only'});
      const url=new URL(req.url,'http://127.0.0.1');
      if(req.method==='GET'&&url.pathname==='/health') return send(res,200,{ok:true,app:'RoAlgo indicator',root:ROOT});
      if(req.method==='GET'&&url.pathname==='/tree') return send(res,200,{files:sourceTree()});
      if(req.method==='GET'&&url.pathname==='/bars') return send(res,200,load(validateQuery(url.searchParams)));
      if(req.method==='POST'&&url.pathname==='/result') {
        const data=await body(req);
        if(!/^application\/json/.test(req.headers['content-type']??'')) throw Error('JSON content type required');
        if(!/^[A-Za-z0-9_-]{1,100}$/.test(data.name??'')||typeof data.result!=='object'||!data.result) throw Error('Invalid result name or payload');
        const dir=join(ROOT,'results');mkdirSync(dir,{recursive:true});
        const path=join(dir,data.name+'.json'),json=JSON.stringify(data.result,null,2)+'\n';
        writeFileSync(path,json,{flag:'wx'});
        return send(res,201,{ok:true,path,sha256:hash(json)});
      }
      return send(res,404,{error:'Unknown route'});
    } catch(e) {return send(res,e.code==='EEXIST'?409:400,{error:e.message});}
  });
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url) {
  const server=createServer();
  server.listen(47622,'127.0.0.1',()=>console.log('RoAlgo indicator bridge listening on http://127.0.0.1:47622'));
}
