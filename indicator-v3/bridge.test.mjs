import test from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';
import { mkdtempSync, readdirSync, rmSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const api = await import('./bridge.mjs').catch(() => ({}));
const sectors = await import('./fetch-sector-context.mjs').catch(() => ({}));
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
    assert.equal(next.metadata.contextStatus.xlkHour.available,false);assert.ok(next.bars.every(b=>!b.contexts.xlkHour));
    const sectorDir=join(bridge,'data','sector-hourly-sip');mkdirSync(sectorDir,{recursive:true});
    const sectorCSV=header+'\n'+['2024-12-02T13:00:00.000Z','2024-12-03T13:00:00.000Z','2024-12-04T13:00:00.000Z'].map(t=>csv(t)).join('\n');
    writeFileSync(join(sectorDir,'XLK.csv'),sectorCSV);writeFileSync(join(sectorDir,'manifest.json'),JSON.stringify({feed:'sip',adjustment:'raw',symbols:{XLK:{available:true,status:'complete',sha256:createHash('sha256').update(sectorCSV).digest('hex')}}}));
    const withSector=m.loadDataset(o);assert.equal(withSector.metadata.contextStatus.xlkHour.available,true);assert.equal(withSector.metadata.contextStatus.xlkHour.present,3);assert.notEqual(withSector.metadata.dataHash,next.metadata.dataHash);assert.notEqual(withSector.metadata.cacheKey,next.metadata.cacheKey);
    writeFileSync(join(sectorDir,'XLK.csv'),sectorCSV+'\n'+csv('2024-12-05T13:00:00.000Z'));assert.throws(()=>m.loadDataset(o),/hash mismatch/i,'modified cache must not masquerade as its recorded source');
  } finally {rmSync(dir,{recursive:true,force:true});}
});
function call(port,path,options={}) {return new Promise((resolve,reject)=>{const req=request({hostname:'127.0.0.1',port,path,method:options.method??'GET',headers:options.headers??{}},res=>{let text='';res.on('data',x=>text+=x);res.on('end',()=>resolve({status:res.statusCode,data:JSON.parse(text)}));});req.on('error',reject);req.end(options.body);});}
test('transport rejects remote host/origin paths and malformed bodies; saves unique results',async()=>{
  assert.equal(typeof api.createServer,'function','Transport must exist');
  const dir=mkdtempSync(join(tmpdir(),'roalgo-v2-'));
  const server=api.createServer({resultDir:dir});await new Promise(r=>server.listen(0,'127.0.0.1',r));const p=server.address().port;
  try {
    const health=await call(p,'/health');assert.equal(health.status,200);assert.equal(health.data.schemaVersion,3);assert.equal(health.data.app,'RoAlgo Market Lab');assert.ok(health.data.root.endsWith('indicator-v3'));
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
    const savedHash=createHash('sha256').update(readFileSync(join(dir,'proof.json'))).digest('hex');
    assert.equal((await call(p,'/saved?name=proof.json&sha256='+savedHash)).status,200);
    assert.equal((await call(p,'/saved?name=proof.json&sha256='+'0'.repeat(64))).status,409);
    assert.equal((await call(p,'/saved?name=..%2fproof.json')).status,400);
    assert.equal((await call(p,'/saved?name=proof.json&name=other.json')).status,400);
    assert.equal((await call(p,'/saved?name=absent.json')).status,404);
    assert.equal((await call(p,'/result',{method:'POST',headers:{'content-type':'application/json','content-length':String(64*1024*1024+1)}})).status,413);
  } finally {await new Promise(r=>server.close(r));rmSync(dir,{recursive:true,force:true});}
});

test('completed hourly joins reject future and stale bars and leave missing observations absent',()=>{
  assert.equal(typeof api.completedContextJoin,'function');
  const rows=[{t:0,availableT:3600},{t:3600,availableT:7200},{t:18000,availableT:21600}];
  const lookup=api.completedContextJoin(rows,'hourly-sector');
  assert.equal(lookup({t:3299}),undefined);
  assert.equal(lookup({t:3300}).t,0);
  assert.equal(lookup({t:6900}).t,3600);
  assert.equal(lookup({t:14100}).t,3600);
  assert.equal(lookup({t:14400}),undefined,'more than two hours past completion is stale');
  assert.equal(lookup({t:21000}),undefined,'future final close may not fill stale context');
  assert.equal(lookup({t:21300}).t,18000);
  assert.throws(()=>api.completedContextJoin([{t:0,availableT:3600},{t:0,availableT:3600}],'hourly-sector'),/order|duplicate/i);
});

test('folds use chronological trading-session strides and never overlap evaluation windows',()=>{
  assert.equal(typeof api.buildFolds,'function');
  const days=['2024-12-02','2024-12-03','2024-12-04','2024-12-05','2024-12-06','2024-12-09','2024-12-10','2024-12-11','2024-12-12','2024-12-13'];
  const result=api.buildFolds(days,{symbol:'SPY',train:2,validation:1,test:2,count:3,stride:2,end:'2024-12-15'});
  assert.deepEqual(result.folds.map(f=>f.endDate),['2024-12-09','2024-12-11','2024-12-13']);
  assert.deepEqual(result.folds.map(f=>f.testSessions),[['2024-12-06','2024-12-09'],['2024-12-10','2024-12-11'],['2024-12-12','2024-12-13']]);
  assert.deepEqual(result.folds[0].datasetQuery,{symbol:'SPY',train:2,validation:1,test:2,end:'2024-12-09'});
  assert.equal(result.metadata.strideUnit,'trading sessions');
  assert.throws(()=>api.buildFolds(days,{train:2,validation:1,test:2,count:2,stride:1,end:'2024-12-15'}),/stride/i);
  assert.throws(()=>api.buildFolds(days,{train:2,validation:1,test:2,count:5,stride:2,end:'2024-12-15'}),/Insufficient/i);
  assert.throws(()=>api.validateFoldQuery(new URLSearchParams('count=2&count=3')),/duplicate/i);
});

