import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const api=await import('../refit-saved.mjs').catch(()=>({}));
const sha=x=>createHash('sha256').update(x).digest('hex');
const names=Array.from({length:33},(_,i)=>'raw'+i),stateNames=Array.from({length:51},(_,i)=>'state'+i),drives=Array.from({length:8},(_,i)=>'drive'+i);
function fixture(dir){
 const records=[0,1,2].map(i=>({bar:{t:1704205800+i*300,day:'2024-01-02',o:1,h:1.01,l:.99,c:1},feature:{t:1704205800+i*300,raw:Array(33).fill(i),names,drive:Array(8).fill(i),reset:i===0,ready:true,volatility:.01},states:Object.fromEntries(['coupled','independent','numeric'].map(id=>[id,{vector:Array(51).fill(i),names:stateNames,nodes:Array.from({length:24},(_,j)=>({index:j+1}))}]))}));
 const native={schema:'roalgo-mechanics-v2-1',totalSteps:36,totalBars:3,numericSteps:36,stepsPerBar:12,dt:1/60,corruptSteps:0,failedBars:0,stepFailures:0,barrierFailures:0,counts:{coupledNodes:24,independentNodes:24}};
 const metadata={symbol:'SPY',schemaVersion:2,dataHash:'test-data',sessionCount:1,sessions:['2024-01-02'],counts:{'2024-01-02':3},bars:3,requestedSplits:{train:1,validation:1,test:1,end:'2024-01-02'}};
 const common={metadata,split:{trainEndT:1704206100,validationEndT:1704206400,testStartT:1704206400},sourceHashes:{'src/Features':'abc'},native,placeId:0};
 const chunk={...structuredClone(common),version:'roalgo-states-v2',symbol:'SPY',firstIndex:1,lastIndex:3,records};
 const file=join(dir,'Capture_states_0001.json'),bytes=JSON.stringify(chunk);writeFileSync(file,bytes);
 const manifest={...common,version:'roalgo-learned-v2',phase:'complete',total:3,completed:3,profile:1,endDate:'2024-01-02',featureInfo:{rawCount:33,driveCount:8,names,driveNames:drives},cacheChunks:[{path:file,sha256:sha(bytes)}],comparisons:[],replayRecords:[records[2]]};
 const path=join(dir,'Capture.json');writeFileSync(path,JSON.stringify(manifest));return {path,file,manifest,chunk,records};
}
test('capture verifier rejects tampering, duplicate chronology, wrong identity and incorrect native accounting',()=>{
 assert.equal(typeof api.verifySavedCapture,'function');
 const dir=mkdtempSync(join(tmpdir(),'refit-capture-'));
 try{
  let f=fixture(dir);const v=api.verifySavedCapture(f.path);assert.equal(v.records.length,3);assert.equal(v.audit.historicalNativeSteps,36);assert.equal(v.audit.newNativeSteps,0);
  writeFileSync(f.file,readFileSync(f.file,'utf8')+' ');assert.throws(()=>api.verifySavedCapture(f.path),/hash/i);
  for(const mutate of [c=>c.records[1].bar.t=c.records[0].bar.t,c=>c.metadata.dataHash='wrong',c=>c.firstIndex=2,c=>c.native.totalSteps=35]){
   f=fixture(dir);mutate(f.chunk);const bytes=JSON.stringify(f.chunk);writeFileSync(f.file,bytes);f.manifest.cacheChunks[0].sha256=sha(bytes);writeFileSync(f.path,JSON.stringify(f.manifest));assert.throws(()=>api.verifySavedCapture(f.path));
  }
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('actual saved v2 capture verifies all 2268 records without changing source bytes',()=>{
 assert.equal(typeof api.verifySavedCapture,'function');const v=api.verifySavedCapture(api.DEFAULT_SOURCE,{expectedRecords:2268,expectedChunks:5});
 assert.equal(v.audit.sessions,30);assert.equal(v.audit.historicalNativeSteps,27216);assert.equal(v.audit.rawDimension,33);assert.equal(v.audit.stateDimension,51);assert.equal(v.audit.replayRecords,354);assert.equal(api.verifyUnchanged(v.inputHashes),true);
});
test('generated Luau memory uses recorded drive lags/current EWMAs and resets without mutating raw/native fields',()=>{
 assert.equal(typeof api.MEMORY_SOURCE,'string');const dir=mkdtempSync(join(tmpdir(),'refit-memory-'));
 try{
  writeFileSync(join(dir,'Memory.luau'),api.MEMORY_SOURCE);writeFileSync(join(dir,'test.luau'),`local Memory=require('./Memory')
local records={};local names={};for i=1,8 do names[i]='drive'..i end
for i=1,5 do records[i]={bar={t=i*300},states={marker=i},feature={raw={i},drive=table.create(8,i*2),reset=i==1 or i==5}}end
local augmented=Memory.augment(records,names)
assert(#augmented[1].feature.memory==32)
local m=augmented[4].feature.memory
assert(m[1]==6 and m[2]==2 and math.abs(m[3]-6.125)<1e-12 and math.abs(m[4]-.9512375)<1e-12)
local reset=augmented[5].feature.memory;assert(reset[1]==0 and reset[2]==0 and reset[3]==5 and reset[4]==.5)
assert(augmented[1].feature.raw==records[1].feature.raw and augmented[1].states==records[1].states and records[1].feature.memory==nil)
local prefix=Memory.augment({records[1],records[2],records[3],records[4]},names)
for i=1,4 do for j=1,32 do assert(prefix[i].feature.memory[j]==augmented[i].feature.memory[j])end end
print('PASS causal saved-drive memory')
`);
  const r=spawnSync((process.env.LUAU_EXE||'luau'),[join(dir,'test.luau')],{encoding:'utf8',timeout:10000});assert.equal(r.status,0,r.stdout+r.stderr);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('preparation snapshots actual Luau sources and refuses nonempty output without running them',()=>{
 assert.equal(typeof api.prepareRefit,'function');const dir=mkdtempSync(join(tmpdir(),'refit-prepare-'));
 try{const f=fixture(dir),out=join(dir,'prepared');const prepared=api.prepareRefit({manifestPath:f.path,outputDir:out});assert.equal(prepared.audit.status,'verified');assert.ok(prepared.sourceHashes['src/Learning']);assert.ok(prepared.sourceHashes['src/Study']);assert.ok(prepared.sourceHashes['src/Execution']);assert.equal(readFileSync(join(out,'src','Learning.luau'),'utf8'),readFileSync(new URL('../src/Learning.luau',import.meta.url),'utf8'));assert.throws(()=>api.prepareRefit({manifestPath:f.path,outputDir:out}),/empty|existing/i);}finally{rmSync(dir,{recursive:true,force:true});}
});
test('readout provenance finalization preserves completed evidence and does not refit or overwrite it',()=>{
 assert.equal(typeof api.finalizeReadoutArtifact,'function');const dir=mkdtempSync(join(tmpdir(),'refit-finalize-'));
 try{
  const path=join(dir,'original.json'),study={version:'roalgo-study-v3',phase:'complete',newNativeSteps:0,historicalNativeSteps:36,sourceHashes:{'src/Learning':'executed-source'},folds:[{id:'saved_v2_24_saved20241231',comparisons:[{id:'raw',model:{weights:[1,2]},result:{rows:[{prediction:3}]}}]}]};
  const bytes=JSON.stringify(study);writeFileSync(path,bytes);const receipt=api.finalizeReadoutArtifact({sourcePath:path,outputPath:join(dir,'corrected.json'),expectedSha256:sha(bytes)});
  assert.equal(readFileSync(path,'utf8'),bytes);const corrected=JSON.parse(readFileSync(receipt.path,'utf8'));assert.equal(corrected.readoutOnly,true);delete corrected.readoutOnly;assert.deepEqual(corrected,study);assert.equal(receipt.sha256,sha(readFileSync(receipt.path)));
  assert.throws(()=>api.finalizeReadoutArtifact({sourcePath:path,outputPath:join(dir,'corrected.json'),expectedSha256:sha(bytes)}),/exist/i);
  assert.throws(()=>api.finalizeReadoutArtifact({sourcePath:path,outputPath:join(dir,'bad.json'),expectedSha256:'wrong'}),/hash/i);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
