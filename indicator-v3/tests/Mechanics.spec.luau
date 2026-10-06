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
local zero = table.create(12,0)
for _=1,20 do
 local state=a:step(zero)
 for _,value in state.vector do near(value,0,1e-12,'zero stays at equilibrium') end
end
local plus=table.create(12,1)
local first=a:step(plus)
assert(#first.vector==59 and #first.nodes==24 and #first.banks==3,'complete readout')
assert(first.banks[1].displacement>first.banks[2].displacement and first.banks[2].displacement>first.banks[3].displacement,'bank speed order')
for _,node in first.nodes do assert(node.x>0 and node.v>0,'positive drive produces positive motion') end
local mixed={1,-1,0.5,-0.5,0.75,-0.75,1.5,-1.5,0.3,-0.3,0.8,-0.8}
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
 for j=1,59 do near(current[j],replay[i][j],1e-12,'reset exactly replays numerical state') end
end
local negative=table.create(12,-1)
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
local bad=pcall(function() a:step({0/0,0,0,0,0,0,0,0,0,0,0,0}) end)
assert(not bad,'nonfinite drive is rejected')
print('PASS Mechanics.spec: geometry, damping, direction, timescales, coupling, reset, stability, release, finite validation')

-- Catch silently ignored architecture options, broken endpoints, topology aliasing,
-- mislabeled projections and state schemas tied to one reservoir size.
for _,count in {24,48} do
 for _,topology in {'grouped','grid'} do
  for _,response in {'diverse','balanced'} do
   local cfg=Mechanics.config({nodeCount=count,topology=topology,response=response})
   assert(#cfg.nodes==count and cfg.nodeCount==count,'requested node count controls the physical system')
   assert(cfg.id==topology..tostring(count)..'-'..response,'architecture identity records every option')
   local seen,bankCounts,groupCounts={},{0,0,0},{0,0,0,0}
   local signed=false
   for i,n in cfg.nodes do
    assert(n.index==i and #n.projection==12 and n.group>=1 and n.group<=4,'all nodes describe the actual market projection')
    bankCounts[n.bank]+=1;groupCounts[n.group]+=1
    local norm=0
    for _,w in n.projection do norm+=math.abs(w);signed=signed or w<0 end
    near(norm,1,1e-12,'fixed projection L1 norm bounds force')
    assert(n.projection[n.dominantDrive]==0.72,'dominant label identifies actual strongest coefficient')
    assert(n.z==(n.column-1)*256 and n.y==(3-n.bank)*256,'rest geometry is shared by numeric/native configurations')
    assert(n.k>0 and n.c>0 and n.mass>0,'passive axial dynamics')
   end
   assert(signed,'fixed projections retain signed relative contributions')
   for _,v in bankCounts do assert(v==count/3,'equal response bank widths') end
   for _,v in groupCounts do assert(v==count/4,'equal financial group counts') end
   for _,e in cfg.edges do
    assert(e.a>=1 and e.b<=count and e.a<e.b and not seen[e.a..':'..e.b],'valid unique spring endpoints')
    seen[e.a..':'..e.b]=true
    assert(e.k>=0 and e.c>=0 and e.freeLength>0 and e.freeLength<e.transverse,'coupling is a passive pretensioned spring')
    local n,m=cfg.nodes[e.a],cfg.nodes[e.b]
    near(e.transverse,math.sqrt((n.y-m.y)^2+(n.z-m.z)^2),1e-9,'native edge rest length follows geometry')
   end
   local numeric=Mechanics.new(cfg,true)
   local state=numeric:step(mixed)
   assert(#state.vector==2*count+11 and #state.names==#state.vector and #state.nodes==count,'dynamic named state schema')
   assert(state.names[count+1]==cfg.nodes[1].name..'.v' and state.names[2*count+1]=='Fast.energy','state positions remain discoverable')
   local values={}
   for i,v in state.vector do assert(finite(v) and not values[state.names[i]],'finite uniquely named state');values[state.names[i]]=true end
   assert(state.measurementOrigin=='derived-from-x-v','derived mechanics explicitly distinguished from measured position/velocity')
  end
 end
end
local grouped,grid=Mechanics.config({topology='grouped'}),Mechanics.config({topology='grid'})
local edgeSets={}
for _,e in grouped.edges do edgeSets[e.a..':'..e.b]=true end
local differs=false
for _,e in grid.edges do if not edgeSets[e.a..':'..e.b] then differs=true end end
assert(differs,'grouped and grid are distinct coupling graphs')
for _,badOptions in {{nodeCount=25},{topology='bad'},{response='bad'}} do assert(not pcall(Mechanics.config,badOptions),'invalid architecture fails before construction') end
print('PASS Mechanics architecture options:24/48,grouped/grid,diverse/balanced,truthful projections,dynamic schema')
local wideA=Mechanics.new(Mechanics.config({nodeCount=48}),true)
local wideB=Mechanics.new(Mechanics.config({nodeCount=48}),true)
local lastWide=nil
for step=1,300 do
 local input=if step%7==0 then zero else mixed
 local x,y=wideA:step(input),wideB:step(input)
 for j,value in x.vector do assert(finite(value) and value==y.vector[j],'48-node finite deterministic repeated trajectories') end
 for _,n in x.nodes do assert(math.abs(n.x)<3.5,'48-node sustained drive stays inside rails') end
 lastWide=x
end
local heldWide=lastWide.energy
for _=1,120 do lastWide=wideA:step(zero) end
assert(lastWide.energy<heldWide*1e-6,'48-node released reservoir dissipates energy')
assert(wideA.totalBars==420 and wideA.totalSteps==5040,'numeric protocol counts every configured interval')
print('PASS Mechanics48 sustained response, repeatability, release and interval accounting')
