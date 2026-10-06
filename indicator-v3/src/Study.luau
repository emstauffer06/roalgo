-- Readout fitting and policy choice use development data only. Each fold starts
-- a separate marked-equity ledger; aggregation never compounds those ledgers.
local Learning=if script then require(script.Parent.Learning) else require("./Learning")
local Execution=if script then require(script.Parent.Execution) else require("./Execution")
local Study={}
local IDS={"coupled","independent","numeric","raw","memory"}
local ALL_IDS={"coupled","independent","numeric","raw","memory","zero"}
local NATIVE={"coupled","independent","numeric"}
local POLICY_RULE={version="blocked-validation-v1",minimumBlocks=3,maximumBlocks=4,minimumSessionsPerBlock=5,
 minimumAvailableBarsPerBlock=64,minimumTradesPerBlock=1,minimumTotalTrades=6,extraTurnoverCostBps=1,
 objective="min(mean, median) of independent cost-adjusted block returns - downside RMS - mean block drawdown - mean block turnover * 1bp",
 gates="forecast validation MSE strictly below zero; at least 3 blocks of 5 sessions; at least 64 common bars and 1 closed trade per block, 6 total; positive median, positive majority, positive score",
 interpretation="fixed exploratory robustness screen, not a calibrated significance test or profitability guarantee"}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function copy(value)
 if type(value)~="table" then return value end
 local out={};for k,v in value do out[k]=copy(v) end;return out
end
local function check(options,message)
 assert(not options.cancelled or not options.cancelled(),"Study: cancelled")
 if message and options.onProgress then options.onProgress(message) end
end
local function validVector(values,names,expected)
 if type(values)~="table" or type(names)~="table" or #values==0 or #values~=#names then return false end
 if expected and #names~=#expected then return false end
 local seen={}
 for j,name in names do
  if type(name)~="string" or seen[name] or not finite(values[j]) or (expected and name~=expected[j]) then return false end
  seen[name]=true
 end
 return true
end
local function available(record,schema)
 local f=record.feature
 if type(f)~="table" or not f.ready then return false,"warming" end
 if not validVector(f.raw,f.names,schema and schema.raw) then return false,"raw_unavailable_or_schema_changed" end
 if not validVector(f.memory,f.memoryNames,schema and schema.memory) then return false,"memory_unavailable_or_schema_changed" end
 for _,id in NATIVE do
  local state=record.states and record.states[id]
  if not state or not validVector(state.vector,state.names,schema and schema[id]) then return false,id.."_unavailable_or_schema_changed" end
 end
 if not finite(f.volatility) or f.volatility<0 then return false,"volatility_unavailable" end
 return true
end
local function recordSchema(record)
 local out={raw=copy(record.feature.names),memory=copy(record.feature.memoryNames)}
 for _,id in NATIVE do out[id]=copy(record.states[id].names) end
 return out
