local ok,Study=pcall(require,"../src/Study")
assert(ok and type(Study)=="table","Study must compare frozen validation selections on chronological evaluation rows")
local passed=0
local function test(name,fn) fn();passed+=1;print("PASS "..name) end
local function near(a,b,e) assert(math.abs(a-b)<=(e or 1e-10),tostring(a).." != "..tostring(b)) end
local function fixture(trainingSessions,validationSessions)
 local train,validation=trainingSessions or 5,validationSessions or 3
 local records={}
 for session=1,train+validation+2 do
  local x=(session%5-2)/2
  for j=1,40 do
   local t=session*86400+j*300;local r=0.001+0.004*x;local c=100*(1+r)^(j/6)
   local states={};for _,id in {"coupled","independent","numeric"} do states[id]={vector={x,j/40,1},names={"x","v","energy"}} end
   records[#records+1]={bar={t=t,day=tostring(session),o=c/(1+r)^(1/6),h=c*1.002,l=c*0.998,c=c},feature={ready=true,raw={x,session},names={"trend","dailyTrend"},memory={x,x/2},memoryNames={"lag1","ewma"},volatility=0.01},states=states}
  end
 end
 return records,{trainEndT=(train+1)*86400+300,validationEndT=(train+validation+1)*86400+300,testStartT=(train+validation+1)*86400+300}
end
test("five readouts and an unfitted no-trade baseline use validation only",function()
 local r,s=fixture();local out=Study.evaluate(r,s,{provenance={configurationId="grouped24"}})
 assert(#out.comparisons==6 and out.selection.scope=="validation_only")
 for i,id in {"coupled","independent","numeric","raw","memory"} do
  local c=out.comparisons[i];assert(c.id==id and c.model.status=="ok" and c.report.status=="ok")
  assert(#c.report.policyCandidates==4 and c.report.selectedPolicyId==c.result.policyId)
  assert(#c.result.rows==80 and c.result.rows[1].t==s.testStartT)
  assert(c.result.summary.initialEquity==1 and #c.result.rows[1].executions==0)
  for _,candidate in c.report.policyCandidates do
   assert(candidate.summary.firstT>=s.trainEndT and candidate.summary.lastT<s.validationEndT)
   assert(candidate.evidence and not candidate.evidence.eligible,"three short validation sessions cannot justify policy selection")
  end
  assert(c.report.selectedPolicyId=="no_trade" and c.result.summary.tradeCount==0)
 end
 local zero=out.comparisons[6]
 assert(zero.id=="zero" and zero.model==nil and zero.report.baseline==true and zero.report.status=="baseline")
 assert(zero.result.policyId=="no_trade" and zero.result.summary.netReturn==0 and #zero.result.rows==80)
 for _,row in zero.result.rows do assert(row.prediction.mean==0 and #row.executions==0 and row.position==0) end
end)
test("evaluation prices and features cannot choose ridge or policies",function()
 local r,s=fixture();local a=Study.evaluate(r,s)
 for i=321,#r do
  local b=r[i].bar;b.o*=1.1;b.h*=1.1;b.l*=1.1;b.c*=1.1
  r[i].feature.raw={-100,100};r[i].feature.memory={100,-100}
  for _,state in r[i].states do state.vector={100,-100,3} end
 end
 local b=Study.evaluate(r,s)
 for i=1,5 do
  local ca,cb=a.comparisons[i],b.comparisons[i]
  assert(ca.model.lambda==cb.model.lambda and ca.report.selectedPolicyId==cb.report.selectedPolicyId)
  for h=1,3 do for j,w in ca.model.weights[h] do near(w,cb.model.weights[h][j]) end end
  for j,candidate in ca.report.policyCandidates do near(candidate.selectionScore,cb.report.policyCandidates[j].selectionScore) end
 end
end)
test("missing model inputs suppress the same timestamp for all readouts without removing bars",function()
 local r,s=fixture();r[5].states.numeric=nil;r[325].feature.memory=nil
 local out=Study.evaluate(r,s)
 assert(out.diagnostics.coverage.train.available==199 and out.diagnostics.coverage.evaluation.available==79)
 for i=1,5 do local c=out.comparisons[i]
  assert(c.report.samples.train==169 and #c.result.rows==80)
  assert(c.result.rows[5].prediction==nil)
 end
 assert(r[5].feature.ready==true,"common availability must not mutate capture records")
end)
test("insufficient history reports all five missing models without inventing success",function()
 local r,s=fixture();s.trainEndT=r[20].bar.t
 local out=Study.evaluate(r,s)
 assert(out.diagnostics.status=="insufficient_samples" and out.diagnostics.fittedModels==0)
 for i=1,5 do local c=out.comparisons[i];assert(c.model==nil and c.report.status=="insufficient_samples" and c.result.summary.tradeCount==0) end
 assert(out.comparisons[6].report.status=="baseline" and out.comparisons[6].result.summary.tradeCount==0)
end)
test("evaluation boundaries and cancellation are enforced",function()
 local r,s=fixture();s.testStartT=s.validationEndT-300
 assert(not pcall(Study.evaluate,r,s))
 r,s=fixture();assert(not pcall(Study.evaluate,r,s,{cancelled=function() return true end}))
 s.testEndT=r[350].bar.t
 local out=Study.evaluate(r,s);assert(#out.comparisons[1].result.rows==29)
end)
test("aggregate independent fold equity without inventing compounding or dropping failures",function()
 local function comparison(id,ret,dd,trades,exposure)
  return {id=id,report={status="ok"},result={rows={},summary={initialEquity=1,equity=1+ret,netReturn=ret,maxDrawdown=dd,tradeCount=trades,exposureFraction=exposure,totalTurnover=trades*2,totalFees=0.01,totalBorrow=0.001}}}
 end
 local out=Study.aggregate({
  {id="a24",configurationId="grouped24",phase="complete",comparisons={comparison("raw",0.1,0.1,2,0.4)}},
  {id="b24",configurationId="grouped24",phase="complete",comparisons={comparison("raw",-0.1,0.2,3,0.6)}},
  {id="c24",configurationId="grouped24",phase="failed",error="capture failed"},
  {id="a48",configurationId="grouped48",phase="complete",comparisons={comparison("raw",0.4,0.3,4,0.8)}},
 })
 local g;for _,group in out.groups do if group.configurationId=="grouped24" and group.id=="raw" then g=group end end
 assert(g and g.folds==2 and g.attemptedFolds==3 and g.failedFolds==1)
 near(g.meanNetReturn,0);near(g.netReturnStdDev,0.1);near(g.worstDrawdown,0.2);near(g.meanExposure,0.5)
 assert(g.totalTrades==5 and #g.netReturns==2 and g.finalEquity==nil)
 assert(out.coverage.attemptedFolds==4 and out.coverage.failedFolds==1 and out.bestModel==nil)
end)
test("insufficient and missing comparison folds remain in aggregate denominators",function()
 local out=Study.aggregate({{id="a",configurationId="grouped24",phase="complete",comparisons={{id="raw",report={status="insufficient_samples"},result={summary={netReturn=0}}}}}})
 assert(#out.groups==6)
 for _,g in out.groups do assert(g.attemptedFolds==1 and g.folds==0 and g.meanNetReturn==nil) end
 local raw;for _,g in out.groups do if g.id=="raw" then raw=g end end
 assert(raw.insufficientFolds==1)
 assert(out.status=="partial" and out.coverage.insufficientModelFolds==1 and out.coverage.missingModelFolds==5)
end)
test("empty or wholly unavailable evaluation windows cannot become successful zero-return folds",function()
 for _,mode in {"empty","unavailable"} do
  local r,s=fixture()
  if mode=="empty" then s.testStartT=r[#r].bar.t+300
  else for i=321,#r do r[i].states.numeric=nil end end
  local result=Study.evaluate(r,s)
  assert(result.diagnostics.status==(if mode=="empty" then "no_evaluation_rows" else "no_available_evaluation_rows"))
  local aggregate=Study.aggregate({{id=mode,configurationId="grouped24",phase="complete",comparisons=result.comparisons,diagnostics=result.diagnostics}})
  assert(aggregate.status=="partial" and aggregate.coverage.successfulModelFolds==0)
  for _,g in aggregate.groups do assert(g.folds==0 and g.failedFolds==1 and g.meanNetReturn==nil) end
 end
end)
local function blockEvidence(returns)
 local blocks={}
 for i,r in returns do blocks[i]={sessionCount=5,availableBars=390,result={config={feeBps=1,slippageBps=1},rows={{close=100}},summary={initialEquity=1,netReturn=r,shares=0,maxDrawdown=0.001,totalTurnover=4,tradeCount=2}}} end
 return blocks
end
test("an isolated return spike cannot select a policy with unstable validation blocks",function()
 local evidence=Study.assessPolicyEvidence(blockEvidence({-0.001,-0.002,0.5}),{validationMeanMSE=0.5,validationZeroMeanMSE=1})
 assert(evidence.meanNetReturn>0 and evidence.medianNetReturn<0)
 assert(not evidence.eligible and evidence.gates.positiveMedian==false and evidence.gates.positiveMajority==false)
end)
test("positive block returns cannot overcome forecasts worse than zero or inadequate trade evidence",function()
 local blocks=blockEvidence({0.01,0.02,0.03})
 local bad=Study.assessPolicyEvidence(blocks,{validationMeanMSE=1,validationZeroMeanMSE=1})
 assert(bad.selectionScore>0 and not bad.eligible and not bad.gates.beatsZeroForecast)
 for _,block in blocks do block.result.summary.tradeCount=0 end
 local sparse=Study.assessPolicyEvidence(blocks,{validationMeanMSE=0.5,validationZeroMeanMSE=1})
 assert(not sparse.eligible and not sparse.gates.minimumTrades and not sparse.gates.eachBlockTrades)
end)
test("stable cost-adjusted validation evidence can pass the declared fixed rule",function()
 local evidence=Study.assessPolicyEvidence(blockEvidence({0.01,0.02,0.03}),{validationMeanMSE=0.5,validationZeroMeanMSE=1})
 assert(evidence.eligible and evidence.selectionScore>0 and evidence.totalTrades==6)
 near(evidence.meanNetReturn,0.02);near(evidence.medianNetReturn,0.02)
 near(evidence.selectionScore,0.02-0.001-4/10000)
end)
test("downside and turnover penalties reject fragile positive-mean positive-median evidence",function()
 local downside=Study.assessPolicyEvidence(blockEvidence({0.001,-0.1,0.4}),{validationMeanMSE=0.5,validationZeroMeanMSE=1})
 assert(downside.meanNetReturn>0 and downside.medianNetReturn>0 and downside.gates.positiveMajority)
 assert(downside.selectionScore<0 and not downside.eligible)
 local blocks=blockEvidence({0.01,0.01,0.01})
 for _,b in blocks do b.result.summary.totalTurnover=200 end
 local churn=Study.assessPolicyEvidence(blocks,{validationMeanMSE=0.5,validationZeroMeanMSE=1})
 assert(churn.meanNetReturn>0 and churn.extraCostStress==0.02 and churn.selectionScore<0 and not churn.eligible)
end)
test("open validation positions reserve closing costs without invented fills",function()
 local blocks=blockEvidence({0.01,0.01,0.01})
 for _,b in blocks do b.result.summary.shares=0.01 end
 local evidence=Study.assessPolicyEvidence(blocks,{validationMeanMSE=0.5,validationZeroMeanMSE=1})
 near(evidence.meanNetReturn,0.0098)
 for i,b in blocks do
  near(evidence.blocks[i].closingCostReserve,0.0002)
  assert(b.result.summary.shares==0.01 and #b.result.rows==1)
 end
end)
test("twenty validation sessions produce four common five-session blocks and real forecast gates",function()
 local r,s=fixture(10,20);local out=Study.evaluate(r,s)
 assert(out.diagnostics.fittedModels==5 and #out.selection.validationBlocks==4)
 for i,b in out.selection.validationBlocks do
  assert(b.sessionCount==5 and b.availableBars==200 and b.firstT>=s.trainEndT and b.lastT<s.validationEndT)
  if i>1 then assert(b.firstT>out.selection.validationBlocks[i-1].lastT) end
 end
 for i=1,5 do
  local c=out.comparisons[i]
  assert(c.report.validationZeroMeanMSE>0 and c.report.validationMseRatioToZero<1)
  for _,candidate in c.report.policyCandidates do
   assert(candidate.evidence.blockCount==4 and candidate.evidence.gates.beatsZeroForecast)
   assert(candidate.evidence.gates.minimumBlocks and candidate.evidence.gates.eachBlockSessions)
  end
  if c.report.selectedPolicyId~="no_trade" then
   assert(c.report.policySelectionEvidence.eligible and c.report.policySelectionEvidence.selectionScore>0)
  end
 end
 near(out.comparisons[6].report.validationMseRatioToZero,1)
 local aggregate=Study.aggregate({{id="long",configurationId="grouped24",phase="complete",comparisons=out.comparisons}})
 assert(aggregate.status=="complete" and aggregate.coverage.successfulModelFolds==6)
 assert(aggregate.groups[6].id=="zero" and aggregate.groups[6].meanNetReturn==0)
end)
test("eligible policies with actual trades remain frozen when evaluation prices and features change",function()
 local r,s=fixture(10,20);local price=100
 for _,record in r do
  local b=record.bar;b.o=price;price*=1.0005;b.c=price;b.h=b.c*1.0001;b.l=b.o*0.9999
  record.feature.volatility=0.003
 end
 local before=Study.evaluate(r,s)
 for i=1,5 do
  local c=before.comparisons[i]
  assert(c.report.selectedPolicyId~="no_trade" and c.result.summary.tradeCount>0,
   "fixture must exercise an eligible frozen trading policy, not only the no-trade fallback")
  assert(c.report.policySelectionEvidence.eligible and c.report.policySelectionEvidence.selectionScore>0)
 end
 local changed=0
 for _,record in r do
  if record.bar.t>=s.testStartT then
   changed+=1;local factor=if changed%2==0 then 2 else 0.2
   for _,key in {"o","h","l","c"} do record.bar[key]*=factor end
   record.feature.raw={100,-100};record.feature.memory={-100,100}
   for _,state in record.states do state.vector={100,-100,100} end
  end
 end
 assert(changed==80)
 local after=Study.evaluate(r,s)
 for i=1,5 do
  local a,b=before.comparisons[i],after.comparisons[i]
  assert(a.model.lambda==b.model.lambda and a.report.selectedPolicyId==b.report.selectedPolicyId)
  for h=1,3 do for j,w in a.model.weights[h] do near(w,b.model.weights[h][j],0) end end
  for j,candidate in a.report.policyCandidates do
   local other=b.report.policyCandidates[j]
   near(candidate.selectionScore,other.selectionScore,0)
   assert(candidate.evidence.eligible==other.evidence.eligible)
   for gate,passedGate in candidate.evidence.gates do assert(passedGate==other.evidence.gates[gate]) end
  end
 end
end)
print("Study: "..passed.." tests passed")
