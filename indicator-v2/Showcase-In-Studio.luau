-- Refresh the idle showcase from local sources, preserving the completed presentation.
-- No historical capture is continued: the replacement runner starts with zero steps.
assert(game.PlaceId==0 and not game:GetService("RunService"):IsRunning(),"RoAlgo Edit required")
local Http=game:GetService("HttpService")
local Core=game:GetService("CoreGui")
local storage=game:GetService("ServerStorage")
local function idle()
 for _,name in {"RoAlgoIndicatorControl","RoAlgoResearchControl"} do
  local control=Core:FindFirstChild(name)
  if control then assert(not control:Invoke("status").busy,"Capture active") end
 end
end
idle()
local current=assert(Core:FindFirstChild("RoAlgoResearchControl"),"Missing controller")
local status=current:Invoke("status")
assert(status.phase=="complete" and status.exportPath,"Completed saved result required")
local savedName=status.exportPath:match("([^/\\]+%.json)$")
assert(savedName and savedName:match("^[A-Za-z0-9_.-]+$"),"Invalid saved result name")
local oldModel=assert(workspace:FindFirstChild("RoAlgoResearchPhysics"),"Missing current rigs")
local pose={}
for _,rigName in {"Coupled","Independent"} do
 local rig=oldModel[rigName];pose[rigName]={}
 for _,p in rig:GetChildren() do
  local i=p:GetAttribute("NodeIndex")
  if p:IsA("BasePart") and i then
   pose[rigName][i]={relative=rig["Guide"..i].CFrame:ToObjectSpace(p.CFrame),linear=p.AssemblyLinearVelocity,
    angular=p.AssemblyAngularVelocity,force=p.ProjectedMarketDrive.Force}
  end
 end
 assert(#pose[rigName]==24,"Incomplete node snapshot")
end
local tree=Http:JSONDecode(Http:GetAsync("http://127.0.0.1:47623/tree"))
local root=Instance.new("Folder");root.Name="RoAlgoResearch_showcase_candidate_"..DateTime.now().UnixTimestampMillis
local seen={}
for _,f in tree.files do
 assert(f.path:match("^[a-z]+/[A-Za-z0-9_]+$") and not seen[f.path],"Invalid path")
 local bits=string.split(f.path,"/");assert(bits[1]=="src" or bits[1]=="tests")
 assert(type(f.source)=="string" and #f.sha256==64 and f.sha256:match("^[a-f0-9]+$"),"Invalid source")
 local dir=root:FindFirstChild(bits[1]);if not dir then dir=Instance.new("Folder");dir.Name=bits[1];dir.Parent=root end
 local m=Instance.new("ModuleScript");m.Name=bits[2];m.Source=f.source;m:SetAttribute("sha256",f.sha256)
 local h=Instance.new("StringValue");h.Name="SourceSHA256";h.Value=f.sha256;h.Parent=m;m.Parent=dir
 seen[f.path]=true
end
for _,n in {"App","Engine","Mechanics","VerifiedStepper","PhysicsView","Dashboard","Features","Regime","Learning","Execution"} do assert(seen["src/"..n],"Missing module") end
idle()
root.Parent=storage
local engine=require(root.src.Engine).new(workspace,{name="RoAlgoResearchShowcaseCandidate"})
local maxPoseError,maxVelocityError=0,0
for _,entry in {{name="Coupled",rig=engine.coupledRig},{name="Independent",rig=engine.independentRig}} do
 for i,n in entry.rig.nodes do
  local p=pose[entry.name][i]
  n.part.CFrame=n.guide.CFrame*p.relative
  n.part.AssemblyLinearVelocity=p.linear;n.part.AssemblyAngularVelocity=p.angular;n.force.Force=p.force
  entry.rig.q[i]=p.force.X/(engine.config.nodes[i].k*engine.config.D)
  maxPoseError=math.max(maxPoseError,(n.guide.CFrame:ToObjectSpace(n.part.CFrame).Position-p.relative.Position).Magnitude)
  maxVelocityError=math.max(maxVelocityError,(n.part.AssemblyLinearVelocity-p.linear).Magnitude,(n.part.AssemblyAngularVelocity-p.angular).Magnitude)
 end
end
assert(maxPoseError<0.001 and maxVelocityError<0.001,"Presentation restoration failed")
local view=require(root.src.PhysicsView).mount(engine.model)
idle()
local backup=storage:FindFirstChild("RoAlgoResearch")
if backup then backup.Name="RoAlgoResearch_backup_showcase_"..DateTime.now().UnixTimestampMillis end
root.Name="RoAlgoResearch"
local control=require(root.src.App).start({engine=engine})
engine.model.Name="RoAlgoResearchPhysics"
engine.model:SetAttribute("RestoredPresentationPose",true)
engine.model:SetAttribute("HistoricalResult",savedName)
control:Invoke("load",savedName)
control:Invoke("viewRig")
local s=control:Invoke("status")
return {layout=engine.model:GetAttribute("Layout"),spawnView=engine.model:GetAttribute("ViewFromSpawn"),
 centerSeparation=(engine.coupledRig.nodes[1].rest-engine.independentRig.nodes[1].rest).Magnitude,
 maxPoseError=maxPoseError,maxVelocityError=maxVelocityError,phase=s.phase,completed=s.completed,
 models=s.models,presentationNativeSteps=engine:stats().totalSteps,labels=view.counts,backup=backup and backup.Name}
