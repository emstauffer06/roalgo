-- Historical exploratory readout. Labels mature after six contiguous observed bars.
local Learning = {}
local VARIANTS = {raw=true,coupled=true,independent=true,numeric=true}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function clone(v)
 if type(v)~="table" then return v end
 local out={}; for k,x in v do out[k]=clone(x) end; return out
end
local function slower(name)
 local n=string.lower(name)
 return string.find(n,"hour",1,true)~=nil or string.find(n,"daily",1,true)~=nil or string.find(n,"regime",1,true)~=nil
end
local function design(record,schema)
 local f=record.feature
 assert(type(f)=="table" and type(f.raw)=="table" and #f.raw==schema.rawDimension,"Learning: raw vector length")
 assert(type(f.names)=="table" and #f.names==schema.rawDimension,"Learning: raw names length")
 for j,name in schema.rawNames do
  assert(f.names[j]==name,"Learning: raw feature names mismatch")
  assert(finite(f.raw[j]),"Learning: non-finite raw feature")
 end
 local x={};for _,j in schema.rawIndices do x[#x+1]=f.raw[j] end
 if schema.stateDimension>0 then
  local state=record.states and record.states[schema.variant]
  assert(state and type(state.vector)=="table" and #state.vector==51,"Learning: state vector length must be 51")
  assert(type(state.names)=="table" and #state.names==51,"Learning: state names length must be 51")
  for j=1,51 do
   assert(state.names[j]==schema.stateNames[j],"Learning: state feature names mismatch")
   assert(finite(state.vector[j]),"Learning: non-finite state feature")
   x[#x+1]=state.vector[j]
  end
 end
 return x
end
local function schemaFor(record,options)
 local f=record.feature
 assert(type(f)=="table" and type(f.raw)=="table" and #f.raw>0 and #f.raw==#f.names,"Learning: raw schema required")
 local schema={variant=options.variant or "raw",contextMode=options.contextMode or "full",rawDimension=#f.raw,rawNames=clone(f.names),rawIndices={},inputNames={},stateDimension=0,stateNames={}}
 assert(VARIANTS[schema.variant],"Learning: unknown variant")
 assert(schema.contextMode=="full" or schema.contextMode=="reduced","Learning: context mode")
 assert(schema.contextMode~="reduced" or schema.variant=="raw","Learning: reduced context only supports raw comparison")
 for j,name in f.names do
  assert(type(name)=="string","Learning: feature name")
  if schema.contextMode=="full" or not slower(name) then
   schema.rawIndices[#schema.rawIndices+1]=j;schema.inputNames[#schema.inputNames+1]=name
  end
 end
 if schema.variant~="raw" then
  schema.stateDimension=51
  local state=record.states and record.states[schema.variant]
  assert(state and type(state.names)=="table" and #state.names==51,"Learning: state schema required")
  schema.stateNames=clone(state.names)
  for _,name in state.names do assert(type(name)=="string","Learning: state feature name");schema.inputNames[#schema.inputNames+1]=schema.variant..":"..name end
 end
 return schema
end
local function outcome(records,i)
 local current=records[i].bar
 local entry=records[i+1] and records[i+1].bar
 if not entry or not finite(entry.o) or entry.o<=0 then return nil end
 local high,low=entry.o,entry.o
 for j=i+1,i+6 do
  local b=records[j] and records[j].bar
  local prev=records[j-1].bar
  if not b or b.day~=current.day or b.t-prev.t~=300 then return nil end
  if not finite(b.h) or not finite(b.l) or not finite(b.c) or b.l<=0 or b.h<b.l or b.c<=0 then return nil end
  high=math.max(high,b.h);low=math.min(low,b.l)
 end
 local last=records[i+6].bar
 return {last.c/entry.o-1,math.max(0,high/entry.o-1),math.max(0,1-low/entry.o)},last.t+300
end
local function solve(A,B)
 local n=#A; local L={}
 for i=1,n do
  L[i]={}
  for j=1,i do
   local s=A[i][j]
   for k=1,j-1 do s-=L[i][k]*L[j][k] end
   if i==j then assert(finite(s) and s>0,"Learning: non-positive ridge pivot");L[i][j]=math.sqrt(s)
   else L[i][j]=s/L[j][j] end
  end
 end
 local weights={}
 for h=1,3 do
  local y,w={},{}
  for i=1,n do local s=B[i][h];for k=1,i-1 do s-=L[i][k]*y[k] end;y[i]=s/L[i][i] end
  for i=n,1,-1 do local s=y[i];for k=i+1,n do s-=L[k][i]*w[k] end;w[i]=s/L[i][i];assert(finite(w[i]),"Learning: non-finite weights") end
  weights[h]=w
 end
 return weights
end
local function rawPredict(model,x)
 local values={}
 for h=1,3 do
  local s=model.weights[h][1]
  for j=1,#x do s+=model.weights[h][j+1]*(x[j]-model.means[j])/model.scales[j] end
  assert(finite(s),"Learning: non-finite prediction");values[h]=s
 end
 return values
end
function Learning.fit(records,options)
 assert(type(options)=="table" and finite(options.trainEndT) and finite(options.validationEndT) and options.trainEndT<options.validationEndT,"Learning: ordered split cutoffs required")
 local report={status="insufficient_samples",scope="historical exploratory research; earlier date ranges have already been inspected",schemaVersion="roalgo-learning-v2-1",cutoffs={trainEndT=options.trainEndT,validationEndT=options.validationEndT},samples={train=0,validation=0},minimum={train=128,validation=32},validationLosses={},labelHorizon=6,labelEntry="next bar open",labelAvailability="sixth future bar start + 300; <= split cutoff",rejectedLabels=0}
 report.provenance=clone(options.provenance or {})
 report.newNativeSteps=0;report.readoutOnly=true
 local train,validation={},{}
 local schema
 for i,record in records do
  local t=record.bar.t
  assert(finite(t) and (i==1 or t>records[i-1].bar.t),"Learning: records must be chronologically ordered")
  if t<options.validationEndT and record.feature.ready then
   local y,available=outcome(records,i)
   local cutoff=if t<options.trainEndT then options.trainEndT else options.validationEndT
   if y and available<=cutoff then
    schema=schema or schemaFor(record,options)
    local sample={x=design(record,schema),y=y,t=t,labelAvailableT=available}
    local bucket=if t<options.trainEndT then train else validation
    bucket[#bucket+1]=sample
   else report.rejectedLabels+=1 end
  end
 end
 report.samples={train=#train,validation=#validation}
 if #train<128 or #validation<32 then return nil,report end
 local dimension=#schema.inputNames
 local means,scales={},{}
 for j=1,dimension do
  local mean,m2=0,0
  for n,sample in train do local delta=sample.x[j]-mean;mean+=delta/n;m2+=delta*(sample.x[j]-mean) end
  means[j]=mean;scales[j]=math.max(math.sqrt(math.max(0,m2/#train)),1e-9)
 end
 local targetMeans={0,0,0}
 for n,sample in train do for h=1,3 do targetMeans[h]+=(sample.y[h]-targetMeans[h])/n end end
 local gram,rhs={},{}
 for j=1,dimension do gram[j]=table.create(dimension,0);rhs[j]={0,0,0} end
 for _,sample in train do
  local z={};for j=1,dimension do z[j]=(sample.x[j]-means[j])/scales[j] end
  for j=1,dimension do
   for k=1,dimension do gram[j][k]+=z[j]*z[k] end
   for h=1,3 do rhs[j][h]+=z[j]*(sample.y[h]-targetMeans[h]) end
  end
 end
 local best,bestLoss=nil,math.huge
 for _,lambda in {0.1,1,10} do
  local matrix=clone(gram);for j=1,dimension do matrix[j][j]+=lambda end
  local slopes=solve(matrix,rhs)
  local model=clone(schema)
  model.status="ok";model.schemaVersion=report.schemaVersion;model.means=clone(means);model.scales=clone(scales);model.lambda=lambda;model.weights={}
  for h=1,3 do model.weights[h]={targetMeans[h]};for j=1,dimension do model.weights[h][j+1]=slopes[h][j] end end
  local losses={0,0,0}
  for _,sample in validation do
   local pred=rawPredict(model,sample.x)
   for h=1,3 do losses[h]+=(pred[h]-sample.y[h])^2/#validation end
  end
  local entry={lambda=lambda,meanMSE=losses[1],upsideMSE=losses[2],downsideMSE=losses[3]}
  report.validationLosses[#report.validationLosses+1]=entry
  if losses[1]<bestLoss then bestLoss=losses[1];best=model end
 end
 report.status="ok";report.selectedLambda=best.lambda;report.validationMeanMSE=bestLoss
 report.sampleRanges={train={firstT=train[1].t,lastT=train[#train].t,lastLabelAvailableT=train[#train].labelAvailableT},validation={firstT=validation[1].t,lastT=validation[#validation].t,lastLabelAvailableT=validation[#validation].labelAvailableT}}
 best.cutoffs=clone(report.cutoffs);best.samples=clone(report.samples);best.validationLosses=clone(report.validationLosses);best.sampleRanges=clone(report.sampleRanges);best.scope=report.scope
 best.provenance=clone(report.provenance);best.newNativeSteps=0;best.readoutOnly=true
 return best,report
end
function Learning.predict(model,record)
 if model==nil or model.status~="ok" then return nil end
 local x=design(record,model);local p=rawPredict(model,x)
 local contributions={{name="intercept",value=model.weights[1][1]}}
 for j,name in model.inputNames do contributions[#contributions+1]={name=name,value=model.weights[1][j+1]*(x[j]-model.means[j])/model.scales[j]} end
 local upside,downside=math.max(0,p[2]),math.max(0,p[3])
 return {mean=p[1],upside=upside,downside=downside,contributions=contributions,score=p[1]/math.max(1e-9,upside+downside)}
end
function Learning.serialize(model) return clone(model) end
function Learning.deserialize(artifact)
 assert(type(artifact)=="table" and artifact.status=="ok" and artifact.schemaVersion=="roalgo-learning-v2-1","Learning: invalid model artifact")
 local m=clone(artifact);local n=#m.inputNames
 assert(VARIANTS[m.variant] and #m.weights==3 and #m.means==n and #m.scales==n and #m.rawNames==m.rawDimension,"Learning: artifact dimensions")
 assert(m.stateDimension==(if m.variant=="raw" then 0 else 51) and #m.rawIndices+m.stateDimension==n,"Learning: artifact state dimensions")
 for j=1,n do assert(finite(m.means[j]) and finite(m.scales[j]) and m.scales[j]>0,"Learning: artifact scaler") end
 for h=1,3 do assert(#m.weights[h]==n+1,"Learning: artifact weights");for _,w in m.weights[h] do assert(finite(w),"Learning: artifact finite weights") end end
 for _,j in m.rawIndices do assert(j>=1 and j<=m.rawDimension and j%1==0,"Learning: artifact raw index") end
 return m
end
return Learning
