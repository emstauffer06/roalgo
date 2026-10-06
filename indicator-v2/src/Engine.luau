--!strict
-- Native readings always originate in 48 Roblox bodies, stepped together by VerifiedStepper.
-- Transform/velocity writes occur only during construction/reset; forces hold between steps.
local RunService=game:GetService("RunService")
local Mechanics=require(script.Parent.Mechanics)
local VerifiedStepper=require(script.Parent.VerifiedStepper)
local Engine={}
Engine.__index=Engine
local Rig={}
Rig.__index=Rig
local function part(name,position,size,anchored,parent)
	local p=Instance.new("Part")
	p.Name=name; p.Size=size; p.CFrame=CFrame.new(position); p.Anchored=anchored
	p.CanCollide=false; p.CanTouch=false; p.CanQuery=false; p.CastShadow=false
	p.TopSurface=Enum.SurfaceType.Smooth; p.BottomSurface=Enum.SurfaceType.Smooth
	p.Parent=parent
	return p
end
local function attach(name,parent)
	local a=Instance.new("Attachment"); a.Name=name; a.Axis=Vector3.xAxis; a.SecondaryAxis=Vector3.yAxis; a.Parent=parent
	return a
end
local colors={Color3.fromRGB(72,214,169),Color3.fromRGB(255,194,95),Color3.fromRGB(105,160,255)}
local function buildRig(parent,c,origin,coupled)
	local model=Instance.new("Model"); model.Name=if coupled then "Coupled" else "Independent"; model.Parent=parent
	local self=setmetatable({model=model,config=c,nodes={},parts={},couplings={},coupled=coupled,q=table.create(24,0)},Rig)
	for i,n in c.nodes do
		local rest=origin+Vector3.new(0,n.y,n.z)
		local guide=part("Guide"..i,rest,Vector3.new(2*c.railLimit,0.18,0.18),true,model)
		guide.Transparency=0.85
		local anchor=part("Anchor"..i,rest-Vector3.new(c.anchorOffset,0,0),Vector3.one,true,model)
		anchor.Transparency=0.75
		local p=part(n.name,rest,Vector3.one*c.nodeSize,false,model)
		p.Color=colors[n.bank]; p.Material=Enum.Material.SmoothPlastic
		p.CustomPhysicalProperties=PhysicalProperties.new(1,0.3,0,1,1)
		p:SetAttribute("NodeIndex",i); p:SetAttribute("Bank",n.bank)
		local center=attach("Center",p)
		local rail=Instance.new("PrismaticConstraint")
		rail.Name="PassiveXAxisRail"; rail.Attachment0=attach("GuideAxis",guide); rail.Attachment1=center
		rail.ActuatorType=Enum.ActuatorType.None; rail.LimitsEnabled=true; rail.LowerLimit=-c.railLimit
		rail.UpperLimit=c.railLimit; rail.Restitution=0; rail.Parent=p
		local spring=Instance.new("SpringConstraint")
		spring.Name="NativeAxialSpring"; spring.Attachment0=attach("AxialAnchor",anchor); spring.Attachment1=center
		spring.FreeLength=c.anchorOffset; spring.Stiffness=n.k; spring.Damping=n.c; spring.MaxForce=c.maxForce
		spring.Visible=true; spring.Coils=6; spring.Radius=0.25; spring.Parent=p
		local force=Instance.new("VectorForce")
		force.Name="ProjectedMarketDrive"; force.Attachment0=center; force.RelativeTo=Enum.ActuatorRelativeTo.World
		force.ApplyAtCenterOfMass=true; force.Force=Vector3.zero; force.Parent=p
		self.nodes[i]={part=p,rest=rest,guide=guide,anchor=anchor,rail=rail,axial=spring,force=force,attachment=center}
		self.parts[i]=p
	end
	if coupled then
		for _,e in c.edges do
			local s=Instance.new("SpringConstraint")
			s.Name=string.format("Couple%02d_%02d",e.a,e.b)
			s.Attachment0=self.nodes[e.a].attachment; s.Attachment1=self.nodes[e.b].attachment
			s.FreeLength=e.freeLength; s.Stiffness=e.k; s.Damping=e.c; s.MaxForce=e.maxForce
			s.Visible=true; s.Coils=3; s.Radius=0.15; s.Parent=model
			table.insert(self.couplings,s)
		end
	end
	return self
end
function Rig:movingParts(): {BasePart} return self.parts end
function Rig:reset()
	self.q=table.create(24,0)
	for _,n in self.nodes do
		n.force.Force=Vector3.zero; n.part.CFrame=CFrame.new(n.rest)
		n.part.AssemblyLinearVelocity=Vector3.zero; n.part.AssemblyAngularVelocity=Vector3.zero
	end
