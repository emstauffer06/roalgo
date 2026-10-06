import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,mkdtempSync,writeFileSync,unlinkSync,rmdirSync} from 'node:fs';
import {join,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {LUAU} from '../../tools/luau-run.mjs';

test('Study loads in Studio using sibling ModuleScript dependencies',()=>{
 const here=dirname(fileURLToPath(import.meta.url));
 const source=readFileSync(join(here,'../src/Study.luau'),'utf8');
 const dir=mkdtempSync(join(tmpdir(),'roalgo-study-imports-'));
 const runner=join(dir,'runner.luau');
 try {
  writeFileSync(runner,`local learning,execution={},{}\nlocal parent={Learning=learning,Execution=execution}\nlocal env=setmetatable({script={Parent=parent},require=function(module) assert(module==learning or module==execution, "Studio require needs a ModuleScript child"); return {} end},{__index=getfenv(0)})\nlocal chunk=assert(loadstring(${JSON.stringify(source)}));setfenv(chunk,env)\nlocal study=chunk();assert(type(study.evaluate)=="function" and type(study.aggregate)=="function")\n`);
  const child=spawnSync(LUAU,[runner],{encoding:'utf8',windowsHide:true,timeout:10000});
  assert.ifError(child.error);assert.equal(child.status,0,`${child.stdout}\n${child.stderr}`);
 } finally {unlinkSync(runner);rmdirSync(dir)}
});
