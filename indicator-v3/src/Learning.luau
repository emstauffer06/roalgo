-- Historical exploratory readout. Labels mature after six contiguous observed bars.
local Learning = {}
local VARIANTS = {raw=true,memory=true,coupled=true,independent=true,numeric=true}
local SCHEMA_VERSION="roalgo-learning-v3-2"
-- These inputs are dimensionless feature coordinates (return fractions, log
-- activity, probabilities, normalized motion/energy), not raw prices or forces.
-- Keep only variation exceeding both numerical absolute and relative floors.
local ABSOLUTE_STD_FLOOR=1e-6
local RELATIVE_STD_FLOOR=1e-4
local CLIP_Z=5
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
 if schema.memoryDimension>0 then
  assert(type(f.memory)=="table" and #f.memory==schema.memoryDimension,"Learning: memory vector length")
  assert(type(f.memoryNames)=="table" and #f.memoryNames==schema.memoryDimension,"Learning: memory names length")
  for j,name in schema.memoryNames do
   assert(f.memoryNames[j]==name,"Learning: memory feature names mismatch")
   assert(finite(f.memory[j]),"Learning: non-finite memory feature");x[#x+1]=f.memory[j]
  end
 end
 if schema.stateDimension>0 then
  local state=record.states and record.states[schema.variant]
  assert(state and type(state.vector)=="table" and #state.vector==schema.stateDimension,"Learning: state vector length")
  assert(type(state.names)=="table" and #state.names==schema.stateDimension,"Learning: state names length")
  for j=1,schema.stateDimension do
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
 local schema={variant=options.variant or "raw",contextMode=options.contextMode or "full",rawDimension=#f.raw,rawNames=clone(f.names),rawIndices={},inputNames={},stateDimension=0,stateNames={},memoryDimension=0,memoryNames={}}
 assert(VARIANTS[schema.variant],"Learning: unknown variant")
 assert(schema.contextMode=="full" or schema.contextMode=="reduced","Learning: context mode")
 assert(schema.contextMode~="reduced" or schema.variant=="raw","Learning: reduced context only supports raw comparison")
 for j,name in f.names do
  assert(type(name)=="string","Learning: feature name")
  if schema.contextMode=="full" or not slower(name) then
   schema.rawIndices[#schema.rawIndices+1]=j;schema.inputNames[#schema.inputNames+1]=name
  end
 end
 if schema.variant=="memory" then
  assert(type(f.memory)=="table" and type(f.memoryNames)=="table" and #f.memory>0 and #f.memory==#f.memoryNames,"Learning: memory schema required")
  schema.memoryDimension=#f.memory;schema.memoryNames=clone(f.memoryNames)
  for _,name in f.memoryNames do assert(type(name)=="string","Learning: memory feature name");schema.inputNames[#schema.inputNames+1]="memory:"..name end
 elseif schema.variant~="raw" then
  local state=record.states and record.states[schema.variant]
  assert(state and type(state.names)=="table" and type(state.vector)=="table" and #state.names>0 and #state.names==#state.vector,"Learning: state schema required")
  schema.stateDimension=#state.vector
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
local function standardize(model,x)
 local z=table.create(#x,0)
 local clipping={clippedValues=0,clippedFeatures={},maxAbsRawZ=0,maxAbsStandardized=0,overflowValues=0}
 for _,j in model.activeIndices do
  local raw=(x[j]-model.means[j])/model.scales[j]
  local bounded=math.clamp(raw,-model.clipZ,model.clipZ);z[j]=bounded
  if finite(raw) then clipping.maxAbsRawZ=math.max(clipping.maxAbsRawZ,math.abs(raw)) else clipping.overflowValues+=1 end
  clipping.maxAbsStandardized=math.max(clipping.maxAbsStandardized,math.abs(bounded))
  if raw~=bounded then
   clipping.clippedValues+=1
   clipping.clippedFeatures[#clipping.clippedFeatures+1]={index=j,name=model.inputNames[j],rawZ=if finite(raw) then raw else nil,standardized=bounded,overflow=not finite(raw)}
  end
 end
 return z,clipping
end
local function clippedSamples(samples,model)
 local totals={rows=#samples,clippedRows=0,clippedValues=0,byFeature=table.create(#model.inputNames,0),maxAbsRawZ=0,maxAbsStandardized=0,overflowValues=0}
 for _,sample in samples do
  local z,clipping=standardize(model,sample.x);sample.z=z
  if clipping.clippedValues>0 then totals.clippedRows+=1 end
  totals.clippedValues+=clipping.clippedValues;totals.overflowValues+=clipping.overflowValues
  totals.maxAbsRawZ=math.max(totals.maxAbsRawZ,clipping.maxAbsRawZ)
  totals.maxAbsStandardized=math.max(totals.maxAbsStandardized,clipping.maxAbsStandardized)
  for _,feature in clipping.clippedFeatures do totals.byFeature[feature.index]+=1 end
 end
 return totals
end
local function predictStandardized(model,z)
 local values={}
 for h=1,3 do
  local s=model.weights[h][1]
  for _,j in model.activeIndices do s+=model.weights[h][j+1]*z[j] end
  assert(finite(s),"Learning: non-finite prediction");values[h]=s
 end
 return values
end
local function relativeMSE(loss,baseline)
 if baseline>0 then local ratio=loss/baseline;return ratio,1-ratio,"positive_baseline" end
 if loss==0 then return 1,0,"both_zero" end
 return nil,nil,"zero_baseline_model_error"
end
function Learning.fit(records,options)
 assert(type(options)=="table" and finite(options.trainEndT) and finite(options.validationEndT) and options.trainEndT<options.validationEndT,"Learning: ordered split cutoffs required")
 local report={status="insufficient_samples",scope="historical exploratory research; earlier date ranges have already been inspected",schemaVersion=SCHEMA_VERSION,version=3,cutoffs={trainEndT=options.trainEndT,validationEndT=options.validationEndT},samples={train=0,validation=0},minimum={train=128,validation=32},validationLosses={},labelHorizon=6,labelEntry="next bar open",labelAvailability="sixth future bar start + 300; <= split cutoff",rejectedLabels=0,selectionScope="validation labels only; mask, normalization and ridge coefficients use training labels only",ridgeCandidates={0.1,1,10}}
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
 report.dimensions={raw=schema.rawDimension,memory=schema.memoryDimension,state=schema.stateDimension,design=dimension}
 local means,scales,activeIndices,activeMask={},{},{},{}
 local preprocessing={schemaVersion="train-mask-clip-v1",trainingOnly=true,absoluteStdFloor=ABSOLUTE_STD_FLOOR,relativeStdFloor=RELATIVE_STD_FLOOR,clipZ=CLIP_Z,
  absoluteUnits="input feature coordinate units; returns/probabilities/log activity and normalized mechanics are dimensionless",relativeReference="training RMS = sqrt(training mean^2 + population variance)",
  activeCriterion="training population std > max(absoluteStdFloor, relativeStdFloor * training RMS)",originalDimension=dimension,activeDimension=0,featureStats={},droppedFeatures={}}
 for j=1,dimension do
  local mean,m2=0,0
  for n,sample in train do local delta=sample.x[j]-mean;mean+=delta/n;m2+=delta*(sample.x[j]-mean) end
  local std=math.sqrt(math.max(0,m2/#train));local rms=math.sqrt(mean^2+std^2)
  local threshold=math.max(ABSOLUTE_STD_FLOOR,RELATIVE_STD_FLOOR*rms)
  local active=std>threshold
  means[j]=mean;scales[j]=if active then std else 1;activeMask[j]=active
  local details={index=j,name=schema.inputNames[j],mean=mean,std=std,rms=rms,threshold=threshold,active=active}
  preprocessing.featureStats[j]=details
  if active then activeIndices[#activeIndices+1]=j else
   details.reason=if std<=ABSOLUTE_STD_FLOOR then "absolute_near_zero_variance" else "relative_near_zero_variance"
   preprocessing.droppedFeatures[#preprocessing.droppedFeatures+1]=clone(details)
  end
 end
 local activeDimension=#activeIndices;preprocessing.activeDimension=activeDimension
 preprocessing.activeIndices=clone(activeIndices);preprocessing.activeMask=clone(activeMask)
 report.dimensions.active=activeDimension
 local transform={means=means,scales=scales,activeIndices=activeIndices,inputNames=schema.inputNames,clipZ=CLIP_Z}
 preprocessing.trainingClipping=clippedSamples(train,transform)
 preprocessing.validationClipping=clippedSamples(validation,transform)
 report.preprocessing=preprocessing
 local zMeans=table.create(activeDimension,0)
 for n,sample in train do for k,j in activeIndices do zMeans[k]+=(sample.z[j]-zMeans[k])/n end end
 local targetMeans={0,0,0}
 for n,sample in train do for h=1,3 do targetMeans[h]+=(sample.y[h]-targetMeans[h])/n end end
 local gram,rhs={},{}
 for j=1,activeDimension do gram[j]=table.create(activeDimension,0);rhs[j]={0,0,0} end
 for _,sample in train do
  local z={};for k,j in activeIndices do z[k]=sample.z[j]-zMeans[k] end
  for j=1,activeDimension do
   for k=1,activeDimension do gram[j][k]+=z[j]*z[k] end
   for h=1,3 do rhs[j][h]+=z[j]*(sample.y[h]-targetMeans[h]) end
  end
 end
 local diversity={scope="training matured-label rows only",stateDimensions=schema.stateDimension,activeDimensions=0,effectiveDimension=0,definition="participation ratio of retained, clipped, centered training state covariance; not an independent-predictive-factor count"}
 local trace,squaredTrace=0,0
 local firstState=#schema.rawIndices+schema.memoryDimension+1
 for j,originalJ in activeIndices do
  if originalJ>=firstState then
   if gram[j][j]>1e-8 then diversity.activeDimensions+=1 end
   trace+=gram[j][j]/#train
   for k,originalK in activeIndices do if originalK>=firstState then squaredTrace+=(gram[j][k]/#train)^2 end end
  end
 end
 if squaredTrace>0 then diversity.effectiveDimension=trace^2/squaredTrace end
 report.trainingDiversity=diversity
 local zeroLosses={0,0,0}
 for _,sample in validation do for h=1,3 do zeroLosses[h]+=sample.y[h]^2/#validation end end
 report.validationBaseline={predictor="zero",meanMSE=zeroLosses[1],upsideMSE=zeroLosses[2],downsideMSE=zeroLosses[3],samples=#validation,scope="same matured validation labels as ridge candidates"}
 report.validationZeroMeanMSE=zeroLosses[1]
 local best,bestLoss=nil,math.huge
 for _,lambda in {0.1,1,10} do
  local matrix=clone(gram);for j=1,activeDimension do matrix[j][j]+=lambda end
  local slopes=solve(matrix,rhs)
  local model=clone(schema)
  model.status="ok";model.schemaVersion=report.schemaVersion;model.version=3;model.means=clone(means);model.scales=clone(scales);model.lambda=lambda;model.weights={}
  model.activeIndices=clone(activeIndices);model.activeMask=clone(activeMask);model.effectiveDimension=activeDimension;model.clipZ=CLIP_Z;model.preprocessing=clone(preprocessing)
  for h=1,3 do
   model.weights[h]=table.create(dimension+1,0);model.weights[h][1]=targetMeans[h]
   for k,j in activeIndices do model.weights[h][j+1]=slopes[h][k];model.weights[h][1]-=slopes[h][k]*zMeans[k] end
  end
  local losses={0,0,0}
  for _,sample in validation do
   local pred=predictStandardized(model,sample.z)
   for h=1,3 do losses[h]+=(pred[h]-sample.y[h])^2/#validation end
  end
  local entry={lambda=lambda,meanMSE=losses[1],upsideMSE=losses[2],downsideMSE=losses[3]}
  entry.meanMseRatioToZero,entry.meanMseSkillToZero,entry.zeroComparisonStatus=relativeMSE(losses[1],zeroLosses[1])
  report.validationLosses[#report.validationLosses+1]=entry
  if losses[1]<bestLoss then bestLoss=losses[1];best=model end
 end
 report.status="ok";report.selectedLambda=best.lambda;report.validationMeanMSE=bestLoss
 report.validationMseRatioToZero,report.validationMseSkillToZero,report.validationZeroComparisonStatus=relativeMSE(bestLoss,zeroLosses[1])
 report.sampleRanges={train={firstT=train[1].t,lastT=train[#train].t,lastLabelAvailableT=train[#train].labelAvailableT},validation={firstT=validation[1].t,lastT=validation[#validation].t,lastLabelAvailableT=validation[#validation].labelAvailableT}}
 best.cutoffs=clone(report.cutoffs);best.samples=clone(report.samples);best.validationLosses=clone(report.validationLosses);best.sampleRanges=clone(report.sampleRanges);best.scope=report.scope
 best.provenance=clone(report.provenance);best.newNativeSteps=0;best.readoutOnly=true
 best.trainingDiversity=clone(report.trainingDiversity)
 best.validationMeanMSE=report.validationMeanMSE;best.validationZeroMeanMSE=report.validationZeroMeanMSE
 best.validationMseRatioToZero=report.validationMseRatioToZero;best.validationMseSkillToZero=report.validationMseSkillToZero
 best.validationZeroComparisonStatus=report.validationZeroComparisonStatus;best.validationBaseline=clone(report.validationBaseline)
 return best,report
end
function Learning.predict(model,record)
 if model==nil or model.status~="ok" then return nil end
 local x=design(record,model);local z,clipping=standardize(model,x);local p=predictStandardized(model,z)
 local contributions={{name="intercept",value=model.weights[1][1]}}
 for j,name in model.inputNames do contributions[#contributions+1]={name=name,value=model.weights[1][j+1]*z[j],active=model.activeMask[j],standardized=z[j]} end
 local upside,downside=math.max(0,p[2]),math.max(0,p[3])
 return {mean=p[1],upside=upside,downside=downside,contributions=contributions,standardizedFeatures=z,clipping=clipping,score=p[1]/math.max(1e-9,upside+downside),scoreKind="signed_mean_to_expected_excursion_ratio",isProbability=false,excursionKind="expected_magnitude_not_barrier_probability"}
end
function Learning.serialize(model) return clone(model) end
function Learning.deserialize(artifact)
 assert(type(artifact)=="table" and artifact.status=="ok" and artifact.schemaVersion==SCHEMA_VERSION,"Learning: invalid model artifact")
 local m=clone(artifact);local n=#m.inputNames
 assert(VARIANTS[m.variant] and #m.weights==3 and #m.means==n and #m.scales==n and #m.rawNames==m.rawDimension,"Learning: artifact dimensions")
 assert(finite(m.stateDimension) and m.stateDimension>=0 and m.stateDimension%1==0 and #m.stateNames==m.stateDimension,"Learning: artifact state dimensions")
 assert(finite(m.memoryDimension) and m.memoryDimension>=0 and m.memoryDimension%1==0 and #m.memoryNames==m.memoryDimension,"Learning: artifact memory dimensions")
 assert((m.variant=="raw" and m.stateDimension==0 and m.memoryDimension==0) or (m.variant=="memory" and m.stateDimension==0 and m.memoryDimension>0) or (m.variant~="raw" and m.variant~="memory" and m.stateDimension>0 and m.memoryDimension==0),"Learning: artifact variant dimensions")
 assert(#m.rawIndices+m.stateDimension+m.memoryDimension==n,"Learning: artifact design dimensions")
 assert(type(m.activeMask)=="table" and #m.activeMask==n and type(m.activeIndices)=="table" and m.effectiveDimension==#m.activeIndices and m.clipZ==CLIP_Z,"Learning: artifact preprocessing dimensions")
 local retained={};local previous=0
 for _,j in m.activeIndices do assert(j%1==0 and j>previous and j<=n and m.activeMask[j]==true,"Learning: artifact active indices");retained[j]=true;previous=j end
 for j=1,n do assert(type(m.activeMask[j])=="boolean" and m.activeMask[j]==(retained[j]==true),"Learning: artifact active mask") end
 for j=1,n do assert(finite(m.means[j]) and finite(m.scales[j]) and m.scales[j]>0,"Learning: artifact scaler") end
 for h=1,3 do
  assert(#m.weights[h]==n+1,"Learning: artifact weights");for _,w in m.weights[h] do assert(finite(w),"Learning: artifact finite weights") end
  for j=1,n do if not m.activeMask[j] then assert(m.weights[h][j+1]==0,"Learning: dropped predictor coefficient") end end
 end
 for _,j in m.rawIndices do assert(j>=1 and j<=m.rawDimension and j%1==0,"Learning: artifact raw index") end
 return m
end
return Learning
