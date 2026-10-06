import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,mkdtempSync,writeFileSync,unlinkSync,rmdirSync} from 'node:fs';
import {join,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {LUAU} from '../../tools/luau-run.mjs';

test('rolling App probe verifies fold accounting and reads live counters during replay',()=>{
 const here=dirname(fileURLToPath(import.meta.url));
 const source=readFileSync(join(here,'AppProbe.luau'),'utf8');
 const dir=mkdtempSync(join(tmpdir(),'roalgo-app-probe-'));
 const runner=join(dir,'runner.luau');
 try {
  writeFileSync(runner,`local Probe=assert(loadstring(${JSON.stringify(source)}))()
local status={phase="complete",busy=false}
local count=0
local control={Invoke=function(_,command)
 if command=="status" then return status end
 if command=="result" then return {version="roalgo-study-v3",phase="complete",completed=2400,total=2400,totalNativeSteps=28800,folds={},foldDescriptors={{id="a"}},configurations={{id="grouped24"}},sourceHashes={["src/App"]="a",["src/Engine"]="b"}} end
 if command=="nativeStats" then return {totalSteps=count,totalBars=0,corruptSteps=0,requests=count} end
 if command=="replay" then count+=12;return true end
 error(command)
end}
assert(not pcall(Probe.run,control),"probe must reject a study whose successful folds are missing")
local study={version="roalgo-study-v3",phase="complete",completed=1200,total=1200,totalNativeSteps=14400,folds={},foldDescriptors={{id="a"},{id="b"}},configurations={{id="grouped24"}},sourceHashes={["src/App"]="a",["src/Engine"]="b"}}
for foldIndex=1,2 do
 local start=foldIndex*1000
 local fold={id="fold"..foldIndex,foldId=if foldIndex==1 then "a" else "b",foldIndex=foldIndex,configurationId="grouped24",phase="complete",completed=600,total=600,configuration={nodeCount=24},featureInfo={rawCount=2,memoryCount=2},split={trainEndT=start-600,validationEndT=start,testStartT=start},native={totalSteps=7200,totalBars=600,corruptSteps=0,config={vectorCount=59}},cacheChunks={{path="saved"}},diagnostics={status="complete",fittedModels=5},comparisons={},replayRecords={}}
 for i=1,3 do
  local states={}
  for _,id in {"coupled","independent","numeric"} do local names={};for j=1,59 do names[j]="n"..j end;states[id]={vector=table.create(59,0),names=names} end
  fold.replayRecords[i]={bar={t=start+(i-1)*300,c=100},feature={raw={1,2},memory={1,2}},states=states}
 end
 for _,id in {"coupled","independent","numeric","raw","memory","zero"} do
  local rows={};for i=1,3 do rows[i]={t=start+(i-1)*300,close=100,signal="HOLD",executions={},equity=1,cash=1,shares=0} end
  local candidates={};for _,policy in {"continuation","horizon6","buffered","excursion"} do candidates[#candidates+1]={id=policy,summary={firstT=start-600,lastT=start-300}} end
  local model={status="ok",variant=id,schemaVersion="roalgo-learning-v3-2",rawDimension=2,memoryDimension=if id=="memory" then 2 else 0,stateDimension=if id=="raw" or id=="memory" then 0 else 59,selectedPolicyId="continuation",samples={train=128,validation=32},sampleRanges={train={lastLabelAvailableT=start-600},validation={lastLabelAvailableT=start}},policySelectionScope="validation_only"}
  fold.comparisons[#fold.comparisons+1]={id=id,model=model,report={status="ok",selectedPolicyId="continuation",policySelectionScope="validation_only",evaluationStatus="ok",policyCandidates=candidates,validationMeanMSE=.5,validationZeroMeanMSE=1,validationMseRatioToZero=.5},result={policyId="continuation",rows=rows,summary={initialEquity=1,equity=1,netReturn=0,tradeCount=0}}}
  if id=="zero" then local c=fold.comparisons[#fold.comparisons];c.model=nil;c.report.status="baseline";c.report.validationMeanMSE=1;c.report.validationMseRatioToZero=1;c.report.selectedPolicyId="no_trade";c.result.policyId="no_trade" end
 end
 study.folds[#study.folds+1]=fold
end
local valid={Invoke=function(_,command) if command=="result" then return study end;return control:Invoke(command) end}
assert(Probe.run(valid).ok,"valid rolling wrapper must pass")
assert(type(Probe.replay)=="function","probe must independently test live replay counters")
assert(not pcall(Probe.replay,control),"a replay that increments live physics counters must fail")
count=0
local clean={Invoke=function(_,command) if command=="replay" then return true end;return control:Invoke(command) end}
local result=Probe.replay(clean);assert(result.ok and result.newNativeSteps==0)
print("PASS rolling probe rejects missing folds and live replay stepping")
`);
  const child=spawnSync(LUAU,[runner],{encoding:'utf8',windowsHide:true,timeout:10000});
  assert.ifError(child.error);assert.equal(child.status,0,`${child.stdout}\n${child.stderr}`);
 } finally {unlinkSync(runner);rmdirSync(dir)}
});