end
local function summarizeCoverage(rows,allowed)
 local out={total=#rows,available=0,unavailable=0,firstT=rows[1] and rows[1].bar.t or nil,lastT=rows[#rows] and rows[#rows].bar.t or nil}
 for _,r in rows do if allowed[r.bar.t] then out.available+=1 else out.unavailable+=1 end end
 return out
end
local function predictions(model,rows,allowed,options)
 local out={}
 if not model then return out end
 for i,record in rows do
  if i%256==0 then check(options) end
  if allowed[record.bar.t] then out[i]=Learning.predict(model,record) end
 end
 return out
end
local function execute(rows,predicted,policyId,options)
 local ledger=Execution.new({policyId=policyId})
 for i,record in rows do
  if i%256==0 then check(options) end
  ledger:step(record.bar,record.feature,predicted[i])
 end
 return ledger:result()
end
local function selectionScore(result)
 local summary=result.summary
 -- All candidates are marked consistently. For selection, reserve the two
 -- remaining closing costs on an open position without fabricating a fill.
 local last=result.rows[#result.rows]
 local rawNotional=if last then math.abs(summary.shares or 0)*last.close else 0
 local reserve=rawNotional*(result.config.feeBps+result.config.slippageBps)/10000
 return summary.netReturn-reserve/summary.initialEquity,reserve
end
local function validationBlocks(rows,allowed)
 local sessions={}
 for i,record in rows do
  local day=record.bar.day
  assert(type(day)=="string","Study: session day required for blocked validation")
  if #sessions==0 or sessions[#sessions].day~=day then sessions[#sessions+1]={day=day,first=i} end
  sessions[#sessions].last=i
 end
 if #sessions==0 then return {} end
 local count=math.min(POLICY_RULE.maximumBlocks,math.max(1,math.floor(#sessions/POLICY_RULE.minimumSessionsPerBlock)))
 local blocks={}
 for i=1,count do
  local a=math.floor((i-1)*#sessions/count)+1;local b=math.floor(i*#sessions/count)
  local first,last=sessions[a].first,sessions[b].last;local availableCount=0
  for j=first,last do if allowed[rows[j].bar.t] then availableCount+=1 end end
  blocks[i]={firstIndex=first,lastIndex=last,sessionCount=b-a+1,availableBars=availableCount,
   firstSession=sessions[a].day,lastSession=sessions[b].day,firstT=rows[first].bar.t,lastT=rows[last].bar.t}
 end
 return blocks
end
-- Public, deterministic evidence assessment also permits auditing saved block ledgers.
-- Constants are declared above and are never selected against evaluation returns.
function Study.assessPolicyEvidence(blocks,forecast)
 local returns,details={},{}
 local mean,downside,drawdown,turnover,trades,positive=0,0,0,0,0,0
 local sessionsOK,barsOK,tradesOK=true,true,true
 for i,block in blocks do
  local result=block.result;local summary=result.summary
  local value,reserve=selectionScore(result)
  assert(finite(value) and finite(summary.maxDrawdown) and finite(summary.totalTurnover) and finite(summary.tradeCount),"Study: finite validation block ledger required")
  returns[i]=value;mean+=value/#blocks;downside+=math.min(0,value)^2/#blocks
  drawdown+=summary.maxDrawdown/#blocks;turnover+=summary.totalTurnover/#blocks;trades+=summary.tradeCount
  if value>0 then positive+=1 end
  sessionsOK=sessionsOK and block.sessionCount>=POLICY_RULE.minimumSessionsPerBlock
  barsOK=barsOK and block.availableBars>=POLICY_RULE.minimumAvailableBarsPerBlock
  tradesOK=tradesOK and summary.tradeCount>=POLICY_RULE.minimumTradesPerBlock
  details[i]={firstT=block.firstT,lastT=block.lastT,firstSession=block.firstSession,lastSession=block.lastSession,
   sessionCount=block.sessionCount,availableBars=block.availableBars,summary=copy(summary),
   costAdjustedNetReturn=value,closingCostReserve=reserve}
 end
 local sorted=copy(returns);table.sort(sorted)
 local median=if #sorted==0 then 0 elseif #sorted%2==1 then sorted[math.ceil(#sorted/2)] else (sorted[#sorted/2]+sorted[#sorted/2+1])/2
 local stress=turnover*POLICY_RULE.extraTurnoverCostBps/10000
 local score=math.min(mean,median)-math.sqrt(downside)-drawdown-stress
 local beatsZero=finite(forecast.validationMeanMSE) and finite(forecast.validationZeroMeanMSE)
  and forecast.validationMeanMSE>=0 and forecast.validationMeanMSE<forecast.validationZeroMeanMSE
 local gates={beatsZeroForecast=beatsZero,minimumBlocks=#blocks>=POLICY_RULE.minimumBlocks,
  eachBlockSessions=sessionsOK and #blocks>0,eachBlockAvailability=barsOK and #blocks>0,
  eachBlockTrades=tradesOK and #blocks>0,minimumTrades=trades>=POLICY_RULE.minimumTotalTrades,
  positiveMedian=median>0,positiveMajority=positive>#blocks/2,positiveScore=score>0}
 local eligible,reasons=true,{}
 for _,name in {"beatsZeroForecast","minimumBlocks","eachBlockSessions","eachBlockAvailability","eachBlockTrades","minimumTrades","positiveMedian","positiveMajority","positiveScore"} do
  if not gates[name] then eligible=false;reasons[#reasons+1]=name end
 end
 return {eligible=eligible,gates=gates,failedGates=reasons,rule=copy(POLICY_RULE),blocks=details,blockCount=#blocks,
  netReturns=returns,meanNetReturn=mean,medianNetReturn=median,downsideRMS=math.sqrt(downside),meanDrawdown=drawdown,
  meanTurnover=turnover,extraCostStress=stress,totalTrades=trades,positiveBlocks=positive,selectionScore=score,
  validationMeanMSE=forecast.validationMeanMSE,validationZeroMeanMSE=forecast.validationZeroMeanMSE,
  validationMseRatioToZero=if finite(forecast.validationZeroMeanMSE) and forecast.validationZeroMeanMSE>0 and finite(forecast.validationMeanMSE) then forecast.validationMeanMSE/forecast.validationZeroMeanMSE else nil}
end
local function blockEvidence(rows,predicted,blocks,policyId,options)
 local out={}
 for i,block in blocks do
  check(options)
  local subset,subsetPredictions={},{}
  for j=block.firstIndex,block.lastIndex do local k=#subset+1;subset[k]=rows[j];subsetPredictions[k]=predicted[j] end
  out[i]=copy(block);out[i].result=execute(subset,subsetPredictions,policyId,options)
 end
 return out
end
function Study.evaluate(records,split,options)
 options=options or {};check(options)
 assert(type(split)=="table" and finite(split.trainEndT) and finite(split.validationEndT) and split.trainEndT<split.validationEndT,"Study: ordered training and validation cutoffs required")
 local testStart=split.testStartT or split.validationEndT
 assert(finite(testStart) and testStart>=split.validationEndT,"Study: evaluation must begin after validation")
 assert(not split.testEndT or (finite(split.testEndT) and split.testEndT>testStart),"Study: evaluation end must follow start")
 local prepared,training,validation,evaluation={},{},{},{}
 local allowed,reasons,schema={},{},nil
 for i,record in records do
  local t=record.bar and record.bar.t
  assert(finite(t) and (i==1 or t>records[i-1].bar.t),"Study: chronological records required")
  local usable,reason=available(record,schema)
  if usable then schema=schema or recordSchema(record);allowed[t]=true else reasons[reason]=(reasons[reason] or 0)+1 end
  local feature={};for k,v in record.feature or {} do feature[k]=v end;feature.ready=usable
  local row={bar=record.bar,feature=feature,states=record.states};prepared[#prepared+1]=row
  if t<split.trainEndT then training[#training+1]=row
  elseif t<split.validationEndT then validation[#validation+1]=row
  elseif t>=testStart and (not split.testEndT or t<split.testEndT) then evaluation[#evaluation+1]=row end
 end
 local diagnostics={version=3,status="complete",fittedModels=0,modelErrors=0,commonAvailability=true,availabilityReasons=reasons,
  coverage={train=summarizeCoverage(training,allowed),validation=summarizeCoverage(validation,allowed),evaluation=summarizeCoverage(evaluation,allowed)},
  schemas=schema,scope="historical exploratory research; earlier project periods have already been inspected",newNativeSteps=0,
  equityConvention="each validation policy and evaluation model starts a separate ledger; final open positions are marked without fictitious fills"}
 local blocks=validationBlocks(validation,allowed)
 local selection={scope="validation_only",ridgeCandidates={0.1,1,10},policyCandidates=Execution.policies(),byModel={},
  objective=POLICY_RULE.objective,rule=copy(POLICY_RULE),validationBlocks=copy(blocks),fallbackPolicy="no_trade",
  tieBreak="declared candidate order; only eligible positive-score candidates can displace no_trade",refitOnValidation=false,evaluationSelectsNothing=true}
 local comparisons={}
 for _,id in IDS do
  check(options,"Fitting "..id.." readout using training labels; selecting ridge on validation")
  local success,model,report=pcall(Learning.fit,prepared,{variant=id,trainEndT=split.trainEndT,validationEndT=split.validationEndT,provenance=options.provenance})
  check(options)
  if not success then report={status="model_error",error=tostring(model),version=3,provenance=copy(options.provenance or {})};model=nil;diagnostics.modelErrors+=1 end
  local selectedPolicy="no_trade";local candidates={};local selectionReason="model_unavailable";local selectedEvidence
  if model then
   diagnostics.fittedModels+=1
   local validationPredictions=predictions(model,validation,allowed,options)
   local bestScore=0;selectionReason="no_candidate_passed_validation_gates"
   for _,policy in selection.policyCandidates do
    check(options,"Validating "..id.." / "..policy.id)
    local result=execute(validation,validationPredictions,policy.id,options)
    local evidence=Study.assessPolicyEvidence(blockEvidence(validation,validationPredictions,blocks,policy.id,options),report)
    local _,reserve=selectionScore(result)
    candidates[#candidates+1]={id=policy.id,experimental=policy.experimental,config=copy(result.config),summary=copy(result.summary),selectionScore=evidence.selectionScore,closingCostReserve=reserve,evidence=evidence}
    if evidence.eligible and evidence.selectionScore>bestScore then
     bestScore=evidence.selectionScore;selectedPolicy=policy.id;selectedEvidence=evidence;selectionReason="passed_fixed_block_validation_rule"
    end
   end
  end
  report.policyCandidates=candidates;report.selectedPolicyId=selectedPolicy;report.policySelectionReason=selectionReason
  report.policySelectionRule=copy(POLICY_RULE);report.validationBlocks=copy(blocks)
  report.policySelectionEvidence=selectedEvidence and copy(selectedEvidence) or nil
  report.evaluationStatus=if #evaluation==0 then "no_evaluation_rows" elseif diagnostics.coverage.evaluation.available==0 then "no_available_evaluation_rows" else "ok"
  report.policySelectionScope="validation_only";report.commonCoverage=copy(diagnostics.coverage)
  report.policySelectionObjective=selection.objective;report.policySelectionTieBreak=selection.tieBreak
  if model then
   model.selectedPolicyId=selectedPolicy;model.policyCandidates=copy(candidates)
   model.policySelectionScope="validation_only";model.policyConfig=copy(Execution.new({policyId=selectedPolicy}).config)
  end
  selection.byModel[id]={status=report.status,policyId=report.selectedPolicyId,reason=selectionReason,lambda=model and model.lambda or nil,
   validationMeanMSE=report.validationMeanMSE,validationZeroMeanMSE=report.validationZeroMeanMSE,validationMseRatioToZero=report.validationMseRatioToZero,candidates=copy(candidates)}
  check(options,"Evaluating frozen "..id.." / "..selectedPolicy)
  local result=execute(evaluation,predictions(model,evaluation,allowed,options),selectedPolicy,options)
  result.summary.modelStatus=report.status;result.summary.availableBars=diagnostics.coverage.evaluation.available
  result.summary.observedBars=#evaluation
  comparisons[#comparisons+1]={id=id,model=Learning.serialize(model),report=report,result=result}
 end
 local zeroPredictions={}
 for i,_ in evaluation do zeroPredictions[i]={mean=0,upside=0,downside=0,contributions={},isProbability=false,forecastKind="fixed_zero_unfitted"} end
 local zeroResult=execute(evaluation,zeroPredictions,"no_trade",options)
 zeroResult.summary.modelStatus="baseline";zeroResult.summary.availableBars=diagnostics.coverage.evaluation.available;zeroResult.summary.observedBars=#evaluation
 local zeroMSE
 for _,comparison in comparisons do
  if finite(comparison.report.validationZeroMeanMSE) then zeroMSE=comparison.report.validationZeroMeanMSE;break end
 end
 local zeroReport={status="baseline",baseline=true,forecast="zero",fitted=false,selectedPolicyId="no_trade",policyCandidates={},
  policySelectionScope="predeclared_baseline",policySelectionReason="unfitted_zero_forecast_cash_baseline",
  validationMeanMSE=zeroMSE,validationZeroMeanMSE=zeroMSE,validationMseRatioToZero=if finite(zeroMSE) then 1 else nil,
  validationMseSkillToZero=if finite(zeroMSE) then 0 else nil,
  validationZeroComparisonStatus=if zeroMSE==0 then "both_zero" elseif finite(zeroMSE) then "positive_baseline" else "unavailable",
  evaluationStatus=if #evaluation==0 then "no_evaluation_rows" elseif diagnostics.coverage.evaluation.available==0 then "no_available_evaluation_rows" else "ok",
  commonCoverage=copy(diagnostics.coverage),returnConvention="cash held flat; no interest, trading fees, slippage or borrow"}
 comparisons[#comparisons+1]={id="zero",model=nil,report=zeroReport,result=zeroResult}
 selection.byModel.zero={status="baseline",policyId="no_trade",reason=zeroReport.policySelectionReason,baseline=true,candidates={}}
 diagnostics.baselines=1;diagnostics.comparisons=#comparisons
 if diagnostics.fittedModels==0 then diagnostics.status=if diagnostics.modelErrors>0 then "model_error" else "insufficient_samples"
 elseif diagnostics.fittedModels<#IDS then diagnostics.status="partial" end
 if #evaluation==0 then diagnostics.status="no_evaluation_rows"
 elseif diagnostics.coverage.evaluation.available==0 then diagnostics.status="no_available_evaluation_rows" end
 check(options,"Readout and policy evaluation complete")
 return {version=3,comparisons=comparisons,selection=selection,diagnostics=diagnostics,provenance=copy(options.provenance or {})}
end

function Study.aggregate(folds)
 local out={version=3,groups={},coverage={attemptedFolds=#folds,completedFolds=0,failedFolds=0,successfulModelFolds=0,failedModelFolds=0,insufficientModelFolds=0,missingModelFolds=0},folds={},
  equityConvention="independent folds restart equity; returns are arithmetic fold summaries, never a continuously funded portfolio",
  selectionScope="no evaluation model or architecture winner is selected",status="complete"}
 local byKey={}
 for _,fold in folds do
  local configurationId=fold.configurationId or fold.configId or "unspecified"
  local completed=fold.phase=="complete"
  if completed then out.coverage.completedFolds+=1 else out.coverage.failedFolds+=1 end
  local detail={id=fold.id,foldId=fold.foldId,configurationId=configurationId,phase=fold.phase,error=fold.error,coverage=fold.diagnostics and copy(fold.diagnostics.coverage) or nil,models={}}
  out.folds[#out.folds+1]=detail
  local comparisons={};for _,c in fold.comparisons or {} do comparisons[c.id]=c end
  for _,id in ALL_IDS do
   local key=configurationId.."/"..id;local g=byKey[key]
   if not g then
    g={configurationId=configurationId,id=id,folds=0,attemptedFolds=0,failedFolds=0,insufficientFolds=0,missingFolds=0,netReturns={},foldIds={},totalTrades=0,totalTurnover=0,totalFees=0,totalBorrow=0,worstDrawdown=0,totalEvaluatedBars=0,totalAvailableBars=0,_exposureSum=0,_grossExposureSum=0}
    byKey[key]=g;out.groups[#out.groups+1]=g
   end
   g.attemptedFolds+=1
   local comparison=comparisons[id];local summary=comparison and comparison.result and comparison.result.summary
   local modelStatus=comparison and comparison.report and comparison.report.status
   local evaluationStatus=comparison and comparison.report and comparison.report.evaluationStatus
   if not completed then g.failedFolds+=1;detail.models[id]="fold_failed"
   elseif not comparison then g.missingFolds+=1;detail.models[id]="comparison_missing"
   elseif modelStatus=="insufficient_samples" then g.insufficientFolds+=1;detail.models[id]=modelStatus
   elseif (evaluationStatus and evaluationStatus~="ok") or (summary and (summary.observedBars==0 or summary.availableBars==0)) then g.failedFolds+=1;detail.models[id]=evaluationStatus or "evaluation_unavailable"
   elseif (modelStatus~="ok" and not (id=="zero" and modelStatus=="baseline")) or not summary or not finite(summary.netReturn) then g.failedFolds+=1;detail.models[id]=modelStatus or "invalid_result"
   else
    g.folds+=1;g.netReturns[#g.netReturns+1]=summary.netReturn;g.foldIds[#g.foldIds+1]=fold.id or fold.foldId or tostring(g.attemptedFolds)
    g.totalTrades+=summary.tradeCount or 0;g.totalTurnover+=summary.totalTurnover or 0
    g.totalFees+=summary.totalFees or 0;g.totalBorrow+=summary.totalBorrow or 0
    g.worstDrawdown=math.max(g.worstDrawdown,summary.maxDrawdown or 0)
    g._exposureSum+=summary.exposureFraction or 0;g._grossExposureSum+=summary.meanGrossExposure or 0
    g.totalEvaluatedBars+=summary.observedBars or #(comparison.result.rows or {})
    g.totalAvailableBars+=summary.availableBars or summary.observedBars or #(comparison.result.rows or {})
    detail.models[id]="ok"
   end
  end
 end
 for _,g in out.groups do
  out.coverage.successfulModelFolds+=g.folds;out.coverage.failedModelFolds+=g.failedFolds
  out.coverage.insufficientModelFolds+=g.insufficientFolds;out.coverage.missingModelFolds+=g.missingFolds
  if g.folds<g.attemptedFolds then out.status="partial" end
  if g.folds>0 then
   local mean=0;for _,r in g.netReturns do mean+=r/g.folds end
   local variance=0;for _,r in g.netReturns do variance+=(r-mean)^2/g.folds end
   g.meanNetReturn=mean;g.netReturnStdDev=math.sqrt(variance);g.meanExposure=g._exposureSum/g.folds;g.meanGrossExposure=g._grossExposureSum/g.folds
   g.minNetReturn=math.min(table.unpack(g.netReturns));g.maxNetReturn=math.max(table.unpack(g.netReturns))
  end
  g._exposureSum=nil;g._grossExposureSum=nil
 end
 if out.coverage.failedFolds>0 then out.status="partial" end
 return out
end
return Study
