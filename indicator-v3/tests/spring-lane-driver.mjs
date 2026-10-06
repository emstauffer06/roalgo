// Runs the actual SpringLaneCapture source with lexical platform/build doubles.
// These tests verify task lifecycle orchestration, never native physics or draw distance.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = process.argv[2] ? path.resolve(process.argv[2]) : path.join(here, '../src/SpringLaneCapture.luau');
const source = fs.readFileSync(sourcePath, 'utf8');
const spec = fs.readFileSync(path.join(here, 'SpringLaneLifecycle.spec.luau'), 'utf8');
const layoutSource = fs.readFileSync(path.join(here, '../src/SpringLaneLayout.luau'), 'utf8');
const frozenSource = fs.readFileSync(path.join(here, '../src/SpringFrozenV1.luau'), 'utf8');
const terminal = /return SpringLaneCapture\s*$/;
if (!terminal.test(source)) throw new Error('SpringLaneCapture terminal return changed; inspect test wrapper');
const wrapped = source.replace(terminal, `
SpringLaneCapture.__test = {
 capture = function(fields) return setmetatable(fields, Capture) end,
 activate = function(value) active = value end,
 build = function(value) buildLanes = value end,
 selectLanePlan = selectLanePlan,
}
return SpringLaneCapture
`);
const code = `
local function loadLane(game, workspace, script, require, task, Color3, Vector3, Instance, UDim2, Enum, settings, version)
${wrapped}
end
local Layout = (function()
${layoutSource}
end)()
local Frozen = (function()
${frozenSource}
end)()
local runTests = (function()
${spec}
end)()
runTests(loadLane, Layout, Frozen)
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'spring-lane-lifecycle-'));
const generated = path.join(directory, 'SpringLaneLifecycle.generated.luau');
try {
 fs.writeFileSync(generated, code);
 const luau = process.env.LUAU_EXE || 'luau';
 const result = spawnSync(luau, [generated], {encoding: 'utf8'});
 process.stdout.write(result.stdout ?? '');
 process.stderr.write(result.stderr ?? '');
 if (result.error) throw result.error;
 process.exitCode = result.status ?? 1;
} finally {
 fs.rmSync(generated, {force: true});
 fs.rmdirSync(directory);
}
