import {mkdirSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {ROOT,sourceTree} from './bridge.mjs';
const xml=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const bootstrap=`-- RoAlgo local plugin; inert in all other places.
if game.PlaceId ~= 0 then return end
local App = require(script.Parent.src.App)
local toolbar = plugin:CreateToolbar("RoAlgo")
local button = toolbar:CreateButton("RoAlgo", "Open the local physics indicator", "")
button.Click:Connect(function()
 local control=game:GetService("CoreGui"):FindFirstChild("RoAlgoIndicatorControl")
 if control then
  local gui=game:GetService("CoreGui"):FindFirstChild("RoAlgoDashboard")
  if gui and gui:IsA("ScreenGui") then gui.Enabled=not gui.Enabled end
 else App.start({plugin=plugin}) end
end)
task.defer(function() local ok,err=pcall(App.start,{plugin=plugin}) if not ok then warn("RoAlgo startup: "..tostring(err)) end end)
plugin.Unloading:Connect(function()
 local control=game:GetService("CoreGui"):FindFirstChild("RoAlgoIndicatorControl")
 if control then pcall(function()control:Invoke("stop")end) end
end)
`;
export function modelXML(files,plugin=false) {
  let nextId=0;
  const item=(kind,name,props='',children='')=>`<Item class="${kind}" referent="ROALGO${nextId++}"><Properties><string name="Name">${xml(name)}</string>${props}</Properties>${children}</Item>`;
  const grouped=new Map();
  for(const f of files) {
    if(!/^(src|tests)\/[A-Za-z0-9_]+$/.test(f.path)) throw Error('Invalid module path');
    const [folder,name]=f.path.split('/');
    if(!grouped.has(folder)) grouped.set(folder,[]);
    const provenance=item('StringValue','SourceSHA256',`<string name="Value">${xml(f.sha256??'')}</string>`);
    grouped.get(folder).push(item('ModuleScript',name,`<ProtectedString name="Source">${xml(f.source)}</ProtectedString>`,provenance));
  }
  let children=[...grouped].map(([name,list])=>item('Folder',name,'',list.join(''))).join('');
  if(plugin)children+=item('Script','Main',`<ProtectedString name="Source">${xml(bootstrap)}</ProtectedString>`);
  return `<roblox version="4"><External>null</External><External>nil</External>${item('Model','RoAlgoIndicator','',children)}</roblox>\n`;
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url) {
  const files=sourceTree();
  for(const required of ['App','Core','Meta','Engine','VerifiedStepper','Dashboard']) if(!files.some(f=>f.path==='src/'+required))throw Error('Missing '+required);
  const directory=join(ROOT,'build');mkdirSync(directory,{recursive:true});
  const artifacts={};
  for(const [name,plugin] of [['RoAlgoIndicator.rbxmx',false],['RoAlgoIndicator.plugin.rbxmx',true]]) {
    const bytes=modelXML(files,plugin);writeFileSync(join(directory,name),bytes);artifacts[name]=createHash('sha256').update(bytes).digest('hex');
  }
  writeFileSync(join(directory,'manifest.json'),JSON.stringify({artifacts,sources:files.map(({path,sha256})=>({path,sha256}))},null,2)+'\n');
  console.log(JSON.stringify({directory,modules:files.length,artifacts}));
}
