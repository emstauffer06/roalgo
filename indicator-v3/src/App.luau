-- Rolling research controller; all feature transforms, physics and training run in Luau.
local Features=if script then require(script.Parent.Features) else require("./Features")
local Engine=if script then require(script.Parent.Engine) else require("./Engine")
local Study=if script then require(script.Parent.Study) else require("./Study")
local Dashboard=if script then require(script.Parent.Dashboard) else require("./Dashboard")
local PhysicsView=if script then require(script.Parent.PhysicsView) else require("./PhysicsView")
local Http=game:GetService("HttpService")
local CoreGui=game:GetService("CoreGui")
local BASE="http://127.0.0.1:47624"
local PROFILES={{20,5,5},{40,10,10},{80,20,20}}
local VARIANTS={"coupled","independent","numeric","raw","memory","zero"}
local CONFIGURATIONS={
 {id="grouped24",nodeCount=24,topology="grouped",response="diverse"},
 {id="grouped48",nodeCount=48,topology="grouped",response="diverse"},
}
local App={}
local function hashes()
 local result={}
 for _,m in script.Parent.Parent:GetDescendants() do
  if m:IsA("ModuleScript") then local h=m:FindFirstChild("SourceSHA256");result[m.Parent.Name.."/"..m.Name]=m:GetAttribute("sha256") or (h and h.Value) end
 end
 return result
