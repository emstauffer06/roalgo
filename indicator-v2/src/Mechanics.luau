--!strict
-- Pure scalar mechanics. Native construction consumes exactly this geometry/config.
-- Native solver integration is proprietary; RK4 here models the same continuous forces.
local Mechanics = {}
Mechanics.SCHEMA = "roalgo-mechanics-v2-1"
local function finite(x: any): boolean
	return type(x) == "number" and x == x and math.abs(x) < math.huge
end
Mechanics.finite = finite

function Mechanics.config(): any
	local c: any = {
		schema = Mechanics.SCHEMA, D = 64, dt = 1/60, stepsPerBar = 12,
		numericSubsteps = 4, integrator = "RK4, 4 substeps per 1/60 native interval",
		driveLimit = 2, railLimit = 224, anchorOffset = 512,
		spacing = 256, couplingFreeLength = 192, nodeSize = 1.5,
		couplingStiffnessRatio = 0.18, couplingDampingRatio = 0.08,
		maxForce = 1e6, massSource = "nominal density 1 x 1.5^3; Engine replaces with AssemblyMass",
		nodes = {}, edges = {}, bankNames = {"Fast", "Medium", "Slow"},
		projectionRule = "L1=1; matching bank channel weight .72, adjacent channels .12/.08/.08 with fixed signs",
		bankChannels = {{2,3,4},{1,5,6},{7,8,1}},
	}
	local bases = {5,2.5,1.25}
	for bank = 1,3 do
		for col = 1,8 do
			local i = (bank-1)*8+col
			local omega = bases[bank]*(0.85+0.30*(col-1)/7)
			local zeta = 0.8+0.35*((col-1)%4)/3
			local mass = 1.5^3
			local projection = table.create(8,0)
			local choices = c.bankChannels[bank]
			local main = choices[(col-1)%3+1]
			projection[main] = 0.72
			local extras = {main%8+1,(main+2)%8+1,(main+4)%8+1}
			local weights = {0.12,0.08,0.08}
			for j,channel in extras do
				projection[channel] += weights[j]*(if (col+j)%3 == 0 then -1 else 1)
			end
			table.insert(c.nodes, {index=i, bank=bank, column=col, name=c.bankNames[bank]..string.format("%02d",col),
				y=(3-bank)*c.spacing, z=(col-1)*c.spacing, mass=mass, omega=omega, zeta=zeta,
				k=mass*omega^2, c=2*zeta*mass*omega, projection=projection})
		end
	end
	local function add(a,b)
		local n,m=c.nodes[a],c.nodes[b]
		table.insert(c.edges,{a=a,b=b,dy=m.y-n.y,dz=m.z-n.z,
			transverse=math.sqrt((m.y-n.y)^2+(m.z-n.z)^2),freeLength=c.couplingFreeLength,
			k=c.couplingStiffnessRatio*math.sqrt(n.k*m.k),
			c=c.couplingDampingRatio*math.sqrt(n.c*m.c),maxForce=c.maxForce})
	end
	for bank=1,3 do for col=1,7 do add((bank-1)*8+col,(bank-1)*8+col+1) end end
	for bank=1,2 do for col=1,8 do add((bank-1)*8+col,bank*8+col) end end
	return c
end

-- dx=x_b-x_a, dv=v_b-v_a. Returns force on a; opposite force acts on b.
-- L=sqrt(transverse^2+dx^2); lengthRate=dv*dx/L.
-- F_a,x = clamp(k*(L-L0)+c*lengthRate, +/-maxForce)*dx/L.
function Mechanics.edgeForce(dx: number,dv: number,edge: any): number
	local length=math.sqrt(edge.transverse^2+dx^2)
	local direction=dx/length
	local tension=edge.k*(length-edge.freeLength)+edge.c*dv*direction
	return math.clamp(tension,-edge.maxForce,edge.maxForce)*direction
end

