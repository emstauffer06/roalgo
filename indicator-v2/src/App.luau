-- Local research controller. All finance and training run in Luau; native states are captured once.
local Features=require("./Features")
local Engine=require("./Engine")
local Learning=require("./Learning")
local Execution=require("./Execution")
local Dashboard=require("./Dashboard")
local PhysicsView=require("./PhysicsView")
local Http=game:GetService("HttpService")
local CoreGui=game:GetService("CoreGui")
local BASE="http://127.0.0.1:47623"
local PROFILES={{20,5,5},{40,10,10},{80,20,20}}
local VARIANTS={"coupled","independent","numeric","raw","reduced"}
local App={}
local function hashes()
 local result={}
 for _,m in script.Parent.Parent:GetDescendants() do
  if m:IsA("ModuleScript") then local h=m:FindFirstChild("SourceSHA256");result[m.Parent.Name.."/"..m.Name]=m:GetAttribute("sha256") or (h and h.Value) end
 end
 return result
end
local function save(name,result)
 local response=Http:RequestAsync({Url=BASE.."/result",Method="POST",Headers={["Content-Type"]="application/json"},Body=Http:JSONEncode({name=name,result=result})})
 assert(response.Success,"RoAlgo export: "..response.Body)
 return Http:JSONDecode(response.Body)
