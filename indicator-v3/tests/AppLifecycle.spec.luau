-- Controller lifecycle regressions. AppLifecycle.test.mjs supplies the real App source.
-- Services, fitting, and physics are scoped test doubles; these tests make no native claims.
return function(appSource)
 local function harness()
  local h={queue={},posts={},savedFiles={},surfaces={},engineCount=0,nativeSteps=0}
  local ui={screenGui={GetAttributes=function()return {}end}}
  for _,name in {"setStatus","render","setSelection","clear","append","setProgress","destroy"} do ui[name]=function()end end
  ui.destroy=function()h.destroyed=true end
  local modules={
   ["./Features"]={new=function()return {step=function()return {drive={},ready=true}end,info=function()return {}end}end},
   ["./Engine"]={new=function()
    h.engineCount+=1
    local steps=0
    return {step=function()
     if h.failAfterSteps and steps>=h.failAfterSteps then steps+=3;h.nativeSteps+=3;error("native fault")end
     steps+=12;h.nativeSteps+=12;return {}
    end,stats=function()return {totalSteps=steps,corruptSteps=0}end,destroy=function()end}
   end},
   ["./Learning"]={fit=function()return {status="ok"},{}end,predict=function()return {}end,serialize=function(x)return x end},
   ["./Execution"]={new=function()
    local rows={}
    return {step=function(_,bar)rows[#rows+1]={t=bar.t,close=1,signal="HOLD"}end,result=function()return {rows=rows}end}
   end},
   ["./Dashboard"]={mount=function(parent,callbacks)assert(parent.FindFirstChild and callbacks.run,"Dashboard needs parent and callbacks");return ui end},
   ["./PhysicsView"]={mount=function()end},
   ["./Study"]={evaluate=function(records)
    local comparisons={}
    for _,id in {"coupled","independent","numeric","raw","memory","zero"} do
     local rows={};for _,r in records do rows[#rows+1]={t=r.bar.t,close=1,signal="HOLD"}end
     comparisons[#comparisons+1]={id=id,model={status="ok"},result={rows=rows,summary={netReturn=0}}}
    end
    return {comparisons=comparisons,selection={},diagnostics=h.evaluationDiagnostics or {status="complete",fittedModels=5,coverage={evaluation={available=#records}}}}
   end,aggregate=function(folds)local n=0;for _,f in folds do if f.phase~='complete' then n+=1 end end;return {groups={},completedFolds=#folds-n,failedFolds=n,attemptedFolds=#folds}end},
  }
  h.dataset={bars={{t=30,c=1}},prehistory={},metadata={symbol="SPY",dataHash="A"},split={trainEndT=10,validationEndT=20,testStartT=20}}
  local comparisons={}
  for _,id in {"coupled","independent","numeric","raw","memory"} do
   comparisons[#comparisons+1]={id=id,model={status="ok"},result={rows={{t=40,close=1}}}}
  end
  local savedFold={id="grouped24_fold1",foldId="fold1",foldIndex=1,configurationId="grouped24",phase="complete",comparisons=comparisons,
   metadata={symbol="QQQ",dataHash="B"},split={trainEndT=31,validationEndT=39,testStartT=39},
   profile=2,endDate="2024-11-30",completed=19,total=19,native={totalSteps=228},replayRecords={{bar={t=40}}}}
  h.saved={version="roalgo-study-v3",phase="complete",symbol="QQQ",profile=2,endDate="2024-11-30",completed=19,total=19,
   totalNativeSteps=228,folds={savedFold},foldDescriptors={{id="fold1",endDate="2024-11-30"}},
   configurations={{id="grouped24",nodeCount=24}},aggregate={groups={}}}
  h.foldPlan={folds={{id="fold1",endDate="2024-11-29"},{id="fold2",endDate="2024-12-31"}}}
  -- Encoding is represented by an object map, keeping mock HTTP response bodies strings.
  local encoded,nextId={},0
  local Http={}
  function Http:JSONEncode(x)nextId+=1;local key="json:"..nextId;encoded[key]=x;return key end
  function Http:JSONDecode(x)assert(encoded[x],"unknown mock JSON");return encoded[x]end
  function Http:GetAsync(url)
   if h.onGet then return self:JSONEncode(h.onGet(url))end
   local savedName=string.match(url,"[?&]name=([^&]+)")
   if savedName and h.savedFiles[savedName] then return self:JSONEncode(h.savedFiles[savedName])end
   return self:JSONEncode(string.find(url,"/saved",1,true) and h.saved or (string.find(url,"/folds",1,true) and h.foldPlan or h.dataset))
  end
  function Http:RequestAsync(req)
   local body=self:JSONDecode(req.Body);h.posts[#h.posts+1]=body
   if h.onPost then h.onPost(body)end
   h.savedFiles[body.name..".json"]=body.result
   return {Success=true,Body=self:JSONEncode({path=body.name..".json",sha256=string.rep("a",64)})}
  end
  local core={FindFirstChild=function(_,name)return h.surfaces[name]end}
  local tick=0
  local env=setmetatable({
   require=function(name)assert(modules[name],"unmocked import "..name);return modules[name]end,
   task={spawn=function(f)h.queue[#h.queue+1]=f end,wait=function()end},
   Instance={new=function()return {Destroy=function()end,Invoke=function(self,command,...)return self.OnInvoke(command,...)end}end},
   game={PlaceId=0,GetService=function(_,name)
    if name=="HttpService" then return Http elseif name=="CoreGui" then return core
    elseif name=="RunService" then return {IsRunning=function()return false end}end
    error("unmocked service "..name)
   end},
   DateTime={now=function()tick+=1;return {UnixTimestampMillis=tick}end},
   script={Parent={Features="./Features",Engine="./Engine",Study="./Study",Dashboard="./Dashboard",PhysicsView="./PhysicsView",Parent={GetDescendants=function()return {}end}}},
   workspace={},version=function()return "lifecycle-test"end,
  },{__index=getfenv(0)})
  local chunk=assert(loadstring(appSource,"App under test"));setfenv(chunk,env)
  h.app=chunk();h.control=h.app.start()
  function h:flush()while #self.queue>0 do table.remove(self.queue,1)()end end
  function h:run(symbol)
   assert(self.control:Invoke("run",symbol or "SPY",1,"2024-12-31"),"run should start")
   self:flush();return self.control:Invoke("status")
  end
  return h
 end
 local passed=0
 local function test(name,body)
  body();passed+=1;print("PASS "..name)
 end
 test("study executes both configurations for every chronological fold",function()
  local h=harness();assert(h:run().phase=="complete")
  local result=h.control:Invoke("result")
  assert(result.version=="roalgo-study-v3" and #result.folds==4,"rolling study requires four configuration/fold results")
  assert(h.nativeSteps==48 and result.totalNativeSteps==48,"each configuration/fold needs its own verified capture")
 end)
 test("completed study export contains only fold references while runtime remains hydrated",function()
  local h=harness();assert(h:run().phase=="complete")
  local runtime=h.control:Invoke("result");local manifest=h.posts[#h.posts].result
  assert(manifest.storage=="fold-references-v1" and #manifest.folds==4,"study must export references")
  for i,fold in manifest.folds do
   assert(fold.comparisons==nil and fold.replayRecords==nil and fold.cacheChunks==nil,"manifest must not duplicate heavy fold data")
   assert(fold.saved.name and fold.saved.sha256 and fold.id==runtime.folds[i].id,"each reference needs a saved identity")
   assert(#runtime.folds[i].comparisons==6 and #runtime.folds[i].replayRecords==1,"runtime must remain fully hydrated")
  end
 end)
 test("individual fold export reuses state checkpoints instead of duplicating replay records",function()
  local h=harness();h:run();local count=0
  for _,post in h.posts do if string.find(post.name,"_evaluation",1,true) then
   count+=1;assert(post.result.storage=="checkpoint-references-v1" and post.result.replayRecords==nil,"fold export must reference replay state")
   assert(post.result.replayCount==1 and #post.result.cacheChunks==1,"checkpoint coverage retained")
  end end
  assert(count==4)
 end)
 test("comparison and replay chunks cross 128 rows without duplicate or missing hydration",function()
  local h=harness();h.dataset.bars={};for i=1,129 do h.dataset.bars[i]={t=i*30,c=1}end
  assert(h:run().phase=="complete");local final=h.posts[#h.posts]
  local fold=h.savedFiles[final.result.folds[1].saved.name]
  assert(fold.comparisons[1].result.rows==nil and #fold.comparisons[1].result.rowChunks==2,"fold headers must keep only bounded row references")
  for _,post in h.posts do if post.result.version=="roalgo-rows-v3" then assert(#post.result.rows<=128,"row export chunk exceeded bound")end end
  h.control:Invoke("load",final.name..".json");local loaded=h.control:Invoke("result").folds[1]
  assert(#loaded.replayRecords==129 and #loaded.comparisons[1].result.rows==129,"hydration must include both chunks")
  assert(loaded.comparisons[1].result.rows[129].t==3870 and loaded.replayRecords[129].bar.t==3870)
 end)
 test("reference load hydrates matching fold and replay artifacts without native work",function()
  local h=harness();h:run();local final=h.posts[#h.posts];local before=h.nativeSteps
  assert(h.control:Invoke("load",final.name..".json"))
  local loaded=h.control:Invoke("result")
  assert(#loaded.folds==4 and #loaded.folds[1].comparisons==6 and #loaded.folds[1].replayRecords==1,"references must hydrate before rendering")
  assert(loaded.folds[1].replayRecords[1].bar.t==30 and h.nativeSteps==before)
 end)
 test("mismatched referenced fold fails atomically without replacing runtime result",function()
  local h=harness();h:run();local final=h.posts[#h.posts];local before=h.control:Invoke("result")
  assert(final.result.storage=="fold-references-v1","reference fixture required")
  local ref=final.result.folds[1];local wrong=table.clone(h.savedFiles[ref.saved.name]);wrong.configurationId="wrong";h.savedFiles[ref.saved.name]=wrong
  assert(not pcall(function()h.control:Invoke("load",final.name..".json")end),"wrong configuration must reject hydration")
  assert(h.control:Invoke("result")==before and not h.control:Invoke("status").busy)
 end)
 test("partial export references completed folds and marks failed fold in aggregation",function()
  local h=harness()
  h.onPost=function(body)if body.result.version=="roalgo-states-v3" and body.result.configurationId=="grouped48" then h.control:Invoke("stop")end end
  assert(h:run().phase=="stopped");local p=h.posts[#h.posts].result;local runtime=h.control:Invoke("result")
  assert(p.storage=="fold-references-v1" and #p.completedFolds==1,"partial must retain completed fold references")
  assert(p.completedFolds[1].replayRecords==nil and p.completedFolds[1].comparisons==nil)
  assert(p.currentFold.phase=="stopped" and p.currentFold.replayRecords==nil and p.currentFold.comparisons==nil,"failed fold evidence must stay small")
  assert(runtime.aggregate.failedFolds==1 and runtime.aggregate.attemptedFolds==2,"failed fold cannot disappear from aggregate")
 end)
 test("capture progress denominator includes all fold datasets before first native interval",function()
  local h=harness();local firstTotal
  h.onPost=function(body)if body.result.version=="roalgo-states-v3" and not firstTotal then firstTotal=h.control:Invoke("status").total end end
  h:run();assert(firstTotal==4,"two folds and two configurations must be counted before capture")
 end)
 test("default profile uses longer history and zero forecast is selectable",function()
  local h=harness();assert(h.control:Invoke("status").profile==3,"default profile must be80/20/20")
  assert(h:run().phase=="complete");assert(h.control:Invoke("variant","zero"))
  assert(h.control:Invoke("status").selectedVariant=="zero")
 end)
 test("unavailable evaluation cannot become a completed study",function()
  local h=harness();h.evaluationDiagnostics={status="no_available_evaluation_rows",fittedModels=5,coverage={evaluation={available=0}}}
  assert(h:run().phase=="error" and h.control:Invoke("result").phase=="error")
  assert(h.control:Invoke("replay")==false)
 end)
 test("busy v1 guard preserves the existing v2 controller",function()
  local h=harness()
  h.surfaces.RoAlgoMarketControl=h.control
  h.surfaces.RoAlgoIndicatorControl={Invoke=function(_,command)
   assert(command=="status");return {busy=true}
  end}
  assert(not pcall(h.app.start),"startup must reject an active v1 run")
  assert(not h.destroyed,"startup rejection must preserve the existing v2 UI and controller")
 end)
 test("load replaces prior data boundaries and export identity",function()
  local h=harness();assert(h:run().phase=="complete")
  h.control:Invoke("load","saved-B.json")
  local s=h.control:Invoke("status")
  assert(s.symbol=="QQQ" and s.metadata.dataHash=="B" and s.split.testStartT==39,"loaded run must own metadata and split")
  assert(s.exportPath=="saved-B.json" and s.exportSHA256==nil,"prior file SHA must not describe loaded file")
 end)
 test("loading reserves busy before yielding to HTTP",function()
  local h=harness()
  h.onGet=function()
   assert(h.control:Invoke("run","SPY",1,"2024-12-31")==false,"load must block concurrent run")
   assert(h.control:Invoke("replay")==false,"load must block concurrent replay")
   return h.saved
  end
  h.control:Invoke("load","saved-B.json")
  assert(not h.control:Invoke("status").busy,"load must release busy")
 end)
 test("failed load preserves result and releases busy",function()
  local h=harness();assert(h:run().phase=="complete")
  local before=h.control:Invoke("result")
  h.onGet=function()error("read unavailable")end
  assert(not pcall(function()h.control:Invoke("load","missing.json")end),"load failure must surface")
  assert(not h.control:Invoke("status").busy and h.control:Invoke("result")==before,"load failure must preserve usable result")
 end)
 test("new dataset failure excludes previous native counters",function()
  local h=harness();assert(h:run().phase=="complete")
  h.onGet=function()error("dataset unavailable")end
  local s=h:run("QQQ");local partial=h.posts[#h.posts].result
  assert(s.phase=="error" and partial.completed==0 and partial.native==nil,"failed new run must not inherit prior physics")
 end)
 test("cancelled export failure is not reported as saved",function()
  local h=harness()
  h.onGet=function()h.control:Invoke("stop");return h.dataset end
  h.onPost=function()error("disk unavailable")end
  local s=h:run()
  assert(s.phase=="stopped" and s.exportError,"cancel must retain export failure")
  assert(not string.find(string.lower(s.message),"saved",1,true),"failed save must not report success")
 end)
 test("failed final export cannot replay as a completed saved result",function()
  local h=harness()
  h.onPost=function(body)if body.result.version=="roalgo-study-v3" then error("final export unavailable")end end
  assert(h:run().phase=="error")
  assert(h.control:Invoke("result").phase=="error" and h.control:Invoke("replay")==false,"failed final export must not remain complete")
 end)
 test("replay reuses records without creating or stepping physics",function()
  local h=harness();assert(h:run().phase=="complete")
  assert(h.nativeSteps==48 and h.engineCount==4)
  assert(h.control:Invoke("replay"));h:flush()
  assert(h.nativeSteps==48 and h.engineCount==4 and h.control:Invoke("status").native.totalSteps==12,"replay must add zero native intervals")
 end)
 test("native failure publishes actual final counters",function()
  local h=harness();h.dataset.bars={}
  for i=1,7 do h.dataset.bars[i]={t=30*i,c=1}end
  h.failAfterSteps=72
  local s=h:run();local partial=h.posts[#h.posts].result
  assert(s.phase=="error" and s.completed==6 and partial.native.totalSteps==75,"fixture must fault after six captured bars plus three intervals")
  assert(s.native.totalSteps==75,"final error status must include all verified native intervals, not last progress snapshot")
 end)
 print("PASS App lifecycle "..passed.." checks")
 return passed
end