function Mechanics.project(c: any,drive: {number}): {number}
	assert(#drive==8,"Mechanics: exactly eight drives required")
	local bounded=table.create(8,0)
	for i=1,8 do
		assert(finite(drive[i]),"Mechanics: finite drive required")
		bounded[i]=math.clamp(drive[i],-c.driveLimit,c.driveLimit)
	end
	local q=table.create(24,0)
	for i,n in c.nodes do for j=1,8 do q[i]+=n.projection[j]*bounded[j] end end
	return q
end

function Mechanics.forces(c: any,x: {number},v: {number},q: {number},coupled: boolean): {number}
	local f=table.create(24,0)
	for i,n in c.nodes do
		local axial=math.clamp(-n.k*x[i]-n.c*v[i],-c.maxForce,c.maxForce)
		f[i]=axial+n.k*c.D*q[i]
	end
	if coupled then
		for _,e in c.edges do
			local force=Mechanics.edgeForce(x[e.b]-x[e.a],v[e.b]-v[e.a],e)
			f[e.a]+=force; f[e.b]-=force
		end
	end
	return f
end

-- Energies are dimensionless: node energy / (mass*omega^2*D^2), averaged by bank.
-- Coupling potential is measured above the pretension reference and split equally.
function Mechanics.state(c: any,x: {number},v: {number},q: {number},coupled: boolean): any
	local vector,names,nodes,banks={},{},{},{}
	local energies=table.create(24,0)
	for i,n in c.nodes do energies[i]=0.5*n.k*x[i]^2+0.5*n.mass*v[i]^2 end
	if coupled then
		for _,e in c.edges do
			local length=math.sqrt(e.transverse^2+(x[e.b]-x[e.a])^2)
			local energy=0.5*e.k*((length-e.freeLength)^2-(e.transverse-e.freeLength)^2)
			energies[e.a]+=0.5*energy; energies[e.b]+=0.5*energy
		end
	end
	local forces=Mechanics.forces(c,x,v,q,coupled)
	for bank=1,3 do banks[bank]={name=c.bankNames[bank],displacement=0,velocity=0,energy=0} end
	for i,n in c.nodes do
		local nx,nv=x[i]/c.D,v[i]/(c.D*n.omega)
		local energy=energies[i]/(n.mass*n.omega^2*c.D^2)
		vector[i]=nx; vector[24+i]=nv
		names[i]=n.name..".x"; names[24+i]=n.name..".v"
		nodes[i]={x=nx,v=nv,force=forces[i],bank=n.bank,drive=q[i]}
		local b=banks[n.bank]
		b.displacement+=nx/8; b.velocity+=nv/8; b.energy+=energy/8
	end
	local energy=0
	for bank,b in banks do vector[48+bank]=b.energy; names[48+bank]=b.name..".energy"; energy+=b.energy/3 end
	for _,value in vector do assert(finite(value),"Mechanics: non-finite readout") end
	return {vector=vector,names=names,banks=banks,nodes=nodes,energy=energy}
end

local Numeric={}
Numeric.__index=Numeric
function Mechanics.new(config: any?,coupled: boolean?): any
	local self: any=setmetatable({config=config or Mechanics.config(),coupled=coupled~=false,totalSteps=0,totalBars=0},Numeric)
	self:reset()
	return self
end
function Numeric.reset(self: any)
	self.x=table.create(24,0); self.v=table.create(24,0); self.q=table.create(24,0)
end
function Numeric.read(self: any): any return Mechanics.state(self.config,self.x,self.v,self.q,self.coupled) end
function Numeric.forces(self: any): {number} return Mechanics.forces(self.config,self.x,self.v,self.q,self.coupled) end
function Numeric._advance(self: any,h: number)
	local c=self.config
	local function derivative(x: {number},v: {number}): ({number},{number})
		local f=Mechanics.forces(c,x,v,self.q,self.coupled)
		local acceleration=table.create(24,0)
		for i,n in c.nodes do acceleration[i]=f[i]/n.mass end
		return v,acceleration
	end
	local function offset(x: {number},v: {number},dx: {number},dv: {number},scale: number): ({number},{number})
		local xx: {number},vv: {number}={},{}
		for i=1,24 do xx[i]=x[i]+dx[i]*scale; vv[i]=v[i]+dv[i]*scale end
		return xx,vv
	end
	local x: {number},v: {number}=self.x,self.v
	local x1,v1=derivative(x,v)
	local xx,vv=offset(x,v,x1,v1,h/2)
	local x2,v2=derivative(xx,vv)
	xx,vv=offset(x,v,x2,v2,h/2)
	local x3,v3=derivative(xx,vv)
	xx,vv=offset(x,v,x3,v3,h)
	local x4,v4=derivative(xx,vv)
	for i=1,24 do
		x[i]+=h*(x1[i]+2*x2[i]+2*x3[i]+x4[i])/6
		v[i]+=h*(v1[i]+2*v2[i]+2*v3[i]+v4[i])/6
		if math.abs(x[i])>c.railLimit then
			x[i]=math.clamp(x[i],-c.railLimit,c.railLimit)
			if x[i]*v[i]>0 then v[i]=0 end
		end
	end
end
function Numeric.step(self: any,drive: {number}): any
	local c=self.config
	self.q=Mechanics.project(c,drive)
	for _=1,c.stepsPerBar do
		for _=1,c.numericSubsteps do self:_advance(c.dt/c.numericSubsteps) end
		self.totalSteps+=1
	end
	self.totalBars+=1
	return self:read()
end
return Mechanics
