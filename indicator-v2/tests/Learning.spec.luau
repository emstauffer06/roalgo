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
 for i=201,320 do r[i].feature.raw[1]=0 end
 local changed=Learning.fit(r,c);near(changed.means[1],originalMean)
 assert(changed.lambda==10,"validation shifted toward intercept selects stronger penalty")
end)
test("physical inputs append exactly 51 values and reject shape corruption", function()
 local r,c=fixture();c.variant="coupled"
 for _,v in r do v.states.coupled={vector=table.create(51,0),names=table.create(51,"state")} end
 local m=Learning.fit(r,c);assert(#m.inputNames==53 and m.stateDimension==51)
 local p=Learning.predict(m,r[1]);assert(#p.contributions==54)
 table.remove(r[1].states.coupled.vector)
 assert(not pcall(Learning.predict,m,r[1]))
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
print("Learning: "..passed.." tests passed")