end
local function save(name,result)
 local body=Http:JSONEncode({name=name,result=result})
 assert(#body<=64*1024*1024,"RoAlgo export exceeds bridge body limit")
 local response=Http:RequestAsync({Url=BASE.."/result",Method="POST",Headers={["Content-Type"]="application/json"},Body=body})
 assert(response.Success,"RoAlgo export: "..response.Body)
 return Http:JSONDecode(response.Body)
end
local function savedReference(receipt)
 assert(type(receipt)=="table" and type(receipt.path)=="string","Missing saved artifact receipt")
 local name=string.match(receipt.path,"([^/\\]+)$")
 assert(name and #name<=105 and string.match(name,"^[%w_-]+%.json$"),"Invalid saved artifact basename")
 assert(type(receipt.sha256)=="string" and #receipt.sha256==64 and string.match(receipt.sha256,"^[a-f0-9]+$"),"Invalid saved artifact hash")
 return {name=name,sha256=receipt.sha256}
end
local function readReference(reference)
 assert(type(reference)=="table","Missing artifact reference")
 local safe=savedReference({path=reference.name,sha256=reference.sha256})
 assert(safe.name==reference.name,"Artifact reference must be a basename")
 return Http:JSONDecode(Http:GetAsync(BASE.."/saved?name="..safe.name.."&sha256="..safe.sha256))
end
local function foldReference(fold)
 assert(fold.phase=="complete" and fold.saved,"Completed fold lacks saved artifact")
 return {id=fold.id,foldId=fold.foldId,foldIndex=fold.foldIndex,configurationId=fold.configurationId,
  phase=fold.phase,endDate=fold.endDate,dataHash=fold.metadata.dataHash,saved=table.clone(fold.saved)}
end
local function studyManifest(result)
 local out=table.clone(result);out.storage="fold-references-v1";out.folds={}
 for _,fold in result.folds do out.folds[#out.folds+1]=foldReference(fold)end
 return out
end
local function partialFold(fold)
 if not fold then return nil end
 return {id=fold.id,foldId=fold.foldId,foldIndex=fold.foldIndex,configurationId=fold.configurationId,configuration=fold.configuration,
  phase=fold.phase,error=fold.error,completed=fold.completed,total=fold.total,native=fold.native,
  metadata=fold.metadata,split=fold.split,cacheChunks=fold.cacheChunks,saved=fold.saved}
end
local function exportFold(runName,fold)
 local out=table.clone(fold);out.version="roalgo-fold-v3";out.storage="checkpoint-references-v1"
 out.replayCount=#fold.replayRecords;out.replayRecords=nil;out.saved=nil;out.comparisons={}
 for _,comparison in fold.comparisons do
  local stored=table.clone(comparison);stored.storage="row-references-v1";stored.result=table.clone(comparison.result)
  stored.result.rows=nil;stored.result.rowCount=#comparison.result.rows;stored.result.rowChunks={}
  for startIndex=1,#comparison.result.rows,128 do
   local rows={};local lastIndex=math.min(startIndex+127,#comparison.result.rows)
   for i=startIndex,lastIndex do rows[#rows+1]=comparison.result.rows[i]end
   local chunkIndex=#stored.result.rowChunks+1
   local receipt=save(runName.."_"..fold.id.."_"..comparison.id.."_rows_"..string.format("%04d",chunkIndex),{
    version="roalgo-rows-v3",foldId=fold.foldId,configurationId=fold.configurationId,comparisonId=comparison.id,
    dataHash=fold.metadata.dataHash,firstIndex=startIndex,lastIndex=lastIndex,rows=rows})
   local reference=savedReference(receipt);reference.firstIndex=startIndex;reference.lastIndex=lastIndex
   stored.result.rowChunks[#stored.result.rowChunks+1]=reference
  end
  out.comparisons[#out.comparisons+1]=stored
 end
 return out
end
local function hydrateFold(fold)
 if fold.storage~="checkpoint-references-v1" then assert(fold.storage==nil,"Unknown fold storage format");return fold end
 local out=table.clone(fold);out.replayRecords={};out.comparisons={}
 local previousT=-math.huge
 for _,receipt in fold.cacheChunks do
  if not receipt.lastT or receipt.lastT>=fold.split.testStartT then
   local chunk=readReference(savedReference(receipt))
   assert(chunk.version=="roalgo-states-v3" and chunk.foldId==fold.foldId and chunk.configurationId==fold.configurationId,"Mismatched replay checkpoint identity")
   assert(chunk.metadata.dataHash==fold.metadata.dataHash and chunk.split.testStartT==fold.split.testStartT,"Mismatched replay checkpoint data")
   assert(#chunk.records==chunk.lastIndex-chunk.firstIndex+1,"Incomplete replay checkpoint")
   for _,record in chunk.records do if record.bar.t>=fold.split.testStartT then
    assert(record.bar.t>previousT,"Replay checkpoint timestamps overlap or regress")
    previousT=record.bar.t;out.replayRecords[#out.replayRecords+1]=record
   end end
  end
 end
 assert(#out.replayRecords==fold.replayCount,"Incomplete replay checkpoint coverage")
 for _,comparison in fold.comparisons do
  if comparison.storage=="row-references-v1" then
   local c=table.clone(comparison);c.result=table.clone(comparison.result);c.result.rows={}
   for _,reference in comparison.result.rowChunks do
    local chunk=readReference(reference)
    assert(chunk.version=="roalgo-rows-v3" and chunk.foldId==fold.foldId and chunk.configurationId==fold.configurationId and chunk.comparisonId==comparison.id,"Mismatched comparison row identity")
    assert(chunk.dataHash==fold.metadata.dataHash and chunk.firstIndex==#c.result.rows+1 and chunk.lastIndex==chunk.firstIndex+#chunk.rows-1,"Incomplete comparison row coverage")
    assert(chunk.firstIndex==reference.firstIndex and chunk.lastIndex==reference.lastIndex,"Mismatched comparison row boundaries")
    for _,row in chunk.rows do c.result.rows[#c.result.rows+1]=row end
   end
   assert(#c.result.rows==comparison.result.rowCount,"Incomplete comparison rows")
   out.comparisons[#out.comparisons+1]=c
  else assert(comparison.storage==nil,"Unknown comparison storage format");out.comparisons[#out.comparisons+1]=comparison end
 end
 return out
end
local function hydrateStudy(value)
 assert(value.version=="roalgo-study-v3" and value.phase=="complete","Expected a completed v3 study")
 assert(#value.folds==#value.foldDescriptors*#value.configurations and #value.folds>0,"Incomplete saved study")
 assert(value.storage==nil or value.storage=="fold-references-v1","Unknown study storage format")
 local out=table.clone(value);out.folds={};local seen={}
 for _,reference in value.folds do
  local fold=reference
  if value.storage=="fold-references-v1" then
   fold=readReference(reference.saved)
   assert(fold.version=="roalgo-fold-v3" and fold.id==reference.id and fold.foldId==reference.foldId and fold.foldIndex==reference.foldIndex and fold.configurationId==reference.configurationId,"Mismatched saved fold identity")
   assert(fold.metadata.dataHash==reference.dataHash,"Mismatched saved fold data")
  end
  local comparisonCount=#fold.comparisons
  assert(fold.phase=="complete" and (comparisonCount==6 or (value.storage==nil and comparisonCount==5)),"Incomplete saved fold")
  local descriptor=value.foldDescriptors[fold.foldIndex];local config
  for _,c in value.configurations do if c.id==fold.configurationId then config=c end end
  assert(config and descriptor and descriptor.id==fold.foldId and fold.id==fold.configurationId.."_"..fold.foldId and not seen[fold.id],"Invalid or duplicate saved fold selection")
  seen[fold.id]=true;out.folds[#out.folds+1]=hydrateFold(fold)
 end
 return out
end
local function query(path,values)
 local keys={};for key in values do keys[#keys+1]=key end;table.sort(keys)
 local pairs={};for _,key in keys do pairs[#pairs+1]=key.."="..tostring(values[key])end
 return BASE..path.."?"..table.concat(pairs,"&")
end
function App.start(options)
 options=options or {}
 assert(game.PlaceId==0,"RoAlgo Market Lab targets the RoAlgo place")
 assert(not game:GetService("RunService"):IsRunning(),"Use Edit mode for verified native stepping")
 for _,name in {"RoAlgoIndicatorControl","RoAlgoResearchControl"} do
  local old=CoreGui:FindFirstChild(name);if old then assert(not old:Invoke("status").busy,"Wait for existing RoAlgo run to finish")end
 end
 if options.engine then
  local e=options.engine
  assert(type(e)=="table" and not e.busy and not e.destroyed and typeof(e.model)=="Instance" and e.model:IsDescendantOf(workspace),"Invalid idle presentation engine")
 end
 local previous=CoreGui:FindFirstChild("RoAlgoMarketControl")
 if previous then assert(not previous:Invoke("status").busy,"Stop existing run before reloading");previous:Invoke("destroy")end
 for _,name in {"RoAlgoDashboard","RoAlgoResearchDashboard"}do local old=CoreGui:FindFirstChild(name);if old then old.Enabled=false end end
 local control=Instance.new("BindableFunction");control.Name="RoAlgoMarketControl"
 local statusValue=Instance.new("StringValue");statusValue.Name="RoAlgoMarketStatus"
 local status={phase="ready",busy=false,symbol="SPY",profile=3,endDate="2024-12-31",completed=0,total=0,
  selectedVariant="coupled",selectedFold=1,selectedConfiguration="grouped24",placeId=game.PlaceId}
 local ui,currentResult
 local engine=options.engine
 local cancelled,destroyed=false,false
 local function publish()if statusValue.Parent then statusValue.Value=Http:JSONEncode(status)end end
 local function message(value)status.message=value;if ui then ui:setStatus(value)end;publish()end
 local function selectedFold()
  for _,fold in currentResult and currentResult.folds or {}do
   if fold.foldIndex==status.selectedFold and fold.configurationId==status.selectedConfiguration then return fold end
  end
 end
 local function selected()
  local fold=selectedFold()
  for _,choice in fold and fold.comparisons or {}do if choice.id==status.selectedVariant then return choice,fold end end
  return nil,fold
 end
 local function render()
  local choice,fold=selected()
  ui:render({symbol=status.symbol,phase=status.phase,selectedVariant=status.selectedVariant,
   selectedFold=status.selectedFold,selectedConfiguration=status.selectedConfiguration,study=currentResult,
   comparisons=fold and fold.comparisons or {},rows=choice and choice.result.rows or {},
   latestRecord=fold and fold.replayRecords[#fold.replayRecords],metadata=fold and fold.metadata or status.metadata,
   split=fold and fold.split or status.split,message=status.message})
 end
 local function syncSelection()
  local choice,fold=selected()
  if fold then status.metadata=fold.metadata;status.split=fold.split;status.native=fold.native;status.evaluationBars=#(choice and choice.result.rows or {});status.models=#fold.comparisons end
  render();publish()
 end
 local function viewRig()
  local model=engine and engine.model
  local savedPresentation=false
  if not model and currentResult and currentResult.readoutOnly then
   model=workspace:FindFirstChild("RoAlgoResearchPhysics");savedPresentation=model~=nil
  end
  if model and model.Parent then
   -- Fixed keeps Studio's editor camera controls active after framing the rig.
   local camera=workspace.CurrentCamera;camera.CameraType=Enum.CameraType.Fixed
   camera.FieldOfView=model:GetAttribute("ViewFieldOfView") or 70
   camera.Focus=CFrame.new(model:GetAttribute("FocusPosition"))
   camera.CFrame=CFrame.lookAt(model:GetAttribute("ViewPosition"),model:GetAttribute("FocusPosition"))
   ui:setCollapsed(true)
   if savedPresentation then message("Existing v2 presentation / saved-state readout refit / no new physics stepping")end
  else message("No native rig in this session. Run a capture to create one.")end
 end
 local function run(symbol,profile,endDate,settings)
  if status.busy or destroyed then return false end
  symbol=symbol or status.symbol;profile=profile or status.profile;endDate=endDate or status.endDate;settings=settings or {}
  assert(symbol=="SPY" or symbol=="QQQ","Select SPY or QQQ");assert(PROFILES[profile],"Invalid profile")
  assert(type(endDate)=="string" and string.match(endDate,"^%d%d%d%d%-%d%d%-%d%d$"),"Use YYYY-MM-DD")
  local p=PROFILES[profile]
  local foldCount=settings.foldCount or 3;local stride=settings.stride or 60
  assert(foldCount>=1 and foldCount<=6 and foldCount%1==0,"foldCount must be 1..6")
  assert(stride>=p[3] and stride%1==0,"stride must cover the evaluation window")
  local configurations={}
  for _,c in CONFIGURATIONS do if not settings.nodeCount or settings.nodeCount==c.nodeCount then configurations[#configurations+1]=table.clone(c)end end
  assert(#configurations>0,"nodeCount must be 24 or 48")
  local runName="RoAlgoV3_"..symbol.."_"..DateTime.now().UnixTimestampMillis
  currentResult={version="roalgo-study-v3",phase="loading",scope="exploratory rolling research; no untouched holdout claim",
   symbol=symbol,profile=profile,endDate=endDate,configurations=configurations,foldDescriptors={},folds={},receipts={},
   sourceHashes=hashes(),completed=0,total=0,totalNativeSteps=0,foldCount=foldCount,stride=stride,studioVersion=version(),placeId=game.PlaceId}
  status={phase="loading",busy=true,symbol=symbol,profile=profile,endDate=endDate,completed=0,total=0,totalNativeSteps=0,
   selectedVariant="coupled",selectedFold=1,selectedConfiguration=configurations[1].id,completedFolds=0,totalFolds=foldCount*#configurations,placeId=game.PlaceId}
  cancelled=false;ui:setSelection(symbol,profile,endDate);ui:clear();message("Loading chronological study windows")
  task.spawn(function()
   local runEngine,currentFold
   local records,pending={},{}
   local nativeBeforeFold=0
   local function checkCancelled()if cancelled or destroyed then error("Study cancelled")end end
   local function checkpoint()
    if #pending==0 then return end
    local index=#currentFold.cacheChunks+1
    local receipt=save(runName.."_"..currentFold.id.."_states_"..string.format("%04d",index),{
     version="roalgo-states-v3",foldId=currentFold.foldId,configurationId=currentFold.configurationId,
     configuration=currentFold.configuration,metadata=currentFold.metadata,split=currentFold.split,sourceHashes=currentResult.sourceHashes,
     firstIndex=#records-#pending+1,lastIndex=#records,records=pending,native=runEngine:stats()})
    receipt.firstIndex=#records-#pending+1;receipt.lastIndex=#records;receipt.firstT=pending[1].bar.t;receipt.lastT=pending[#pending].bar.t
    currentFold.cacheChunks[#currentFold.cacheChunks+1]=receipt;pending={}
   end
   local ok,err=pcall(function()
    local plan=Http:JSONDecode(Http:GetAsync(query("/folds",{symbol=symbol,train=p[1],validation=p[2],test=p[3],["end"]=endDate,count=foldCount,stride=stride})))
    checkCancelled();assert(plan.folds and #plan.folds>0,"Bridge returned no folds")
    currentResult.foldDescriptors=plan.folds;currentResult.foldPlanMetadata=plan.metadata
    status.totalFolds=#plan.folds*#configurations
    local datasets,total={},0
    for foldIndex,descriptor in plan.folds do
     local dataset=Http:JSONDecode(Http:GetAsync(query("/dataset",{symbol=symbol,train=p[1],validation=p[2],test=p[3],["end"]=descriptor.endDate})))
     checkCancelled();assert(dataset.bars and #dataset.bars>0,"Bridge returned no bars")
     datasets[foldIndex]=dataset;total+=#dataset.bars*#configurations
    end
    currentResult.total=total;status.total=total;publish()
    for foldIndex,descriptor in plan.folds do
     local dataset=datasets[foldIndex]
     for _,configuration in configurations do
      checkCancelled();nativeBeforeFold=currentResult.totalNativeSteps;records={};pending={}
      currentFold={id=configuration.id.."_"..descriptor.id,foldId=descriptor.id,foldIndex=foldIndex,
       configurationId=configuration.id,configuration=configuration,phase="capturing",metadata=dataset.metadata,split=dataset.split,
       completed=0,total=#dataset.bars,sourceHashes=currentResult.sourceHashes,cacheChunks={},comparisons={},replayRecords={},endDate=descriptor.endDate}
      status.selectedFold=foldIndex;status.selectedConfiguration=configuration.id;status.phase="capturing";status.native=nil
      status.metadata=dataset.metadata;status.split=dataset.split
      local featureBuilder=Features.new(dataset.prehistory,{symbol=symbol})
      if engine then engine:destroy();engine=nil end
      local config=table.clone(configuration);config.name="RoAlgoMarketPhysics"
      runEngine=Engine.new(workspace,config);engine=runEngine
      if engine.model then engine.model:SetAttribute("CaptureIdentity",currentFold.id)end
      PhysicsView.mount(engine.model);ui:clear()
      message("Capturing "..configuration.id.." / fold "..foldIndex.." of "..#plan.folds)
      for i,bar in dataset.bars do
       checkCancelled()
       local feature=featureBuilder:step(bar)
       local state=runEngine:step(feature.drive,feature.reset)
       local record={bar=bar,feature=feature,states=state}
       records[#records+1]=record;pending[#pending+1]=record
       currentFold.completed=i;currentResult.completed+=1;status.completed=currentResult.completed
       if i%5==0 or i==#dataset.bars then
        ui:append({t=bar.t,close=bar.c,signal="OBSERVE"},record);ui:setProgress(status.completed,status.total)
        status.native=runEngine:stats();status.totalNativeSteps=nativeBeforeFold+status.native.totalSteps;publish()
       end
       if #pending>=128 then checkpoint()end
      end
      checkpoint();checkCancelled()
      currentFold.native=runEngine:stats();currentFold.featureInfo=featureBuilder:info()
      assert(currentFold.native.totalSteps==#records*12 and currentFold.native.corruptSteps==0,"Native accounting failed")
      currentResult.totalNativeSteps=nativeBeforeFold+currentFold.native.totalSteps;status.totalNativeSteps=currentResult.totalNativeSteps
      currentFold.phase="fitting";status.phase="fitting";message("Training and selecting policies on validation only")
      local evaluation=Study.evaluate(records,dataset.split,{
       cancelled=function()return cancelled or destroyed end,
       onProgress=function(value)message(value);task.wait()end,
       provenance={sourceHashes=currentResult.sourceHashes,metadata=dataset.metadata,native=currentFold.native,
        configuration=configuration,cacheChunks=currentFold.cacheChunks}})
      checkCancelled()
      currentFold.comparisons=evaluation.comparisons;currentFold.selection=evaluation.selection;currentFold.diagnostics=evaluation.diagnostics
      assert(#currentFold.comparisons==6,"All six comparisons including zero forecast are required")
      assert(evaluation.diagnostics.status=="complete" and evaluation.diagnostics.fittedModels==5
       and evaluation.diagnostics.coverage.evaluation.available>0,"Evaluation unavailable: "..tostring(evaluation.diagnostics.status))
      for _,record in records do if record.bar.t>=dataset.split.testStartT then currentFold.replayRecords[#currentFold.replayRecords+1]=record end end
      currentFold.phase="complete"
      local receipt=save(runName.."_"..currentFold.id.."_evaluation",exportFold(runName,currentFold))
      currentFold.saved=savedReference(receipt)
      currentResult.receipts[#currentResult.receipts+1]=receipt
      currentResult.folds[#currentResult.folds+1]=currentFold;currentResult.aggregate=Study.aggregate(currentResult.folds)
      status.completedFolds=#currentResult.folds;syncSelection()
      message("Completed "..status.completedFolds.." / "..status.totalFolds.." configuration/fold captures")
      currentFold=nil;records={};pending={};runEngine=nil
     end
    end
    checkCancelled();assert(#currentResult.folds==status.totalFolds,"Incomplete study")
    currentResult.phase="complete";status.phase="complete"
    local receipt=save(runName,studyManifest(currentResult));status.exportPath=receipt.path;status.exportSHA256=receipt.sha256
    message("Study complete. Independent fold results and native state checkpoints saved.");render()
   end)
   if not ok then
    status.phase=cancelled and "stopped" or "error";currentResult.phase=status.phase;currentResult.error=tostring(err)
    status.native=runEngine and runEngine:stats() or nil
    if status.native then currentResult.totalNativeSteps=nativeBeforeFold+status.native.totalSteps end
    status.totalNativeSteps=currentResult.totalNativeSteps
    if currentFold then
     currentFold.phase=status.phase;currentFold.error=tostring(err);currentFold.native=status.native
     if not table.find(currentResult.folds,currentFold) then currentResult.folds[#currentResult.folds+1]=currentFold end
    end
    currentResult.aggregate=Study.aggregate(currentResult.folds)
    local saved,receipt=pcall(function()
     if runEngine then checkpoint()end
     local completedFolds={};for _,fold in currentResult.folds do if fold.phase=="complete" then completedFolds[#completedFolds+1]=foldReference(fold)end end
     return save(runName.."_partial",{version="roalgo-partial-v3",storage="fold-references-v1",phase=status.phase,error=tostring(err),
      completed=status.completed,total=status.total,native=status.native,totalNativeSteps=currentResult.totalNativeSteps,
      sourceHashes=currentResult.sourceHashes,aggregate=currentResult.aggregate,completedFolds=completedFolds,currentFold=partialFold(currentFold)})
    end)
    if saved then status.exportPath=receipt.path;status.exportSHA256=receipt.sha256;message(status.phase..": "..tostring(err)..". Partial evidence saved.")
    else status.exportError=tostring(receipt);message(status.phase..": "..tostring(err)..". Export failed: "..tostring(receipt))end
   end
   status.busy=false;publish()
  end)
  return true
 end
 local function replay()
  if status.busy or destroyed or not currentResult or currentResult.phase~="complete" then return false end
  local choice,fold=selected();if not choice then return false end
  status.busy=true;status.phase="replay";cancelled=false;ui:clear();publish()
  task.spawn(function()
   local ok,err=pcall(function()
    local byTime={};for _,record in fold.replayRecords do byTime[record.bar.t]=record end
    for _,row in choice.result.rows do if cancelled or destroyed then break end;ui:append(row,byTime[row.t]);task.wait(options.replayDelay or .04)end
   end)
   status.busy=false;status.phase=ok and "complete" or "error"
   message(ok and "Replay complete; zero new physics intervals." or tostring(err));render()
  end)
  return true
 end
 local function variant(id)
  if status.busy then return false end
  assert(table.find(VARIANTS,id),"Unknown model");status.selectedVariant=id;syncSelection();return true
 end
 local function selectFold(index)
  if status.busy or not currentResult then return false end
  assert(index%1==0 and currentResult.foldDescriptors[index],"Unknown fold");status.selectedFold=index;syncSelection();return true
 end
 local function selectConfiguration(id)
  if status.busy or not currentResult then return false end
  local found=false;for _,config in currentResult.configurations do if config.id==id then found=true end end
  assert(found,"Unknown configuration");status.selectedConfiguration=id;syncSelection();return true
 end
 ui=Dashboard.mount(CoreGui,{run=run,stop=function()cancelled=true end,replay=replay,viewRig=viewRig,variant=variant,
  selectFold=selectFold,selectConfiguration=selectConfiguration})
 control.OnInvoke=function(command,...)
  if command=="status" then return status
  elseif command=="nativeStats" then return engine and engine:stats() or nil
  elseif command=="result" then return currentResult
  elseif command=="run" then return run(...)
  elseif command=="stop" then cancelled=true;return true
  elseif command=="replay" then return replay()
  elseif command=="variant" then return variant(...)
  elseif command=="selectFold" then return selectFold(...)
  elseif command=="selectConfiguration" then return selectConfiguration(...)
  elseif command=="viewRig" then viewRig();return true
  elseif command=="inspect" then return ui:inspect()
  elseif command=="testActivate" then return ui:testActivate(...)
  elseif command=="load" then
   if status.busy then return false end
   local name=...;assert(type(name)=="string" and string.match(name,"^[%w_.%-]+%.json$"),"Invalid saved name")
   status.busy=true;publish()
   local ok,result=pcall(function()
    local value=Http:JSONDecode(Http:GetAsync(BASE.."/saved?name="..name))
    return hydrateStudy(value)
   end)
   status.busy=false
   if not ok then publish();error(result)end
   currentResult=result;local first=result.folds[1]
   status={phase="complete",busy=false,symbol=result.symbol,profile=result.profile,endDate=result.endDate,
    completed=result.completed,total=result.total,totalNativeSteps=result.totalNativeSteps,completedFolds=#result.folds,totalFolds=#result.folds,
    selectedVariant="coupled",selectedFold=first.foldIndex,selectedConfiguration=first.configurationId,exportPath=name,placeId=game.PlaceId}
   ui:setSelection(status.symbol,status.profile,status.endDate);syncSelection();message("Loaded completed rolling study");return true
  elseif command=="destroy" then
   assert(not status.busy,"Stop and wait before destroying")
   destroyed=true;if engine then engine:destroy()end;ui:destroy();control:Destroy();statusValue:Destroy();return true
  end
  error("Unknown control command "..tostring(command))
 end
 control.Parent=CoreGui;statusValue.Parent=CoreGui
 message("Ready: longer training history, five fitted models and zero-forecast baseline");render()
 return control
end
return App