end
function Rig:drive(input: {number})
	self.q=Mechanics.project(self.config,input)
	for i,n in self.nodes do n.force.Force=Vector3.new(self.config.nodes[i].k*self.config.D*self.q[i],0,0) end
end
function Rig:read(): {number}
	local out=table.create(48,0)
	for i,n in self.nodes do
		out[i]=(n.part.Position.X-n.rest.X)/self.config.D
		out[24+i]=n.part.AssemblyLinearVelocity.X/(self.config.D*self.config.nodes[i].omega)
		assert(Mechanics.finite(out[i]) and Mechanics.finite(out[24+i]),"Engine: non-finite native motion")
	end
	return out
end
function Rig:state(values)
	local x,v={},{}
	for i,n in self.config.nodes do x[i]=values[i]*self.config.D; v[i]=values[24+i]*self.config.D*n.omega end
	return Mechanics.state(self.config,x,v,self.q,self.coupled)
end

function Engine.new(parent: Instance,options: any?): any
	assert(not RunService:IsRunning(),"Engine: requires Studio Edit mode")
	assert(typeof(parent)=="Instance" and (parent==workspace or parent:IsDescendantOf(workspace)),"Engine: parent must be in Workspace")
	local ancestor: Instance?=parent
	while ancestor and ancestor~=workspace do
		assert(not ancestor:IsA("WorldModel"),"Engine: WorldModel unsupported"); ancestor=ancestor.Parent
	end
	assert(Mechanics.finite(workspace.Gravity) and workspace.Gravity>0,"Engine: positive gravity required for metronomes")
	local opts=options or {}
	local spawn=workspace:FindFirstChildWhichIsA("SpawnLocation",true)
	-- Keep the measured world-X dynamics intact; place the full-size exhibit facing spawn.
	local fromSpawn=opts.origin==nil and spawn~=nil
	local origin=opts.origin or (if spawn then spawn.Position+Vector3.new(-1536,847.5,-896) else Vector3.new(0,1024,1024))
	assert(typeof(origin)=="Vector3" and Mechanics.finite(origin.X) and Mechanics.finite(origin.Y) and Mechanics.finite(origin.Z),"Engine: finite Vector3 origin required")
	local c=Mechanics.config()
	local layout=opts.layout or "showcase"
	assert(layout=="showcase" or layout=="wide","Engine: unknown layout")
	-- Translate whole rigs only; internal geometry and world-X drive axes stay unchanged.
	local independentOffset=if layout=="wide" then Vector3.new(0,0,11*c.spacing) else Vector3.new(0,-3*c.spacing,0)
	c.nativeProtocol={schema="verified-stepper-v2-2",lossFrames=3,postBarQuietFrames=2,
		recovery="reject corrupted capture; explicit reset and replay required"}
	local model=Instance.new("Model"); model.Name=opts.name or "RoAlgoResearchPhysics"
	model:SetAttribute("MechanicsSchema",c.schema); model:SetAttribute("NativeSolver","Roblox StepPhysics with two metronomes")
	model:SetAttribute("DisplacementStudsPerDrive",c.D); model:SetAttribute("SecondsPerBar",c.dt*c.stepsPerBar)
	local focus=origin+Vector3.new(0,c.spacing,3.5*c.spacing)+independentOffset/2
	model:SetAttribute("Layout",layout)
	model:SetAttribute("IndependentOffset",independentOffset)
	model:SetAttribute("FocusPosition",focus)
	model:SetAttribute("ViewPosition",if fromSpawn then spawn.Position+Vector3.new(0,31.5,0) else focus+Vector3.new(1800,250,600))
	model:SetAttribute("ViewFieldOfView",if fromSpawn then 50 else 70)
	model:SetAttribute("ViewFromSpawn",fromSpawn)
	model.Parent=parent
	local coupled,independent,runner
	local ok,err=pcall(function()
		coupled=buildRig(model,c,origin,true)
		independent=buildRig(model,c,origin+independentOffset,false)
		-- Both rigs have identical unconnected body sizes/density. Numerical coefficients use actual assembly mass.
		for i,n in c.nodes do
			local actual=coupled.nodes[i].part.AssemblyMass
			assert(Mechanics.finite(actual) and actual>0,"Engine: invalid native AssemblyMass")
			assert(math.abs(actual-independent.nodes[i].part.AssemblyMass)<1e-9,"Engine: rigs must have identical masses")
			n.mass=actual; n.k=actual*n.omega^2; n.c=2*n.zeta*actual*n.omega
			for _,rig in {coupled,independent} do
				rig.nodes[i].axial.Stiffness=n.k; rig.nodes[i].axial.Damping=n.c
				rig.nodes[i].part:SetAttribute("MeasuredMass",actual)
			end
		end
		c.massSource="coupled native Part.AssemblyMass, checked identical to independent rig"
		for i,e in c.edges do
			e.k=c.couplingStiffnessRatio*math.sqrt(c.nodes[e.a].k*c.nodes[e.b].k)
			e.c=c.couplingDampingRatio*math.sqrt(c.nodes[e.a].c*c.nodes[e.b].c)
			coupled.couplings[i].Stiffness=e.k; coupled.couplings[i].Damping=e.c
		end
		runner=VerifiedStepper.new({coupled,independent},{dt=1/60,stepsPerBar=12,settleSteps=0,parent=model,
			lossFrames=3,postBarQuietFrames=2})
	end)
	if not ok then model:Destroy(); error(tostring(err),2) end
	local self=setmetatable({model=model,config=c,coupledRig=coupled,independentRig=independent,runner=runner,
		numeric=Mechanics.new(c,true),destroyed=false,busy=false,fault=nil,failedBars=0,clippedInputs=0,
		maxAbsX=0,maxOffAxis=0,saturationObservations=0,offAxisObservations=0},Engine)
	self:reset()
	return self
