-- Executed by spring-lane-display-driver.mjs against the actual production module.
return function(loadDisplay)
 local passed,failed=0,0
 local function test(name,fn)
  local ok,err=pcall(fn)
  if ok then passed+=1;print("PASS "..name) else failed+=1;print("FAIL "..name..": "..tostring(err)) end
 end
 local function rejects(fn,fragment)
  local ok,err=pcall(fn);assert(not ok,"expected rejection")
  if fragment then assert(string.find(string.lower(tostring(err)),string.lower(fragment),1,true),"wrong error: "..tostring(err)) end
 end
 local function fixture()
  local f={all={},originals={},originalWrites={},createdClasses={},watch=false}
  local VM={};VM.__index=VM
  local function vector(x,y,z)return setmetatable({X=x or 0,Y=y or 0,Z=z or 0,_kind="Vector3"},VM)end
  VM.__add=function(a,b)return vector(a.X+b.X,a.Y+b.Y,a.Z+b.Z)end
  VM.__sub=function(a,b)return vector(a.X-b.X,a.Y-b.Y,a.Z-b.Z)end
  VM.__mul=function(a,b)if type(a)=="number"then return vector(a*b.X,a*b.Y,a*b.Z)end;return vector(a.X*b,a.Y*b,a.Z*b)end
  VM.__eq=function(a,b)return a.X==b.X and a.Y==b.Y and a.Z==b.Z end
  f.Vector3={new=vector,zero=vector(),one=vector(1,1,1)}
  local CM={};CM.__index=CM
  local function cf(...)
   local args={...};local x,y,z=0,0,0
   if type(args[1])=="table"then x,y,z=args[1].X,args[1].Y,args[1].Z
   elseif #args>0 then x,y,z=args[1],args[2]or 0,args[3]or 0 end
   local r=if #args==12 then {table.unpack(args,4,12)}else {1,0,0,0,1,0,0,0,1}
   return setmetatable({_kind="CFrame",Position=vector(x,y,z),_r=r},CM)
  end
  function CM:GetComponents()return self.Position.X,self.Position.Y,self.Position.Z,table.unpack(self._r)end
  CM.__add=function(a,b)local p=a.Position+b;return cf(p.X,p.Y,p.Z,table.unpack(a._r))end
  CM.__sub=function(a,b)return a+vector(-b.X,-b.Y,-b.Z)end
  CM.__eq=function(a,b)
   if a.Position~=b.Position then return false end
   for k=1,9 do if a._r[k]~=b._r[k]then return false end end;return true
  end
  f.CFrame={new=cf,identity=cf()}
  local function color(r,g,b)return {R=r,G=g,B=b,_kind="Color3"}end
  f.Color3={new=color,fromRGB=function(r,g,b)return color(r/255,g/255,b/255)end}
  local function signal()
   local s={listeners={}}
   function s:Connect(fn)
    local c={Connected=true};function c:Disconnect()self.Connected=false end
    table.insert(self.listeners,{fn=fn,c=c});return c
   end
   function s:Fire()for _,it in table.clone(self.listeners)do if it.c.Connected then it.fn()end end end
   return s
  end
  local IM={};local methods={}
  IM.__index=function(self,k)
   if methods[k]then return methods[k]end
   if k=="Position"and self._class=="Part"then return self._props.CFrame.Position end
   return self._props[k]
  end
  IM.__newindex=function(self,k,v)
   if f.watch and f.originals[self]then table.insert(f.originalWrites,self.Name.."."..k)end
   if k=="Parent"then
    local old=self._props.Parent
    if old then for i,child in old._children do if child==self then table.remove(old._children,i);break end end end
    if v then table.insert(v._children,self)end
   end
   self._props[k]=v
  end
  function methods:IsA(kind)
   return kind==self._class or kind=="Instance" or(kind=="BasePart"and self._class=="Part")
    or(kind=="Constraint"and(self._class=="SpringConstraint"or self._class=="PrismaticConstraint"))
  end
  function methods:GetChildren()return table.clone(self._children)end
  function methods:GetDescendants()
   local out={};local function walk(node)for _,child in node._children do table.insert(out,child);walk(child)end end
   walk(self);return out
  end
  function methods:IsDescendantOf(parent)local p=self.Parent;while p do if p==parent then return true end;p=p.Parent end;return false end
  function methods:FindFirstChild(name,recursive)
   for _,child in self._children do if child.Name==name then return child end end
   if recursive then for _,child in self._children do local got=child:FindFirstChild(name,true);if got then return got end end end
   return nil
  end
  function methods:GetFullName()return if self.Parent then self.Parent:GetFullName().."."..self.Name else self.Name end
  function methods:SetAttribute(k,v)self._attrs[k]=v end
  function methods:GetAttribute(k)return self._attrs[k]end
  function methods:Destroy()
   if self._dead or self._destroying then return end
   rawset(self,"_destroying",true);self.Destroying:Fire()
   for _,child in table.clone(self._children)do child:Destroy()end
   self.Parent=nil;rawset(self,"_dead",true);rawset(self,"_destroying",false)
  end
  local function instance(kind)
   local props={Name=kind,ClassName=kind,Destroying=signal()}
   if kind=="Part"then
    props.CFrame=cf();props.AssemblyLinearVelocity=vector();props.AssemblyAngularVelocity=vector();props.AssemblyMass=3.375
    props.Size=vector(1.5,1.5,1.5);props.Anchored=false;props.CanCollide=false;props.CanTouch=false;props.CanQuery=false
    props.Color=color(1,.5,0);props.Transparency=0;props.Massless=false;props.CustomPhysicalProperties={Density=1}
   elseif kind=="Attachment"then props.CFrame=cf();props.Axis=vector(1,0,0);props.SecondaryAxis=vector(0,1,0)end
   local obj=setmetatable({_kind="Instance",_class=kind,_props=props,_children={},_attrs={}},IM)
   table.insert(f.all,obj);if f.watch then table.insert(f.createdClasses,kind)end;return obj
  end
  f.Instance={new=instance}
  f.typeof=function(v)return if type(v)=="table"and v._kind then v._kind else type(v)end
  local function make(kind,name,parent)local obj=instance(kind);obj.Name=name;obj.Parent=parent;return obj end
  f.workspace=make("Workspace","Workspace")
  f.container=make("Model","RoAlgoSpringLiveLanes",f.workspace)
  f.lanes={};f.runner={parts={}}
  local function attachment(name,parent)local a=make("Attachment",name,parent);return a end
  for k=1,2 do
   local offset=(k-1.5)*13060
   local model=make("Model","Lane0"..k,f.container)
   local config={spacing=256,anchorOffset=512,railLimit=224,nodeSize=1.5,nodes={},edges={{a=1,b=2}}}
   local lane={index=k,offsetZ=offset,config=config,engine={model=model,config=config}}
   for r,variant in {"coupled","independent"}do
    local rig={nodes={},parts={},couplings={},coupled=r==1,model=make("Model",variant,model)}
    for i=1,2 do
     local rest=vector(0,1024+(2-i)*256,1024+offset+(i-1)*256+(if r==2 then 2816 else 0))
     local body=make("Part","Node"..i,rig.model);body.CFrame=cf(rest)
     local guide=make("Part","Guide"..i,rig.model);guide.CFrame=cf(rest);guide.Anchored=true
     local anchor=make("Part","Anchor"..i,rig.model);anchor.CFrame=cf(rest-vector(512,0,0));anchor.Anchored=true
     local center=attachment("Center",body);local axialAnchor=attachment("AxialAnchor",anchor);local guideAxis=attachment("GuideAxis",guide)
     local spring=make("SpringConstraint","NativeAxialSpring",body)
     spring.Attachment0=axialAnchor;spring.Attachment1=center;spring.FreeLength=512;spring.Stiffness=2;spring.Damping=1;spring.MaxForce=1000
     local rail=make("PrismaticConstraint","PassiveXAxisRail",body)
     rail.Attachment0=guideAxis;rail.Attachment1=center;rail.LimitsEnabled=true;rail.LowerLimit=-224;rail.UpperLimit=224;rail.ActuatorType="None"
     local force=make("VectorForce","ProjectedMarketDrive",body);force.Attachment0=center;force.Force=vector(2,0,0);force.ApplyAtCenterOfMass=true;force.RelativeTo="World"
     rig.nodes[i]={part=body,guide=guide,anchor=anchor,rest=rest,attachment=center,axial=spring,rail=rail,force=force}
     rig.parts[i]=body;table.insert(f.runner.parts,body)
     config.nodes[i]={index=i,bank=i,y=(2-i)*256,z=(i-1)*256}
    end
    if r==1 then
     local spring=make("SpringConstraint","Couple01_02",rig.model);spring.Attachment0=rig.nodes[1].attachment;spring.Attachment1=rig.nodes[2].attachment
     spring.FreeLength=256;spring.Stiffness=2;spring.Damping=1;spring.MaxForce=1000;rig.couplings[1]=spring
    end
    lane[variant]=rig
   end
   f.lanes[k]=lane
  end
  for k=1,2 do table.insert(f.runner.parts,make("Part","Metronome"..k,f.container))end
  for _,obj in f.all do f.originals[obj]=true end
  f.partList=f.runner.parts;f.partOrder=table.clone(f.runner.parts)
  local CS={new=function(...)return{_kind="ColorSequence",...}end}
  local NS={new=function(...)return{_kind="NumberSequence",...}end}
  -- typeof is passed separately to avoid using a globally available Roblox implementation in CLI.
  f.module=loadDisplay(f.Instance,f.Vector3,f.CFrame,f.Color3,CS,NS,{},f.typeof)
  f.watch=true
  function f:assertUntouched()
   assert(#self.originalWrites==0,"original physics property writes: "..table.concat(self.originalWrites,","))
   assert(self.runner.parts==self.partList and #self.runner.parts==#self.partOrder,"runner list identity/length changed")
   for i,p in self.partOrder do assert(self.runner.parts[i]==p,"runner part order changed")end
   for _,kind in self.createdClasses do assert(kind~="Part"and kind~="SpringConstraint"and kind~="PrismaticConstraint"and kind~="VectorForce","created physical class "..kind)end
  end
  function f:owned()
   local out={};for _,obj in self.all do if not self.originals[obj]and not obj._dead then table.insert(out,obj)end end;return out
  end
  return f
 end

 test("translated adornments and beams use live source endpoints without physics writes",function()
  local f=fixture();local view=f.module.mount(f.container,f.lanes,{runner=f.runner})
  assert(view.root.Name=="RoAlgoSpringLaneDisplay"and view.root.Parent==f.container)
  local info=view:describe();assert(info.bodyCount==8 and info.axialCount==8 and info.couplingCount==2)
  assert(info.layerSpacing==800 and info.sphereRadius==16 and info.invariants.mountPhysicsUnchanged==true)
  local spheres,beams=0,0
  for _,obj in f:owned()do
   if obj:IsA("SphereHandleAdornment")then
    spheres+=1;assert(obj.Radius==16)
    local found=false
    for k,lane in f.lanes do for _,rig in {lane.coupled,lane.independent}do for _,node in rig.nodes do
     if obj.Adornee==node.part then
      assert(obj.CFrame==f.CFrame.new((k-1.5)*800,0,-lane.offsetZ),"wrong adornment translation")
      found=true
     end
    end end end
    assert(found,"marker does not follow a lane body")
   elseif obj:IsA("Beam")then
    beams+=1;assert(obj.Attachment0 and obj.Attachment1)
    assert(not f.originals[obj.Attachment0]and not f.originals[obj.Attachment1],"beam reused physical attachments")
    local pair=false
    for k,lane in f.lanes do for _,rig in {lane.coupled,lane.independent}do
     local sources={};for _,node in rig.nodes do table.insert(sources,node.axial)end
     for _,spring in rig.couplings do table.insert(sources,spring)end
     for _,spring in sources do
      if obj.Attachment0.Parent==spring.Attachment0.Parent and obj.Attachment1.Parent==spring.Attachment1.Parent then
       local delta=f.Vector3.new((k-1.5)*800,0,-lane.offsetZ)
       assert(obj.Attachment0.CFrame==spring.Attachment0.CFrame+delta and obj.Attachment1.CFrame==spring.Attachment1.CFrame+delta,"wrong beam endpoint translation")
       pair=true
      end
     end
    end end
    assert(pair,"beam joins the wrong bodies")
   end
  end
  assert(spheres==8 and beams==10)
  for k,anchor in view.labelAnchors do
   assert(anchor.Parent==f.lanes[k].coupled.nodes[1].guide and anchor.CFrame==f.CFrame.new((k-1.5)*800,0,-f.lanes[k].offsetZ))
  end
  f:assertUntouched();view:destroy();f:assertUntouched();assert(#f:owned()==0,"owned visual instances leaked")
 end)

 test("explicit cleanup is idempotent and removes body-owned attachments",function()
  local f=fixture();local before=#f.container:GetDescendants();local view=f.module.mount(f.container,f.lanes,{runner=f.runner})
  assert(#f.container:GetDescendants()>before)
  view:destroy();view:destroy()
  assert(#f.container:GetDescendants()==before and #f:owned()==0)
  f:assertUntouched()
 end)

 test("external display-root destruction also removes body-owned attachments",function()
  local f=fixture();local view=f.module.mount(f.container,f.lanes,{runner=f.runner})
  view.root:Destroy();assert(#f:owned()==0,"display deletion leaked remote attachments")
  view:destroy();f:assertUntouched()
 end)

 test("rotated native body is rejected before visuals are constructed",function()
  local f=fixture();f.watch=false;f.lanes[1].coupled.nodes[1].part.CFrame=f.CFrame.new(0,1280,-5506,0,0,1,0,1,0,-1,0,0);f.watch=true
  rejects(function()f.module.mount(f.container,f.lanes,{runner=f.runner})end,"rotation")
  assert(#f:owned()==0);f:assertUntouched()
 end)

 test("cross-lane physical connector is rejected without creating a display",function()
  local f=fixture();f.watch=false
  f.lanes[1].coupled.nodes[1].axial.Attachment0=f.lanes[2].coupled.nodes[1].attachment;f.watch=true
  rejects(function()f.module.mount(f.container,f.lanes,{runner=f.runner})end)
  assert(#f:owned()==0);f:assertUntouched()
 end)

 test("duplicate stepped body is rejected instead of masking runner selection",function()
  local f=fixture();f.runner.parts[2]=f.runner.parts[1]
  rejects(function()f.module.mount(f.container,f.lanes,{runner=f.runner})end)
  assert(#f:owned()==0 and #f.originalWrites==0)
 end)

 print(string.format("SpringLaneDisplay: %d passed, %d failed",passed,failed))
 assert(failed==0,"SpringLaneDisplay failures")
end
