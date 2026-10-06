// Read-only replay/refit of one persisted v2 native capture. No Studio or network APIs.
import {readFileSync,writeFileSync,mkdirSync,readdirSync,existsSync} from 'node:fs';
import {join,dirname,basename,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {runLuau,luauIdentity} from '../tools/luau-run.mjs';
const ROOT=dirname(fileURLToPath(import.meta.url));
export const DEFAULT_SOURCE=join(ROOT,'../indicator-v2/results/RoAlgoV2_SPY_1791205420530.json');
const hash=x=>createHash('sha256').update(x).digest('hex');
const canonical=x=>JSON.stringify(x,(_k,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
const finiteArray=(x,n)=>Array.isArray(x)&&x.length===n&&x.every(Number.isFinite);
const jsonFile=path=>JSON.parse(readFileSync(path,'utf8'));
function exclusive(path,bytes){writeFileSync(path,bytes,{flag:'wx'});return {path,sha256:hash(bytes),bytes:Buffer.byteLength(bytes)};}

export function verifyUnchanged(inputHashes){for(const entry of inputHashes)assert.equal(hash(readFileSync(entry.path)),entry.sha256,'Original input changed: '+entry.path);return true;}
export function verifySavedCapture(manifestPath=DEFAULT_SOURCE,{expectedRecords,expectedChunks}={}){
 manifestPath=resolve(manifestPath);const bytes=readFileSync(manifestPath),manifest=JSON.parse(bytes);
 assert.equal(manifest.version,'roalgo-learned-v2');assert.equal(manifest.phase,'complete');assert.equal(manifest.placeId,0);
 assert.equal(manifest.completed,manifest.total);assert.equal(manifest.metadata.bars,manifest.total);assert.equal(manifest.metadata.symbol,'SPY');
 assert.equal(manifest.featureInfo.rawCount,33);assert.equal(manifest.featureInfo.driveCount,8);assert.equal(manifest.featureInfo.names.length,33);assert.equal(manifest.featureInfo.driveNames.length,8);
 assert.ok(manifest.metadata.sessionCount<=30,'Saved capture scope exceeds 30 sessions');
 if(expectedRecords!==undefined)assert.equal(manifest.total,expectedRecords);if(expectedChunks!==undefined)assert.equal(manifest.cacheChunks.length,expectedChunks);
 const inputHashes=[{path:manifestPath,sha256:hash(bytes),bytes:bytes.length}],records=[],chunks=[],prefix=basename(manifestPath,'.json')+'_states_';
 let previous=-Infinity,expectedIndex=1;const stateSchemas={};
 for(const receipt of manifest.cacheChunks){
  assert.equal(typeof receipt.path,'string');assert.match(receipt.sha256,/^[a-f0-9]{64}$/);
  const name=receipt.path.split(/[\\/]/).at(-1);assert.ok(name.startsWith(prefix)&&/^.+_states_\d{4}\.json$/.test(name),'Unexpected checkpoint identity');
  const path=join(dirname(manifestPath),name),source=readFileSync(path);assert.equal(hash(source),receipt.sha256,'Saved checkpoint hash mismatch');
  inputHashes.push({path,sha256:receipt.sha256,bytes:source.length});const c=JSON.parse(source);
  assert.equal(c.version,'roalgo-states-v2');assert.equal(c.placeId,manifest.placeId);assert.equal(c.symbol,manifest.metadata.symbol);
  for(const key of ['split','sourceHashes'])assert.equal(canonical(c[key]),canonical(manifest[key]),'Checkpoint '+key+' mismatch');
  assert.equal(c.metadata.dataHash,manifest.metadata.dataHash,'Checkpoint data identity mismatch');assert.equal(c.firstIndex,expectedIndex,'Checkpoint index gap or overlap');
  assert.equal(c.records.length,c.lastIndex-c.firstIndex+1);assert.equal(c.native.totalBars,c.lastIndex);assert.equal(c.native.totalSteps,c.lastIndex*12);assert.equal(c.native.numericSteps,c.lastIndex*12);
  assert.equal(c.native.stepsPerBar,12);assert.equal(c.native.dt,1/60);assert.equal(c.native.counts.coupledNodes,24);assert.equal(c.native.counts.independentNodes,24);
  for(const key of ['corruptSteps','failedBars','stepFailures','barrierFailures'])assert.equal(c.native[key],0,'Native capture failure '+key);
  for(const record of c.records){
   const {bar,feature,states}=record;assert.ok(Number.isInteger(bar.t)&&bar.t>previous&&bar.t%300===0,'Duplicate/unordered observation timestamp');previous=bar.t;
   assert.equal(feature.t,bar.t);assert.ok(finiteArray(feature.raw,33)&&finiteArray(feature.drive,8),'Frozen feature dimensions or values invalid');
   assert.equal(canonical(feature.names),canonical(manifest.featureInfo.names),'Frozen raw feature schema changed');assert.equal(typeof feature.reset,'boolean');
   for(const id of ['coupled','independent','numeric']){const s=states[id];assert.ok(s&&finiteArray(s.vector,51)&&s.names?.length===51&&s.nodes?.length===24,'Frozen state schema invalid');stateSchemas[id]??=s.names;assert.equal(canonical(s.names),canonical(stateSchemas[id]),'Frozen state names changed');}
   records.push(record);
  }
  chunks.push({name,sha256:receipt.sha256,firstIndex:c.firstIndex,lastIndex:c.lastIndex,records:c.records.length,totalSteps:c.native.totalSteps});expectedIndex=c.lastIndex+1;
 }
 assert.equal(records.length,manifest.total);assert.equal(manifest.native.totalBars,records.length);assert.equal(manifest.native.totalSteps,records.length*12);assert.equal(manifest.native.numericSteps,records.length*12);
 const sessions=[...new Set(records.map(r=>r.bar.day))];assert.equal(canonical(sessions),canonical(manifest.metadata.sessions));assert.equal(sessions.length,manifest.metadata.sessionCount);
 for(const day of sessions)assert.equal(records.filter(r=>r.bar.day===day).length,manifest.metadata.counts[day]);
 const replay=records.filter(r=>r.bar.t>=manifest.split.testStartT);assert.equal(canonical(replay),canonical(manifest.replayRecords),'Embedded replay differs from verified checkpoints');
 const frozenRecordHash=hash(canonical(records));
 const audit={status:'verified',manifestPath,manifestSha256:hash(bytes),records:records.length,chunks,sessions:sessions.length,firstT:records[0].bar.t,lastT:records.at(-1).bar.t,rawDimension:33,stateDimension:51,driveDimension:8,nodesPerRig:24,replayRecords:replay.length,historicalNativeSteps:manifest.native.totalSteps,newNativeSteps:0,captureSourceVersion:manifest.version,frozenRecordHash};
 return {manifest,records,inputHashes,audit};
}

// Same lag/EWMA order and reset rule as Features.luau, operating on frozen v2 drives only.
export const MEMORY_SOURCE=`local Memory={}
function Memory.augment(records,driveNames)
 assert(#driveNames==8,'exactly eight recorded v2 drive names required')
 local names={};for _,name in driveNames do for _,suffix in {'lag1','lag3','ewmaFast','ewmaSlow'}do names[#names+1]=name..'.'..suffix end end
 local history,fast,slow={},{},{};local out={}
 for _,record in records do
  local f=record.feature;assert(#f.drive==8,'eight frozen drive values required')
  if f.reset then history={};fast={};slow={}end
  local memory={}
  for i,x in f.drive do
   assert(type(x)=='number' and x==x and math.abs(x)<math.huge,'finite recorded drive required')
   fast[i]=.5*(fast[i] or 0)+.5*x;slow[i]=.95*(slow[i] or 0)+.05*x
   memory[#memory+1]=history[1] and history[1][i] or 0;memory[#memory+1]=history[3] and history[3][i] or 0
   memory[#memory+1]=fast[i];memory[#memory+1]=slow[i]
  end
  table.insert(history,1,table.clone(f.drive));if #history>3 then table.remove(history)end
  local feature=table.clone(f);feature.memory=memory;feature.memoryNames=table.clone(names)
  out[#out+1]={bar=record.bar,feature=feature,states=record.states}
 end
 return out,names
end
return Memory
`;
function dataModule(value,requirePath='./Json'){
 const json=JSON.stringify(value);let equal='==';while(json.includes(']'+equal+']'))equal+='=';
 return `local Json=require(${JSON.stringify(requirePath)})\nreturn Json.decode([${equal}[${json}]${equal}])\n`;
}
function runnerSource(chunkNames){return `local Json=require('./Json')
local Study=require('./src/Study')
local Learning=require('./src/Learning')
local Memory=require('./Memory')
local input=require('./Input')
local original={}
${chunkNames.map(n=>`for _,record in require('./data/${n}') do original[#original+1]=record end`).join('\n')}
local before={};for i,r in original do before[i]=Json.encode(r)end
local records,memoryNames=Memory.augment(original,input.featureInfo.driveNames)
local provenance={captureSourceVersion=input.captureSourceVersion,nativeSourceHashes=input.nativeSourceHashes,sourceHashes=input.sourceHashes,
 sourceManifestSha256=input.audit.manifestSha256,inputHashes=input.inputHashes,newNativeSteps=0,historicalNativeSteps=input.audit.historicalNativeSteps,
 limitation='Frozen legacy v2 raw33/state51 capture; memory32 added from the eight recorded drives. Thirty sessions maximum; no new native capture.'}
local evaluated=Study.evaluate(records,input.split,{provenance=provenance,onProgress=function(message)print(message)end})
assert(evaluated.diagnostics.fittedModels==5 and #evaluated.comparisons==6,'All five actual Luau fits and zero baseline required')
local reducedModel,reducedReport=Learning.fit(records,{variant='raw',contextMode='reduced',trainEndT=input.split.trainEndT,validationEndT=input.split.validationEndT,provenance=provenance})
assert(reducedModel,'Reduced diagnostic fit failed')
local historyDiagnostic={scope='Maximum existing history:25 training sessions,5 validation sessions,0 evaluation sessions. Prior evaluation observations reused as validation; no untouched period remains.',
 trainSessions=25,validationSessions=5,evaluationSessions=0,trainEndT=input.split.testStartT,validationEndT=records[#records].bar.t+300,
 execution='disabled; no evaluation period; five validation sessions are insufficient for policy robustness gates',fits={}}
for _,id in {'coupled','independent','numeric','raw','memory'} do
 print('Fitting maximum-history diagnostic '..id)
 local model,report=Learning.fit(records,{variant=id,trainEndT=historyDiagnostic.trainEndT,validationEndT=historyDiagnostic.validationEndT,provenance=provenance})
 assert(model,'Maximum-history diagnostic fit failed '..id)
 historyDiagnostic.fits[#historyDiagnostic.fits+1]={id=id,model=Learning.serialize(model),report=report}
end
local replay={};for _,r in records do if r.bar.t>=input.split.testStartT then replay[#replay+1]=r end end
for i,r in original do assert(Json.encode(r)==before[i],'Frozen original raw/native record was mutated')end
local info=table.clone(input.featureInfo);info.memoryCount=#memoryNames;info.memoryNames=memoryNames
info.memoryDefinition='Frozen eight v2 drives x lag1/lag3/current-inclusive EWMA alpha.5/.05; zero initialization and original feature.reset semantics'
info.captureSourceVersion=input.captureSourceVersion;info.addedMemoryOnly=true
local config={id='saved_v2_24',nodeCount=24,topology='legacy_v2_grid',response='legacy_v2',captureSourceVersion=input.captureSourceVersion}
local fold={id='saved_v2_24_saved20241231',foldId='saved20241231',foldIndex=1,configurationId=config.id,configuration=config,
 phase='complete',metadata=input.metadata,split=input.split,featureInfo=info,native=input.native,completed=#records,total=#records,
 comparisons=evaluated.comparisons,selection=evaluated.selection,diagnostics=evaluated.diagnostics,replayRecords=replay,
 sourceHashes=input.sourceHashes,nativeSourceHashes=input.nativeSourceHashes,cacheChunks=input.cacheChunks,
 captureSourceVersion=input.captureSourceVersion,newNativeSteps=0,historicalNativeSteps=input.audit.historicalNativeSteps,endDate=input.endDate}
local study={version='roalgo-study-v3',phase='complete',readoutOnly=true,scope='Readout-only refit of previously inspected legacy v2 saved native history; no new native capture or holdout claim',
 symbol=input.metadata.symbol,profile=input.profile,endDate=input.endDate,placeId=input.placeId,studioVersion=input.studioVersion,
 configurations={config},foldDescriptors={{id='saved20241231',endDate=input.endDate,symbol=input.metadata.symbol,train=20,validation=5,test=5,
  trainEndT=input.split.trainEndT,validationEndT=input.split.validationEndT,testStartT=input.split.testStartT,testEndT=records[#records].bar.t+300}},
 folds={fold},aggregate=Study.aggregate({fold}),completed=#records,total=#records,foldCount=1,stride=5,
 sourceHashes=input.sourceHashes,nativeSourceHashes=input.nativeSourceHashes,captureSourceVersion=input.captureSourceVersion,
 newNativeSteps=0,historicalNativeSteps=input.audit.historicalNativeSteps,totalNativeSteps=input.audit.historicalNativeSteps,
 nativeStepInterpretation='totalNativeSteps is historical persisted evidence; this refit executed zero native steps',
 refitProvenance=provenance,featureInfo=info}
print('@@JSON '..Json.encode({study=study,reducedDiagnostic={id='reduced',model=Learning.serialize(reducedModel),report=reducedReport},maximumHistoryDiagnostic=historyDiagnostic,
 frozenRecordVerification={records=#original,originalRecordsUnchanged=true,rawDimension=33,stateDimension=51,memoryDimension=#memoryNames,newNativeSteps=0}}))
`;}

export function prepareRefit({manifestPath=DEFAULT_SOURCE,outputDir,expectedRecords,expectedChunks}={}){
 assert.ok(outputDir,'An empty refit output directory is required');outputDir=resolve(outputDir);
 assert.ok(!existsSync(outputDir)||readdirSync(outputDir).length===0,'Refit output directory must be empty; existing evidence is preserved');
 const capture=verifySavedCapture(manifestPath,{expectedRecords,expectedChunks});mkdirSync(join(outputDir,'src'),{recursive:true});mkdirSync(join(outputDir,'data'),{recursive:true});
 const sourceHashes={},sourceFiles=[];
 for(const name of ['Learning','Study','Execution']){const source=readFileSync(join(ROOT,'src',name+'.luau'));sourceHashes['src/'+name]=hash(source);exclusive(join(outputDir,'src',name+'.luau'),source);sourceFiles.push({path:join(ROOT,'src',name+'.luau'),sha256:hash(source)});}
 const json=readFileSync(join(ROOT,'../lab/src/Util/Json.luau'));exclusive(join(outputDir,'Json.luau'),json);sourceHashes['util/Json']=hash(json);
 const featureSource=readFileSync(join(ROOT,'src/Features.luau'));sourceHashes['memoryDefinition/Features']=hash(featureSource);
 exclusive(join(outputDir,'Memory.luau'),MEMORY_SOURCE);sourceHashes['refit/Memory']=hash(MEMORY_SOURCE);
 sourceHashes['refit/runnerTool']=hash(readFileSync(fileURLToPath(import.meta.url)));
 const chunkNames=[];
 for(let start=0;start<capture.records.length;start+=64){const name='Records'+String(chunkNames.length+1).padStart(4,'0');const source=dataModule(capture.records.slice(start,start+64),'../Json');assert.ok(Buffer.byteLength(source)<4*1024*1024,'Data module exceeds bounded source size');exclusive(join(outputDir,'data',name+'.luau'),source);chunkNames.push(name);}
 const m=capture.manifest,input={metadata:m.metadata,split:m.split,featureInfo:m.featureInfo,native:m.native,cacheChunks:m.cacheChunks,nativeSourceHashes:m.sourceHashes,sourceHashes,inputHashes:capture.inputHashes,audit:capture.audit,captureSourceVersion:m.version,profile:m.profile,endDate:m.endDate,placeId:m.placeId,studioVersion:m.studioVersion};
 const runner=runnerSource(chunkNames);sourceHashes['refit/Runner']=hash(runner);exclusive(join(outputDir,'Input.luau'),dataModule(input));exclusive(join(outputDir,'Runner.luau'),runner);
 const preparation={status:'prepared',outputDir,manifestPath:resolve(manifestPath),audit:capture.audit,inputHashes:capture.inputHashes,sourceHashes,sourceFiles,runtime:luauIdentity(),dataModules:chunkNames.length,recordCount:capture.records.length,preparedAtUTC:new Date().toISOString()};
 exclusive(join(outputDir,'preparation.json'),JSON.stringify(preparation,null,2)+'\n');return preparation;
}

function compareMetrics(old,after){
 const oldById=new Map(old.comparisons.map(c=>[c.id,c]));
 return [...after.study.folds[0].comparisons,{id:'reduced',report:after.reducedDiagnostic.report}].map(c=>{
  const r=c.report,p=r.preprocessing??{},before=oldById.get(c.id)?.report;
  return {id:c.id,beforeValidationMSE:before?.validationMeanMSE??null,afterValidationMSE:r.validationMeanMSE??null,zeroValidationMSE:r.validationZeroMeanMSE??null,
   beforeRatioToZero:before&&r.validationZeroMeanMSE>0?before.validationMeanMSE/r.validationZeroMeanMSE:null,afterRatioToZero:r.validationMseRatioToZero??null,
   beforeSamples:before?.samples??null,afterSamples:r.samples??null,droppedFeatures:p.droppedFeatures?.map(f=>({name:f.name,std:f.std,reason:f.reason}))??[],
   activeDimension:p.activeDimension??null,originalDimension:p.originalDimension??null,trainingClipping:p.trainingClipping??null,validationClipping:p.validationClipping??null,
   policy:r.selectedPolicy??c.result?.policyId??null,policySelectionReason:r.policySelectionReason??null,netReturn:c.result?.summary?.netReturn??null,tradeCount:c.result?.summary?.tradeCount??null};
 });
}
export function markdownReport(report){
 const fmt=n=>n===null||n===undefined?'—':Number(n).toPrecision(7);
 const rows=report.primaryComparison.map(m=>`| ${m.id} | ${fmt(m.beforeValidationMSE)} | ${fmt(m.afterValidationMSE)} | ${fmt(m.beforeRatioToZero)} | ${fmt(m.afterRatioToZero)} | ${m.droppedFeatures.length} | ${m.policy??'diagnostic only'} |`).join('\n');
 const long=report.maximumHistoryDiagnostic.fits.map(c=>`| ${c.id} | ${c.report.samples.train} | ${c.report.samples.validation} | ${fmt(c.report.validationMeanMSE)} | ${fmt(c.report.validationMseRatioToZero)} |`).join('\n');
 return `# Saved v2 native-history readout refit\n\nThis run used ${report.audit.records} original observations over ${report.audit.sessions} sessions, with ${report.audit.historicalNativeSteps} historical native intervals and **zero new native steps**. Raw33/state51 vectors and all original records were preserved; only32 causal memory values from the eight recorded v2 drives were added. This is a legacy24-node capture, not a v3 native24/48 experiment. All original input file hashes matched before and after.\n\n## Controlled original20/5/5 comparison\n\nThe original training/validation/evaluation split is unchanged. Zero-forecast validation MSE comes from the same matured labels under the actual Luau learning code. The six study comparisons include five fitted readouts and the zero baseline; reduced-context raw is a separate diagnostic.\n\n| Model | Old validation MSE | Refit validation MSE | Old / zero | Refit / zero | Dropped inputs | Selected policy |\n|---|---:|---:|---:|---:|---:|---|\n${rows}\n\nFive validation sessions provide only one five-session block. They cannot satisfy the fixed requirement of at least three such blocks; the result is no_trade rather than permission to trade an unreliable model. The detailed JSON retains clipping counts, dropped-feature reasons, feature statistics and every failed policy gate. Evaluation remains historical and previously inspected.\n\n## Maximum existing-history diagnostic25/5/0\n\nThe final five sessions, which were evaluation observations above, are reused here as validation. There is **no remaining evaluation period** and no untouched-holdout claim. These are only five Luau Learning fits, not a second Study or trading evaluation. The history cap remains30 sessions.\n\n| Model | Mature training labels | Mature validation labels | Validation MSE | MSE / zero |\n|---|---:|---:|---:|---:|\n${long}\n\n## Evidence\n\n- Source manifest SHA256: ${report.audit.manifestSha256}\n- Frozen record SHA256: ${report.audit.frozenRecordHash}\n- Study output: ${report.studyReceipt.path}\n- Study SHA256: ${report.studyReceipt.sha256}\n- Study bytes: ${report.studyReceipt.bytes}\n- Native history: ${report.audit.firstT} through ${report.audit.lastT}; no additional source period was read.\n- Learning, Study, Execution, JSON utility, generated memory module and runner hashes are recorded in preparation.json and report.json.\n`;
}
export async function executeRefit(preparation,{publish=true,onLog=()=>{}}={}){
 verifyUnchanged(preparation.inputHashes);for(const source of preparation.sourceFiles)assert.equal(hash(readFileSync(source.path)),source.sha256,'Source changed after refit preparation');
 const run=await runLuau(join(preparation.outputDir,'Runner.luau'),[],{cwd:preparation.outputDir,onLog});const result=run.result;
 assert.equal(result.frozenRecordVerification.originalRecordsUnchanged,true);assert.equal(result.study.readoutOnly,true);assert.equal(result.study.newNativeSteps,0);assert.equal(result.study.historicalNativeSteps,preparation.audit.historicalNativeSteps);
 verifyUnchanged(preparation.inputHashes);const old=jsonFile(preparation.manifestPath);const study=result.study;
 const bytes=JSON.stringify(study)+'\n';assert.ok(Buffer.byteLength(bytes)<64*1024*1024,'Embedded legacy refit exceeds64MiB; bounded publishing required');
 const outputName='RoAlgoV3_refit_saved_v2_24_'+Date.now()+'.json';const receipt=exclusive(join(preparation.outputDir,outputName),bytes);
 if(publish){mkdirSync(join(ROOT,'results'),{recursive:true});exclusive(join(ROOT,'results',outputName),bytes);receipt.path=join(ROOT,'results',outputName);}
 const report={status:'complete',completedAtUTC:new Date().toISOString(),audit:preparation.audit,inputHashesBefore:preparation.inputHashes,inputHashesAfter:preparation.inputHashes.map(i=>({...i,sha256:hash(readFileSync(i.path))})),originalInputsUnchanged:true,
  sourceHashes:preparation.sourceHashes,runtime:preparation.runtime,studyReceipt:receipt,primaryComparison:compareMetrics(old,result),reducedDiagnostic:result.reducedDiagnostic,maximumHistoryDiagnostic:result.maximumHistoryDiagnostic,frozenRecordVerification:result.frozenRecordVerification};
 exclusive(join(preparation.outputDir,'report.json'),JSON.stringify(report,null,2)+'\n');exclusive(join(preparation.outputDir,'report.md'),markdownReport(report));exclusive(join(preparation.outputDir,'runner.log'),run.logs.join('\n')+'\n');return report;
}
// Metadata-only correction for completed artifacts; executed source hashes and all fit outputs stay untouched.
export function finalizeReadoutArtifact({sourcePath,outputPath,expectedSha256}){
 assert.notEqual(resolve(sourcePath),resolve(outputPath),'Corrected artifact requires a new output path');
 const original=readFileSync(sourcePath);assert.equal(hash(original),expectedSha256,'Completed artifact hash mismatch');
 const study=JSON.parse(original);assert.equal(study.version,'roalgo-study-v3');assert.equal(study.phase,'complete');assert.equal(study.newNativeSteps,0);
 assert.ok(Number.isFinite(study.historicalNativeSteps)&&study.historicalNativeSteps>0,'Persisted native history required');
 study.readoutOnly=true;const bytes=JSON.stringify(study)+'\n';assert.ok(Buffer.byteLength(bytes)<64*1024*1024,'Corrected artifact exceeds 64MiB');
 return exclusive(outputPath,bytes);
}
async function main(){
 const args=process.argv.slice(2);assert.ok(args.every(a=>['--run','--prepare-only'].includes(a)),'Use --prepare-only or --run');assert.ok(args.length===1,'Choose exactly --prepare-only or --run');
 const id='saved-v2-24-'+new Date().toISOString().replace(/[^0-9T]/g,'');const prepared=prepareRefit({outputDir:join(ROOT,'refits',id),expectedRecords:2268,expectedChunks:5});console.log(JSON.stringify({status:prepared.status,outputDir:prepared.outputDir,records:prepared.recordCount,inputHashes:prepared.inputHashes.map(i=>({name:basename(i.path),sha256:i.sha256}))}));
 if(args[0]==='--run'){const r=await executeRefit(prepared,{onLog:line=>console.log(line)});console.log(JSON.stringify({status:r.status,study:r.studyReceipt,metrics:r.primaryComparison.map(m=>({id:m.id,before:m.beforeRatioToZero,after:m.afterRatioToZero,policy:m.policy})),newNativeSteps:0}));}
}
if(process.argv[1]&&pathToFileURL(resolve(process.argv[1])).href===import.meta.url)main().catch(error=>{console.error(error.message);process.exitCode=1;});
