local Json=require('./Json')
local Study=require('./src/Study')
local Learning=require('./src/Learning')
local Memory=require('./Memory')
local input=require('./Input')
local original={}
for _,record in require('./data/Records0001') do original[#original+1]=record end
for _,record in require('./data/Records0002') do original[#original+1]=record end
for _,record in require('./data/Records0003') do original[#original+1]=record end
for _,record in require('./data/Records0004') do original[#original+1]=record end
for _,record in require('./data/Records0005') do original[#original+1]=record end
for _,record in require('./data/Records0006') do original[#original+1]=record end
for _,record in require('./data/Records0007') do original[#original+1]=record end
for _,record in require('./data/Records0008') do original[#original+1]=record end
for _,record in require('./data/Records0009') do original[#original+1]=record end
for _,record in require('./data/Records0010') do original[#original+1]=record end
for _,record in require('./data/Records0011') do original[#original+1]=record end
for _,record in require('./data/Records0012') do original[#original+1]=record end
for _,record in require('./data/Records0013') do original[#original+1]=record end
for _,record in require('./data/Records0014') do original[#original+1]=record end
for _,record in require('./data/Records0015') do original[#original+1]=record end
for _,record in require('./data/Records0016') do original[#original+1]=record end
for _,record in require('./data/Records0017') do original[#original+1]=record end
for _,record in require('./data/Records0018') do original[#original+1]=record end
for _,record in require('./data/Records0019') do original[#original+1]=record end
for _,record in require('./data/Records0020') do original[#original+1]=record end
for _,record in require('./data/Records0021') do original[#original+1]=record end
for _,record in require('./data/Records0022') do original[#original+1]=record end
for _,record in require('./data/Records0023') do original[#original+1]=record end
for _,record in require('./data/Records0024') do original[#original+1]=record end
for _,record in require('./data/Records0025') do original[#original+1]=record end
for _,record in require('./data/Records0026') do original[#original+1]=record end
for _,record in require('./data/Records0027') do original[#original+1]=record end
for _,record in require('./data/Records0028') do original[#original+1]=record end
for _,record in require('./data/Records0029') do original[#original+1]=record end
for _,record in require('./data/Records0030') do original[#original+1]=record end
for _,record in require('./data/Records0031') do original[#original+1]=record end
for _,record in require('./data/Records0032') do original[#original+1]=record end
for _,record in require('./data/Records0033') do original[#original+1]=record end
for _,record in require('./data/Records0034') do original[#original+1]=record end
for _,record in require('./data/Records0035') do original[#original+1]=record end
for _,record in require('./data/Records0036') do original[#original+1]=record end
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
local study={version='roalgo-study-v3',phase='complete',scope='Readout-only refit of previously inspected legacy v2 saved native history; no new native capture or holdout claim',
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
