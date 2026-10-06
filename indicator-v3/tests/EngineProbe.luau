--!strict
-- Bounded native behavior test; only Studio Edit mode. Root runs 24 and 48 separately.
local Probe={}
local function difference(a,b,first,last)
 local d=0
 for i=first,last do d=math.max(d,math.abs(a[i]-b[i])) end
 return d
end
function Probe.run(parent: Instance,options: any?): any
 local opts=options or {};local count=opts.nodeCount or 24
 local report: any={ok=false,nodeCount=count,kind='native v3 bounded mechanical probe',checks={},
  tolerances={replay=.002,nativeNumeric=.10,offAxisStuds=.01,zero=1e-4},
  nativeNumeric={maxPosition=0,maxVelocity=0,maxEnergy=0,squared=0,count=0},
  scope=tostring(count)..' coupled + '..tostring(count)..' independent native bodies, twelve market drives; scalar comparator separately integrated'}
 local fixture,engine=nil,nil
 local function check(name,passed,detail) table.insert(report.checks,{name=name,passed=passed,detail=detail}) end
 local ok,err=pcall(function()
  local folder=script.Parent.Parent:FindFirstChild('src');assert(folder,'EngineProbe: src required')
  local Engine=require(folder.Engine)
  fixture=Instance.new('Folder');fixture.Name='RoAlgoMarketProbe';fixture.Parent=parent
  engine=Engine.new(fixture,{name='ProbePhysics',origin=Vector3.new(0,1024,1024),nodeCount=count,topology=opts.topology or 'grouped',response=opts.response or 'diverse'})
  local sentinel=Instance.new('Part');sentinel.Name='UnrelatedUnsteppedSentinel';sentinel.Anchored=false;sentinel.CanCollide=false
  sentinel.CanTouch=false;sentinel.CanQuery=false;sentinel.Transparency=1;sentinel.CFrame=CFrame.new(5000,100,5000);sentinel.Parent=fixture
  local sentinelPosition=sentinel.Position
  local completed=0
  local zero,positive=table.create(12,0),table.create(12,1)
  local mixed={1,-1,.5,-.5,.75,-.75,1.5,-1.5,.3,-.3,.8,-.8}
  local function step(drive,reset)
   local states=engine:step(drive,reset);completed+=1
   for _,key in {'coupled','independent','numeric'} do
    local s=states[key];assert(#s.vector==2*count+11 and #s.names==#s.vector and #s.nodes==count and #s.banks==3,'EngineProbe: dynamic schema')
    for i,v in s.vector do assert(v==v and math.abs(v)<math.huge,'EngineProbe: finite readout');assert(s.names[i]==states.coupled.names[i],'EngineProbe: shared schema') end
   end
   local m=report.nativeNumeric
   m.maxPosition=math.max(m.maxPosition,difference(states.coupled.vector,states.numeric.vector,1,count))
   m.maxVelocity=math.max(m.maxVelocity,difference(states.coupled.vector,states.numeric.vector,count+1,2*count))
   m.maxEnergy=math.max(m.maxEnergy,difference(states.coupled.vector,states.numeric.vector,2*count+1,2*count+3))
   for i=1,2*count do m.squared+=(states.coupled.vector[i]-states.numeric.vector[i])^2;m.count+=1 end
   if opts.onProgress then opts.onProgress(completed,12) end
   return states
  end
  local rest=step(zero,true)
  check('zero equilibrium',difference(rest.coupled.vector,table.create(2*count,0),1,2*count)<report.tolerances.zero,rest.coupled.banks)
  local first=step(positive,true);local directional=true
  for _,n in first.coupled.nodes do directional=directional and n.x>0 and n.v>0 end
  check('positive mixed drive motion',directional,first.coupled.banks)
  check('ordered response bank averages',first.coupled.banks[1].displacement>first.coupled.banks[2].displacement and first.coupled.banks[2].displacement>first.coupled.banks[3].displacement,first.coupled.banks)
  local driven=step(mixed,true)
  report.couplingDifference=difference(driven.coupled.vector,driven.independent.vector,1,2*count)
  check('disconnected control differs',report.couplingDifference>1e-5,report.couplingDifference)
  local replay={};local sequence={positive,mixed,positive}
  for r=1,2 do replay[r]={};for i,d in sequence do replay[r][i]=step(d,i==1) end end
  report.maxReplayDifference=0
  for i=1,#sequence do for _,key in {'coupled','independent'} do report.maxReplayDifference=math.max(report.maxReplayDifference,difference(replay[1][i][key].vector,replay[2][i][key].vector,1,2*count+11)) end end
  check('reset replay',report.maxReplayDifference<=report.tolerances.replay,report.maxReplayDifference)
  local held=replay[2][#sequence];local released=nil
  for _=1,3 do released=step(zero) end
  check('release dissipates total derived energy',released.coupled.energy<held.coupled.energy,{initial=held.coupled.energy,final=released.coupled.energy})
  local stats=engine:stats()
  check('exact dynamic fixture counts',stats.counts.nodes==2*count and stats.counts.rails==2*count and stats.counts.axial==2*count and stats.counts.forces==2*count and stats.counts.couplings==#engine.config.edges and stats.counts.independentCouplings==0 and stats.counts.metronomes==2,stats.counts)
  check('twelve verified intervals each bar',completed==12 and stats.totalSteps==144 and stats.totalBars==12 and stats.parts==2*count+2 and stats.corruptSteps==0,stats)
  check('world-X rails and no saturation',stats.allAxesX and stats.maxOffAxis<=report.tolerances.offAxisStuds and stats.saturationObservations==0,stats.maxOffAxis)
  check('unrelated body unchanged',(sentinel.Position-sentinelPosition).Magnitude<1e-6 and sentinel.AssemblyLinearVelocity.Magnitude<1e-6)
  report.nativeNumeric.rmse=math.sqrt(report.nativeNumeric.squared/report.nativeNumeric.count)
  check('native continuous-model deviation',report.nativeNumeric.maxPosition<=report.tolerances.nativeNumeric and report.nativeNumeric.maxVelocity<=report.tolerances.nativeNumeric,report.nativeNumeric)
  report.stats=stats;report.completedBars=completed
 end)
 local cleaned,cleanupError=pcall(function() if engine then if not report.stats then report.stats=engine:stats() end;engine:destroy() end;if fixture then fixture:Destroy() end end)
 report.cleaned=cleaned and (not fixture or fixture.Parent==nil)
 report.ok=ok and report.cleaned
 for _,c in report.checks do if not c.passed then report.ok=false end end
 if not ok then report.error=tostring(err) end;if not cleaned then report.cleanupError=tostring(cleanupError) end
 return report
end
return Probe
