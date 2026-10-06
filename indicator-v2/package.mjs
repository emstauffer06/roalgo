// Local inspectable Roblox packages. The source model has no executable Script.
import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {ROOT,sourceTree} from './bridge.mjs';
const hash=x=>createHash('sha256').update(x).digest('hex');
const xml=s=>{
  const text=String(s);if(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/.test(text))throw Error('Invalid XML source character');
  return text.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll('\r','&#13;');
};
function stringAttribute(name,value){
  // Roblox AttributesSerialize: count u32, name length/string, type2, value length/string.
  const n=Buffer.from(name),v=Buffer.from(value),b=Buffer.alloc(4+4+n.length+1+4+v.length);let p=0;
  b.writeUInt32LE(1,p);p+=4;b.writeUInt32LE(n.length,p);p+=4;n.copy(b,p);p+=n.length;b[p++]=2;b.writeUInt32LE(v.length,p);p+=4;v.copy(b,p);
  return b.toString('base64');
}
export const bootstrap=`-- RoAlgo Research local plugin. Historical research; no orders/publishing.
if game.PlaceId ~= 0 then return end
if not plugin or game:GetService("RunService"):IsRunning() then return end
local CoreGui = game:GetService("CoreGui")
local App = require(script.Parent.src.App)
local toolbar = plugin:CreateToolbar("RoAlgo Research")
local button = toolbar:CreateButton("RoAlgoResearch", "Open learned mechanical research", "")
local function open()
 local control = CoreGui:FindFirstChild("RoAlgoResearchControl")
 if control then
  local gui = CoreGui:FindFirstChild("RoAlgoResearchDashboard")
  if gui and gui:IsA("ScreenGui") then gui.Enabled = not gui.Enabled end
 else
  local ok, err = pcall(App.start, {plugin=plugin})
  if not ok then warn("RoAlgo Research startup: "..tostring(err)) end
 end
end
button.Click:Connect(open)
task.defer(function()
 if not CoreGui:FindFirstChild("RoAlgoResearchControl") then
  local ok, err = pcall(App.start, {plugin=plugin})
  if not ok then warn("RoAlgo Research startup: "..tostring(err)) end
 end
end)
plugin.Unloading:Connect(function()
 local control = CoreGui:FindFirstChild("RoAlgoResearchControl")
 if control then
  local ok, err = pcall(function()
   control:Invoke("stop")
   while control:Invoke("status").busy do task.wait() end
   control:Invoke("destroy")
  end)
  if not ok then warn("RoAlgo Research unload: "..tostring(err)) end
 end
end)
`;
export function modelXML(files,plugin=false){
  let nextId=0;
  const item=(kind,name,props='',children='')=>`<Item class="${kind}" referent="ROALGOV2${nextId++}"><Properties><string name="Name">${xml(name)}</string>${props}</Properties>${children}</Item>`;
  const grouped=new Map(),seen=new Set();
  for(const f of files){
    if(!/^(src|tests)\/[A-Za-z0-9_]+$/.test(f.path)||seen.has(f.path)||typeof f.source!=='string'||typeof f.sha256!=='string')throw Error('Invalid/duplicate module definition');
    seen.add(f.path);const [folder,name]=f.path.split('/');if(!grouped.has(folder))grouped.set(folder,[]);
    const provenance=item('StringValue','SourceSHA256',`<string name="Value">${xml(f.sha256)}</string>`);
    const props=`<ProtectedString name="Source">${xml(f.source)}</ProtectedString><BinaryString name="AttributesSerialize">${stringAttribute('sha256',f.sha256)}</BinaryString>`;
    grouped.get(folder).push(item('ModuleScript',name,props,provenance));
  }
  let children=[...grouped].map(([name,list])=>item('Folder',name,'',list.join(''))).join('');
  if(plugin)children+=item('Script','Main',`<ProtectedString name="Source">${xml(bootstrap)}</ProtectedString>`);
  return `<roblox version="4"><External>null</External><External>nil</External>${item('Model','RoAlgoResearch','',children)}</roblox>\n`;
}
export function build({directory=join(ROOT,'build'),files=sourceTree()}={}){
  for(const required of ['App','Dashboard','PhysicsView','Features','Regime','Engine','Mechanics','Learning','Execution','VerifiedStepper'])if(!files.some(f=>f.path==='src/'+required))throw Error('Missing '+required);
  for(const f of files)if(hash(f.source)!==f.sha256)throw Error('Source hash mismatch '+f.path);
  const bytes={'RoAlgoResearch.rbxmx':modelXML(files,false),'RoAlgoResearch.plugin.rbxmx':modelXML(files,true)};
  const installHashes=Object.fromEntries(['Install-In-Studio.luau','Start-RoAlgo.ps1','package.mjs','bridge.mjs'].map(f=>[f,hash(readFileSync(join(ROOT,f)))]));
  const artifacts=Object.fromEntries(Object.entries(bytes).map(([name,s])=>[name,hash(s)]));
  const manifest={schemaVersion:2,placeId:0,bridge:'http://127.0.0.1:47623',pluginInstallName:'RoAlgoResearch.rbxmx',pluginArtifact:'RoAlgoResearch.plugin.rbxmx',scope:'Historical exploratory research; earlier date ranges have already been inspected',nativeSteps:0,artifacts,sources:files.map(({path,sha256})=>({path,sha256})),sourceTreeHash:hash(JSON.stringify(files.map(({path,sha256})=>({path,sha256})))),installHashes};
  mkdirSync(directory,{recursive:true});for(const [name,s]of Object.entries(bytes))writeFileSync(join(directory,name),s);
  writeFileSync(join(directory,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
  return {directory,modules:files.length,artifacts,manifest};
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){const {directory,modules,artifacts}=build();console.log(JSON.stringify({directory,modules,artifacts}));}
