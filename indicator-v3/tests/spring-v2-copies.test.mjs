// Pins the capture-time v2 modules the live forward test executes (spring-live-contract.md W2, L13; contract D15).
// node --test tests/spring-v2-copies.test.mjs   (cwd anywhere; reads indicator-v2 read-only; temp files in os.tmpdir())
// Studio is never involved: these checks prove byte identity, the one-line Engine change, the require graph, that the
// Luau SHA-256 used in Studio hashes Sources like Node, and two CLI predictions of the Studio pre-flight (config
// deep-equal and bit-exact numeric replay of the saved 2024 rows).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync, mkdirSync, rmSync, copyFileSync, existsSync} from 'node:fs';
import {join, dirname, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const V3 = resolve(here, '..');
const V2 = resolve(V3, '../indicator-v2');
const SRC = join(V3, 'src');
const LUAU = (process.env.LUAU_EXE||'luau');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const read = rel => readFileSync(join(V3, rel));

// Pinned identities (measured 2026-10-05).
const SOURCE_JSON = join(V2, 'results/RoAlgoV2_SPY_1791205420530_source.json');
const SOURCE_JSON_SHA = 'ecbee1e2e639acd7e9b51d0b81a0d9541e24cc1ec23fdc4e033a2860a16dee58';
const MANIFEST = join(V2, 'results/RoAlgoV2_SPY_1791205420530.json');
const MANIFEST_SHA = 'bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828';
const CAPTURE = {
  'src/Engine': '5dbebef9c245bf26a0e327b630612c3a43a3b214d747f90e25fa32be2a91f486',
  'src/Mechanics': 'd4680345e89cf738b5b9d0ca00bf88750b1b01b697cae9747ff6156d1c2b3e28',
  'src/Features': 'c1ac95b23491d9fb76cc574e72a556d9c2ad621d934fa90ee798256c8e066c76',
  'src/Regime': '5b8ac36eac95fb2e9f7c100c89202bbe9267f24ff0787fafbdf8bbe35bdb0d4f',
  'src/VerifiedStepper': '1ee4c13cac93f1dafea47c0f5d8a595558a0a03d14decb357fef36eb14a31fa4',
};
const COPIES = {
  SpringV2Mechanics: 'd4680345e89cf738b5b9d0ca00bf88750b1b01b697cae9747ff6156d1c2b3e28',
  SpringV2Features: 'c1ac95b23491d9fb76cc574e72a556d9c2ad621d934fa90ee798256c8e066c76',
  SpringV2Engine: 'fcf8784e92f758746f761aaa941fc5959c88e298f98f4c437c42a095349d0d47',
};
const LEAVES = {Regime: CAPTURE['src/Regime'], VerifiedStepper: CAPTURE['src/VerifiedStepper']};
const ENGINE_LINE_OLD = 'local Mechanics=require(script.Parent.Mechanics)';
const ENGINE_LINE_NEW = 'local Mechanics=require(script.Parent.SpringV2Mechanics)';

let captureFiles;
function capture() {
  if (!captureFiles) {
    const bytes = readFileSync(SOURCE_JSON);
    assert.equal(sha(bytes), SOURCE_JSON_SHA, '_source.json is the pinned capture source (indicator-v2/VERIFICATION.md:15)');
    captureFiles = Object.fromEntries(JSON.parse(bytes.toString('utf8')).files.map(f => [f.path, f]));
  }
  return captureFiles;
}

// ---------------------------------------------------------------------------------------------------------------------
// Require graph. Comments are stripped; every remaining `require` must be one of the recognised call forms.
function stripComments(source) {
  return source.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '').replace(/--[^\n]*/g, '');
}
export function luauRequires(source, name) {
  const code = stripComments(source);
  const targets = new Set();
  const bare = (code.match(/\brequire\b/g) ?? []).length;
  let calls = 0;
  for (const m of code.matchAll(/\brequire\s*\(([^()]*)\)/g)) {
    calls++;
    const arg = m[1].trim();
    const parent = /^script\.Parent\.([A-Za-z0-9_]+)$/.exec(arg);
    const relative = /^(["'])\.\/([A-Za-z0-9_]+)\1$/.exec(arg);
    if (parent) targets.add(parent[1]);
    else if (relative) targets.add(relative[2]);
    else throw new Error(`${name}: unrecognised require form require(${arg})`);
  }
  if (bare !== calls) throw new Error(`${name}: ${bare - calls} require reference(s) outside a recognised call`);
  return [...targets].sort();
}
export function requireClosure(roots, sourceOf) {
  const graph = {};
  const queue = [...roots];
  while (queue.length) {
    const name = queue.shift();
    if (graph[name]) continue;
    graph[name] = luauRequires(sourceOf(name), name);
    queue.push(...graph[name]);
  }
  return graph;
}
function v3Source(name) {
  const path = join(SRC, name + '.luau');
  if (!existsSync(path)) throw new Error(`required module ${name} does not exist in v3 src`);
  return readFileSync(path, 'utf8');
}
function classify(name) {
  const hash = sha(readFileSync(join(SRC, name + '.luau')));
  if (COPIES[name]) return hash === COPIES[name] ? 'pinned copy' : `copy ${name} hash ${hash} differs from its pin`;
  if (LEAVES[name]) return hash === LEAVES[name] ? 'capture-identical' : `${name} hash ${hash} differs from the capture`;
  if (name === 'SpringLiveCapture') return 'controller';
  return `forbidden module ${name}`;
}

// ---------------------------------------------------------------------------------------------------------------------
// Luau harness in an OS temp directory.
function runLuau(srcFiles, script, timeout = 300000) {
  const dir = mkdtempSync(join(tmpdir(), 'spring-v2-copies-'));
  try {
    mkdirSync(join(dir, 'src'));
    for (const f of srcFiles) copyFileSync(join(SRC, f + '.luau'), join(dir, 'src', f + '.luau'));
    writeFileSync(join(dir, 'check.luau'), script);
    const run = spawnSync(LUAU, [join(dir, 'check.luau')], {encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024});
    if (run.error) throw run.error;
    assert.equal(run.status, 0, run.stderr || run.stdout);
    return run.stdout.split(/\r?\n/).filter(l => l.startsWith('@@')).map(l => l.slice(2).split(' '));
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
}
const hexDoubles = values => {
  const b = Buffer.alloc(8 * values.length);
  values.forEach((x, i) => {
    if (typeof x !== 'number' || !Number.isFinite(x)) throw new Error('finite number required');
    b.writeDoubleLE(x, 8 * i);
  });
  return b.toString('hex');
};
// Exact Luau literal: numbers travel as little-endian IEEE-754 hex, decoded with string.unpack.
function luauLiteral(value) {
  if (typeof value === 'number') return `D"${hexDoubles([value])}"`;
  if (typeof value === 'boolean') return String(value);
  if (typeof value === 'string') {
    if (!/^[\x20-\x7e]*$/.test(value) || /["\\]/.test(value)) throw new Error('plain ASCII string required: ' + value);
    return `"${value}"`;
  }
  if (Array.isArray(value)) return `{${value.map(luauLiteral).join(',')}}`;
  if (value && typeof value === 'object') {
    return `{${Object.entries(value).map(([k, v]) => {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) throw new Error('plain key required: ' + k);
      return `${k}=${luauLiteral(v)}`;
    }).join(',')}}`;
  }
  throw new Error('unsupported literal ' + typeof value);
}
const LUAU_PRELUDE = `local function unhex(h) return (string.gsub(h, "%x%x", function(c) return string.char(tonumber(c, 16)) end)) end
local function D(h) return (string.unpack("<d", unhex(h))) end
local function V(h) local b, out = unhex(h), {} for i = 1, #b // 8 do out[i] = (string.unpack("<d", b, (i - 1) * 8 + 1)) end return out end
`;
// The capture Engine's own config post-processing statements, taken verbatim from SpringV2Engine.luau.
function engineConfigLuau() {
  const lines = readFileSync(join(SRC, 'SpringV2Engine.luau'), 'utf8').split('\n').map(l => l.trim());
  const take = text => {
    const hits = lines.filter(l => l === text);
    assert.equal(hits.length, 1, `SpringV2Engine must contain exactly once: ${text}`);
    return text;
  };
  return [
    take('local c=Mechanics.config()'),
    take('c.nativeProtocol={schema="verified-stepper-v2-2",lossFrames=3,postBarQuietFrames=2,'),
    take('recovery="reject corrupted capture; explicit reset and replay required"}'),
    'local actual=3.375 -- the 2024 measured AssemblyMass (manifest native.config.nodes[i].mass)',
    'for i,n in c.nodes do',
    take('n.mass=actual; n.k=actual*n.omega^2; n.c=2*n.zeta*actual*n.omega'),
    'end',
    take('c.massSource="coupled native Part.AssemblyMass, checked identical to independent rig"'),
    take('for i,e in c.edges do'),
    take('e.k=c.couplingStiffnessRatio*math.sqrt(c.nodes[e.a].k*c.nodes[e.b].k)'),
    take('e.c=c.couplingDampingRatio*math.sqrt(c.nodes[e.a].c*c.nodes[e.b].c)'),
    'end',
  ].join('\n');
}
let manifestCache;
function manifest() {
  if (!manifestCache) {
    const bytes = readFileSync(MANIFEST);
    assert.equal(sha(bytes), MANIFEST_SHA, 'the 2024 capture manifest is the pinned one (contract D15)');
    manifestCache = JSON.parse(bytes.toString('utf8'));
  }
  return manifestCache;
}

// ---------------------------------------------------------------------------------------------------------------------
test('the capture source file is pinned and every module in it matches its recorded hash', () => {
  const files = capture();
  for (const [path, hash] of Object.entries(CAPTURE)) {
    assert.equal(files[path].sha256, hash, path + ' recorded hash');
    assert.equal(sha(Buffer.from(files[path].source, 'utf8')), hash, path + ' source bytes');
  }
});

test('SpringV2Mechanics and SpringV2Features are byte-identical to indicator-v2 and to the capture', () => {
  const files = capture();
  for (const [copy, original] of [['SpringV2Mechanics', 'Mechanics'], ['SpringV2Features', 'Features']]) {
    const bytes = read(`src/${copy}.luau`);
    assert.equal(sha(bytes), COPIES[copy], copy + ' pin');
    assert.ok(bytes.equals(readFileSync(join(V2, `src/${original}.luau`))), copy + ' equals indicator-v2/src/' + original);
    assert.ok(bytes.equals(Buffer.from(files['src/' + original].source, 'utf8')), copy + ' equals the capture-time ' + original);
  }
});

test('SpringV2Engine is the capture Engine with exactly line 5 changed, and reverting it reproduces 5dbebef9', () => {
  const copy = read('src/SpringV2Engine.luau').toString('utf8');
  assert.equal(sha(Buffer.from(copy, 'utf8')), COPIES.SpringV2Engine, 'SpringV2Engine pin');
  const original = capture()['src/Engine'].source;
  const a = original.split('\n'), b = copy.split('\n');
  assert.equal(b.length, a.length, 'same line count');
  const changed = b.map((line, i) => (line === a[i] ? -1 : i)).filter(i => i >= 0);
  assert.deepEqual(changed, [4], 'exactly one changed line, line 5');
  assert.equal(a[4], ENGINE_LINE_OLD);
  assert.equal(b[4], ENGINE_LINE_NEW);
  const reverted = b.map((line, i) => (i === 4 ? ENGINE_LINE_OLD : line)).join('\n');
  assert.equal(sha(Buffer.from(reverted, 'utf8')), CAPTURE['src/Engine'], 'revert reproduces the capture Engine hash');
  assert.equal(reverted, original, 'revert reproduces the capture Engine bytes');
  assert.notEqual(sha(read('src/Engine.luau')), CAPTURE['src/Engine'], 'v3 Engine is not the capture Engine (so it must never be used)');
  assert.notEqual(sha(readFileSync(join(V2, 'src/Engine.luau'))), CAPTURE['src/Engine'], 'on-disk v2 Engine changed after the capture (D15)');
});

test('v3 Regime and VerifiedStepper are byte-identical to the capture-time modules', () => {
  const files = capture();
  for (const name of Object.keys(LEAVES)) {
    const bytes = read(`src/${name}.luau`);
    assert.equal(sha(bytes), CAPTURE['src/' + name], name);
    assert.ok(bytes.equals(Buffer.from(files['src/' + name].source, 'utf8')), name + ' bytes');
  }
});

test('copies and the controller are LF-only ASCII', () => {
  for (const name of [...Object.keys(COPIES), 'SpringLiveCapture']) {
    const bytes = read(`src/${name}.luau`);
    assert.ok(!bytes.includes(13), name + ' has no CR');
    assert.ok(bytes.every(c => c === 9 || c === 10 || (c >= 32 && c < 127)), name + ' is ASCII');
  }
  assert.ok(!read('tests/SpringLiveCapture.spec.luau').includes(13), 'spec has no CR');
});

test('require graph: every require resolves to a pinned SpringV2 copy or a capture-identical module, never v3 Engine/Features/Mechanics', () => {
  const graph = requireClosure(['SpringLiveCapture', 'SpringV2Engine', 'SpringV2Features', 'SpringV2Mechanics'], v3Source);
  assert.deepEqual(graph, {
    SpringLiveCapture: ['SpringV2Engine', 'SpringV2Features'],
    SpringV2Engine: ['SpringV2Mechanics', 'VerifiedStepper'],
    SpringV2Features: ['Regime'],
    SpringV2Mechanics: [],
    VerifiedStepper: [],
    Regime: [],
  });
  for (const name of Object.keys(graph)) {
    const verdict = classify(name);
    assert.ok(['pinned copy', 'capture-identical', 'controller'].includes(verdict), verdict);
  }
  // Both arms of the dual require in SpringV2Features name the same module.
  assert.match(readFileSync(join(SRC, 'SpringV2Features.luau'), 'utf8'), /^local Regime=if script then require\(script\.Parent\.Regime\) else require\('\.\/Regime'\)\n/);
});

test('the require-graph checker itself fails on forbidden or unrecognised requires', () => {
  const fake = {
    Root: 'local E=require(script.Parent.SpringV2Engine)\nlocal X=require(script.Parent.Engine)',
    SpringV2Engine: v3Source('SpringV2Engine'), SpringV2Mechanics: v3Source('SpringV2Mechanics'),
    VerifiedStepper: v3Source('VerifiedStepper'), Engine: v3Source('Engine'), Mechanics: v3Source('Mechanics'),
  };
  const graph = requireClosure(['Root'], n => { if (!(n in fake)) throw new Error('missing ' + n); return fake[n]; });
  assert.ok('Engine' in graph && classify('Engine') === 'forbidden module Engine', 'v3 Engine would be flagged');
  assert.throws(() => luauRequires('local M=require(game.ServerStorage.Mechanics)', 'X'), /unrecognised require form/);
  assert.throws(() => luauRequires('local r=require\nlocal M=r(script.Parent.Mechanics)', 'X'), /outside a recognised call/);
  assert.deepEqual(luauRequires('-- require(script.Parent.Engine)\nlocal M=require("./SpringV2Mechanics")', 'X'), ['SpringV2Mechanics']);
});

test('SpringLiveCapture MODULE_PINS and CAPTURE_SOURCE equal the measured hashes', () => {
  const source = read('src/SpringLiveCapture.luau').toString('utf8');
  const block = /SpringLiveCapture\.MODULE_PINS = table\.freeze\(\{([\s\S]*?)\}\)/.exec(source);
  assert.ok(block, 'MODULE_PINS block');
  const pins = Object.fromEntries([...block[1].matchAll(/(\w+) = "([0-9a-f]{64})"/g)].map(m => [m[1], m[2]]));
  const expected = {...COPIES, ...LEAVES};
  assert.deepEqual(pins, expected, 'Luau pins equal the Node pins');
  for (const [name, hash] of Object.entries(pins)) assert.equal(sha(read(`src/${name}.luau`)), hash, name + ' file hash');
  assert.match(source, new RegExp(`sourceJsonSha256 = "${SOURCE_JSON_SHA}"`));
  assert.match(source, new RegExp(`engineSha256 = "${CAPTURE['src/Engine']}"`));
});

test('the Luau sha256 used in Studio reproduces Node SHA-256 over every pinned Source', () => {
  const names = [...Object.keys(COPIES), ...Object.keys(LEAVES), 'SpringLiveCapture'];
  const entries = names.map(n => `{name="${n}", hex="${read(`src/${n}.luau`).toString('hex')}"}`).join(',\n');
  const out = runLuau(['SpringLiveCapture'], `${LUAU_PRELUDE}
local Cap = require("./src/SpringLiveCapture")
for _, e in {${entries}} do print("@@SHA " .. e.name .. " " .. Cap.sha256(unhex(e.hex))) end
`);
  assert.equal(out.length, names.length);
  for (const [, name, hash] of out) assert.equal(hash, sha(read(`src/${name}.luau`)), name);
});

test('PREDICTION: SpringV2Mechanics.config() + the Engine mass post-processing (mass 3.375) deep-equals the 2024 native.config', () => {
  const config = manifest().native.config;
  const out = runLuau(['SpringLiveCapture', 'SpringV2Mechanics'], `${LUAU_PRELUDE}
local Cap = require("./src/SpringLiveCapture")
local Mechanics = require("./src/SpringV2Mechanics")
local saved = ${luauLiteral(config)}
${engineConfigLuau()}
local same, where = Cap.deepEqual(c, saved, "config")
print("@@CONFIG " .. tostring(same) .. " " .. tostring(where))
c.edges[1].k *= 1 + 2 ^ -52
local mutated = Cap.deepEqual(c, saved, "config")
print("@@MUTATED " .. tostring(mutated))
`);
  const result = Object.fromEntries(out.map(([k, ...v]) => [k, v.join(' ')]));
  assert.equal(result.CONFIG, 'true nil', 'live rig config equals the 2024 config exactly when AssemblyMass is 3.375');
  assert.equal(result.MUTATED, 'false', 'a 1-ulp edge change is detected');
});

test('PREDICTION: the SpringV2Mechanics numeric comparator replays all 2,268 saved 2024 rows bit-exactly from the saved drives', () => {
  const m = manifest();
  const records = [];
  for (const receipt of m.cacheChunks) {
    const file = join(V2, 'results', receipt.path.split(/[\\/]/).pop());
    const bytes = readFileSync(file);
    assert.equal(sha(bytes), receipt.sha256, 'checkpoint receipt ' + file);
    for (const r of JSON.parse(bytes.toString('utf8')).records) records.push(r);
  }
  assert.equal(records.length, 2268);
  const rows = records.map(r => `{${r.feature.reset ? 'true' : 'false'},"${hexDoubles(r.feature.drive)}","${hexDoubles(r.states.numeric.vector)}"}`);
  const out = runLuau(['SpringLiveCapture', 'SpringV2Mechanics'], `${LUAU_PRELUDE}
local Mechanics = require("./src/SpringV2Mechanics")
${engineConfigLuau()}
local numeric = Mechanics.new(c, true) -- capture Engine.luau:138
local rows = {${rows.join(',\n')}}
local exact, differing, maxAbs, resets = 0, 0, 0, 0
for i, row in rows do
	if row[1] then numeric:reset(); resets += 1 end -- Engine:step(drive, reset) -> Engine:reset() -> numeric:reset()
	local s = numeric:step(V(row[2]))
	local saved = V(row[3])
	local same = #s.vector == 51
	for k = 1, 51 do
		local d = math.abs(s.vector[k] - saved[k])
		if d ~= 0 then same = false end
		if d > maxAbs then maxAbs = d end
	end
	if same then exact += 1 else differing += 1 end
end
print(string.format("@@NUMERIC %d %d %.17g %d %d", exact, differing, maxAbs, resets, numeric.totalSteps))
`);
  const [, exact, differing, maxAbs, resets, steps] = out.find(r => r[0] === 'NUMERIC');
  assert.equal(Number(resets), 1, 'one reset, at record 1');
  assert.equal(Number(steps), 2268 * 12, '12 numeric intervals per bar');
  assert.equal(Number(differing), 0, `rows differing: ${differing}, max |diff| ${maxAbs}`);
  assert.equal(Number(exact), 2268);
  assert.equal(Number(maxAbs), 0);
});

test('fences: SpringLiveCapture never steps physics itself, never touches the presentation rig or the camera', () => {
  const code = stripComments(read('src/SpringLiveCapture.luau').toString('utf8'));
  assert.doesNotMatch(code, /StepPhysics\s*\(/, 'no StepPhysics call');
  assert.doesNotMatch(code, /CurrentCamera|CameraType|HttpService|RunService\.Heartbeat|task\.(wait|spawn|defer)/, 'no camera, HTTP or scheduling');
  assert.equal((code.match(/RoAlgoResearchPhysics/g) ?? []).length, 1, 'the presentation name appears only as FORBIDDEN_NAME');
  assert.match(code, /FORBIDDEN_NAME = "RoAlgoResearchPhysics"/);
  assert.doesNotMatch(code, /Instance\.new|:Clone\(|\.Parent\s*=[^=]/, 'it creates and re-parents no instances itself');
});

test('the fields SpringLiveCapture checks exist in the capture-time Engine, VerifiedStepper, Mechanics and Features', () => {
  const engine = readFileSync(join(SRC, 'SpringV2Engine.luau'), 'utf8');
  const stepper = readFileSync(join(SRC, 'VerifiedStepper.luau'), 'utf8');
  const mechanics = readFileSync(join(SRC, 'SpringV2Mechanics.luau'), 'utf8');
  const features = readFileSync(join(SRC, 'SpringV2Features.luau'), 'utf8');
  const expectations = [
    [engine, 'local origin=opts.origin or Vector3.new(0,1024,1024)'],
    [engine, 'local model=Instance.new("Model"); model.Name=opts.name or "RoAlgoResearchPhysics"'],
    [engine, 'model:SetAttribute("MechanicsSchema",c.schema)'],
    [engine, 'local focus=origin+Vector3.new(0,c.spacing,3.5*c.spacing)'],
    [engine, 'independent=buildRig(model,c,origin+Vector3.new(0,0,11*c.spacing),false)'],
    [engine, 'local self=setmetatable({model=model,config=c,nodes={},parts={},couplings={},coupled=coupled,q=table.create(24,0)},Rig)'],
    [engine, 'self.nodes[i]={part=p,rest=rest,guide=guide,anchor=anchor,rail=rail,axial=spring,force=force,attachment=center}'],
    [engine, 'runner=VerifiedStepper.new({coupled,independent},{dt=1/60,stepsPerBar=12,settleSteps=0,parent=model,\n\t\t\tlossFrames=3,postBarQuietFrames=2})'],
    [engine, 'local self=setmetatable({model=model,config=c,coupledRig=coupled,independentRig=independent,runner=runner,\n\t\tnumeric=Mechanics.new(c,true),destroyed=false,busy=false,fault=nil,failedBars=0,clippedInputs=0,'],
    [engine, 'local rest=origin+Vector3.new(0,n.y,n.z)'],
    [stepper, 'reservoirs = reservoirs,\n\t\toptions = options,'],
    [stepper, 'parts = parts,\n\t\tmetronomes = {} :: { BasePart },'],
    [stepper, 'lossFrames = options.lossFrames or 3,'],
    [stepper, 'postBarQuietFrames = options.postBarQuietFrames or 2,'],
    [stepper, 'maxReissues = options.maxReissues or 30,'],
    [stepper, 'warmupFrames = options.warmupFrames or 20,'],
    [stepper, 'stepper = options.stepper or defaultStepper,'],
    [stepper, 'self.metronomes = { newMetronome("MetronomeA", -400, parent), newMetronome("MetronomeB", 400, parent) }'],
    [stepper, 'settleCount = 0,'], [stepper, 'self.settleCount += 1'], [stepper, 'corrupt = 0,'],
    [stepper, 'totalSteps = 0,\n\t\ttotalBars = 0,'],
    [mechanics, 'setmetatable({config=config or Mechanics.config(),coupled=coupled~=false,totalSteps=0,totalBars=0},Numeric)'],
    [features, 'return setmetatable({prehistory=prehistory or {},options=options,observations=0,previous=nil,trend=0,var=1e-8,volumeMean=nil,tradeMean=nil,driveScales={1e-6,1e-6,1e-6,1e-6,1e-6,1e-6,1e-6},alpha=math.clamp(options.alpha or 0.05,0.001,1),regimeModel=nil},Features)'],
    [features, "regime=if self.regimeModel then self.regimeModel:info() else {status='awaiting-first-decision'}"],
  ];
  for (const [text, fragment] of expectations) assert.ok(text.includes(fragment), 'missing in source: ' + fragment);
  assert.match(read('src/Regime.luau').toString('utf8'), /self\.status='fit'/, "a fitted Regime reports status 'fit'");
});

// ---------------------------------------------------------------------------------------------------------------------
// The REAL SpringV2Engine, VerifiedStepper, SpringV2Mechanics, SpringV2Features and Regime sources, loaded through their
// Studio `script.Parent` requires, run under SpringLiveCapture with Roblox platform doubles (the stepper-driver.mjs
// pattern). The doubles apply StepPhysics synchronously and only move the metronomes, so native spring motion is NOT
// simulated: this proves orchestration, rig identity and audit counters against the real code, not native physics.
const PLATFORM_LUAU = `
local function makePlatform(opts)
	opts = opts or {}
	local P = { frames = 0, stepCalls = 0 }
	local V3mt = {}
	local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3mt) end
	V3mt.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
	V3mt.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
	V3mt.__mul = function(a, b)
		if type(a) == "number" then return vec(a * b.X, a * b.Y, a * b.Z) end
		if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
		return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end
	P.vec = vec
	P.Vector3 = { new = vec, zero = vec(0, 0, 0), one = vec(1, 1, 1), xAxis = vec(1, 0, 0), yAxis = vec(0, 1, 0) }
	P.CFrame = { new = function(a, b, c) return { Position = if type(a) == "number" then vec(a, b, c) else a } end }
	P.Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end }
	P.PhysicalProperties = { new = function(density) return { Density = density } end }
	P.Enum = setmetatable({}, { __index = function(_, group)
		return setmetatable({}, { __index = function(_, item) return "Enum." .. group .. "." .. item end })
	end })
	local Inst, methods = {}, {}
	local IS = { Part = { BasePart = true }, Workspace = { WorldRoot = true } }
	local function new(className)
		local self = setmetatable({}, Inst)
		local props = { Name = className, ClassName = className }
		if className == "Part" then
			props.Anchored = false; props.Size = vec(4, 1, 2); props.Position = vec(0, 0, 0)
			props.AssemblyLinearVelocity = vec(0, 0, 0); props.AssemblyAngularVelocity = vec(0, 0, 0)
		end
		rawset(self, "_props", props); rawset(self, "_children", {}); rawset(self, "_attrs", {})
		return self
	end
	Inst.__index = function(self, key)
		if methods[key] then return methods[key] end
		local props = rawget(self, "_props")
		if key == "AssemblyMass" then
			local s, custom = props.Size, props.CustomPhysicalProperties
			return s.X * s.Y * s.Z * (if custom then custom.Density else 0.7) * (opts.densityScale or 1)
		end
		if key == "CFrame" then return P.CFrame.new(props.Position) end
		return props[key]
	end
	Inst.__newindex = function(self, key, value)
		local props = rawget(self, "_props")
		if key == "Parent" then
			local old = props.Parent
			if old then
				local list = rawget(old, "_children")
				for i = #list, 1, -1 do if list[i] == self then table.remove(list, i) end end
			end
			props.Parent = value
			if value then table.insert(rawget(value, "_children"), self) end
		elseif key == "CFrame" then
			props.Position = value.Position
		else
			props[key] = value
		end
	end
	function methods:IsA(name) return self.ClassName == name or name == "Instance" or (IS[self.ClassName] or {})[name] == true end
	function methods:SetAttribute(k, v) rawget(self, "_attrs")[k] = v end
	function methods:GetAttribute(k) return rawget(self, "_attrs")[k] end
	function methods:GetChildren() return table.clone(rawget(self, "_children")) end
	function methods:GetDescendants()
		local out = {}
		local function walk(x) for _, c in rawget(x, "_children") do table.insert(out, c); walk(c) end end
		walk(self)
		return out
	end
	function methods:FindFirstChild(name) for _, c in rawget(self, "_children") do if c.Name == name then return c end end return nil end
	function methods:IsDescendantOf(a) local p = self.Parent while p do if p == a then return true end p = p.Parent end return false end
	function methods:GetFullName() local n, p = {}, self while p do table.insert(n, 1, p.Name) p = p.Parent end return table.concat(n, ".") end
	function methods:Destroy() for _, c in table.clone(rawget(self, "_children")) do c:Destroy() end self.Parent = nil end
	function methods:StepPhysics(dt, parts)
		P.stepCalls += 1
		local list = parts
		if opts.leaky then
			list = {}
			for _, p in self:GetDescendants() do if p:IsA("BasePart") and not p.Anchored then table.insert(list, p) end end
		end
		for _, p in list do
			if opts.leaky or string.sub(p.Name, 1, 9) == "Metronome" then
				local v = p.AssemblyLinearVelocity
				p.AssemblyLinearVelocity = vec(v.X, v.Y - self.Gravity * dt, v.Z)
			end
		end
	end
	P.Instance = { new = new }
	P.workspace = new("Workspace")
	P.workspace.Name = "Workspace"
	P.workspace.Gravity = 196.2
	P.workspace.PhysicsSteppingMethod = "Enum.PhysicsSteppingMethod.Fixed"
	local RunService = { IsRunning = function() return false end, Heartbeat = { Wait = function() P.frames += 1 end } }
	P.game = { PlaceId = 0, GetService = function(_, name) assert(name == "RunService", name) return RunService end }
	P.typeof = function(x)
		local mt = type(x) == "table" and getmetatable(x)
		if mt == V3mt then return "Vector3" end
		if mt == Inst then return "Instance" end
		return typeof(x)
	end
	return P
end
-- Loads a module the way Studio does: its own script, siblings in script.Parent, require(ModuleScript).
local function makeLoader(P, sources)
	local folder, tokens, cache = {}, {}, {}
	for name in sources do local t = { Name = name } folder[name] = t tokens[t] = name end
	local load
	load = function(name)
		if cache[name] == nil then
			local env = setmetatable({
				script = { Name = name, Parent = folder },
				require = function(m) local n = tokens[m] assert(n, "require needs a sibling ModuleScript") return load(n) end,
				game = P.game, workspace = P.workspace, Instance = P.Instance, Vector3 = P.Vector3, CFrame = P.CFrame,
				Color3 = P.Color3, Enum = P.Enum, PhysicalProperties = P.PhysicalProperties, typeof = P.typeof,
			}, { __index = getfenv(0) })
			local chunk = assert(loadstring(sources[name], "=" .. name))
			setfenv(chunk, env)
			cache[name] = chunk()
		end
		return cache[name]
	end
	return load
end
`;

test('the real capture-time Engine, VerifiedStepper, Mechanics, Features and Regime pass SpringLiveCapture under platform doubles', () => {
  const m = manifest();
  const receipt = m.cacheChunks[0];
  const chunkFile = join(V2, 'results', receipt.path.split(/[\\/]/).pop());
  const chunkBytes = readFileSync(chunkFile);
  assert.equal(sha(chunkBytes), receipt.sha256, 'checkpoint 0001 receipt');
  const records = JSON.parse(chunkBytes.toString('utf8')).records.slice(0, 78);
  assert.ok(records[0].feature.reset && records.slice(1).every(r => !r.feature.reset), '2024 record 1 is the only reset in session 1');
  const rows = records.map((r, i) => `{index=${i + 1},reset=${r.feature.reset},drive="${hexDoubles(r.feature.drive)}",coupled="${hexDoubles(r.states.coupled.vector)}",independent="${hexDoubles(r.states.independent.vector)}",numeric="${hexDoubles(r.states.numeric.vector)}"}`);
  const modules = ['SpringV2Engine', 'SpringV2Mechanics', 'VerifiedStepper', 'SpringV2Features', 'Regime'];
  const sources = modules.map(n => `${n}=unhex("${read(`src/${n}.luau`).toString('hex')}")`).join(',\n');
  const out = runLuau(['SpringLiveCapture'], `${LUAU_PRELUDE}${PLATFORM_LUAU}
local Cap = require("./src/SpringLiveCapture")
local SOURCES = {${sources}}
local CONFIG2024 = ${luauLiteral(m.native.config)}
local COUNTS2024 = ${luauLiteral(m.native.counts)}
local function env(P)
	local load = makeLoader(P, SOURCES)
	return {
		game = P.game, workspace = P.workspace, Vector3 = P.Vector3,
		Engine = load("SpringV2Engine"), Features = load("SpringV2Features"),
		-- Studio reads ModuleScript.Source; here the same bytes are hashed, with the installer's stamps.
		moduleHash = function(name) local h = Cap.sha256(SOURCES[name]) return h, { attribute = h, sourceSHA256 = h } end,
		version = function() return "platform-double" end,
	}
end
local function prehistory()
	local rows = {}
	for i = 1, 60 do
		local c = 100 + 3 * math.sin(i * 1.7) + i / 10
		rows[i] = { t = 1735000000 - (61 - i) * 86400, day = string.format("2024-%03d", i), availableT = 1735000000 - (61 - i) * 86400 + 23400,
			o = c - 0.5, c = c, h = c + 1 + (i % 3), l = c - 1 - (i % 5) / 2 }
	end
	return { targetDaily = rows }
end
local function bar(i)
	local c = 590 + math.sin(i) + i / 50
	return { t = 1735828200 + (i - 1) * 300, day = "2025-01-02", minute = 570 + (i - 1) * 5, o = c - 0.2, h = c + 0.4, l = c - 0.5,
		c = c, v = 100000 + 37 * i, n = 900 + i, vwap = c - 0.05, contexts = {} }
end
local function say(...) print("@@" .. table.concat({ ... }, " ")) end

-- 1. a live capture on the real Engine
local P = makePlatform()
local sentinel = P.Instance.new("Part") sentinel.Name = "Sentinel" sentinel.CFrame = P.CFrame.new(5000, 100, 5000) sentinel.Parent = P.workspace
local anchored = P.Instance.new("Part") anchored.Name = "Fixed" anchored.Anchored = true anchored.Parent = P.workspace
local cap = Cap.new({ prehistory = prehistory(), guard = function() return true end, nativeConfig2024 = CONFIG2024, env = env(P) })
say("NEW", tostring(cap.engine.model.Parent == P.workspace), cap.engine.model.Name, tostring(#cap.engine.runner.parts))
for i = 1, 30 do cap:step(bar(i)) end
local s = cap:stats()
say("STATS", s.totalSteps, s.totalBars, s.settles, s.requests, s.droppedRequests, s.corruptSteps, s.parts, s.barrierChecks,
	s.barrierFailures, s.quietFramesWaited, s.numericSteps, s.numericBars, s.capture.bars, s.capture.resets, s.capture.regime.status)
say("COUNTS", tostring((Cap.deepEqual(s.counts, COUNTS2024))))
say("CONFIG", tostring((Cap.deepEqual(s.config, CONFIG2024))), tostring(s.config ~= cap.engine.config))
say("MODULES", tostring(s.capture.modules.SpringV2Engine.sha256 == Cap.MODULE_PINS.SpringV2Engine), tostring(s.capture.modules.Regime.attribute == Cap.MODULE_PINS.Regime))
say("ISOLATION", string.format("%.17g", (cap:verifyIsolation())), s.isolation.parts)
cap:destroy()
say("DESTROYED", tostring(P.workspace:FindFirstChild("RoAlgoSpringLiveRig") == nil), tostring(Cap.activeCount()))

-- 2. an unscoped StepPhysics (moves every unanchored part) is caught by the isolation check
local L = makePlatform({ leaky = true })
local s2 = L.Instance.new("Part") s2.Name = "Sentinel" s2.Parent = L.workspace
local leaky = Cap.new({ prehistory = prehistory(), guard = function() return true end, nativeConfig2024 = CONFIG2024, env = env(L) })
leaky:step(bar(1))
local ok, err = pcall(function() leaky:verifyIsolation() end)
say("LEAKY", tostring(ok), tostring(string.find(tostring(err), "isolation breach", 1, true) ~= nil), tostring(leaky.fault ~= nil))
leaky:destroy()

-- 3. a rig whose AssemblyMass differs by 1e-7 relative is refused and removed
local Q = makePlatform({ densityScale = 1 + 1e-7 })
local okMass, errMass = pcall(Cap.new, { prehistory = prehistory(), guard = function() return true end, nativeConfig2024 = CONFIG2024, env = env(Q) })
say("MASS", tostring(okMass), tostring(string.find(tostring(errMass), "rig identity check failed", 1, true) ~= nil),
	tostring(Q.workspace:FindFirstChild("RoAlgoSpringLiveRig") == nil))

-- 4. pre-flight replay of 2024 records 1-78 (hex rows) on the real Engine: numeric exact; native not simulated here
local R = makePlatform()
local rows = {${rows.join(',\n')}}
local result = Cap.replayCheck(rows, { guard = function() return true end, nativeConfig2024 = CONFIG2024, env = env(R) })
say("REPLAY", result.count, string.format("%.17g", result.maxAbs.numeric), tostring(result.numericExact),
	tostring(result.maxAbs.coupled > 0.002), tostring(result.pass), result.native.totalSteps, result.native.settles,
	tostring(R.workspace:FindFirstChild("RoAlgoSpringLivePreflight") == nil), tostring(Cap.activeCount()))
`);
  const r = Object.fromEntries(out.map(([k, ...v]) => [k, v]));
  assert.deepEqual(r.NEW, ['true', 'RoAlgoSpringLiveRig', '50'], 'all identity checks pass against the real Engine.new');
  // 30 bars: 12 verified steps each, constructor + bar-1 reset (2024: settles 2), 4*bars-1 barrier checks (2024: 9071 = 4*2268-1)
  assert.deepEqual(r.STATS, ['360', '30', '2', '360', '0', '0', '50', '119', '0', '60', '360', '30', '30', '1', 'fit']);
  assert.deepEqual(r.COUNTS, ['true'], 'instance counts equal the 2024 native.counts');
  assert.deepEqual(r.CONFIG, ['true', 'true'], 'real Engine.new reproduces the 2024 native.config exactly; stats returns a copy');
  assert.deepEqual(r.MODULES, ['true', 'true']);
  assert.deepEqual(r.ISOLATION, ['0', '1'], 'scoped stepping leaves the sentinel unmoved');
  assert.deepEqual(r.DESTROYED, ['true', '0']);
  assert.deepEqual(r.LEAKY, ['false', 'true', 'true'], 'an unscoped step is caught and faults the capture');
  assert.deepEqual(r.MASS, ['false', 'true', 'true'], 'a 1e-7 mass difference is refused and the rig removed');
  assert.deepEqual(r.REPLAY, ['78', '0', 'true', 'true', 'false', String(78 * 12), '2', 'true', '0'],
    'numeric comparator exact through the real Engine; native vectors differ because the doubles do not simulate springs');
});

test('the SpringLiveCapture Luau orchestration spec runs green', () => {
  const run = spawnSync(LUAU, [join(here, 'SpringLiveCapture.spec.luau')], {cwd: resolve(V3, '..'), encoding: 'utf8', timeout: 120000});
  assert.equal(run.status, 0, run.stderr || run.stdout);
  assert.match(run.stdout, /^SpringLiveCapture: 22 tests passed\r?$/m);
});
