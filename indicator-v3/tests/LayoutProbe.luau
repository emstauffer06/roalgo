--!strict
-- Studio Edit-mode probe. Temporary wide/showcase engines run sequentially.
local Probe={}
local function equal(a: any,b: any): boolean
	if type(a)~="table" or type(b)~="table" then return a==b end
	for key,value in a do if not equal(value,b[key]) then return false end end
	for key in b do if a[key]==nil then return false end end
	return true
end
local function geometry(engine: any): any
	local result={}
	for _,key in {"coupledRig","independentRig"} do
		local rig=engine[key]
		local origin=rig.nodes[1].rest
		local nodes,edges={},{}
		for i,n in rig.nodes do
			nodes[i]={rest=n.rest-origin,guide=n.guide.Position-n.rest,anchor=n.anchor.Position-n.rest,
				body=n.part.Position-n.rest,size=n.part.Size,guideSize=n.guide.Size,anchorSize=n.anchor.Size,
				mass=n.part.AssemblyMass,lower=n.rail.LowerLimit,upper=n.rail.UpperLimit,
				axis0=n.rail.Attachment0.Axis,axis1=n.rail.Attachment1.Axis,
				freeLength=n.axial.FreeLength,stiffness=n.axial.Stiffness,damping=n.axial.Damping,maxForce=n.axial.MaxForce}
		end
		for i,s in rig.couplings do
			edges[i]={a=s.Attachment0.Parent:GetAttribute("NodeIndex"),b=s.Attachment1.Parent:GetAttribute("NodeIndex"),
				span=s.Attachment1.WorldPosition-s.Attachment0.WorldPosition,
				freeLength=s.FreeLength,stiffness=s.Stiffness,damping=s.Damping,maxForce=s.MaxForce}
		end
		result[key]={nodes=nodes,edges=edges}
	end
	return result
end
function Probe.run(parent: Instance,options: any?): any
	local opts=options or {}
	local report: any={ok=false,tolerance=0.002,barsPerLayout=6,resetBar=4,
		maxDifference={coupled=0,independent=0,numeric=0},checks={},layouts={}}
	local fixture: Instance?=nil
	local engine: any=nil
	local function check(name: string,passed: boolean)
		table.insert(report.checks,{name=name,passed=passed})
		assert(passed,"LayoutProbe: "..name)
	end
	local ok,err=pcall(function()
		local folder=script.Parent.Parent:FindFirstChild("src")
		assert(folder and folder:FindFirstChild("Engine"),"LayoutProbe: native Engine required")
		local Engine=require(folder.Engine)
		local patterns={table.create(12,0),table.create(12,0.75),{1,-1,0.5,-0.5,0.75,-0.75,1.2,-1.2,.3,-.3,.8,-.8},
			table.create(12,-0.75),{-.5,.2,-.7,-.1,.4,-.3,-.8,.6,.2,-.2,.1,-.1},table.create(12,0)}
		local baseline,baselineGeometry,baselineConfig=nil,nil,nil
		local baselineCounts=nil
		fixture=Instance.new("Folder");fixture.Name="RoAlgoLayoutProbe";fixture.Parent=parent
		for layoutIndex,layout in {"wide","showcase"} do
			engine=Engine.new(fixture,{name="LayoutProbePhysics",layout=layout,nodeCount=opts.nodeCount or 24,
				origin=if layout=="wide" then Vector3.new(0,1024,1024) else nil})
			report[layout.."Origin"]=tostring(engine.coupledRig.nodes[1].rest-Vector3.new(0,2*engine.config.spacing,0))
			local shape=geometry(engine)
			local expectedOffset=if layout=="wide" then Vector3.new(0,0,(engine.config.columns+3)*engine.config.spacing)
				else Vector3.new(0,-3*engine.config.spacing,0)
			check(layout.." placement",engine.independentRig.nodes[1].rest-engine.coupledRig.nodes[1].rest==expectedOffset)
			if layoutIndex==1 then baselineGeometry=shape;baselineConfig=engine.config
			else check("identical internal geometry",equal(shape,baselineGeometry));check("identical mechanics config",equal(engine.config,baselineConfig)) end
			local captured={}
			for bar=1,6 do
				local states=engine:step(patterns[(bar-1)%#patterns+1],bar==4)
				captured[bar]={}
				for _,key in {"coupled","independent","numeric"} do
					local vector=states[key].vector
					assert(#vector==engine.config.vectorCount,"LayoutProbe: dynamic readouts required")
					captured[bar][key]=table.clone(vector)
					for i,value in vector do
						assert(value==value and math.abs(value)<math.huge,"LayoutProbe: finite readout required")
						if baseline then report.maxDifference[key]=math.max(report.maxDifference[key],math.abs(value-baseline[bar][key][i])) end
					end
				end
				if opts.onProgress then opts.onProgress((layoutIndex-1)*6+bar,12) end
			end
			local stats=engine:stats();report.layouts[layout]=stats
			check(layout.." 72 verified intervals",stats.totalSteps==72 and stats.totalBars==6 and stats.parts==2*engine.config.nodeCount+2)
			check(layout.." clean native capture",stats.corruptSteps==0 and stats.failedBars==0 and stats.fault==nil
				and stats.saturationObservations==0 and stats.saturatedNodes==0 and stats.offAxisObservations==0
				and stats.maxOffAxis<=0.01 and stats.clippedInputs==0)
			local counts=stats.counts
			check(layout.." exact inventory",counts.nodes==2*engine.config.nodeCount and counts.rails==counts.nodes and counts.axial==counts.nodes
				and counts.couplings==#engine.config.edges and counts.forces==counts.nodes and counts.metronomes==2)
			if layoutIndex==1 then baseline=captured;baselineCounts=counts
			else check("identical inventory",equal(counts,baselineCounts)) end
			engine:destroy();engine=nil
		end
		for key,difference in report.maxDifference do check(key.." all dynamic readouts within tolerance",difference<=report.tolerance) end
	end)
	local cleaned,cleanupError=pcall(function()if engine then engine:destroy() end end)
	if fixture then fixture:Destroy() end
	report.ok=ok and cleaned
	if not ok then report.error=tostring(err) end
	if not cleaned then report.cleanupError=tostring(cleanupError) end
	return report
end
return Probe

