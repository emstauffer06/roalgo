import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
test('source package preserves literal text and hash provenance',async()=>{
 const {modelXML}=await import('./package.mjs');
 const xml=modelXML([{path:'src/Probe',source:'return "<>&\\n"',sha256:'testhash'}]);
 assert.match(xml,/&lt;&gt;&amp;/);assert.match(xml,/testhash/);assert.doesNotMatch(xml,/<Item class="Script"/);
});
test('local plugin guards RoAlgo and loads research controller',async()=>{
 const {modelXML}=await import('./package.mjs');
 const xml=modelXML([{path:'src/App',source:'return {}',sha256:'h'}],true);
 assert.match(xml,/PlaceId ~= 0 then return/);assert.match(xml,/RoAlgoResearchControl/);assert.match(xml,/<Item class="Script"/);
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
 const {build}=await import('./package.mjs');const dir=mkdtempSync(join(tmpdir(),'roalgo-v2-build-'));
 try {
 const files=['App','Dashboard','PhysicsView','Features','Regime','Engine','Mechanics','Learning','Execution','VerifiedStepper'].map(n=>({path:'src/'+n,source:'return {}',sha256:createHash('sha256').update('return {}').digest('hex')}));
 const report=build({directory:dir,files}),manifest=JSON.parse(readFileSync(join(dir,'manifest.json')));
 assert.equal(manifest.schemaVersion,2);assert.equal(manifest.placeId,0);assert.equal(manifest.bridge,'http://127.0.0.1:47623');assert.equal(manifest.sources.length,10);
 for(const [name,sha]of Object.entries(report.artifacts))assert.equal(createHash('sha256').update(readFileSync(join(dir,name))).digest('hex'),sha);
 assert.doesNotMatch(readFileSync(join(dir,'RoAlgoResearch.rbxmx'),'utf8'),/<Item class="Script"/);
 assert.match(readFileSync(join(dir,'RoAlgoResearch.plugin.rbxmx'),'utf8'),/<Item class="Script"/);
 assert.ok(manifest.installHashes['Install-In-Studio.luau']);assert.ok(manifest.installHashes['Start-RoAlgo.ps1']);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('build refuses an omitted PhysicsView dependency before creating artifacts',async()=>{
 const {build}=await import('./package.mjs'),dir=mkdtempSync(join(tmpdir(),'roalgo-v2-missing-view-'));
 try {
 const files=['App','Dashboard','Features','Regime','Engine','Mechanics','Learning','Execution','VerifiedStepper'].map(n=>({path:'src/'+n,source:'return {}',sha256:createHash('sha256').update('return {}').digest('hex')}));
 assert.throws(()=>build({directory:dir,files}),/Missing PhysicsView/);
 assert.deepEqual(readdirSync(dir),[]);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('plugin behavior stays inert elsewhere and waits for cancellation before destroying controller',async()=>{
 const {bootstrap}=await import('./package.mjs'),dir=mkdtempSync(join(tmpdir(),'roalgo-v2-bootstrap-'));
 try {
 const setup=`local calls={starts=0,stop=0,destroy=0,waits=0}\nlocal services=0\nlocal busy=true\nlocal control={Invoke=function(self,cmd) if cmd=='stop' then calls.stop+=1 elseif cmd=='status' then return {busy=busy} elseif cmd=='destroy' then assert(not busy,'controller cannot be destroyed while busy');calls.destroy+=1 end end}\nlocal gui={Enabled=true,IsA=function(self,kind)return kind=='ScreenGui' end}\nlocal core={FindFirstChild=function(self,name)if name=='RoAlgoResearchControl' then return control elseif name=='RoAlgoResearchDashboard' then return gui end end}\nlocal click,unload\nlocal button={Click={Connect=function(self,fn)click=fn end}}\nlocal plugin={CreateToolbar=function(self,name)return {CreateButton=function(self,...)return button end} end,Unloading={Connect=function(self,fn)unload=fn end}}\nlocal script={Parent={src={App={}}}}\nlocal require=function(m)assert(m==script.Parent.src.App);return {start=function(opts)assert(opts.plugin==plugin);calls.starts+=1 end} end\nlocal task={defer=function(fn)fn() end,wait=function()calls.waits+=1;busy=false end}\nlocal game={PlaceId=0,GetService=function(self,name)services+=1;if name=='CoreGui' then return core elseif name=='RunService' then return {IsRunning=function()return false end} end;error('unexpected service') end}\n`;
 for(const wrong of [true,false]){
 const source=setup+(wrong?'game.PlaceId=1\n':'')+'local function main()\n'+bootstrap+'\nend\nmain()\n'+(wrong?"assert(services==0 and calls.starts==0 and unload==nil,'other place must stay inert')":"assert(click and unload,'target must register UI/unload');click();assert(gui.Enabled==false,'existing dashboard toggles');unload();assert(calls.stop==1 and calls.waits>=1 and calls.destroy==1,'stop must finish before destroy')")+"\nprint('PASS plugin lifecycle')\n";
 const f=join(dir,wrong?'wrong.luau':'target.luau');writeFileSync(f,source);const r=spawnSync((process.env.LUAU_EXE||'luau'),[f],{encoding:'utf8',timeout:10000});assert.equal(r.status,0,r.stdout+r.stderr);
 }
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('installer refuses either active controller before mutation and preserves prior source folder',()=>{
 const source=readFileSync(new URL('./Install-In-Studio.luau',import.meta.url),'utf8'),dir=mkdtempSync(join(tmpdir(),'roalgo-v2-installer-'));
 try {
 for(const mode of ['v1busy','v2busy','idle','v1startsDuringFetch','missingPhysicsView']){
 const setup=`local mode='${mode}'\nlocal mutations=0\nlocal oldDestroyed=false\nlocal started=false\nlocal function node(kind)\n local value={ClassName=kind,children={},attributes={}}\n local methods={}\n function methods:FindFirstChild(name)for _,v in self.children do if v.Name==name and not v.destroyed then return v end end return nil end\n function methods:SetAttribute(name,v)self.attributes[name]=v end\n function methods:Destroy()self.destroyed=true;mutations+=1;if self.isOld then oldDestroyed=true end end\n return setmetatable(value,{__index=function(self,k)return methods[k] or methods.FindFirstChild(self,k) end,__newindex=function(self,k,v)if k=='Parent' and v then table.insert(v.children,self) end rawset(self,k,v);if k=='Name' or k=='Parent' then mutations+=1 end end})\nend\nlocal storage=node('ServerStorage')\nlocal old=node('Folder');old.Name='RoAlgoResearch';old.isOld=true;old.Parent=storage\nlocal existingBackup=node('Folder');existingBackup.Name='RoAlgoResearch_backup_12345';existingBackup.Parent=storage\nlocal v1={Invoke=function(self,cmd)assert(cmd=='status');return {busy=mode=='v1busy'} end}\nlocal v2={Invoke=function(self,cmd)if cmd=='status' then return {busy=mode=='v2busy'} elseif cmd=='destroy' then mutations+=1 end end}\nlocal core={FindFirstChild=function(self,name)if name=='RoAlgoIndicatorControl' then return v1 elseif name=='RoAlgoResearchControl' then return v2 end end}\nlocal tree={files={}}\nfor _,name in {'App','Dashboard','Features','Regime','Engine','Mechanics','Learning','Execution','VerifiedStepper'} do table.insert(tree.files,{path='src/'..name,source='return {}',sha256=string.rep('a',64)}) end\nlocal Http={GetAsync=function(self,url)return 'tree' end,JSONDecode=function(self,text)return tree end}\nlocal game={PlaceId=0,GetService=function(self,name)if name=='RunService' then return {IsRunning=function()return false end} elseif name=='HttpService' then return Http elseif name=='ServerStorage' then return storage elseif name=='CoreGui' then return core end error(name) end}\nlocal Instance={new=function(kind)mutations+=1;return node(kind) end}\nlocal DateTime={now=function()return {UnixTimestampMillis=12345} end}\nlocal require=function(module)assert(module.Name=='App');return {start=function()assert(mode=='idle','busy v1 must prevent installation before mutation');started=true;return 'started' end} end\nlocal split=function(s,sep)local out={} for v in string.gmatch(s,'[^/]+') do table.insert(out,v) end return out end\nlocal string=setmetatable({split=split},{__index=string})\nmutations=0\n`;
 const assertions=mode==='idle'?"assert(ok and started, tostring(err));assert(not oldDestroyed,'old source folder must survive');assert(old.Parent==storage and old.Name=='RoAlgoResearch_backup_12345_2','backup must use collision-free name');assert(storage:FindFirstChild('RoAlgoResearch')~=old,'replacement installed')":mode==='missingPhysicsView'?"assert(not ok and string.find(tostring(err),'Missing PhysicsView'),'missing dependency must reject installation');assert(old.Name=='RoAlgoResearch' and not oldDestroyed,'missing dependency must preserve old source')":mode==='v1startsDuringFetch'?"assert(not ok and not started,'yielded fetch must recheck active controller');assert(old.Name=='RoAlgoResearch' and not oldDestroyed,'recheck must preserve old source')":"assert(not ok,'active controller must reject installation');assert(mutations==0,'busy rejection must precede mutation');assert(old.Name=='RoAlgoResearch' and not oldDestroyed,'old source unchanged')";
 const yielded=(mode==='v1startsDuringFetch'?"Http.GetAsync=function(self,url) mode='v1busy';return 'tree' end\n":"")+(mode!=='missingPhysicsView'?"table.insert(tree.files,{path='src/PhysicsView',source='return {}',sha256=string.rep('a',64)})\n":"");
 const f=join(dir,mode+'.luau');writeFileSync(f,setup+yielded+'local function install()\n'+source+'\nend\nlocal ok,err=pcall(install)\n'+assertions+"\nprint('PASS installer safety')\n");
 const r=spawnSync((process.env.LUAU_EXE||'luau'),[f],{encoding:'utf8',timeout:10000});assert.equal(r.status,0,r.stdout+r.stderr);
 }
 }finally{rmSync(dir,{recursive:true,force:true});}
});
