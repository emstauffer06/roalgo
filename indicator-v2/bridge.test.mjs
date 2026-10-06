import test from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';
import { mkdtempSync, readdirSync, rmSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const api = await import('./bridge.mjs').catch(() => ({}));
const header='timestamp_utc,timestamp_unix,open,high,low,close,volume,trade_count,vwap';
const csv=(iso,extra='100,102,99,101,20,3,100.5')=>`${iso},${Date.parse(iso)/1000},${extra}`;
test('CSV rejects nonfinite values, duplicates and invalid OHLCV while preserving activity',()=>{
  assert.equal(typeof api.parseCSV,'function','CSV validation must exist');
  const line=csv('2024-12-02T14:30:00.000Z');
  assert.deepEqual(api.parseCSV(header+'\n'+line)[0],{t:1733149800,o:100,h:102,l:99,c:101,v:20,n:3,vwap:100.5});
  for(const s of [line+'\n'+line,csv('2024-12-02T14:30:00.000Z','100,102,99,101,NaN,3,100'),csv('2024-12-02T14:30:00.000Z','100,99,99,101,20,3,100')]) assert.throws(()=>api.parseCSV(header+'\n'+s));
  assert.throws(()=>api.parseCSV(header+'\n'+csv('2024-12-02T14:30:00.000Z','100,102,99,101,20,,100')),'blank trade counts cannot become zero');
});
test('New York DST and early close are respected',()=>{
  assert.equal(typeof api.nyTime,'function','New York conversion must exist');
  assert.equal(api.nyTime(Date.parse('2024-07-03T13:30:00Z')/1000).minute,570);
  assert.equal(api.nyTime(Date.parse('2024-12-02T14:30:00Z')/1000).minute,570);
  assert.equal(api.isRegular(Date.parse('2024-07-03T16:55:00Z')/1000),true);
  assert.equal(api.isRegular(Date.parse('2024-07-03T17:00:00Z')/1000),false);
  assert.equal(api.isRegular(Date.parse('2025-12-24T18:00:00Z')/1000),false);
  assert.equal(api.isRegular(Date.parse('2025-01-09T15:00:00Z')/1000),false);
  assert.equal(api.isRegular(Date.parse('2026-07-03T15:00:00Z')/1000),false);
  assert.equal(api.isRegular(Date.parse('2024-12-07T15:00:00Z')/1000),false);
});
test('real cache joins only completed context, daily prior dates and whole session splits',()=>{
  assert.equal(typeof api.loadDataset,'function','Dataset loader must exist');
  const d=api.loadDataset({symbol:'SPY',train:20,validation:5,test:5,end:'2024-12-31'});
  assert.equal(d.metadata.sessionCount,30);
  assert.equal(d.split.trainEndT,d.bars.find(b=>b.day===d.metadata.sessions[20]).t);
  assert.equal(d.split.validationEndT,d.bars.find(b=>b.day===d.metadata.sessions[25]).t);
  assert.ok(d.prehistory.targetDaily.length>100);
  assert.ok(d.prehistory.targetDaily.every(b=>b.day<d.bars[0].day));
  for(const b of d.bars) for(const [k,c] of Object.entries(b.contexts)){assert.ok(c.availableT<=b.t+300,k);if(k.endsWith('Daily'))assert.ok(c.day<b.day);if(k.endsWith('Hour'))assert.equal(c.availableT,c.t+3600);}
  const first=d.bars[0]; assert.equal(first.contexts.peerFive.t,first.t);
  assert.ok(Object.keys(d.metadata.sourceHashes).length>=8);
  assert.deepEqual(Object.values(d.metadata.counts).filter(n=>n!==78&&n!==42),[]);
  assert.deepEqual(d.metadata.earlyCloseDays,['2024-11-29','2024-12-24']);
});
test('query limits accept 1000 sessions and reject unsafe parameters',()=>{
  assert.equal(typeof api.validateQuery,'function','Query validator must exist');
  assert.equal(api.validateQuery(new URLSearchParams('train=990&validation=5&test=5&end=2026-10-02')).train,990);
  for(const q of ['symbol=../SPY','train=1000','train=0','end=2024-02-30','end=2026-10-03','extra=1'])assert.throws(()=>api.validateQuery(new URLSearchParams(q)));
});
test('dataset cache invalidates when source definitions change',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'roalgo-v2-cache-'));
  try {
    const bridge=join(dir,'indicator-v2');mkdirSync(join(bridge,'src'),{recursive:true});writeFileSync(join(bridge,'bridge.mjs'),readFileSync(new URL('./bridge.mjs',import.meta.url)));
    writeFileSync(join(bridge,'src','Temp.luau'),'return 1');
    const data=join(dir,'data','alpaca-supplement-2016-01-01_2026-10-02');
    for(const [g,s] of [['five-minute','SPY'],['five-minute','QQQ'],['hourly-combined','SPY'],['hourly-combined','QQQ'],['hourly-context','IWM'],['hourly-context','TLT'],['daily-context','SPY'],['daily-context','QQQ']]){mkdirSync(join(data,g),{recursive:true});const lines=['2024-12-02T14:30:00.000Z','2024-12-03T14:30:00.000Z','2024-12-04T14:30:00.000Z'].map(t=>csv(t));writeFileSync(join(data,g,s+'.csv'),header+'\n'+lines.join('\n'));}
    const m=await import(pathToFileURL(join(bridge,'bridge.mjs')).href),o={train:1,validation:1,test:1,end:'2024-12-04'};
    const first=m.loadDataset(o);writeFileSync(join(bridge,'src','Temp.luau'),'return 2');const next=m.loadDataset(o);
    assert.notEqual(first.metadata.sourceCodeHashes['src/Temp'],next.metadata.sourceCodeHashes['src/Temp']);
    assert.notEqual(first.metadata.cacheKey,next.metadata.cacheKey);
  } finally {rmSync(dir,{recursive:true,force:true});}
});
function call(port,path,options={}) {return new Promise((resolve,reject)=>{const req=request({hostname:'127.0.0.1',port,path,method:options.method??'GET',headers:options.headers??{}},res=>{let text='';res.on('data',x=>text+=x);res.on('end',()=>resolve({status:res.statusCode,data:JSON.parse(text)}));});req.on('error',reject);req.end(options.body);});}
test('transport rejects remote host/origin paths and malformed bodies; saves unique results',async()=>{
  assert.equal(typeof api.createServer,'function','Transport must exist');
  const dir=mkdtempSync(join(tmpdir(),'roalgo-v2-'));
  const server=api.createServer({resultDir:dir});await new Promise(r=>server.listen(0,'127.0.0.1',r));const p=server.address().port;
  try {
    assert.equal((await call(p,'/health')).status,200);
    assert.equal((await call(p,'/health',{headers:{host:'evil.example'}})).status,403);
    assert.equal((await call(p,'/health',{headers:{origin:'https://evil.example'}})).status,403);
    assert.equal((await call(p,'/%2e%2e/health')).status,404);
    assert.equal((await call(p,'/tree')).data.files.some(f=>f.path.includes('.spec')),false);
    for(const body of ['{',JSON.stringify({name:'../bad',result:{}}),JSON.stringify({name:'valid',result:[]})])assert.equal((await call(p,'/result',{method:'POST',headers:{'content-type':'application/json'},body})).status,400);
    const body=JSON.stringify({name:'proof',result:{scope:'historical exploratory research'}}),opts={method:'POST',headers:{'content-type':'application/json'},body};
    assert.equal((await call(p,'/result',opts)).status,201);assert.equal((await call(p,'/result',opts)).status,409);
    assert.deepEqual(readdirSync(dir),['proof.json']);
    assert.equal((await call(p,'/saved?name=proof.json')).status,200);
    assert.equal((await call(p,'/saved?name=proof.json')).data.scope,'historical exploratory research');
    assert.equal((await call(p,'/saved?name=..%2fproof.json')).status,400);
    assert.equal((await call(p,'/saved?name=proof.json&name=other.json')).status,400);
    assert.equal((await call(p,'/saved?name=absent.json')).status,404);
    assert.equal((await call(p,'/result',{method:'POST',headers:{'content-type':'application/json','content-length':String(64*1024*1024+1)}})).status,413);
  } finally {await new Promise(r=>server.close(r));rmSync(dir,{recursive:true,force:true});}
});
