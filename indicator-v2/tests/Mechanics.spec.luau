-- Behavior tests catch lost pretension, wrong damping projection, unstable integration,
-- stale reset state, accidentally coupled independent rig, and incorrect normalization.
local ok, Mechanics = pcall(require, '../src/Mechanics')
assert(ok and type(Mechanics) == 'table', 'Mechanics implementation is required for real dynamics tests')
local function near(a,b,tol,message) assert(math.abs(a-b)<=tol, message .. ': '..tostring(a)..' vs '..tostring(b)) end
local function finite(x) return x==x and math.abs(x)<math.huge end
local edge = {transverse=256, freeLength=192, k=10, c=3, maxForce=1e6}
near(Mechanics.edgeForce(192,5,edge),773.4,1e-9,'stretched spring force includes projected relative damping')
near(Mechanics.edgeForce(0.001,0,edge)/0.001,2.5,1e-9,'pretension has quarter-stiffness small-signal tangent')
assert(Mechanics.edgeForce(192,0,edge)/192 > 3.9,'large excursions change coupling stiffness')
near(Mechanics.edgeForce(-192,-5,edge),-773.4,1e-9,'coupling force is signed')
local a = Mechanics.new(nil,true)
local independent = Mechanics.new(nil,false)
local zero = table.create(8,0)
for _=1,20 do
 local state=a:step(zero)
 for _,value in state.vector do near(value,0,1e-12,'zero stays at equilibrium') end
end
local plus=table.create(8,1)
local first=a:step(plus)
assert(#first.vector==51 and #first.nodes==24 and #first.banks==3,'complete readout')
assert(first.banks[1].displacement>first.banks[2].displacement and first.banks[2].displacement>first.banks[3].displacement,'bank speed order')
for _,node in first.nodes do assert(node.x>0 and node.v>0,'positive drive produces positive motion') end
local mixed={1,-1,0.5,-0.5,0.75,-0.75,1.5,-1.5}
a:reset()
local initial=a:step(mixed)
local isolated=independent:step(mixed)
local difference=0
for i=1,48 do difference=math.max(difference,math.abs(initial.vector[i]-isolated.vector[i])) end
assert(difference>1e-5,'removing coupling changes trajectory')
local sequence={plus,mixed,zero,plus,zero}
local replay={}
a:reset()
for i,d in sequence do replay[i]=a:step(d).vector end
a:reset()
for i,d in sequence do
 local current=a:step(d).vector
 for j=1,51 do near(current[j],replay[i][j],1e-12,'reset exactly replays numerical state') end
end
local negative=table.create(8,-1)
a:reset()
local positive=a:step(plus)
a:reset()
local negativeState=a:step(negative)
for i=1,48 do near(positive.vector[i],-negativeState.vector[i],1e-12,'signed numerical symmetry') end
for _=1,1000 do
 local state=a:step(mixed)
 for _,v in state.vector do assert(finite(v),'bounded input cannot create nonfinite state') end
 for _,node in state.nodes do assert(math.abs(node.x)<3.5,'stable input remains inside rail') end
end
local held=a:read()
for _=1,120 do a:step(zero) end
assert(a:read().energy<held.energy*1e-6,'release dissipates energy')
local bad=pcall(function() a:step({0/0,0,0,0,0,0,0,0}) end)
assert(not bad,'nonfinite drive is rejected')
print('PASS Mechanics.spec: geometry, damping, direction, timescales, coupling, reset, stability, release, finite validation')
