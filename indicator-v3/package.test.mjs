import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';

test('installer protects all busy versions, preserves v2 and replaces only idle v3',()=>{
 const source=readFileSync(new URL('./Install-In-Studio.luau',import.meta.url),'utf8'),dir=mkdtempSync(join(tmpdir(),'roalgo-v3-install-'));
 try {
 for(const mode of ['v1busy','v2busy','v3busy','idle','v2startsDuringFetch','badHealth','missingStudy']){
 const setup=`local mode='${mode}'
local mutations=0
local started=false
local destroyed={v1=0,v2=0,v3=0}
local function node(kind)
 local value={ClassName=kind,children={},attributes={}}
 local methods={}
 function methods:FindFirstChild(name)for _,v in self.children do if v.Name==name and not v.destroyed then return v end end return nil end
 function methods:SetAttribute(name,v)self.attributes[name]=v end
 function methods:Destroy()self.destroyed=true;mutations+=1 end
 return setmetatable(value,{__index=function(self,k)return methods[k] or methods.FindFirstChild(self,k) end,__newindex=function(self,k,v)if k=='Parent' and v then table.insert(v.children,self) end rawset(self,k,v);if k=='Name' or k=='Parent' then mutations+=1 end end})
end
local storage=node('ServerStorage')
local older=node('Folder');older.Name='RoAlgoResearch';older.Parent=storage
local old=node('Folder');old.Name='RoAlgoMarketLab';old.Parent=storage
local backup=node('Folder');backup.Name='RoAlgoMarketLab_backup_12345';backup.Parent=storage
local function control(version)return {Invoke=function(self,cmd)if cmd=='status' then return {busy=mode==version..'busy'} elseif cmd=='destroy' then destroyed[version]+=1;mutations+=1 end end}end
local controls={RoAlgoIndicatorControl=control('v1'),RoAlgoResearchControl=control('v2'),RoAlgoMarketControl=control('v3')}
local core={FindFirstChild=function(self,name)return controls[name] end}
local tree={files={}}
for _,name in {'App','Dashboard','PhysicsView','Features','Regime','Engine','Mechanics','Learning','Execution','VerifiedStepper'} do table.insert(tree.files,{path='src/'..name,source='return {}',sha256=string.rep('a',64)})end
if mode~='missingStudy' then table.insert(tree.files,{path='src/Study',source='return {}',sha256=string.rep('a',64)})end
local Http={GetAsync=function(self,url)
 assert(string.find(url,'127.0.0.1:47624',1,true),'installer must use isolated v3 bridge')
 if string.find(url,'/health',1,true)then return 'health' end
 if mode=='v2startsDuringFetch' then mode='v2busy' end
 return 'tree'
end,JSONDecode=function(self,text)if text=='health' then return {ok=true,app=mode=='badHealth' and 'wrong' or 'RoAlgo Market Lab',schemaVersion=3} end;return tree end}
local game={PlaceId=0,GetService=function(self,name)if name=='RunService' then return {IsRunning=function()return false end} elseif name=='HttpService' then return Http elseif name=='ServerStorage' then return storage elseif name=='CoreGui' then return core end;error(name)end}
local Instance={new=function(kind)mutations+=1;return node(kind)end}
local DateTime={now=function()return {UnixTimestampMillis=12345} end}
local require=function(module)assert(module.Name=='App');return {start=function()assert(mode=='idle');started=true;return 'started'end}end
local split=function(s)local out={}for v in string.gmatch(s,'[^/]+')do table.insert(out,v)end;return out end
local string=setmetatable({split=split},{__index=string})
mutations=0
`;
 const assertions=mode==='idle'?`assert(ok and started,tostring(err));assert(destroyed.v1==0 and destroyed.v2==0 and destroyed.v3==1,'only idle v3 is replaced');assert(older.Name=='RoAlgoResearch' and not older.destroyed,'v2 source survives unchanged');assert(old.Name=='RoAlgoMarketLab_backup_12345_2' and not old.destroyed,'v3 source backed up');assert(storage:FindFirstChild('RoAlgoMarketLab')~=old,'new v3 source installed')`
 :mode==='missingStudy'?`assert(not ok and string.find(tostring(err),'Missing Study'),tostring(err));assert(old.Name=='RoAlgoMarketLab' and not old.destroyed and destroyed.v3==0,'missing Study preserves current installation')`
 :`assert(not ok and not started,'invalid/busy installation rejected');assert(mutations==0,'busy/identity rejection precedes mutation');assert(old.Name=='RoAlgoMarketLab' and not old.destroyed,'old v3 source unchanged');assert(destroyed.v1+destroyed.v2+destroyed.v3==0,'no live controller destroyed')`;
 const f=join(dir,mode+'.luau');writeFileSync(f,setup+'local function install()\n'+source+'\nend\nlocal ok,err=pcall(install)\n'+assertions+"\nprint('PASS installer isolation')\n");
 const r=spawnSync((process.env.LUAU_EXE||'luau'),[f],{encoding:'utf8',timeout:10000});assert.equal(r.status,0,mode+'\n'+r.stdout+r.stderr);
 }
 }finally{rmSync(dir,{recursive:true,force:true});}
});