end
function App.start(options)
 options=options or {}
 assert(game.PlaceId==0,"RoAlgo research targets the RoAlgo place")
 assert(not game:GetService("RunService"):IsRunning(),"Use Edit mode for verified native stepping")
 -- An idle presentation engine can be handed over when reloading the local showcase.
 -- Every new capture still constructs a fresh engine below.
 if options.engine then
  local e=options.engine
  assert(type(e)=="table" and not e.busy and not e.destroyed and typeof(e.model)=="Instance"
   and e.model:IsDescendantOf(workspace),"Invalid idle presentation engine")
 end
 local old=CoreGui:FindFirstChild("RoAlgoIndicatorControl")
 if old then assert(not old:Invoke("status").busy,"Wait for v1 run to finish")end
 local previous=CoreGui:FindFirstChild("RoAlgoResearchControl")
 if previous then assert(not previous:Invoke("status").busy,"Stop existing run before reloading");previous:Invoke("destroy") end
 local oldGui=CoreGui:FindFirstChild("RoAlgoDashboard");if oldGui then oldGui.Enabled=false end
 local control=Instance.new("BindableFunction");control.Name="RoAlgoResearchControl"
 local statusValue=Instance.new("StringValue");statusValue.Name="RoAlgoResearchStatus"
 local status={phase="ready",busy=false,symbol="SPY",profile=1,endDate="2024-12-31",completed=0,total=0,selectedVariant="coupled",placeId=game.PlaceId}
 local ui,currentResult
 local engine=options.engine
 local cancelled,destroyed=false,false
 local function publish()if statusValue.Parent then statusValue.Value=Http:JSONEncode(status)end end
 local function message(value)status.message=value;if ui then ui:setStatus(value)end;publish()end
 local function selected()
  for _,v in currentResult and currentResult.comparisons or {} do if v.id==status.selectedVariant then return v end end
 end
 local function render()
  local choice=selected()
  ui:render({symbol=status.symbol,phase=status.phase,selectedVariant=status.selectedVariant,
   comparisons=currentResult and currentResult.comparisons or {},rows=choice and choice.result.rows or {},
   latestRecord=currentResult and currentResult.replayRecords[#currentResult.replayRecords],
   metadata=currentResult and currentResult.metadata,split=currentResult and currentResult.split,message=status.message})
 end
 local function viewRig()
  local model=engine and engine.model
  if model and model.Parent then
   local camera=workspace.CurrentCamera
   camera.CameraType=Enum.CameraType.Scriptable
   camera.FieldOfView=model:GetAttribute("ViewFieldOfView") or 70
   camera.Focus=CFrame.new(model:GetAttribute("FocusPosition"))
   camera.CFrame=CFrame.lookAt(model:GetAttribute("ViewPosition"),model:GetAttribute("FocusPosition"))
   ui:setCollapsed(true)
  else message("No native rig in this session. Run a capture to create one.")end
 end
 local function run(symbol,profile,endDate)
  if status.busy or destroyed then return false end
  assert(symbol=="SPY" or symbol=="QQQ","Unsupported symbol")
  assert(PROFILES[profile],"Choose a listed chronological profile")
  assert(type(endDate)=="string" and string.match(endDate,"^%d%d%d%d%-%d%d%-%d%d$"),"End date must be YYYY-MM-DD")
  cancelled=false;currentResult=nil
  status={phase="loading",busy=true,hasUI=true,symbol=symbol,profile=profile,endDate=endDate,completed=0,total=0,selectedVariant=status.selectedVariant,placeId=game.PlaceId}
  ui:clear();ui:setSelection(symbol,profile,endDate);render()
  message("Loading cached completed market data…")
  task.spawn(function()
   local data,featureBuilder,records,chunks,pending={},{},{},{},{}
   local runEngine
   local sourceHashes=hashes()
   local runName="RoAlgoV2_"..symbol.."_"..tostring(DateTime.now().UnixTimestampMillis)
   local function checkpoint()
    if #pending==0 then return end
    local receipt=save(runName.."_states_"..string.format("%04d",#chunks+1),{
     version="roalgo-states-v2",scope="captured causal states; not evaluation results",symbol=symbol,
     metadata=data.metadata,split=data.split,sourceHashes=sourceHashes,records=pending,
     firstIndex=status.completed-#pending+1,lastIndex=status.completed,native=runEngine:stats(),studioVersion=version(),placeId=game.PlaceId})
    chunks[#chunks+1]=receipt;pending={}
   end
   local ok,err=xpcall(function()
    local p=PROFILES[profile]
    local url=BASE.."/dataset?symbol="..symbol.."&train="..p[1].."&validation="..p[2].."&test="..p[3].."&end="..endDate
    data=Http:JSONDecode(Http:GetAsync(url))
    assert(#data.bars>0,"No bars in dataset")
    if cancelled then return end
    status.metadata=data.metadata;status.split=data.split;status.total=#data.bars;status.phase="capturing"
    featureBuilder=Features.new(data.prehistory,{symbol=data.metadata.symbol})
    if engine then engine:destroy()end
    engine=Engine.new(workspace,{name="RoAlgoResearchPhysics"});runEngine=engine
    PhysicsView.mount(engine.model)
    ui:render({symbol=symbol,phase="capturing",selectedVariant=status.selectedVariant,comparisons={},metadata=data.metadata,split=data.split})
    message("Capturing "..#data.bars.." bars / 12 verified native intervals each / no trades during capture")
    for i,bar in data.bars do
     if cancelled then break end
     local feature=featureBuilder:step(bar)
     local state=engine:step(feature.drive,feature.reset)
     local rec={bar=bar,feature=feature,states=state}
     records[i]=rec;pending[#pending+1]=rec;status.completed=i
     ui:append({t=bar.t,label=bar.label,close=bar.c,signal="OBSERVE",position=0},rec)
     if i%5==0 or i==#data.bars then
      ui:setProgress(i,#data.bars,"NATIVE CAPTURE");status.native=engine:stats();publish()
     end
     if #pending>=512 then checkpoint()end
    end
    checkpoint();status.native=engine:stats()
    if cancelled then return end
    assert(status.native.totalSteps==#records*12 and status.native.corruptSteps==0,"Native capture counters invalid")
    currentResult={version="roalgo-learned-v2",scope="historical exploratory research; previously inspected period, not an untouched holdout",
     metadata=data.metadata,split=data.split,featureInfo=featureBuilder:info(),sourceHashes=sourceHashes,
     cacheChunks=chunks,native=status.native,completed=#records,total=#data.bars,comparisons={},replayRecords={},
     studioVersion=version(),placeId=game.PlaceId,profile=profile,endDate=endDate,phase="fitting"}
    for _,record in records do if record.bar.t>=data.split.testStartT then table.insert(currentResult.replayRecords,record)end end
    for _,id in VARIANTS do
     if cancelled then break end
     status.phase="fitting";message("Fitting "..id.." readout on training labels; selecting regularization on validation only")
     task.wait()
     local model,report=Learning.fit(records,{trainEndT=data.split.trainEndT,validationEndT=data.split.validationEndT,
      variant=id=="reduced" and "raw" or id,contextMode=id=="reduced" and "reduced" or "full",
      provenance={sourceHashes=sourceHashes,metadata=data.metadata,nativeSteps=status.native.totalSteps,cacheChunks=chunks}})
     assert(model,"Insufficient training/validation samples for "..id)
     local execution=Execution.new()
     for i,record in currentResult.replayRecords do
      execution:step(record.bar,record.feature,Learning.predict(model,record))
      if i%100==0 then task.wait()end
     end
     currentResult.comparisons[#currentResult.comparisons+1]={id=id,model=Learning.serialize(model),report=report,result=execution:result()}
     render()
    end
    if cancelled then return end
    currentResult.phase="complete";status.phase="complete"
    local receipt=save(runName,currentResult);status.exportPath=receipt.path;status.exportSHA256=receipt.sha256
    status.models=#currentResult.comparisons;status.evaluationBars=#currentResult.replayRecords
    message("Complete: "..#records.." captured bars, "..status.evaluationBars.." evaluation bars, five trained models. Costs included; exploratory results.")
    render()
   end,debug.traceback)
   if not ok or cancelled then
    status.phase=cancelled and "stopped" or "error";status.error=not ok and tostring(err) or nil
    if runEngine then status.native=runEngine:stats()end
    local saved,receipt=pcall(function()
     if runEngine then checkpoint()end
     return save(runName.."_partial",{version="roalgo-partial-v2",phase=status.phase,error=status.error,
      completed=status.completed,total=status.total,metadata=data.metadata,split=data.split,sourceHashes=sourceHashes,
      cacheChunks=chunks,native=runEngine and runEngine:stats(),comparisons=currentResult and currentResult.comparisons or {},
      scope="incomplete capture or evaluation; not a completed comparison"})
    end)
    if saved then status.exportPath=receipt.path;status.exportSHA256=receipt.sha256 else status.exportError=tostring(receipt)end
    if currentResult then currentResult.phase=status.phase end
    message((cancelled and "Stopped." or "Error: "..tostring(err))..(saved and " Partial status saved." or " Saving failed: "..tostring(receipt)))
   end
   status.busy=false;publish()
  end)
  return true
 end
 local function replay()
  if status.busy or not currentResult or currentResult.phase~="complete" then return false end
  local choice=selected();if not choice then return false end
  cancelled=false;status.busy=true;status.phase="replay";ui:clear();message("Recorded evaluation replay / no new physics steps")
  task.spawn(function()
   local ok,err=xpcall(function()
    for i,row in choice.result.rows do
     if cancelled then break end
     ui:append(row,currentResult.replayRecords[i]);ui:setProgress(i,#choice.result.rows,"RECORDED REPLAY")
     task.wait(options.replayDelay or .035)
    end
   end,debug.traceback)
   status.busy=false;status.phase=ok and "complete" or "error"
   message(not ok and tostring(err) or (cancelled and "Replay stopped; saved evaluation unchanged." or "Replay complete; no native steps added."));render()
  end)
  return true
 end
 local function variant(id)
  if status.busy then return false end
  assert(table.find(VARIANTS,id),"Unknown model")
  status.selectedVariant=id;render();publish();return true
 end
 ui=Dashboard.mount(CoreGui,{run=run,stop=function()cancelled=true;message("Stopping after current verified bar…")end,replay=replay,viewRig=viewRig,variant=variant})
 control.OnInvoke=function(command,...)
  if command=="status" then return status
  elseif command=="result" then return currentResult
  elseif command=="run" then return run(...)
  elseif command=="stop" then cancelled=true;return true
  elseif command=="replay" then return replay()
  elseif command=="variant" then return variant(...)
  elseif command=="viewRig" then viewRig();return true
  elseif command=="inspect" then return {ui=ui.screenGui:GetAttributes(),status=status}
  elseif command=="testActivate" then ui:testActivate(...);return true
  elseif command=="load" then
   assert(not status.busy,"Wait for current activity")
   local name=...;assert(type(name)=="string" and string.match(name,"^[%w_%-]+%.json$"),"Safe result basename required")
   status.busy=true;publish()
   local ok,result=pcall(function()
    local r=Http:JSONDecode(Http:GetAsync(BASE.."/saved?name="..name))
    assert(r.version=="roalgo-learned-v2" and r.phase=="complete" and #r.comparisons==5,"Completed v2 result required")
    return r
   end)
   status.busy=false
   if not ok then publish();error(result)end
   currentResult=result
   status={busy=false,hasUI=true,phase="complete",symbol=result.metadata.symbol,profile=result.profile,endDate=result.endDate,
    completed=result.completed,total=result.total,native=result.native,metadata=result.metadata,split=result.split,
    evaluationBars=#result.replayRecords,models=#result.comparisons,exportPath=name,selectedVariant=status.selectedVariant,placeId=game.PlaceId}
   ui:setSelection(status.symbol,status.profile,status.endDate);message("Loaded saved completed evaluation / no new native steps");render();return true
  elseif command=="destroy" then
   assert(not status.busy,"Stop and await completion before destroying")
   destroyed=true;if engine then engine:destroy()end;ui:destroy();control:Destroy();statusValue:Destroy();return true
  end
  error("Unknown RoAlgo command: "..tostring(command))
 end
 control.Parent=CoreGui;statusValue.Parent=CoreGui;status.hasUI=true
 message("Ready / SPY or QQQ / train → validation → evaluation / local historical research")
 return control
end
return App
