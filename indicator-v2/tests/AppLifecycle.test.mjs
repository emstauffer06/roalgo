import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,mkdtempSync,writeFileSync,unlinkSync,rmdirSync} from 'node:fs';
import {join,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {LUAU} from '../../tools/luau-run.mjs';

// Run with: node --test indicator-v2/tests/AppLifecycle.test.mjs
test('actual App source satisfies lifecycle and native provenance regressions',()=>{
 const here=dirname(fileURLToPath(import.meta.url));
 const source=readFileSync(join(here,'../src/App.luau'),'utf8');
 const spec=readFileSync(join(here,'AppLifecycle.spec.luau'),'utf8');
 const dir=mkdtempSync(join(tmpdir(),'roalgo-app-lifecycle-'));
 const runner=join(dir,'runner.luau');
 try {
  writeFileSync(runner,`local run=assert(loadstring(${JSON.stringify(spec)}))()\nassert(run(${JSON.stringify(source)})==9)\n`);
  const child=spawnSync(LUAU,[runner],{encoding:'utf8',windowsHide:true,timeout:10000});
  assert.ifError(child.error);
  assert.equal(child.status,0,`${child.stdout}\n${child.stderr}`);
  assert.match(child.stdout,/PASS App lifecycle 9 checks/);
  console.log(child.stdout.trim());
 } finally {
  unlinkSync(runner);rmdirSync(dir);
 }
});
