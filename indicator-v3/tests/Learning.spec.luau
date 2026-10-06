local loaded, Learning = pcall(require, "../src/Learning")
assert(loaded and type(Learning) == "table", "Learning must implement causal three-head fitting")
local passed = 0
local function test(name, f) f(); passed += 1; print("PASS " .. name) end
local function near(a,b,e) assert(math.abs(a-b) <= (e or 1e-10), tostring(a).." != "..tostring(b)) end
local function fixture()
 local records = {}
 for session = 1, 10 do
  local x = (session % 5 - 2) / 2
  for j = 1, 40 do
   local t = session * 86400 + j * 300
   local r = 0.001 + 0.004*x
   local c = 100 * (1+r)^(j/6)
   records[#records+1] = {bar={t=t,day=tostring(session),o=c/(1+r)^(1/6),c=c,h=c*1.002,l=c*0.998},feature={raw={x,session},names={"trend","dailyTrend"},ready=true},states={}}
  end
 end
 return records, {trainEndT=6*86400+300,validationEndT=9*86400+300,variant="raw"}
end
test("strict six-bar completion excludes outcomes unavailable at train boundary", function()
 local r,c = fixture(); c.trainEndT = r[40].bar.t
 local _,report=Learning.fit(r,c)
 assert(report.samples.train==33, "bar ending exactly at cutoff is admitted; later labels excluded")
 assert(report.samples.validation==238)
end)
test("session boundaries and missing intervals reject labels", function()
 local r,c=fixture(); local _,before=Learning.fit(r,c)
 r[15].bar.t += 30
 local _,after=Learning.fit(r,c)
 assert(before.samples.train==170 and after.samples.train==163)
end)
test("insufficient train and validation counts explicitly suppress fit", function()
 local r,c=fixture(); c.trainEndT=r[100].bar.t
 local m,report=Learning.fit(r,c)
 assert(m==nil and report.status=="insufficient_samples")
 assert(report.minimum.train==128 and report.minimum.validation==32)
end)
test("learns known relation with training scaler and unpenalized intercept", function()
 local r,c=fixture(); local m,report=Learning.fit(r,c)
 assert(m and report.status=="ok" and #m.weights==3)
 print("METRIC synthetic fit train="..report.samples.train.." validation="..report.samples.validation.." lambda="..m.lambda.." validationMSE="..report.validationMeanMSE)
 near(m.means[2],3)
 local p=Learning.predict(m,r[1]); near(p.mean,-0.001,0.00003)
 assert(p.upside>=0 and p.downside>=0)
 local sum=0; for _,v in p.contributions do sum+=v.value end
 near(sum,p.mean,1e-12)
 assert(#p.contributions==3 and p.contributions[1].name=="intercept")
end)
test("evaluation changes do not affect scaler weights selection or predictions", function()
 local r,c=fixture(); local a=Learning.fit(r,c)
 for i=321,#r do r[i].feature.raw={1e9,-1e9};r[i].bar.h*=3;r[i].bar.c*=2 end
 local b=Learning.fit(r,c)
 assert(a.lambda==b.lambda)
 for j=1,#a.means do near(a.means[j],b.means[j]);near(a.scales[j],b.scales[j]) end
 for h=1,3 do for j=1,#a.weights[h] do near(a.weights[h][j],b.weights[h][j]) end end
end)
test("validation alone selects among exact three ridge candidates without refit", function()
 local r,c=fixture();local m,report=Learning.fit(r,c)
 local best=math.huge;local lambda
 for _,v in report.validationLosses do if v.meanMSE<best then best=v.meanMSE;lambda=v.lambda end end
 assert(m.lambda==lambda and #report.validationLosses==3)
 local originalMean=m.means[1]
 for i=201,320 do r[i].feature.raw[1]= -r[i].feature.raw[1] end
 local changed=Learning.fit(r,c);near(changed.means[1],originalMean)
 assert(changed.lambda==10,"validation relation reversed from training selects stronger penalty")
end)
test("physical schemas support both recorded node counts and reject corruption", function()
 for _,dimension in {59,107} do
  local r,c=fixture();c.variant="coupled"
  local names={};for j=1,dimension do names[j]="state"..j end
  for _,v in r do v.states.coupled={vector=table.create(dimension,0),names=names} end
  local m=Learning.fit(r,c);assert(#m.inputNames==dimension+2 and m.stateDimension==dimension)
  local p=Learning.predict(m,r[1]);assert(#p.contributions==dimension+3)
  local restored=Learning.deserialize(Learning.serialize(m));near(Learning.predict(restored,r[1]).mean,p.mean)
  table.remove(r[1].states.coupled.vector)
  assert(not pcall(Learning.predict,m,r[1]))
 end
end)
test("memory baseline fits causal memory alongside raw inputs with train-only scaling", function()
 local r,c=fixture();c.variant="memory"
 for _,v in r do v.feature.memory={v.feature.raw[1]*2,3};v.feature.memoryNames={"trend.lag1","volume.ewmaSlow"} end
 local m,report=Learning.fit(r,c)
 assert(m.memoryDimension==2 and m.stateDimension==0 and #m.inputNames==4)
 near(m.means[4],3)
 local p=Learning.predict(Learning.deserialize(m),r[1]);assert(#p.contributions==5 and p.isProbability==false)
 r[1].feature.memoryNames={"changed","volume.ewmaSlow"};assert(not pcall(Learning.predict,m,r[1]))
end)
test("evaluation memory and state values cannot influence fitted parameters", function()
 for _,variant in {"coupled","memory"} do
  local r,c=fixture();c.variant=variant
  for _,v in r do v.feature.memory={1};v.feature.memoryNames={"lag"};v.states.coupled={vector={1,2,3},names={"x","v","energy"}} end
  local a=Learning.fit(r,c)
  for i=321,#r do r[i].feature.memory={1e9};r[i].states.coupled.vector={1e9,-1e9,1e9} end
  local b=Learning.fit(r,c);assert(a.lambda==b.lambda)
  for h=1,3 do for j=1,#a.weights[h] do near(a.weights[h][j],b.weights[h][j]) end end
 end
end)
test("reduced context applies only to raw comparison and validates names", function()
 local r,c=fixture();c.contextMode="reduced";local m=Learning.fit(r,c)
 assert(#m.inputNames==1 and m.rawDimension==2)
 local query=r[1];query.feature.names={"wrong","dailyTrend"}
 assert(not pcall(Learning.predict,m,query))
 c.variant="numeric";assert(not pcall(Learning.fit,r,c))
end)
test("models round trip through plain table serializer", function()
 local r,c=fixture();local m=Learning.fit(r,c)
 local serial=Learning.serialize(m);local restored=Learning.deserialize(serial)
 near(Learning.predict(m,r[10]).mean,Learning.predict(restored,r[10]).mean,0)
 serial.weights[1][1]=0/0;assert(not pcall(Learning.deserialize,serial))
end)
test("validation shortage never admits evaluation labels to meet minimum", function()
 local r,c=fixture();c.validationEndT=r[238].bar.t
 local m,report=Learning.fit(r,c);assert(m==nil and report.samples.train==170 and report.samples.validation==31)
end)
test("three constant heads recover exact return and high-low excursions", function()
 local r,c=fixture()
 for _,row in r do row.bar.o=100;row.bar.c=100;row.bar.h=105;row.bar.l=95;row.feature.raw={7,7} end
 local m=Learning.fit(r,c);local p=Learning.predict(m,r[1])
 near(p.mean,0,1e-14);near(p.upside,0.05,1e-14);near(p.downside,0.05,1e-14)
end)
test("unready features cannot train and absent model has no prediction", function()
 local r,c=fixture();for i=1,10 do r[i].feature.ready=false end
 local _,report=Learning.fit(r,c);assert(report.samples.train==160)
 assert(Learning.predict(nil,r[1])==nil)
end)
test("feature length and nonfinite values fail rather than silently truncate", function()
 local r,c=fixture();local m=Learning.fit(r,c)
 r[1].feature.raw[3]=1;assert(not pcall(Learning.predict,m,r[1]));r[1].feature.raw[3]=nil
 r[1].feature.raw[1]=math.huge;assert(not pcall(Learning.predict,m,r[1]))
end)
test("caller provenance survives fitting and model serialization without claiming physics rerun", function()
 local r,c=fixture();c.provenance={sourceHash="synthetic-source",dataHash="synthetic-data",configHash="synthetic-config",nativeStepCounters={coupled=48000}}
 local m,report=Learning.fit(r,c)
 assert(report.provenance.dataHash=="synthetic-data" and report.newNativeSteps==0)
 local artifact=Learning.serialize(m);assert(artifact.provenance.sourceHash=="synthetic-source")
 c.provenance.dataHash="mutated";assert(m.provenance.dataHash=="synthetic-data")
end)
test("state diversity is measured on training only and detects redundant dimensions",function()
 local r,c=fixture();c.variant="coupled"
 for _,v in r do local x=v.feature.raw[1];v.states.coupled={vector={x,2*x,1},names={"x","duplicate","constant"}} end
 local _,report=Learning.fit(r,c)
 assert(report.trainingDiversity.stateDimensions==3 and report.trainingDiversity.activeDimensions==2)
 near(report.trainingDiversity.effectiveDimension,1,1e-8)
 for i=201,#r do r[i].states.coupled.vector={i,i%17,i%31} end
 local _,changed=Learning.fit(r,c)
 near(changed.trainingDiversity.effectiveDimension,report.trainingDiversity.effectiveDimension)
end)
test("training-only variance mask drops absolute and relative near-constants while preserving schema",function()
 local r,c=fixture()
 for i,row in r do local x=row.feature.raw[1];row.feature.raw={x,1e-8*x,1e6+x,1};row.feature.names={"trend","tiny","largeOffset","constant"} end
 local model,report=Learning.fit(r,c)
 assert(#model.inputNames==4 and model.effectiveDimension==1 and #model.activeIndices==1 and model.activeIndices[1]==1)
 assert(#report.preprocessing.droppedFeatures==3 and report.preprocessing.trainingOnly)
 assert(model.activeMask[1] and not model.activeMask[2] and not model.activeMask[3] and not model.activeMask[4])
 local p=Learning.predict(model,r[1]);assert(#p.contributions==5)
 for j=3,5 do near(p.contributions[j].value,0,0) end
 for i=201,#r do r[i].feature.raw[2]=i*100;r[i].feature.raw[3]=i*1e6;r[i].feature.raw[4]=-i end
 local changed=Learning.fit(r,c)
 for j=1,4 do assert(changed.activeMask[j]==model.activeMask[j]);near(changed.means[j],model.means[j]);near(changed.scales[j],model.scales[j]) end
end)
test("regime covariate shift at z93 is clipped to five with exact contribution mapping",function()
 local r,c=fixture()
 for _,row in r do local x=row.feature.raw[1];row.feature.raw={0.02+0.0043*math.sqrt(2)*x};row.feature.names={"regimeHigh"} end
 local model,report=Learning.fit(r,c);near(model.scales[1],0.0043,1e-12)
 local query=r[321];query.feature.raw[1]=model.means[1]+93*model.scales[1]
 local p=Learning.predict(model,query)
 assert(p.standardizedFeatures[1]==5 and p.clipping.clippedValues==1 and p.clipping.clippedFeatures[1].name=="regimeHigh")
 near(p.contributions[2].value,model.weights[1][2]*5,1e-14)
 near(p.mean,p.contributions[1].value+p.contributions[2].value,1e-14)
 query.feature.raw[1]=model.means[1]-93*model.scales[1]
 assert(Learning.predict(Learning.deserialize(model),query).standardizedFeatures[1]==-5)
 assert(report.preprocessing.clipZ==5)
end)
test("training and validation use clipped design and expose counts without refitting the mask",function()
 local r,c=fixture()
 for i,row in r do row.feature.raw={if i==10 then 100 else if i<201 then 0 else 1000};row.feature.names={"outlier"} end
 local model,report=Learning.fit(r,c)
 assert(report.preprocessing.trainingClipping.clippedValues==1 and report.preprocessing.validationClipping.clippedValues==102)
 assert(report.preprocessing.trainingClipping.maxAbsStandardized<=5 and report.preprocessing.validationClipping.maxAbsStandardized<=5)
 local residualMean,trainN=0,0
 for i=1,200 do
  if i%40<=34 and i%40~=0 then
   local actual=r[i+6].bar.c/r[i+1].bar.o-1
   residualMean+=Learning.predict(model,r[i]).mean-actual;trainN+=1
  end
 end
 assert(trainN==170);near(residualMean/trainN,0,1e-12)
 local loss,n=0,0
 for i=201,320 do
  local row=r[i]
  if i%40<=34 and i%40~=0 then
   local pred=Learning.predict(model,row)
   local actual=r[i+6].bar.c/r[i+1].bar.o-1
   loss+=(pred.mean-actual)^2;n+=1
  end
 end
 assert(n==102);near(loss/n,report.validationMeanMSE,1e-14)
end)
test("validation zero-return comparator uses the same matured labels",function()
 local r,c=fixture();local model,report=Learning.fit(r,c)
 -- Validation sessions 6,7,8 have six-bar returns -.001, .001, .003.
 near(report.validationZeroMeanMSE,11e-6/3,1e-14)
 near(report.validationMseRatioToZero,report.validationMeanMSE/(11e-6/3),1e-10)
 near(report.validationMseSkillToZero,1-report.validationMseRatioToZero,1e-12)
 assert(report.validationZeroComparisonStatus=="positive_baseline")
 assert(model.validationZeroMeanMSE==report.validationZeroMeanMSE)
end)
test("zero baseline error yields finite explicit equality or undefined worse-model diagnostics",function()
 local r,c=fixture()
 for _,row in r do row.bar.o=100;row.bar.c=100;row.bar.h=100;row.bar.l=100;row.feature.raw={1,1} end
 local model,report=Learning.fit(r,c)
 assert(model.effectiveDimension==0 and #model.activeIndices==0)
 assert(report.validationZeroMeanMSE==0 and report.validationMeanMSE==0)
 assert(report.validationMseRatioToZero==1 and report.validationMseSkillToZero==0 and report.validationZeroComparisonStatus=="both_zero")
 local restored=Learning.deserialize(model);near(Learning.predict(restored,r[321]).mean,0,0)
 for i=1,200 do r[i].bar.c=101;r[i].bar.h=101 end
 local _,worse=Learning.fit(r,c)
 assert(worse.validationZeroMeanMSE==0 and worse.validationMeanMSE>0)
 assert(worse.validationMseRatioToZero==nil and worse.validationMseSkillToZero==nil and worse.validationZeroComparisonStatus=="zero_baseline_model_error")
end)
test("serialization rejects a mask that would reactivate dropped predictors",function()
 local r,c=fixture();for _,row in r do row.feature.raw[2]=1 end
 local model=Learning.fit(r,c);local artifact=Learning.serialize(model)
 artifact.activeMask[2]=true
 assert(not pcall(Learning.deserialize,artifact))
end)
print("Learning: "..passed.." tests passed")