end
function Engine:reset()
	assert(not self.destroyed and not self.busy,"Engine: reset unavailable")
	self.runner:recover(); self.runner:resetSegment(); self.numeric:reset(); self.fault=nil
end
function Engine:step(drive: {number},reset: boolean?): any
	assert(not self.destroyed and not self.busy,"Engine: step unavailable")
	Mechanics.project(self.config,drive) -- validate completely before mutation/native request
	if reset then self:reset() end
	assert(not self.fault,"Engine: reset and replay after failed native step")
	for _,value in drive do if math.abs(value)>2 then self.clippedInputs+=1 end end
	self.busy=true
	local ok,result=pcall(function()
		local arrays=self.runner:stepBar({drive,drive})
		local states={coupled=self.coupledRig:state(arrays[1]),independent=self.independentRig:state(arrays[2]),numeric=self.numeric:step(drive)}
		for _,rig in {self.coupledRig,self.independentRig} do
			for _,n in rig.nodes do
				local delta=n.part.Position-n.rest
				local offAxis=math.max(math.abs(delta.Y),math.abs(delta.Z))
				self.maxAbsX=math.max(self.maxAbsX,math.abs(delta.X)); self.maxOffAxis=math.max(self.maxOffAxis,offAxis)
				if math.abs(delta.X)>=self.config.railLimit-0.01 then self.saturationObservations+=1 end
				if offAxis>0.01 then self.offAxisObservations+=1 end
			end
		end
		return states
	end)
	self.busy=false
	if not ok then
		self.failedBars+=1; self.fault=tostring(result)
		self.coupledRig:drive(table.create(8,0)); self.independentRig:drive(table.create(8,0))
		error(result,2)
	end
	return result
end
function Engine:stats(): any
	local s=self.runner:stats()
	s.schema=self.config.schema; s.config=self.config
	local counts={nodes=0,rails=0,axial=0,couplings=0,forces=0,metronomes=0,
		coupledNodes=0,independentNodes=0,independentCouplings=0}
	s.saturatedNodes=0
	for _,rig in {self.coupledRig,self.independentRig} do
		for _,n in rig.nodes do
			if n.part.Parent then
				counts.nodes+=1
				if rig.coupled then counts.coupledNodes+=1 else counts.independentNodes+=1 end
				if math.abs(n.part.Position.X-n.rest.X)>=self.config.railLimit-0.01 then s.saturatedNodes+=1 end
			end
			if n.rail.Parent then counts.rails+=1 end
			if n.axial.Parent then counts.axial+=1 end
			if n.force.Parent then counts.forces+=1 end
		end
		for _,edge in rig.couplings do
			if edge.Parent then
				counts.couplings+=1
				if not rig.coupled then counts.independentCouplings+=1 end
			end
		end
	end
	for _,m in self.runner.metronomes do if m.Parent then counts.metronomes+=1 end end
	s.counts=counts
	s.dt=self.config.dt; s.stepsPerBar=self.config.stepsPerBar; s.secondsPerBar=self.config.dt*self.config.stepsPerBar
	s.numericSteps=self.numeric.totalSteps; s.numericBars=self.numeric.totalBars
	s.maxAbsX=self.maxAbsX; s.maxOffAxis=self.maxOffAxis; s.saturationObservations=self.saturationObservations
	s.offAxisObservations=self.offAxisObservations; s.clippedInputs=self.clippedInputs
	s.failedBars=self.failedBars; s.fault=self.fault; s.destroyed=self.destroyed
	return s
end
function Engine:destroy()
	if self.destroyed then return end
	assert(not self.busy,"Engine: active step must finish before destruction")
	self.destroyed=true; self.runner:destroy(); self.model:Destroy()
end
return Engine