test('build refuses an omitted Study dependency without creating artifacts',async()=>{
 const {build}=await import('./package.mjs'),dir=mkdtempSync(join(tmpdir(),'roalgo-v3-no-study-'));
 try{const files=['App','Dashboard','PhysicsView','Features','Regime','Engine','Mechanics','Learning','Execution','VerifiedStepper'].map(n=>({path:'src/'+n,source:'return {}',sha256:createHash('sha256').update('return {}').digest('hex')}));assert.throws(()=>build({directory:dir,files}),/Missing Study/);assert.deepEqual(readdirSync(dir),[]);}finally{rmSync(dir,{recursive:true,force:true});}
});

test('launcher validates existing and newly started health identities without opening a visible process',()=>{
 const source=readFileSync(new URL('./Start-RoAlgo.ps1',import.meta.url),'utf8'),dir=mkdtempSync(join(tmpdir(),'roalgo-v3-launch-'));
 try{for(const mode of ['existing','wrongApp','wrongSchema','wrongRoot','notOk','fresh','freshWrongRoot']){
 const fixture=`$testMode='${mode}'
$script:healthCalls=0
function Invoke-RestMethod {
 param($Uri,$TimeoutSec)
 if($Uri -ne 'http://127.0.0.1:47624/health'){throw 'Wrong bridge endpoint'}
 $script:healthCalls++
 if($testMode.StartsWith('fresh') -and $script:healthCalls -eq 1){throw 'Not listening yet'}
 $testHealth=@{ok=$true;app='RoAlgo Market Lab';schemaVersion=3;root=$PSScriptRoot}
 if($testMode -eq 'wrongApp'){$testHealth.app='RoAlgo Research'}
 if($testMode -eq 'wrongSchema'){$testHealth.schemaVersion=2}
 if($testMode -eq 'wrongRoot' -or $testMode -eq 'freshWrongRoot'){$testHealth.root=(Join-Path $PSScriptRoot 'other')}
 if($testMode -eq 'notOk'){$testHealth.ok=$false}
 return [pscustomobject]$testHealth
}
function Start-Process {
 param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru)
 if(-not $testMode.StartsWith('fresh')){throw 'Existing listener must not spawn a process'}
 if($WindowStyle -ne 'Hidden' -or $ArgumentList -ne 'bridge.mjs' -or $WorkingDirectory -ne $PSScriptRoot){throw 'Invalid hidden bridge launch'}
 return [pscustomobject]@{HasExited=$false;Id=321}
}
function Start-Sleep {param($Milliseconds)}
`;
 const f=join(dir,mode+'.ps1');writeFileSync(f,fixture+source);const r=spawnSync('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',f],{encoding:'utf8',timeout:15000});
 if(['existing','fresh'].includes(mode)){assert.equal(r.status,0,mode+'\n'+r.stdout+r.stderr);assert.match(r.stdout,mode==='existing'?/already running/:/bridge ready/);}else assert.notEqual(r.status,0,mode+' must reject incompatible health');
 }}finally{rmSync(dir,{recursive:true,force:true});}
});
test('source package preserves literal text and hash provenance',async()=>{
 const {modelXML}=await import('./package.mjs');
 const xml=modelXML([{path:'src/Probe',source:'return "<>&\\n"',sha256:'testhash'}]);
 assert.match(xml,/&lt;&gt;&amp;/);assert.match(xml,/testhash/);assert.doesNotMatch(xml,/<Item class="Script"/);
});
test('local plugin guards RoAlgo and loads research controller',async()=>{
 const {modelXML}=await import('./package.mjs');
 const xml=modelXML([{path:'src/App',source:'return {}',sha256:'h'}],true);
 assert.match(xml,/PlaceId ~= 0 then return/);assert.match(xml,/RoAlgoMarketControl/);assert.match(xml,/<Item class="Script"/);
});
test('module package retains both inspectable SHA child and native string attribute',async()=>{
 const {modelXML}=await import('./package.mjs'),sha='a'.repeat(64);
 const text=modelXML([{path:'src/Probe',source:'return 1\r\n',sha256:sha}]);
 const encoded=text.match(/<BinaryString name="AttributesSerialize">([^<]+)<\/BinaryString>/)?.[1];
 assert.ok(encoded,'native attribute bytes required');const b=Buffer.from(encoded,'base64');let p=0;
 const u32=()=>{const n=b.readUInt32LE(p);p+=4;return n;},s=()=>{const n=u32(),v=b.toString('utf8',p,p+n);p+=n;return v;};
 assert.equal(u32(),1);assert.equal(s(),'sha256');assert.equal(b[p++],2);assert.equal(s(),sha);assert.equal(p,b.length);
 assert.match(text,/<string name="Name">SourceSHA256<\/string>/);assert.match(text,/&#13;\n/);
});
test('package rejects duplicate modules and unsafe paths before artifact creation',async()=>{
 const {modelXML}=await import('./package.mjs');
 const x={path:'src/App',source:'return {}',sha256:'h'};
 assert.throws(()=>modelXML([x,x]));for(const path of ['../App','src/../App','src/Test.spec','src/a/b'])assert.throws(()=>modelXML([{...x,path}]));
});
test('build records exact artifact/source/install hashes and creates inert source plus plugin',async()=>{
 const {build}=await import('./package.mjs');const dir=mkdtempSync(join(tmpdir(),'roalgo-v3-build-'));
 try {
 const files=['App','Dashboard','PhysicsView','Features','Regime','Engine','Mechanics','Learning','Execution','Study','VerifiedStepper'].map(n=>({path:'src/'+n,source:'return {}',sha256:createHash('sha256').update('return {}').digest('hex')}));
 const report=build({directory:dir,files}),manifest=JSON.parse(readFileSync(join(dir,'manifest.json')));
 assert.equal(manifest.schemaVersion,3);assert.equal(manifest.placeId,0);assert.equal(manifest.bridge,'http://127.0.0.1:47624');assert.equal(manifest.sources.length,11);
 for(const [name,sha]of Object.entries(report.artifacts))assert.equal(createHash('sha256').update(readFileSync(join(dir,name))).digest('hex'),sha);
 assert.doesNotMatch(readFileSync(join(dir,'RoAlgoMarketLab.rbxmx'),'utf8'),/<Item class="Script"/);
 assert.match(readFileSync(join(dir,'RoAlgoMarketLab.plugin.rbxmx'),'utf8'),/<Item class="Script"/);
 assert.ok(manifest.installHashes['Install-In-Studio.luau']);assert.ok(manifest.installHashes['Start-RoAlgo.ps1']);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('build refuses an omitted PhysicsView dependency before creating artifacts',async()=>{
 const {build}=await import('./package.mjs'),dir=mkdtempSync(join(tmpdir(),'roalgo-v3-missing-view-'));
 try {
 const files=['App','Dashboard','Features','Regime','Engine','Mechanics','Learning','Execution','Study','VerifiedStepper'].map(n=>({path:'src/'+n,source:'return {}',sha256:createHash('sha256').update('return {}').digest('hex')}));
 assert.throws(()=>build({directory:dir,files}),/Missing PhysicsView/);
 assert.deepEqual(readdirSync(dir),[]);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('plugin behavior stays inert elsewhere and waits for cancellation before destroying controller',async()=>{
 const {bootstrap}=await import('./package.mjs'),dir=mkdtempSync(join(tmpdir(),'roalgo-v3-bootstrap-'));
 try {
 const setup=`local calls={starts=0,stop=0,destroy=0,waits=0}\nlocal services=0\nlocal busy=true\nlocal control={Invoke=function(self,cmd) if cmd=='stop' then calls.stop+=1 elseif cmd=='status' then return {busy=busy} elseif cmd=='destroy' then assert(not busy,'controller cannot be destroyed while busy');calls.destroy+=1 end end}\nlocal gui={Enabled=true,IsA=function(self,kind)return kind=='ScreenGui' end}\nlocal core={FindFirstChild=function(self,name)if name=='RoAlgoMarketControl' then return control elseif name=='RoAlgoMarketDashboard' then return gui end end}\nlocal click,unload\nlocal button={Click={Connect=function(self,fn)click=fn end}}\nlocal plugin={CreateToolbar=function(self,name)return {CreateButton=function(self,...)return button end} end,Unloading={Connect=function(self,fn)unload=fn end}}\nlocal script={Parent={src={App={}}}}\nlocal require=function(m)assert(m==script.Parent.src.App);return {start=function(opts)assert(opts.plugin==plugin);calls.starts+=1 end} end\nlocal task={defer=function(fn)fn() end,wait=function()calls.waits+=1;busy=false end}\nlocal game={PlaceId=0,GetService=function(self,name)services+=1;if name=='CoreGui' then return core elseif name=='RunService' then return {IsRunning=function()return false end} end;error('unexpected service') end}\n`;
 for(const wrong of [true,false]){
 const source=setup+(wrong?'game.PlaceId=1\n':'')+'local function main()\n'+bootstrap+'\nend\nmain()\n'+(wrong?"assert(services==0 and calls.starts==0 and unload==nil,'other place must stay inert')":"assert(click and unload,'target must register UI/unload');click();assert(gui.Enabled==false,'existing dashboard toggles');unload();assert(calls.stop==1 and calls.waits>=1 and calls.destroy==1,'stop must finish before destroy')")+"\nprint('PASS plugin lifecycle')\n";
 const f=join(dir,wrong?'wrong.luau':'target.luau');writeFileSync(f,source);const r=spawnSync((process.env.LUAU_EXE||'luau'),[f],{encoding:'utf8',timeout:10000});assert.equal(r.status,0,r.stdout+r.stderr);
 }
 }finally{rmSync(dir,{recursive:true,force:true});}
});
