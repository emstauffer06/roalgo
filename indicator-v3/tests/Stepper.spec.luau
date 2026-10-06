-- Exercises the real runner protocol with injected asynchronous scheduling.
-- Platform doubles replace Roblox objects only; no native-physics pass is implied.
return function(newRunner)
 local function runBar(runner)return runner:stepBar({{1}})end
 do
  local runner,sim=newRunner({firstDelay=2})
  local ok,result=pcall(runBar,runner)
  assert(ok,"A two-frame request delay must not be mistaken for loss/reissued: "..tostring(result))
  assert(math.abs(result[1][1]-12)<1e-10 and runner:stats().totalSteps==12,"Bar contains exactly twelve completed intervals")
  assert(sim.requests==12,"A delayed acknowledgement must not duplicate a request")
  assert(runner:stats().lossFrames==3,"Longer loss observation window is active")
 end
 do
  local runner,sim=newRunner({extraAfterLast=true})
  local ok,result=pcall(runBar,runner)
  assert(not ok and string.find(tostring(result),"CORRUPT_STEP",1,true),"Late extra interval must be rejected before publishing a bar")
  assert(runner:stats().totalBars==0 and sim.reads==0,"Corrupt final interval cannot publish a rig readout")
 end
 do
  local runner,sim=newRunner({firstDropped=true})
  local result=runBar(runner)
  assert(math.abs(result[1][1]-12)<1e-10 and sim.requests==13,"A genuinely dropped request retries to twelve completed intervals")
  assert(runner:stats().droppedRequests==1,"Dropped request is recorded")
 end
 do
  local runner=newRunner({firstDelay=4})
  local ok,result=pcall(runBar,runner)
  assert(not ok and string.find(tostring(result),"CORRUPT_STEP",1,true),"Delay outside bounded observation window remains corrupt rather than accepted")
 end
 do
  local runner,sim=newRunner({})
  runBar(runner);runBar(runner)
  local stats=runner:stats()
  assert(stats.totalSteps==24 and stats.totalBars==2 and stats.corruptSteps==0,"Clean consecutive bars preserve counters")
  assert(sim.reads==2 and stats.quietFramesWaited==4,"Two quiet frames are observed before each bar readout")
  assert(stats.barrierChecks>=4 and stats.barrierFailures==0,"Barrier verification is recorded")
 end
 print("PASS Stepper.spec: delayed acknowledgement, pre-publication late completion rejection, loss retry, bounded corruption rejection, clean barriers")
end
