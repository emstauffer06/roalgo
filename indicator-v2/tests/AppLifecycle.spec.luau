-- Controller lifecycle regressions. AppLifecycle.test.mjs supplies the real App source.
-- Services, fitting, and physics are scoped test doubles; these tests make no native claims.
return function(appSource)
 local function harness()
  local h={queue={},posts={},surfaces={},engineCount=0,nativeSteps=0}
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
   ["./Dashboard"]={mount=function()return ui end},
   ["./PhysicsView"]={mount=function()end},
  }
  h.dataset={bars={{t=30,c=1}},prehistory={},metadata={symbol="SPY",dataHash="A"},split={trainEndT=10,validationEndT=20,testStartT=20}}
  local comparisons={}
  for _,id in {"coupled","independent","numeric","raw","reduced"} do
   comparisons[#comparisons+1]={id=id,model={status="ok"},result={rows={{t=40,close=1}}}}
  end
  h.saved={version="roalgo-learned-v2",phase="complete",comparisons=comparisons,
   metadata={symbol="QQQ",dataHash="B"},split={trainEndT=31,validationEndT=39,testStartT=39},
   profile=2,endDate="2024-11-30",completed=19,total=19,native={totalSteps=228},replayRecords={{bar={t=40}}}}
  -- Encoding is represented by an object map, keeping mock HTTP response bodies strings.
  local encoded,nextId={},0
  local Http={}
  function Http:JSONEncode(x)nextId+=1;local key="json:"..nextId;encoded[key]=x;return key end
  function Http:JSONDecode(x)assert(encoded[x],"unknown mock JSON");return encoded[x]end
  function Http:GetAsync(url)
   if h.onGet then return self:JSONEncode(h.onGet(url))end
   return self:JSONEncode(string.find(url,"/saved",1,true) and h.saved or h.dataset)
  end
  function Http:RequestAsync(req)
   local body=self:JSONDecode(req.Body);h.posts[#h.posts+1]=body
   if h.onPost then h.onPost(body)end
   return {Success=true,Body=self:JSONEncode({path=body.name..".json",sha256="A-SHA"})}
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
   script={Parent={Parent={GetDescendants=function()return {}end}}},
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
 test("busy v1 guard preserves the existing v2 controller",function()
  local h=harness()
  h.surfaces.RoAlgoResearchControl=h.control
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
  h.onPost=function(body)if body.result.version=="roalgo-learned-v2" then error("final export unavailable")end end
  assert(h:run().phase=="error")
  assert(h.control:Invoke("result").phase=="error" and h.control:Invoke("replay")==false,"failed final export must not remain complete")
 end)
 test("replay reuses records without creating or stepping physics",function()
  local h=harness();assert(h:run().phase=="complete")
  assert(h.nativeSteps==12 and h.engineCount==1)
  assert(h.control:Invoke("replay"));h:flush()
  assert(h.nativeSteps==12 and h.engineCount==1 and h.control:Invoke("status").native.totalSteps==12,"replay must add zero native intervals")
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
