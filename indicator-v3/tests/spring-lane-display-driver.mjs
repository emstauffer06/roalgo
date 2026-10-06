// Executes the real display module with a local Roblox platform double; no native physics claim.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const here=path.dirname(fileURLToPath(import.meta.url));
const source=fs.readFileSync(path.join(here,'../src/SpringLaneDisplay.luau'),'utf8');
const spec=fs.readFileSync(path.join(here,'SpringLaneDisplay.spec.luau'),'utf8');
const code=`local function loadDisplay(Instance,Vector3,CFrame,Color3,ColorSequence,NumberSequence,Enum,typeof)\n${source}\nend\nlocal runTests=(function()\n${spec}\nend)()\nrunTests(loadDisplay)\n`;
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'spring-lane-display-'));
const generated=path.join(directory,'SpringLaneDisplay.generated.luau');
try{
 fs.writeFileSync(generated,code);
 const result=spawnSync(process.env.LUAU_EXE||'luau',[generated],{encoding:'utf8'});
 process.stdout.write(result.stdout??'');process.stderr.write(result.stderr??'');
 if(result.error)throw result.error;
 process.exitCode=result.status??1;
}finally{fs.rmSync(generated,{force:true});fs.rmdirSync(directory);}
