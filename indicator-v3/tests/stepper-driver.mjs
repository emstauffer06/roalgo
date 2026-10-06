// Executes actual VerifiedStepper source with injected Roblox platform/scheduling doubles.
// This verifies orchestration behavior only; Studio tests verify real native physics.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const here=path.dirname(fileURLToPath(import.meta.url));
const sourcePath=process.argv[2]?path.resolve(process.argv[2]):path.join(here,'../src/VerifiedStepper.luau');
const source=fs.readFileSync(sourcePath,'utf8');
const spec=fs.readFileSync(path.join(here,'Stepper.spec.luau'),'utf8');
const generated=path.join(here,'Stepper.generated.luau');
const fixture=String.raw`
local function makeFixture(options)
 local sim={frame=0,requests=0,reads=0,events={}}
 local V={new=function(x,y,z)return {X=x,Y=y,Z=z}end};V.zero=V.new(0,0,0)
 local CF={new=V.new}
 local function body()
  local properties={Position=V.zero,AssemblyLinearVelocity=V.zero,AssemblyAngularVelocity=V.zero}
  return setmetatable({}, {
   __index=function(_,k)if k=="Destroy"then return function()end end;return properties[k]end,
   __newindex=function(_,k,value)properties[k]=value;if k=="CFrame"then properties.Position=value end end,
  })
 end
 local I={new=function(kind)assert(kind=="Part");return body()end}
 local world={Gravity=196.2}
 local function apply(parts)
  for _,p in parts do local v=p.AssemblyLinearVelocity;p.AssemblyLinearVelocity=V.new(v.X,v.Y-world.Gravity/60,v.Z)end
 end
 local function waitFrame()
  sim.frame+=1
  local pending={}
  for _,event in sim.events do if event.at<=sim.frame then apply(event.parts)else table.insert(pending,event)end end
  sim.events=pending
 end
 local service={IsRunning=function()return false end,Heartbeat={Wait=waitFrame}}
 local g={GetService=function(_,name)assert(name=="RunService");return service end}
 local moving=body()
 local rig={model={}}
 function rig:movingParts()return {moving}end
 function rig:reset()moving.AssemblyLinearVelocity=V.zero end
 function rig:drive(_)end
 function rig:read()sim.reads+=1;return {-moving.AssemblyLinearVelocity.Y/(world.Gravity/60)}end
 local function stepper(dt,parts)
  assert(dt==1/60)
  sim.requests+=1
  if sim.requests==1 and options.firstDropped then return end
  local delay=if sim.requests==1 and options.firstDelay then options.firstDelay else 1
  table.insert(sim.events,{at=sim.frame+delay,parts=parts})
  if sim.requests==12 and options.extraAfterLast then table.insert(sim.events,{at=sim.frame+2,parts=parts})end
 end
 return g,world,I,V,CF,sim,rig,stepper,waitFrame
end
`;
const code=`${fixture}\nlocal function loadRunner(game,workspace,Instance,Vector3,CFrame)\n${source}\nend\nlocal runTests=(function()\n${spec}\nend)()\nrunTests(function(options)\nlocal g,w,I,V,CF,sim,rig,stepper,waitFrame=makeFixture(options)\nlocal Runner=loadRunner(g,w,I,V,CF)\nreturn Runner.new({rig},{dt=1/60,stepsPerBar=12,settleSteps=0,parent=rig.model,stepper=stepper,waitFrame=waitFrame,warmupFrames=0}),sim\nend)\n`;
try{
 fs.writeFileSync(generated,code);
 const run=spawnSync((process.env.LUAU_EXE||'luau'),[generated],{encoding:'utf8'});
 process.stdout.write(run.stdout??'');process.stderr.write(run.stderr??'');
 if(run.error)throw run.error;
 process.exitCode=run.status??1;
}finally{fs.unlinkSync(generated);}