test('real folds expose dataset-compatible queries and explicit sector availability',async()=>{
  assert.equal(typeof api.loadFolds,'function');
  const f=api.loadFolds({symbol:'SPY',train:20,validation:5,test:5,count:3,stride:60,end:'2024-12-31'});
  assert.equal(f.folds.length,3);let previousEnd=0;
  for(const fold of f.folds){
    const d=api.loadDataset(fold.datasetQuery);assert.equal(d.metadata.schemaVersion,3);assert.equal(fold.testEndT,d.bars.at(-1).t+300,'fold test end is exclusive');
    assert.ok(d.split.testStartT>previousEnd);previousEnd=d.bars.at(-1).t;
    for(const name of ['xlkHour','xlfHour','xleHour']){
      const status=d.metadata.contextStatus[name];assert.equal(typeof status.available,'boolean');
      assert.equal(status.present+status.missing,d.bars.length);
      if(!status.available)assert.ok(d.bars.every(b=>b.contexts[name]===undefined));
    }
  }
  const server=api.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));
  try{const response=await call(server.address().port,'/folds?train=2&validation=1&test=1&count=2&stride=3&end=2024-12-31');assert.equal(response.status,200);assert.equal(response.data.folds.length,2);assert.equal((await call(server.address().port,'/folds?test=5&stride=4')).status,400);}finally{await new Promise(r=>server.close(r));}
});

const providerBar=t=>({t,o:100,h:102,l:99,c:101,v:20,n:3,vw:100.5});
const response=(bars,token=null,status=200)=>({ok:status===200,status,headers:new Headers(),text:async()=>JSON.stringify({bars,next_page_token:token}),body:{cancel:async()=>{}}});
test('sector fetch validates pagination and preserves exact raw response provenance',async()=>{
  assert.equal(typeof sectors.fetchSectorBars,'function');
  const requests=[],pages=[];
  const result=await sectors.fetchSectorBars({symbol:'XLK',start:'2024-12-02T00:00:00Z',end:'2024-12-03T00:00:00Z',credentials:{key:'test-key',secret:'test-secret'},sleep:async()=>{},onPage:p=>pages.push(p),fetchImpl:async(url,options)=>{
    requests.push({url:String(url),method:options.method});return requests.length===1?response({XLK:[providerBar('2024-12-02T14:00:00Z')]},'next'):response({XLK:[providerBar('2024-12-02T15:00:00Z')]});
  }});
  assert.equal(result.bars.length,2);assert.equal(result.requestCount,2);assert.equal(pages.length,2);
  for(const r of requests){const u=new URL(r.url);assert.equal(u.origin,'https://data.alpaca.markets');assert.equal(u.pathname,'/v2/stocks/bars');assert.equal(r.method,'GET');assert.equal(u.searchParams.get('feed'),'sip');assert.equal(u.searchParams.get('adjustment'),'raw');}
  assert.equal(new URL(requests[1].url).searchParams.get('page_token'),'next');
  assert.equal(pages[0].sha256.length,64);assert.equal(JSON.parse(pages[0].raw).bars.XLK[0].t,'2024-12-02T14:00:00Z');
  await assert.rejects(()=>sectors.fetchSectorBars({symbol:'XLK',start:'2024-12-02T00:00:00Z',end:'2024-12-03T00:00:00Z',credentials:{key:'test',secret:'test'},sleep:async()=>{},fetchImpl:async()=>response({XLK:[providerBar('2024-12-02T14:00:00Z'),providerBar('2024-12-02T14:00:00Z')]})}),/duplicate|order/i);
});

test('sector cache marks network failure unavailable without synthetic prices or secret-bearing errors',async()=>{
  assert.equal(typeof sectors.runSectorDownload,'function');
  const dir=mkdtempSync(join(tmpdir(),'roalgo-v3-sectors-'));
  try{
    const m=await sectors.runSectorDownload({outputDir:dir,start:'2024-12-02T00:00:00Z',end:'2024-12-03T00:00:00Z',credentials:{key:'test-key',secret:'test-secret'},sleep:async()=>{},log:()=>{},fetchImpl:async url=>{
      const s=url.searchParams.get('symbols');if(s==='XLF')throw Error('test-secret');return response({[s]:[providerBar('2024-12-02T14:00:00Z')]});
    }});
    assert.equal(m.status,'partial');assert.equal(m.symbols.XLK.available,true);assert.equal(m.symbols.XLF.available,false);assert.equal(m.symbols.XLF.requestCount,3);
    assert.equal(readdirSync(dir).includes('XLF.csv'),false);assert.equal(api.parseCSV(readFileSync(join(dir,'XLK.csv'),'utf8')).length,1);
    assert.equal(readFileSync(join(dir,'manifest.json'),'utf8').includes('test-secret'),false);
    await assert.rejects(()=>sectors.runSectorDownload({outputDir:dir,credentials:{key:'test',secret:'test'}}),/empty|existing/i);
  }finally{rmSync(dir,{recursive:true,force:true});}
});
