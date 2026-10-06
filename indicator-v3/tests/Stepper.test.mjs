// Reproducible orchestration regressions: the driver executes actual Luau runner source
// with injected platform/scheduling globals, rather than asserting source text.
import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const driver=path.join(here,'stepper-driver.mjs');
const repository=path.resolve(here,'../..');

function execute(source){
 const args=[driver];
 if(source)args.push(source);
 const result=spawnSync(process.execPath,args,{cwd:repository,encoding:'utf8',timeout:30000});
 if(result.error)throw result.error;
 return result;
}

test('actual repaired runner passes delayed acknowledgement, strict barriers and dropped-request scheduling regressions',{concurrency:false},()=>{
 const result=execute();
 assert.equal(result.status,0,result.stderr||result.stdout);
 assert.match(result.stdout,/PASS Stepper\.spec: delayed acknowledgement, pre-publication late completion rejection, loss retry, bounded corruption rejection, clean barriers/);
});

test('unchanged original runner reproduces premature retry on a two-frame acknowledgement',{concurrency:false},()=>{
 const original=path.resolve(repository,'indicator/src/VerifiedStepper.luau');
 const result=execute(original);
 assert.notEqual(result.status,0,'The regression must fail against the original protocol');
 assert.match(result.stderr,/A two-frame request delay must not be mistaken for loss\/reissued/);
 assert.match(result.stderr,/CORRUPT_STEP increments 2\.00000 \/ 2\.00000/);
});
