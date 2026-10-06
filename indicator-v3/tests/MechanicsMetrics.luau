local M=require('../src/Mechanics')
local a,b=M.new(nil,true),M.new(nil,false)
local drive={1,-1,.5,-.5,.75,-.75,1.5,-1.5,.3,-.3,.8,-.8}
local s,t=a:step(drive),b:step(drive)
local diff=0
for i=1,48 do diff=math.max(diff,math.abs(s.vector[i]-t.vector[i])) end
print('firstBarCouplingDifference',diff)
for _=1,1000 do s=a:step(drive) end
local maxX=0
for _,n in s.nodes do maxX=math.max(maxX,math.abs(n.x)) end
print('1001BarMaxNormalizedPosition',maxX,'heldEnergy',s.energy)
local e=s.energy
for _=1,120 do s=a:step(table.create(12,0)) end
print('releaseEnergy',s.energy,'energyRatio',s.energy/e)
local config=M.config()
print('nodeCount',#config.nodes,'edgeCount',#config.edges,'nominalMass',config.nodes[1].mass)
local small,large=table.create(12,0),table.create(12,0)
small[2]=.5; large[2]=2
local states={}
for r,d in {small,large} do
 a:reset(); b:reset()
 for _=1,12 do s=a:step(d);t=b:step(d) end
 states[r]={s.vector,t.vector}
end
local nonlin,linear=0,0
for i=1,48 do nonlin=math.max(nonlin,math.abs(states[2][1][i]/4-states[1][1][i]));linear=math.max(linear,math.abs(states[2][2][i]/4-states[1][2][i])) end
print('coupledNonlinearity',nonlin,'independentNonlinearity',linear)

