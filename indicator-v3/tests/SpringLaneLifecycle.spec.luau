-- Used by spring-lane-driver.mjs: real-source lifecycle tests, with native construction/physics doubled.
return function(loadLane, Layout, Frozen)
 local passed, failed = 0, 0
 local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed += 1; print("PASS " .. name)
  else failed += 1; print("FAIL " .. name .. ": " .. tostring(err)) end
 end
 local function rejects(fn, fragment)
  local ok, err = pcall(fn)
  assert(not ok, "expected rejection: " .. fragment)
  assert(string.find(string.lower(tostring(err)), string.lower(fragment), 1, true), "wrong rejection: " .. tostring(err))
 end
 local function resume(thread)
  local ok, err = coroutine.resume(thread)
  assert(ok, tostring(err))
 end
 local function fixture()
  local f = { threads = {}, events = {}, builds = 0, requests = 0, destroys = 0, guards = 0, hashes = 0, controllers = {}, running = false }
  local function event(value) table.insert(f.events, value) end
  local task = {}
  function task.spawn(fn, ...)
   local thread = coroutine.create(fn)
   table.insert(f.threads, thread)
   local ok, err = coroutine.resume(thread, ...)
   assert(ok, tostring(err))
   return thread
  end
  function task.wait() coroutine.yield() end
  f.task = task
  local core = { FindFirstChild = function(_, name) return f.controllers[name] end, GetChildren = function()
   local all = {}; for _, c in f.controllers do table.insert(all, c) end; return all
  end }
  local runService = { IsRunning = function() return f.running end }
  local game = { PlaceId = 0, GetService = function(_, name)
   if name == "RunService" then return runService elseif name == "CoreGui" then return core end
   error("unexpected service " .. name)
  end }
  local world = { GetDescendants = function() return {} end, FindFirstChild = function() return nil end }
  local live = { DEFAULT_NAME = "RoAlgoSpringLiveRig", REPLAY_NAME = "RoAlgoSpringLiveReplayCheck", FORBIDDEN_NAME = "RoAlgoResearchPhysics",
   MODULE_ORDER = { "Pinned" }, MODULE_PINS = { Pinned = "good" }, activeCount = function() return f.singleActive or 0 end,
   sha256 = function(source) f.hashes += 1; return source end, replayCheck = function() end }
  local parent = { FindFirstChild = function(_, name)
   return { Name = name, Source = if name == "Pinned" then (f.pinnedSource or "good") else name,
    IsA = function(_, kind) return kind == "ModuleScript" end, FindFirstChild = function() return nil end,
    GetAttribute = function() return nil end }
  end }
  local script = { Parent = parent }
  local function requireModule(module)
   assert(module.Name == "SpringLiveCapture", "unexpected require " .. module.Name)
   return live
  end
  local color = { fromRGB = function(r,g,b) return {r,g,b} end }
  local vector = { new = function(x,y,z) return { X=x, Y=y, Z=z } end }
  local instance = { new = function(kind)
   return { Name = kind, SetAttribute = function() end, Destroy = function(self) self.Parent = nil end }
  end }
  local udim = { fromOffset = function() return {} end, fromScale = function() return {} end }
  local enum = { Font = { RobotoMono = "RobotoMono" } }
  local module = loadLane(game, world, script, requireModule, task, color, vector, instance, udim, enum,
   function() return { Physics = {} } end, function() return "fixture" end)
  f.module = module
  function f.guard() f.guards += 1; return f.allowed ~= false, "fixture guard refused" end
  function f.capture(fields)
   local cap = { guard = f.guard, isRunning = function() return f.controllerRunning ~= false end,
    destroyed = false, producing = false, stepping = false, index = 0, times = {11,22}, buffer = {}, buffered = 0,
    runner = { destroy = function() f.destroys += 1; event("runner destroyed") end }, lanes = {},
    container = { Parent = world, Destroy = function(self) self.Parent = nil; f.destroys += 1; event("container destroyed") end } }
   for k,v in fields or {} do cap[k] = v end
   return module.__test.capture(cap)
  end
  module.__test.build(function(count)
   f.builds += 1; event("build")
   local runner = {totalSteps=0, framesWaited=0, dropped=0, corrupt=0, parts=table.create(count*48+2), metronomes={}}
   function runner:stepBar()
    event("step")
    if f.onProbeStep then f.onProbeStep(self) end
    self.totalSteps += 12; self.framesWaited += 14; f.requests += 12
   end
   function runner:destroy() f.destroys += 1; event("runner destroyed") end
   local lanes = {}
   for k=1,count do
    lanes[k] = { index=k, coupled={nodes={{guide={}}}}, engine={destroy=function() f.destroys += 1; event("engine destroyed") end} }
   end
   local built = { runner=runner, lanes=lanes, plan={spacing=5122}, built={minLaneSeparation=512.5},
    container={Parent=world, Destroy=function(self) self.Parent=nil; f.destroys += 1; event("container destroyed") end} }
   f.built = built
   return built
  end)
  return f
 end

 test("shutdown waits for outstanding global bar before returning terminal counters", function()
  local f = fixture(); local globalBars = 0
  local cap = f.capture({_globalStep=function(self)
   f.requests += 1; f.task.wait(); f.requests += 11; globalBars += 1; return true
  end})
  cap.producing = true
  local producer = f.task.spawn(cap._produce, cap)
  assert(f.requests == 1 and cap.producing)
  local joined = false
  local waiter = f.task.spawn(function() cap:shutdown("controller failure"); joined=true end)
  assert(not joined, "shutdown returned with an outstanding native bar")
  resume(producer)
  assert(coroutine.status(producer)=="dead" and f.requests==12 and globalBars==1, "shutdown allowed a second global bar")
  resume(waiter)
  assert(joined and not cap.producing and not cap.stepping, "join did not reach quiescence")
  cap:shutdown("repeat")
  assert(f.requests==12, "idempotent shutdown stepped again")
 end)

 test("producer fault clears activity flags so shutdown can join", function()
  local f=fixture(); local cap=f.capture({_globalStep=function() error("simulated native failure") end})
  cap.producing=true
  f.task.spawn(cap._produce,cap)
  assert(not cap.producing and not cap.stepping and cap.fault, "producer leaked activity on failure")
  cap:shutdown("after fault")
  rejects(function() cap:step({t=11}) end,"fault")
 end)

 test("controller-status errors cannot strand the producer activity flag", function()
  local f=fixture(); local cap=f.capture({isRunning=function()error("status unavailable")end})
  cap.producing=true
  f.task.spawn(cap._produce,cap)
  assert(not cap.producing and not cap.stepping and cap.fault,"status failure leaked producer activity")
  cap:shutdown("status failed")
 end)

 test("isolation fault from the consumer stops the producer at its next bar boundary", function()
  local f=fixture();local cap=f.capture({_globalStep=function()
   f.requests+=1;f.task.wait();f.requests+=11;return true
  end})
  cap.producing=true
  local producer=f.task.spawn(cap._produce,cap)
  assert(f.requests==1)
  cap.fault="isolation breach discovered during chunk flush"
  resume(producer)
  assert(f.requests==12 and coroutine.status(producer)=="dead","known isolation fault allowed another native bar")
  assert(not cap.producing and not cap.stepping and cap.halted=="fault")
  cap:shutdown("faulted")
 end)

 for _, kind in {"fault", "guard", "shutdown"} do
  test("awaited row is not delivered after " .. kind .. " before consumer resumes", function()
   local f=fixture(); local cap=f.capture({producing=true}); local ok,err
   local consumer=f.task.spawn(function() ok,err=pcall(cap.step,cap,{t=11}) end)
   assert(coroutine.status(consumer)=="suspended")
   cap.buffer[1]={feature={},states={}}; cap.buffered=1
   if kind=="fault" then cap.fault="native failed";cap.halted="fault"
   elseif kind=="guard" then f.allowed=false
   else cap.haltRequested="stop";cap.halted="stop" end
   resume(consumer)
   assert(ok==false, "returned row after " .. kind .. ": " .. tostring(err))
   assert(cap.index==0 and cap.buffered==1 and cap.buffer[1]~=nil,"failed step consumed a row")
  end)
 end

 test("normal completed producer still delivers its final buffered row", function()
  local f=fixture(); local cap=f.capture({halted="complete",buffer={[1]={feature={},states={}}},buffered=1})
  local row=cap:step({t=11})
  assert(row.bar.t==11 and cap.index==1 and cap.buffered==0)
 end)

 test("release rejects a running capture and explicitly clears active after shutdown", function()
  local f=fixture(); local cap=f.capture(); f.module.__test.activate(cap)
  assert(f.module.module({}).activeCount()==1)
  rejects(function() cap:release() end,"running")
  assert(f.destroys==0)
  f.controllerRunning=false; cap:shutdown("terminal")
  cap:release()
  assert(cap.destroyed and f.destroys==2 and f.module.module({}).activeCount()==0)
  cap:release()
  assert(f.destroys==2,"repeat release destroyed twice")
 end)

 test("release cannot destroy a producer still stepping", function()
  local f=fixture();f.controllerRunning=false
  local cap=f.capture({producing=true,stepping=true,halted="stop"})
  rejects(function() cap:release() end,"step")
  assert(f.destroys==0)
 end)

 test("probe requires a guard and refuses guard failure before construction", function()
  local f=fixture()
  rejects(function() f.module.probe({lanes=2,bars=1,nativeConfig2024={}}) end,"guard")
  f.allowed=false
  rejects(function() f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard}) end,"guard")
  assert(f.builds==0 and f.requests==0)
 end)

 test("probe rejects active single capture and changed pins before construction", function()
  local f=fixture();f.singleActive=1
  rejects(function() f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard}) end,"capture")
  assert(f.builds==0)
  f.singleActive=0;f.pinnedSource="modified"
  rejects(function() f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard}) end,"pinned")
  assert(f.builds==0)
 end)

 test("retained probe is exclusive and releaseProbe removes only its geometry", function()
  local f=fixture()
  local result=f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard,keep=true})
  assert(result.kept==true and result.modules and f.hashes>0,"probe omitted receipts or retention")
  assert(f.destroys==0 and f.module.module({}).activeCount()==1)
  rejects(function() f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard}) end,"probe")
  rejects(function() f.module.module({}).replayCheck({}, {}) end,"probe")
  assert(f.builds==1)
  assert(f.module.releaseProbe()==true)
  assert(f.destroys==4 and f.module.module({}).activeCount()==0)
  assert(f.module.releaseProbe()==false and f.destroys==4)
 end)

 test("default probe cleans up and guard loss stops between probe bars", function()
  local f=fixture()
  local result=f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard})
  assert(result.kept~=true and f.requests==24 and f.destroys==4)
  assert(f.guards>=3,"probe did not guard construction and each stepped bar")
  local g=fixture();g.onProbeStep=function()g.allowed=false end
  rejects(function()g.module.probe({lanes=2,bars=2,nativeConfig2024={},guard=g.guard,keep=true})end,"guard")
  assert(g.requests==12 and g.destroys==4,"guard failure either kept stepping or leaked probe")
  assert(g.module.module({}).activeCount()==0)
 end)

 test("probe release is refused until an in-flight probe finishes", function()
  local f=fixture();local result
  f.onProbeStep=function()f.task.wait()end
  local probe=f.task.spawn(function() result=f.module.probe({lanes=2,bars=1,nativeConfig2024={},guard=f.guard,keep=true}) end)
  rejects(function()f.module.releaseProbe()end,"running")
  assert(f.destroys==0)
  resume(probe);resume(probe)
  assert(result and result.kept)
  assert(f.module.releaseProbe()==true)
 end)

 -- Scene geometry tests use the unchanged pure layout verifier and the real frozen 2024 engine config.
 local config = Frozen.nativeConfig2024
 local function zone(x0,y0,z0,x1,y1,z1)
  return {min={x=x0,y=y0,z=z0},max={x=x1,y=y1,z=z1}}
 end
 local sceneZone = zone(-2048.5,79.25,-896.75,404,5004,896.75)
 local function sceneZones()
  local zones=Layout.metronomeZones();table.insert(zones,sceneZone);return zones
 end
 local function selectPlan(count,zones)
  local select=fixture().module.__test.selectLanePlan
  assert(type(select)=="function","selectLanePlan missing")
  return select(Layout,config,count,zones)
 end
 local function clearOf(a,b)
  return a.max.x<b.min.x or b.max.x<a.min.x or a.max.y<b.min.y or b.max.y<a.min.y or a.max.z<b.min.z or b.max.z<a.min.z
 end
 local function checkPlan(plan,count,zones)
  Layout.verify(plan,config)
  assert(plan.origin.x==0 and plan.origin.y==1024 and plan.origin.z==1024,"capture origin changed")
  assert(plan.spacing%2==0 and plan.spacing-plan.depth>=512,"quantum/gap changed")
  for i,lane in plan.lanes do
   assert(lane.origin.x==0 and lane.origin.y==1024,"lane moved in X or Y")
   assert(lane.offsetZ==(i-(count+1)/2)*plan.spacing,"lane offset is not centered")
   assert(lane.offsetZ==-plan.lanes[count+1-i].offsetZ,"opposite lane offsets are not symmetric")
   for _,excluded in zones do assert(clearOf(lane.box,excluded),"lane touches or intersects excluded scene geometry") end
  end
 end

 for _,case in {{count=8,spacing=13060},{count=7,spacing=6530}} do
  test("scene exclusion selects minimal safe spacing for " .. case.count .. " lanes",function()
   local zones=sceneZones();local plan=selectPlan(case.count,zones)
   assert(plan.spacing==case.spacing,"unexpected scene spacing " .. tostring(plan.spacing))
   checkPlan(plan,case.count,zones)
   rejects(function()Layout.plan(config,{count=case.count,excluded=zones,spacing=plan.spacing-2})end,"excluded")
  end)
 end

 test("unobstructed layout keeps the declared default spacing",function()
  local zones=Layout.metronomeZones()
  table.insert(zones,zone(10000,0,-100000,11000,10000,100000)) -- Z overlaps every lane, X does not.
  local plan=selectPlan(8,zones)
  assert(plan.spacing==5122,"nonoverlapping zone changed the default spacing")
  checkPlan(plan,8,zones)
 end)

 test("touching exclusion boundary advances by one spacing quantum",function()
  -- At S=5122 the negative N=2 lane has maxZ=3071.75, exactly touching this plane.
  local zones={zone(0,1100,3071.75,1,1200,3071.75)}
  local plan=selectPlan(2,zones)
  assert(plan.spacing==5124,"touching boundary was not excluded strictly")
  checkPlan(plan,2,zones)
  rejects(function()Layout.plan(config,{count=2,excluded=zones,spacing=5122})end,"excluded")
 end)

 test("overlapping forbidden intervals are traversed in sorted order",function()
  local zones={zone(0,1100,-2000,1,1200,-1800),zone(0,1100,20000,1,1200,20100),zone(0,1100,-10,1,1200,10)}
  local plan=selectPlan(2,zones)
  assert(plan.spacing==15266,"multiple intervals selected nonminimal spacing " .. tostring(plan.spacing))
  checkPlan(plan,2,zones)
  rejects(function()Layout.plan(config,{count=2,excluded=zones,spacing=15264})end,"excluded")
 end)

 test("an excluded fixed middle lane refuses instead of translating the capture origin",function()
  local zones={zone(0,1100,2000,1,1200,2100)}
  local select=fixture().module.__test.selectLanePlan
  assert(type(select)=="function","selectLanePlan missing")
  local ok,err=pcall(select,Layout,config,3,zones)
  assert(not ok,"fixed middle lane overlap was accepted")
  assert(type(err)=="string" and #err>0)
 end)

 print(string.format("SpringLaneLifecycle: %d passed, %d failed",passed,failed))
 assert(failed==0,"SpringLaneLifecycle failures")
end
