--!strict
-- Native behavior test; run only in Studio Edit mode. Owns/cleans its fixture.
local Probe={}
local function maxDifference(a,b,startAt,endAt)
	local difference=0
	for i=startAt or 1,endAt or 48 do difference=math.max(difference,math.abs(a[i]-b[i])) end
	return difference
end
function Probe.run(parent: Instance,options: any?): any
	local opts=options or {}
	local report: any={ok=false,kind="historical exploratory research; native mechanics probe",
		checks={},tolerances={replay=0.002,nativeNumeric=0.10,offAxisStuds=0.01,zero=1e-4},
		nativeNumeric={maxPosition=0,maxVelocity=0,maxEnergy=0,squared=0,count=0},
		scope="24 coupled + 24 independent bodies; identical 8-input drive; numeric coupled continuous model"}
	local fixture,engine=nil,nil
	local function check(name,passed,detail)
		table.insert(report.checks,{name=name,passed=passed,detail=detail})
	end
	local ok,err=pcall(function()
		local folder=script.Parent.Parent:FindFirstChild("src")
		assert(folder and folder:FindFirstChild("Engine"),"EngineProbe: native Engine implementation required")
		local Engine=require(folder.Engine)
		fixture=Instance.new("Folder"); fixture.Name="RoAlgoResearchProbe"; fixture.Parent=parent
		engine=Engine.new(fixture,{name="ProbePhysics",origin=Vector3.new(0,1024,1024)})
		local sentinel=Instance.new("Part")
		sentinel.Name="UnrelatedUnsteppedSentinel"; sentinel.Anchored=false; sentinel.CanCollide=false
		sentinel.CanTouch=false; sentinel.CanQuery=false; sentinel.Transparency=1
		sentinel.CFrame=CFrame.new(5000,100,5000); sentinel.Parent=fixture
		local sentinelPosition=sentinel.Position
		local completed=0
		local zero=table.create(8,0)
		local function step(drive,reset)
			local states=engine:step(drive,reset); completed+=1
			for _,key in {"coupled","independent","numeric"} do
				local s=states[key]
				assert(#s.vector==51 and #s.nodes==24 and #s.banks==3,"EngineProbe: readout dimensions")
				for _,v in s.vector do assert(v==v and math.abs(v)<math.huge,"EngineProbe: finite native readout") end
			end
			local measure=report.nativeNumeric
			measure.maxPosition=math.max(measure.maxPosition,maxDifference(states.coupled.vector,states.numeric.vector,1,24))
			measure.maxVelocity=math.max(measure.maxVelocity,maxDifference(states.coupled.vector,states.numeric.vector,25,48))
			measure.maxEnergy=math.max(measure.maxEnergy,maxDifference(states.coupled.vector,states.numeric.vector,49,51))
			for i=1,48 do measure.squared+=(states.coupled.vector[i]-states.numeric.vector[i])^2; measure.count+=1 end
			if opts.onProgress then opts.onProgress(completed,94) end
			return states
		end
		local rest=step(zero,true)
		check("zero equilibrium",maxDifference(rest.coupled.vector,table.create(48,0))<report.tolerances.zero,rest.coupled.banks)
		local positive=table.create(8,1)
		local first=step(positive,true)
		local direction=true
		for _,n in first.coupled.nodes do direction=direction and n.x>0 and n.v>0 end
		check("positive directional response",direction,first.coupled.banks)
		check("ordered bank response",first.coupled.banks[1].displacement>first.coupled.banks[2].displacement
			and first.coupled.banks[2].displacement>first.coupled.banks[3].displacement,first.coupled.banks)
		local held=first
		for _=1,15 do held=step(positive) end
		local released=held
		for _=1,40 do released=step(zero) end
		check("native release loses energy",released.coupled.energy<held.coupled.energy*1e-3,
			{initial=held.coupled.energy,final=released.coupled.energy})
		report.releaseMaxPosition=0
		for i=1,24 do report.releaseMaxPosition=math.max(report.releaseMaxPosition,math.abs(released.coupled.vector[i])) end
		check("native release floor below .005 normalized",report.releaseMaxPosition<0.005,report.releaseMaxPosition)
		local mixed={1,-1,0.5,-0.5,0.75,-0.75,1.5,-1.5}
		local driven=step(mixed,true)
		report.couplingDifference=maxDifference(driven.coupled.vector,driven.independent.vector)
		check("coupling changes native response",report.couplingDifference>1e-5,report.couplingDifference)
		local sequence={positive,mixed,zero,{0.5,-0.2,0.7,0.1,-0.4,0.3,0.8,-0.6},zero,positive}
		local replay={}
		for r=1,2 do
			replay[r]={}
			for i,d in sequence do replay[r][i]=step(d,i==1) end
		end
		report.maxReplayDifference=0
		for i=1,#sequence do for _,key in {"coupled","independent"} do
			report.maxReplayDifference=math.max(report.maxReplayDifference,maxDifference(replay[1][i][key].vector,replay[2][i][key].vector,1,51))
		end end
		check("native reset replay",report.maxReplayDifference<=report.tolerances.replay,report.maxReplayDifference)
		local small=table.create(8,0); small[2]=0.5
		local large=table.create(8,0); large[2]=2
		local smallState,largeState=nil,nil
		for i=1,12 do smallState=step(small,i==1) end
		for i=1,12 do largeState=step(large,i==1) end
		local coupledResidual,independentResidual=0,0
		for i=1,48 do
			coupledResidual=math.max(coupledResidual,math.abs(largeState.coupled.vector[i]/4-smallState.coupled.vector[i]))
			independentResidual=math.max(independentResidual,math.abs(largeState.independent.vector[i]/4-smallState.independent.vector[i]))
		end
		report.nonlinearity={coupledResidual=coupledResidual,independentResidual=independentResidual,
			definition="max |state(2)/4-state(.5)| over x,v after 12 held bars; independent controls solver scale error"}
		check("geometric nonlinearity exceeds independent scale error",coupledResidual>independentResidual+1e-5,report.nonlinearity)
		local stats=engine:stats()
		check("exact fixture counts",stats.counts.nodes==48 and stats.counts.rails==48 and stats.counts.axial==48
			and stats.counts.couplings==37 and stats.counts.forces==48 and stats.counts.metronomes==2,stats.counts)
		check("12 verified native intervals per bar",stats.totalSteps==completed*12 and stats.totalBars==completed
			and stats.parts==50 and stats.corruptSteps==0,stats)
		check("rails restrained without saturation",stats.maxOffAxis<=report.tolerances.offAxisStuds
			and stats.saturationObservations==0,stats)
		check("unrelated part unchanged",(sentinel.Position-sentinelPosition).Magnitude<1e-6
			and sentinel.AssemblyLinearVelocity.Magnitude<1e-6)
		report.nativeNumeric.rmse=math.sqrt(report.nativeNumeric.squared/report.nativeNumeric.count)
		check("native versus continuous-model deviation within declared tolerance",report.nativeNumeric.maxPosition<=report.tolerances.nativeNumeric
			and report.nativeNumeric.maxVelocity<=report.tolerances.nativeNumeric,report.nativeNumeric)
		report.stats=stats; report.completedBars=completed
	end)
	if engine then if not report.stats then report.stats=engine:stats() end; engine:destroy() end
	if fixture then fixture:Destroy() end
	report.ok=ok
	for _,c in report.checks do if not c.passed then report.ok=false end end
	if not ok then report.error=tostring(err) end
	return report
end
return Probe
