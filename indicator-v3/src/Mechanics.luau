--!strict
-- Pure continuous-force comparator. Native motion is read separately by Engine.
local Mechanics = {}
Mechanics.SCHEMA = 'roalgo-mechanics-v3-1'
local function finite(x: any): boolean return type(x)=='number' and x==x and math.abs(x)<math.huge end
Mechanics.finite=finite

function Mechanics.config(options: any?): any
 local opts=options or {}
 local count,topology,response=opts.nodeCount or 24,opts.topology or 'grouped',opts.response or 'diverse'
 assert(count==24 or count==48,'Mechanics: nodeCount must be 24 or 48')
 assert(topology=='grouped' or topology=='grid','Mechanics: unknown topology')
 assert(response=='diverse' or response=='balanced','Mechanics: unknown response')
 local c: any={schema=Mechanics.SCHEMA,id=topology..tostring(count)..'-'..response,nodeCount=count,columns=count/3,
  topology=topology,response=response,replicasPerGroup=count/12,D=64,dt=1/60,stepsPerBar=12,
  numericSubsteps=4,integrator='RK4, 4 substeps per 1/60 native interval',driveLimit=2,railLimit=224,
  anchorOffset=512,spacing=256,couplingFreeLength=192,couplingRestRatio=.75,nodeSize=1.5,
  couplingStiffnessRatio=.18,couplingDampingRatio=.08,maxForce=1e6,
  massSource='nominal density 1 x 1.5^3; Engine replaces with AssemblyMass',nodes={},edges={},
  bankNames={'Fast','Medium','Slow'},groupNames={'Tape','EquityRelative','SectorBond','ParticipationRegime'},
  groupChannels={{1,2,3},{5,6,8},{7,9,10},{4,11,12}},
  driveNames={'trend','immediateReturn','rangeActivity','volume','qqqMinusSpy','iwmMinusSpy','tltReturn','xlkMinusSpy','xlfMinusSpy','xleMinusSpy','targetDailyReturn','regimeStress'},
  projectionRule='fixed L1=1: dominant +.72, two other group channels signed .12/.08, one next-group channel signed .08; signs are input projections, not correlation claims',
  couplingMeaning='nonnegative passive springs; graph encodes an experimental coupling architecture, not universal market correlation signs'}
 local bases={5,2.5,1.25}
 for bank=1,#c.bankNames do
  for group=1,#c.groupNames do
   for replica=1,c.replicasPerGroup do
    local col=(group-1)*c.replicasPerGroup+replica
    local index=(bank-1)*c.columns+col
    local channels=c.groupChannels[group]
    local slot=(bank+replica-2)%3+1
    local main=channels[slot]
    local projection=table.create(#c.driveNames,0)
    projection[main]=.72
    projection[channels[slot%3+1]]=.12*(if (bank+replica)%2==0 then -1 else 1)
    projection[channels[(slot+1)%3+1]]=.08*(if (group+replica)%3==0 then -1 else 1)
    projection[c.groupChannels[group%4+1][slot]]=.08*(if (bank+group+replica)%2==0 then -1 else 1)
    local omega=bases[bank]*(if response=='diverse' then .80+.40*(col-1)/(c.columns-1) else 1)
    local zeta=if response=='diverse' then .70+.55*((group+replica+bank-3)%5)/4 else .95
    local mass=c.nodeSize^3
    table.insert(c.nodes,{index=index,bank=bank,group=group,replica=replica,column=col,
     name=c.bankNames[bank]..'.'..c.groupNames[group]..string.format('%02d',replica),
     bankName=c.bankNames[bank],groupName=c.groupNames[group],dominantDrive=main,dominantDriveName=c.driveNames[main],
     y=(3-bank)*c.spacing,z=(col-1)*c.spacing,mass=mass,omega=omega,zeta=zeta,k=mass*omega^2,c=2*zeta*mass*omega,projection=projection})
   end
  end
 end
 local seen={}
 local function add(a,b)
  if a>b then a,b=b,a end
  local key=a..':'..b
  if seen[key] then return end
  seen[key]=true
  local n,m=c.nodes[a],c.nodes[b]
  local transverse=math.sqrt((m.y-n.y)^2+(m.z-n.z)^2)
  table.insert(c.edges,{a=a,b=b,dy=m.y-n.y,dz=m.z-n.z,transverse=transverse,freeLength=transverse*c.couplingRestRatio,
   k=c.couplingStiffnessRatio*math.sqrt(n.k*m.k),c=c.couplingDampingRatio*math.sqrt(n.c*m.c),maxForce=c.maxForce})
 end
 for bank=1,3 do
  local start=(bank-1)*c.columns
  if topology=='grid' then
   for col=1,c.columns-1 do add(start+col,start+col+1) end
  else
   for group=1,4 do
    local first=start+(group-1)*c.replicasPerGroup+1
    for replica=1,c.replicasPerGroup-1 do add(first+replica-1,first+replica) end
    if group<4 then add(first,first+c.replicasPerGroup) end
   end
  end
 end
 for bank=1,2 do for col=1,c.columns do add((bank-1)*c.columns+col,bank*c.columns+col) end end
 c.vectorCount=2*count+11
 return c
end

-- Force on endpoint a; equal/opposite on b. Damping projects relative axial speed.
function Mechanics.edgeForce(dx: number,dv: number,edge: any): number
 local length=math.sqrt(edge.transverse^2+dx^2)
 local direction=dx/length
 local tension=edge.k*(length-edge.freeLength)+edge.c*dv*direction
 return math.clamp(tension,-edge.maxForce,edge.maxForce)*direction
end
function Mechanics.project(c: any,drive: {number}): {number}
 assert(#drive==#c.driveNames,'Mechanics: exactly twelve drives required')
 local bounded=table.create(#c.driveNames,0)
 for i=1,#c.driveNames do assert(finite(drive[i]),'Mechanics: finite drive required');bounded[i]=math.clamp(drive[i],-c.driveLimit,c.driveLimit) end
 local q=table.create(#c.nodes,0)
 for i,n in c.nodes do for j=1,#c.driveNames do q[i]+=n.projection[j]*bounded[j] end end
 return q
end
function Mechanics.forces(c: any,x: {number},v: {number},q: {number},coupled: boolean): {number}
 local f=table.create(#c.nodes,0)
 for i,n in c.nodes do f[i]=math.clamp(-n.k*x[i]-n.c*v[i],-c.maxForce,c.maxForce)+n.k*c.D*q[i] end
 if coupled then for _,e in c.edges do
  local force=Mechanics.edgeForce(x[e.b]-x[e.a],v[e.b]-v[e.a],e)
  f[e.a]+=force;f[e.b]-=force
 end end
 return f
end

-- x/v are normalized position and velocity; forces/energies are derived from those
-- readings and configured coefficients, never independent force-sensor measurements.
function Mechanics.state(c: any,x: {number},v: {number},q: {number},coupled: boolean): any
 local count=#c.nodes
 local vector,names,nodes,banks,groups={},{},{},{},{}
 local energies=table.create(count,0)
 for i,n in c.nodes do energies[i]=.5*n.k*x[i]^2+.5*n.mass*v[i]^2 end
 if coupled then for _,e in c.edges do
  local length=math.sqrt(e.transverse^2+(x[e.b]-x[e.a])^2)
  local energy=.5*e.k*((length-e.freeLength)^2-(e.transverse-e.freeLength)^2)
  energies[e.a]+=.5*energy;energies[e.b]+=.5*energy
 end end
 local forces=Mechanics.forces(c,x,v,q,coupled)
 for bank,name in c.bankNames do banks[bank]={name=name,displacement=0,velocity=0,energy=0} end
 for group,name in c.groupNames do groups[group]={name=name,displacement=0,velocity=0} end
 for i,n in c.nodes do
  local nx,nv=x[i]/c.D,v[i]/(c.D*n.omega)
  local energy=energies[i]/(n.mass*n.omega^2*c.D^2)
  vector[i]=nx;vector[count+i]=nv;names[i]=n.name..'.x';names[count+i]=n.name..'.v'
  nodes[i]={x=nx,v=nv,force=forces[i],bank=n.bank,group=n.group,drive=q[i],energy=energy,
   name=n.name,dominantDrive=n.dominantDrive,dominantDriveName=n.dominantDriveName}
  local b=banks[n.bank];b.displacement+=nx/c.columns;b.velocity+=nv/c.columns;b.energy+=energy/c.columns
  local g=groups[n.group];g.displacement+=nx/(count/4);g.velocity+=nv/(count/4)
 end
 local energy=0
 for _,b in banks do table.insert(vector,b.energy);table.insert(names,b.name..'.energy');energy+=b.energy/#banks end
 for _,g in groups do
  table.insert(vector,g.displacement);table.insert(names,g.name..'.xMean')
  table.insert(vector,g.velocity);table.insert(names,g.name..'.vMean')
 end
 for _,value in vector do assert(finite(value),'Mechanics: non-finite readout') end
 return {schema=c.schema,configuration=c.id,vector=vector,names=names,banks=banks,groups=groups,nodes=nodes,energy=energy,
  measurementOrigin='derived-from-x-v',derivedMeasurements='bank energies, group means and node forces derived from normalized x/v and fixed coefficients'}
end

local Numeric={};Numeric.__index=Numeric
function Mechanics.new(config: any?,coupled: boolean?): any
 local self: any=setmetatable({config=config or Mechanics.config(),coupled=coupled~=false,totalSteps=0,totalBars=0},Numeric)
 self:reset();return self
end
function Numeric.reset(self: any)
 local count=#self.config.nodes
 self.x=table.create(count,0);self.v=table.create(count,0);self.q=table.create(count,0)
end
function Numeric.read(self: any): any
 local s=Mechanics.state(self.config,self.x,self.v,self.q,self.coupled)
 s.positionVelocityOrigin='numerically integrated continuous-force comparator'
 return s
end
function Numeric.forces(self: any): {number} return Mechanics.forces(self.config,self.x,self.v,self.q,self.coupled) end
function Numeric._advance(self: any,h: number)
 local c=self.config
 local function derivative(x: {number},v: {number}): ({number},{number})
  local f=Mechanics.forces(c,x,v,self.q,self.coupled)
  local acceleration=table.create(#c.nodes,0)
  for i,n in c.nodes do acceleration[i]=f[i]/n.mass end
  return v,acceleration
 end
 local function offset(x: {number},v: {number},dx: {number},dv: {number},scale: number): ({number},{number})
  local xx: {number},vv: {number}={},{}
  for i=1,#c.nodes do xx[i]=x[i]+dx[i]*scale;vv[i]=v[i]+dv[i]*scale end
  return xx,vv
 end
 local x: {number},v: {number}=self.x,self.v
 local x1,v1=derivative(x,v)
 local xx,vv=offset(x,v,x1,v1,h/2);local x2,v2=derivative(xx,vv)
 xx,vv=offset(x,v,x2,v2,h/2);local x3,v3=derivative(xx,vv)
 xx,vv=offset(x,v,x3,v3,h);local x4,v4=derivative(xx,vv)
 for i=1,#c.nodes do
  x[i]+=h*(x1[i]+2*x2[i]+2*x3[i]+x4[i])/6;v[i]+=h*(v1[i]+2*v2[i]+2*v3[i]+v4[i])/6
  if math.abs(x[i])>c.railLimit then x[i]=math.clamp(x[i],-c.railLimit,c.railLimit);if x[i]*v[i]>0 then v[i]=0 end end
 end
end
function Numeric.step(self: any,drive: {number}): any
 local c=self.config;self.q=Mechanics.project(c,drive)
 for _=1,c.stepsPerBar do for _=1,c.numericSubsteps do self:_advance(c.dt/c.numericSubsteps) end;self.totalSteps+=1 end
 self.totalBars+=1;return self:read()
end
return Mechanics
