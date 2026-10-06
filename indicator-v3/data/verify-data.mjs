// Reproducible read-only cache audit; writes only its requested verification report.
import {readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import {loadDataset,loadFolds,parseCSV} from '../bridge.mjs';
import {parseCredentials} from '../../download.mjs';
const data=dirname(fileURLToPath(import.meta.url)),root=join(data,'..'),cache=join(data,'sector-hourly-sip');
const hash=x=>createHash('sha256').update(x).digest('hex');
const manifestBytes=readFileSync(join(cache,'manifest.json')),manifest=JSON.parse(manifestBytes),series=[];
for(const [symbol,entry]of Object.entries(manifest.symbols)){
  assert.equal(entry.available,true);const bytes=readFileSync(join(cache,entry.csvPath));assert.equal(hash(bytes),entry.sha256);const csv=parseCSV(bytes.toString()),raw=[];
  for(const p of entry.pages){const source=readFileSync(join(cache,p.file));assert.equal(hash(source),p.sha256);assert.equal(source.length,p.bytes);const payload=JSON.parse(source);assert.equal(payload.bars[symbol].length,p.received);raw.push(...payload.bars[symbol]);}
  assert.equal(csv.length,entry.count);assert.equal(raw.length,csv.length);
  for(let i=0;i<csv.length;i++){const c=csv[i],b=raw[i];assert.deepEqual(c,{t:Date.parse(b.t)/1000,o:b.o,h:b.h,l:b.l,c:b.c,v:b.v,n:b.n,vwap:b.vw});}
  series.push({symbol,rows:entry.count,first:entry.first,last:entry.last,requests:entry.requestCount,pages:entry.pageCount,csvSha256:entry.sha256});
}
const audits=[];
for(const symbol of ['SPY','QQQ']){
  const f=loadFolds({symbol,train:20,validation:5,test:5,count:3,stride:60,end:'2024-12-31'});let lastTestEnd=0;
  for(const fold of f.folds){
    const d=loadDataset(fold.datasetQuery);assert.ok(d.split.testStartT>lastTestEnd);lastTestEnd=d.bars.at(-1).t;let future=0,stale=0,sameDayDaily=0;
    for(const b of d.bars)for(const[name,c]of Object.entries(b.contexts)){if(c.availableT>b.t+300)future++;if(name.endsWith('Hour')&&b.t+300-c.availableT>7200)stale++;if(name.endsWith('Daily')&&c.day>=b.day)sameDayDaily++;}
    assert.equal(future+stale+sameDayDaily,0);assert.equal(d.metadata.intradayGaps,0);
    audits.push({symbol,foldId:fold.id,first:d.metadata.first,last:d.metadata.last,sessions:d.metadata.sessionCount,bars:d.bars.length,trainEndT:d.split.trainEndT,testStartT:d.split.testStartT,testEndT:lastTestEnd,prehistory:d.prehistory.targetDaily.length,intradayGaps:d.metadata.intradayGaps,future,stale,sameDayDaily,missing:Object.fromEntries(Object.entries(d.metadata.contextStatus).map(([k,v])=>[k,v.missing])),dataHash:d.metadata.dataHash});
  }
}
let credentialLeakCheck='not-requested';
if(process.argv[2]){const credentials=parseCredentials(readFileSync(process.argv[2],'utf8'));let checked=0;function scan(dir){for(const e of readdirSync(dir,{withFileTypes:true})){if(e.isDirectory()){if(e.name!=='results'&&e.name!=='build')scan(join(dir,e.name));}else{const bytes=readFileSync(join(dir,e.name));assert.equal(bytes.includes(Buffer.from(credentials.key)),false,'Credential ID found in output');assert.equal(bytes.includes(Buffer.from(credentials.secret)),false,'Credential secret found in output');checked++;}}}scan(root);credentialLeakCheck={status:'passed',filesChecked:checked};}
const report={verifiedAtUTC:new Date().toISOString(),status:'passed',manifestSha256:hash(manifestBytes),requestCount:manifest.requestCount,pageCount:manifest.pageCount,series,foldAudits:audits,credentialLeakCheck,ownedSourceHashes:Object.fromEntries(['bridge.mjs','bridge.test.mjs','fetch-sector-context.mjs'].map(f=>[f,hash(readFileSync(join(root,f)))]))};
writeFileSync(join(data,'verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
