-- Run in Edit mode after a completed real-data rolling study. This checks the
-- actual persisted capture/readout structure; it never creates physics states.
local Probe={}
local IDS={"coupled","independent","numeric","raw","memory","zero"}
local function near(a,b) return math.abs(a-b)<=1e-8*math.max(1,math.abs(a),math.abs(b)) end
function Probe.run(control)
 local status=control:Invoke("status")
 assert(status.phase=="complete" and not status.busy,"complete nonbusy study required")
 local result=control:Invoke("result")
 assert(result.version=="roalgo-study-v3" and result.phase=="complete","completed rolling study required")
 assert(result.completed==result.total and result.total>1000,"full study captured")
 assert(#result.folds==#result.foldDescriptors*#result.configurations and #result.folds>0,"every configuration/fold required")
 if result.readoutOnly then
  assert(result.newNativeSteps==0 and result.nativeSourceHashes["src/Engine"],"refit retains native provenance and creates no capture")
 else assert(result.sourceHashes["src/App"] and result.sourceHashes["src/Engine"],"source provenance")end
 local totalBars,totalSteps,totalEvaluationRows=0,0,0
 local actions={BUY=0,SELL=0,CLOSE=0,HOLD=0}
 local identities,windows,foldSummaries={},{},{}
 for _,fold in result.folds do
  local key=fold.configurationId.."/"..fold.foldId
  assert(not identities[key],"duplicate configuration/fold");identities[key]=true
  assert(fold.phase=="complete" and fold.completed==fold.total,"complete individual capture required")
  assert(fold.native.totalSteps==fold.total*12 and fold.native.totalBars==fold.total and fold.native.corruptSteps==0,"verified per-fold native interval count")
  assert(fold.diagnostics.status=="complete" and fold.diagnostics.fittedModels==5,"five successful fitted models required")
  assert(#fold.cacheChunks>0,"native state checkpoints persisted")
  assert(#fold.comparisons==6 and #fold.replayRecords>0,"five fitted comparisons, zero baseline and evaluation records required")
  totalBars+=fold.total;totalSteps+=fold.native.totalSteps
  local vectorCount=fold.native.config.vectorCount or (result.readoutOnly and #fold.replayRecords[1].states.coupled.vector)
  assert(vectorCount>0,"recorded native vector dimension required")
  local samples,validationSamples,nrows
  for index,comparison in fold.comparisons do
   assert(comparison.id==IDS[index],"comparison identity/order mismatch")
   local model,report=comparison.model,comparison.report
   if comparison.id=="zero" then
    assert(report.status=="baseline" and comparison.result.policyId=="no_trade","explicit zero/no-trade baseline")
    assert(comparison.result.summary.netReturn==0 and comparison.result.summary.tradeCount==0,"baseline remains flat without fees or fills")
   else
   assert(model and model.status=="ok" and report.status=="ok","all readouts trained: "..comparison.id)
   assert(model.schemaVersion=="roalgo-learning-v3-2","bounded scaler model schema required")
   assert(model.sampleRanges.train.lastLabelAvailableT<=fold.split.trainEndT,"training label maturity cutoff")
   assert(model.sampleRanges.validation.lastLabelAvailableT<=fold.split.validationEndT,"validation label maturity cutoff")
   samples=samples or model.samples.train;validationSamples=validationSamples or model.samples.validation
   assert(model.samples.train==samples and model.samples.validation==validationSamples,"matched readout samples")
   assert(model.rawDimension==fold.featureInfo.rawCount,"raw schema dimensions")
   if comparison.id=="raw" or comparison.id=="memory" then
    assert(model.stateDimension==0,"direct baselines must not consume physical state")
    assert(model.memoryDimension==(if comparison.id=="memory" then fold.featureInfo.memoryCount else 0),"memory baseline dimensions")
   else assert(model.stateDimension==vectorCount,"native dimensions derive from recorded configuration") end
   assert(report.policySelectionScope=="validation_only" and model.policySelectionScope=="validation_only","validation-only policy selection provenance")
   assert(report.selectedPolicyId==model.selectedPolicyId and model.selectedPolicyId==comparison.result.policyId,"frozen selected policy identity")
   assert(#report.policyCandidates==4 and report.evaluationStatus=="ok","declared policy budget and available evaluation")
   for _,candidate in report.policyCandidates do
    assert(candidate.summary.firstT>=fold.split.trainEndT and candidate.summary.lastT<fold.split.validationEndT,"policy candidates use validation timestamps only")
   end
   end
   assert(type(report.validationZeroMeanMSE)=="number" and report.validationZeroMeanMSE>=0,"zero forecast validation loss is reported")
   if report.validationZeroMeanMSE>0 then assert(near(report.validationMseRatioToZero,report.validationMeanMSE/report.validationZeroMeanMSE),"validation MSE relative to zero forecast")end
   local rows=comparison.result.rows;nrows=nrows or #rows
   assert(#rows==nrows and nrows==#fold.replayRecords,"matched evaluation timestamps")
   assert(rows[1].t==fold.split.testStartT and #rows[1].executions==0,"fresh ledger at evaluation cutoff")
   for i,row in rows do
    assert(row.t==fold.replayRecords[i].bar.t,"evaluation record alignment")
    assert(actions[row.signal]~=nil,"valid action code");actions[row.signal]+=1
    assert(near(row.equity,row.cash+row.shares*row.close),"signed-share marked-equity accounting")
    for _,fill in row.executions do
     if fill.action~="CLOSE" then
      assert(fill.signalT and fill.signalT<=fill.t and i>1,"no same-bar prediction entry")
      assert(fill.signalT<=rows[i-1].t+300,"entry signal was available before current open")
     end
    end
   end
  end
  for _,record in fold.replayRecords do
   assert(#record.feature.raw==fold.featureInfo.rawCount and #record.feature.memory==fold.featureInfo.memoryCount,"captured feature schema")
   for _,id in {"coupled","independent","numeric"} do
    local state=record.states[id]
    assert(state and #state.vector==vectorCount and #state.names==vectorCount,"captured physical schema")
   end
  end
  local firstT,lastT=fold.replayRecords[1].bar.t,fold.replayRecords[#fold.replayRecords].bar.t
  local window=windows[fold.foldIndex]
  if window then assert(window.firstT==firstT and window.lastT==lastT,"architectures use identical evaluation windows")
  else windows[fold.foldIndex]={firstT=firstT,lastT=lastT} end
  totalEvaluationRows+=nrows
  foldSummaries[#foldSummaries+1]={id=fold.id,configurationId=fold.configurationId,bars=fold.total,evaluationRows=nrows,trainSamples=samples,validationSamples=validationSamples,nativeSteps=fold.native.totalSteps}
 end
 for index=2,#result.foldDescriptors do assert(windows[index] and windows[index-1] and windows[index].firstT>windows[index-1].lastT,"chronological nonoverlapping evaluation folds") end
 assert(totalBars==result.total and totalSteps==result.totalNativeSteps and totalSteps==totalBars*12,"study totals equal independent fold counters")
 return {ok=true,configurationFolds=#result.folds,comparisonsPerFold=6,bars=totalBars,evaluationRows=totalEvaluationRows,actions=actions,nativeSteps=totalSteps,newNativeSteps=result.newNativeSteps,readoutOnly=result.readoutOnly,folds=foldSummaries,sourceHashes=result.sourceHashes}
end

-- Separate bounded replay verification uses live engine counters, not immutable
-- result/status copies, so accidental new native stepping cannot hide.
function Probe.replay(control,timeoutSeconds)
 assert(not control:Invoke("status").busy,"replay requires an idle controller")
 local before=control:Invoke("nativeStats")
 assert(not before or before.corruptSteps==0,"native engine must be uncorrupted when present")
 assert(control:Invoke("replay"),"replay must start")
 local deadline=os.clock()+(timeoutSeconds or 60)
 while control:Invoke("status").busy do
  if os.clock()>deadline then control:Invoke("stop");error("Replay probe timed out; stop requested") end
  task.wait(0.05)
 end
 local after=control:Invoke("nativeStats")
 assert(control:Invoke("status").phase=="complete","replay completed without errors")
 if before then
  assert(after and after.totalSteps==before.totalSteps and after.totalBars==before.totalBars and after.requests==before.requests and after.corruptSteps==before.corruptSteps,"replay must request zero new native intervals")
 else assert(after==nil,"saved-only replay must not create a native engine")end
 return {ok=true,newNativeSteps=0,before=before and before.totalSteps,after=after and after.totalSteps,savedOnly=before==nil}
end
return Probe
