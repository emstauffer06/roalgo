// Tests for run-spring-indicator.mjs / spring-runner-lib.mjs. Every Luau run here uses STUB SpringState/SpringStudy
// modules written into temp dirs and a SYNTHETIC capture fixture; real data is only read (verification test).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, readdirSync, statSync, existsSync, copyFileSync} from 'node:fs';
import {join, dirname, basename, relative} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const lib = await import('../spring-runner-lib.mjs');
const LUAU = lib.LUAU_PATH;
const NODE = process.execPath;
const sha = x => createHash('sha256').update(x).digest('hex');
const PROTOCOL = 'spring-consensus-v1';

// ---- Guard: nothing under indicator-v3/results, indicator-v2 or indicator-v3/spring-runs may change. ----
function snapshot(dir) {
  const out = {};
  if (!existsSync(dir)) return out;
  const walk = d => {
    for (const entry of readdirSync(d, {withFileTypes: true})) {
      const p = join(d, entry.name);
      if (entry.isDirectory()) walk(p);
      else { const s = statSync(p); out[relative(dir, p)] = `${s.size}:${s.mtimeMs}`; }
    }
  };
  walk(dir);
  return out;
}
const GUARDED = [join(ROOT, 'results'), join(ROOT, '../indicator-v2'), join(ROOT, 'spring-runs')];
const BEFORE = GUARDED.map(snapshot);
const SPRING_RUNS_EXISTED = existsSync(join(ROOT, 'spring-runs'));

const temp = prefix => mkdtempSync(join(tmpdir(), prefix));
const listFiles = dir => (existsSync(dir) ? readdirSync(dir, {recursive: true}).map(String).sort() : []);

// ---- Synthetic capture fixture (labelled synthetic; mirrors the v2 checkpoint layout) ----
const BANKS = ['Fast', 'Medium', 'Slow'];
const RAW_NAMES = Array.from({length: 33}, (_, i) => 'raw' + i);
const NODE_NAMES = Array.from({length: 24}, (_, i) => BANKS[Math.floor(i / 8)] + String(i % 8 + 1).padStart(2, '0'));
const STATE_NAMES = [...NODE_NAMES.map(n => n + '.x'), ...NODE_NAMES.map(n => n + '.v'), ...BANKS.map(b => b + '.energy')];
const CONFIG = {
  schema: 'synthetic-fixture-config', D: 64, spacing: 256, bankNames: BANKS,
  nodes: NODE_NAMES.map((name, i) => ({index: i + 1, name, bank: Math.floor(i / 8) + 1, omega: 1 + i / 7, y: i * 8, z: -i * 4, projection: [0.72, 0.08, -0.08, 0.04, 0.02, 0.02, 0.02, 0.02]})),
  edges: [{a: 1, b: 2, k: 1.5}, {a: 1, b: 9, k: 0.75}],
};
const DAY_A = 1731940200, DAY_B = 1732026600; // 2024-11-18 / 2024-11-19 09:30 ET
const awkward = (i, j, k) => Math.sin(i * 7.1 + j * 1.3 + k * 0.7) * 1.2345678901234567 + (j === 5 ? 1e-17 : 0);
function makeRecords(n = 30) {
  return Array.from({length: n}, (_, i) => {
    const onA = i < 15, t = (onA ? DAY_A : DAY_B) + (onA ? i : i - 15) * 300, day = onA ? '2024-11-18' : '2024-11-19';
    const states = {};
    lib.VARIANTS.forEach((id, k) => {
      const vector = Array.from({length: 51}, (_, j) => awkward(i, j, k));
      states[id] = {vector, names: [...STATE_NAMES], energy: 2.5,
        nodes: NODE_NAMES.map((_, j) => ({x: vector[j], v: vector[24 + j], bank: Math.floor(j / 8) + 1, drive: 0.5 + j, force: -0.25 * j})),
        banks: BANKS.map(name => ({name, displacement: 0.1, velocity: 0.2, energy: 0.3}))};
    });
    const o = 100 + i * 0.01, c = o + Math.cos(i) * 0.05;
    return {
      bar: {t, availableT: t + 300, o, h: Math.max(o, c) + 0.1, l: Math.min(o, c) - 0.1, c, v: 1000 + i, n: 10 + i, vwap: o, label: `fixture bar ${i + 1}`, day, minute: 570 + i * 5, contexts: {peerFive: {c: 1.25}}},
      feature: {t, raw: RAW_NAMES.map((_, j) => i / 100 + j), names: [...RAW_NAMES], drive: lib.DRIVE_NAMES.map((_, j) => j / 10), volatility: 0.001 + i * 1e-5, ready: i >= 11, reset: i === 0, regime: [0.2, 0.3, 0.5], contextMissing: false},
      states,
    };
  });
}
const ENGINE_SOURCE = '-- synthetic capture source\nreturn {}\n', FEATURES_SOURCE = '-- synthetic features source\nreturn {}\n';
function baseSpec() {
  return {records: makeRecords(), chunkSizes: [16, 14], chunkConfigs: null, config: structuredClone(CONFIG), driveNames: [...lib.DRIVE_NAMES],
    sourceFiles: [{path: 'src/Engine', source: ENGINE_SOURCE}, {path: 'src/Features', source: FEATURES_SOURCE}]};
}
// Writes manifest + checkpoints + _source.json; pins are computed from the written bytes.
function writeCapture(dir, spec = baseSpec()) {
  const {records} = spec, manifestPath = join(dir, 'Fixture.json'), placeId = 0;
  const days = [...new Set(records.map(r => r.bar.day))], counts = Object.fromEntries(days.map(d => [d, records.filter(r => r.bar.day === d).length]));
  const metadata = {symbol: 'SPY', dataHash: 'synthetic-fixture-data', sessionCount: days.length, sessions: days, counts, bars: records.length};
  const split = {trainEndT: DAY_B, validationEndT: DAY_B + 5 * 300, testStartT: DAY_B + 5 * 300};
  const sourceHashes = Object.fromEntries(spec.sourceFiles.map(f => [f.path, sha(f.source)]));
  const cacheChunks = [];
  let first = 1;
  spec.chunkSizes.forEach((size, k) => {
    const last = first + size - 1, path = join(dir, `Fixture_states_${String(k + 1).padStart(4, '0')}.json`);
    const config = spec.chunkConfigs?.[k] ?? spec.config;
    const chunk = {version: 'roalgo-states-v2', placeId, symbol: 'SPY', metadata, split, sourceHashes, firstIndex: first, lastIndex: last, records: records.slice(first - 1, last),
      native: {schema: 'synthetic', config, totalBars: last, totalSteps: last * 12, numericSteps: last * 12, stepsPerBar: 12, dt: 1 / 60, counts: {coupledNodes: 24, independentNodes: 24}, corruptSteps: 0, failedBars: 0, stepFailures: 0, barrierFailures: 0}};
    const bytes = JSON.stringify(chunk);
    writeFileSync(path, bytes);
    cacheChunks.push({ok: true, path, sha256: sha(bytes)});
    first = last + 1;
  });
  const manifest = {version: 'roalgo-learned-v2', phase: 'complete', placeId, total: records.length, completed: records.length, profile: 1, endDate: '2024-11-19', metadata, split, sourceHashes,
    featureInfo: {rawCount: 33, driveCount: 8, names: RAW_NAMES, driveNames: spec.driveNames},
    native: {config: spec.config, totalBars: records.length, totalSteps: records.length * 12, numericSteps: records.length * 12},
    cacheChunks, replayRecords: records.filter(r => r.bar.t >= split.testStartT), comparisons: []};
  const manifestBytes = JSON.stringify(manifest);
  writeFileSync(manifestPath, manifestBytes);
  const sourceDoc = {placeId, scope: 'synthetic fixture', studioVersion: '0', files: spec.sourceFiles.map(f => ({path: f.path, sha256: sha(f.source), source: f.source}))};
  const sourceBytes = JSON.stringify(sourceDoc);
  writeFileSync(lib.sourceJsonPathFor(manifestPath), sourceBytes);
  return {dir, manifestPath, records, pins: {manifestSha256: sha(manifestBytes), checkpointSha256s: cacheChunks.map(c => c.sha256), sourceJsonSha256: sha(sourceBytes), sourceJsonPinnedFrom: 'synthetic fixture'}};
}

// ---- Stub Luau modules (never the real SpringStudy; phase 2 writes that) ----
const STUB_POLICY = `-- STUB SpringPolicy for runner tests: owns a (tiny) canonical protocol table, like the real module
local SpringPolicy = {}
local PROTOCOL = table.freeze({id = "spring-consensus-v1", stub = true, policy = table.freeze({warmup = 12})})
function SpringPolicy.protocol(id)
	assert(id == "spring-consensus-v1", "stub SpringPolicy: unknown protocol " .. tostring(id))
	return PROTOCOL
end
return SpringPolicy
`;
const STUB_STATE = `-- STUB SpringState for runner tests
local SpringState = {}
function SpringState.describe(nativeConfig, stateNames, driveNames, protocol)
	assert(#nativeConfig.nodes == 24 and #stateNames == 51 and #driveNames == 8, "stub describe: unexpected descriptor inputs")
	assert(protocol.id == "spring-consensus-v1", "stub describe: protocol id")
	return table.freeze({schema = "stub-descriptor", nodeCount = #nativeConfig.nodes, firstName = stateNames[1], lastName = stateNames[51], drive1 = driveNames[1]})
end
return SpringState
`;
const studyModule = body => `-- STUB SpringStudy for runner tests (not the phase-2 module)
local SpringState = if script then require(script.Parent.SpringState) else require("./SpringState")
local SpringStudy = {}
local function sortedKeys(t)
	local out = {}
	for k in t do table.insert(out, k) end
	table.sort(out)
	return table.concat(out, ",")
end
local function copy(a)
	local o = table.create(#a)
	for i, v in a do o[i] = v end
	return o
end
${body}
function SpringStudy.validateResult(result)
	if type(result) ~= "table" then return false, "not a table" end
	if result.validateOk == false then return false, "stub validator says no" end
	return true
end
return SpringStudy
`;
const INSPECT_BODY = `function SpringStudy.evaluate(records, split, descriptor, protocol)
	assert(SpringState.describe ~= nil)
	local first = records[1]
	local sameKeys = true
	for _, r in records do
		if sortedKeys(r) ~= "bar,feature,states" or sortedKeys(r.bar) ~= sortedKeys(first.bar) or sortedKeys(r.feature) ~= "ready,reset,volatility"
			or sortedKeys(r.states) ~= "coupled,independent,numeric" or sortedKeys(r.states.numeric) ~= "names,vector" then sameKeys = false end
	end
	local barBlocked = not pcall(function() first.bar.c = 0 end)
	local vectorBlocked = not pcall(function() first.states.coupled.vector[1] = 99 end)
	local ordered = true
	for i = 2, #records do if records[i].bar.t <= records[i - 1].bar.t then ordered = false end end
	return {
		schema = "roalgo-spring-indicator-v1",
		header = "Recorded native physics \\u{00B7} 5-minute observations \\u{00B7} no live simulation.",
		recordCount = #records,
		keys = {record = sortedKeys(first), bar = sortedKeys(first.bar), feature = sortedKeys(first.feature), states = sortedKeys(first.states), state = sortedKeys(first.states.coupled)},
		allRecordsSameKeys = sameKeys,
		mutationBlocked = barBlocked and vectorBlocked,
		ordered = ordered,
		echo = {bar = first.bar, feature = first.feature, lastBar = records[#records].bar, numericVector = copy(first.states.numeric.vector), coupledNames = copy(first.states.coupled.names)},
		split = {trainEndT = split.trainEndT, validationEndT = split.validationEndT, testStartT = split.testStartT},
		descriptor = {schema = descriptor.schema, firstName = descriptor.firstName, lastName = descriptor.lastName, drive1 = descriptor.drive1},
		protocolId = protocol.id,
		warmup = protocol.policy.warmup,
		newNativeSteps = 0,
	}
end`;
function stubSrc(dir, {body = INSPECT_BODY, extra = {}, omitStudy = false, policy = STUB_POLICY} = {}) {
  mkdirSync(dir, {recursive: true});
  writeFileSync(join(dir, 'SpringPolicy.luau'), policy);
  writeFileSync(join(dir, 'SpringState.luau'), STUB_STATE);
  if (!omitStudy) writeFileSync(join(dir, 'SpringStudy.luau'), studyModule(body));
  for (const [name, source] of Object.entries(extra)) writeFileSync(join(dir, name + '.luau'), source);
  return dir;
}
function setup({spec, body, extra, omitStudy, policy} = {}) {
  const dir = temp('spring-runner-test-');
  const captureDir = join(dir, 'capture');
  mkdirSync(captureDir);
  const capture = writeCapture(captureDir, spec);
  const srcDir = stubSrc(join(dir, 'src'), {body, extra, omitStudy, policy});
  const opts = (more = {}) => ({manifestPath: capture.manifestPath, protocolId: PROTOCOL, pins: capture.pins, srcDir, outDir: join(dir, 'results'), reportsDir: join(dir, 'spring-runs'), runRoot: join(dir, 'runs'), nowMs: 1700000000000, timeoutMs: 60000, ...more});
  return {dir, capture, srcDir, opts, cleanup: () => rmSync(dir, {recursive: true, force: true})};
}

// =============================================================================================

test('deterministic serialisers: JS->Luau literal->SpringJson->JS round-trips doubles and strings exactly, ASCII only, sorted keys, rejects NaN/Inf/sparse/mixed/cycles/bad UTF-8', () => {
  const dir = temp('spring-json-');
  try {
    const values = [0, -0, 0.1, 1 / 3, 2 / 3, 1e-7, 5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 2 ** 53, 2 ** 53 + 2, -(2 ** 53) - 2, 123456789.12345679,
      1e21, -1e-300, Math.PI, Math.E, 0.30000000000000004, 1731940200, -0.19783909618854523, 4.35, 1 + 2 ** -52];
    const strings = ['plain', 'quote " backslash \\ slash /', 'tab\tnewline\ncr\r', 'nul\u0000 del\u007f', 'middle \u00b7 dot', '\u2265 0.72', 'emoji \u{1F600}', 'e\u0301', '\u2028\u2029'];
    writeFileSync(join(dir, 'Data.luau'), 'return ' + lib.luauLiteral({values, strings, keys: {b: 1, a: 2, Z: 3, 'a b': 4, '\u00e9': 5, end: 6}}) + '\n');
    copyFileSync(join(lib.RUNNER_DIR, 'SpringJson.luau'), join(dir, 'SpringJson.luau'));
    writeFileSync(join(dir, 'probe.luau'), `local SpringJson = require("./SpringJson")
local data = require("./Data")
local function err(v) local ok, e = pcall(SpringJson.encode, v) return if ok then "NO ERROR" else e end
local sparse = {} sparse[1] = 1 sparse[3] = 3
local cyc = {} cyc.self = cyc
print("@@JSON " .. SpringJson.encode({values = data.values, strings = data.strings, keys = data.keys}))
print("@@ERR " .. SpringJson.encode({
	nan = err({x = {0 / 0}}), inf = err({y = math.huge}), ninf = err(-math.huge), sparse = err(sparse), mixed = err({1, a = 2}),
	cycle = err(cyc), fn = err({f = print}), utf8 = err("\\255bad"), nilv = err(nil), meta = err(setmetatable({}, {})),
}))
`);
    const r = spawnSync(LUAU, [join(dir, 'probe.luau')], {encoding: 'buffer', timeout: 20000});
    assert.equal(r.status, 0, r.stderr.toString());
    assert.ok(r.stdout.every(b => b === 10 || b === 13 || (b >= 0x20 && b <= 0x7e)), 'SpringJson output must be printable ASCII');
    const lines = r.stdout.toString('latin1').split(/\r?\n/);
    const json = lines.find(l => l.startsWith('@@JSON ')).slice(7), errs = JSON.parse(lines.find(l => l.startsWith('@@ERR ')).slice(6));
    const decoded = JSON.parse(json);
    assert.equal(decoded.values.length, values.length);
    values.forEach((v, i) => assert.ok(Object.is(decoded.values[i], v), `value ${i}: ${decoded.values[i]} !== ${v}`));
    assert.deepEqual(decoded.strings, strings);
    assert.ok(json.includes('\\u00b7') && json.includes('\\u2265') && json.includes('\\ud83d\\ude00'), 'non-ASCII escaped as \\uXXXX with surrogate pairs');
    assert.match(json, /"keys":\{"Z":3,"a":2,"a b":4,"b":1,"end":6,"\\u00e9":5\}/, 'keys sorted by byte order');
    assert.match(json, /"values":\[0,-0,0\.1,/, 'integral and -0 formatting');
    assert.match(errs.nan, /non-finite number at \$\.x\[1\]/);
    assert.match(errs.inf, /non-finite number at \$\.y/);
    assert.match(errs.ninf, /non-finite/);
    assert.match(errs.sparse, /sparse array/);
    assert.match(errs.mixed, /mixed table/);
    assert.match(errs.cycle, /cycle detected at \$\.self/);
    assert.match(errs.fn, /unsupported value type function at \$\.f/);
    assert.match(errs.utf8, /invalid UTF-8/);
    assert.match(errs.nilv, /nil value/);
    assert.match(errs.meta, /metatable/);
    // JS side: same rules.
    assert.throws(() => lib.luauLiteral({x: NaN}), /non-finite number at \$\.x/);
    assert.throws(() => lib.luauLiteral([1, , 3]), /sparse/);
    assert.throws(() => lib.luauLiteral({x: null}), /null/);
    assert.throws(() => lib.luauLiteral('\ud800'), /surrogate/);
    assert.equal(lib.luauLiteral('a\u{1F600}\u00b7'), '"a\\240\\159\\152\\128\\194\\183"', 'astral characters are encoded whole, never as lone surrogates');
    assert.throws(() => lib.stableStringify({x: Infinity}), /non-finite/);
    assert.equal(lib.stableStringify({b: [1, -0, 'x\u00b7\u{1F600}'], a: true}), '{"a":true,"b":[1,-0,"x\\u00b7\\ud83d\\ude00"]}');
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test('input verification: control fixture passes, and each tampered input class fails loudly with its own reason', () => {
  const dirs = [];
  const fresh = () => { const d = temp('spring-verify-'); dirs.push(d); return d; };
  const verify = f => lib.verifySpringInputs(f.manifestPath, {pins: f.pins});
  try {
    const control = writeCapture(fresh());
    const ok = verify(control);
    assert.equal(ok.records.length, 30);
    assert.equal(ok.checks.nodeXV.comparisons, 30 * 3 * 48);
    assert.equal(ok.checks.sourceJson.modules, 2);
    assert.equal(ok.checks.nativeConfig.checkpointsEqualManifest, 2);
    assert.deepEqual(ok.stateNames, STATE_NAMES);
    assert.deepEqual(ok.checks.partitions, {training: 15, validation: 5, evaluation: 10});
    assert.equal(ok.inputHashes.length, 4, 'manifest + 2 checkpoints + _source.json');
    assert.equal(ok.inputHashes[3].path, lib.sourceJsonPathFor(control.manifestPath));

    // Pins: each pin class is exercised with every other check still consistent.
    let f = writeCapture(fresh());
    writeFileSync(f.manifestPath, readFileSync(f.manifestPath, 'utf8') + ' ');
    assert.throws(() => verify(f), /manifest sha256 pin mismatch/);

    f = writeCapture(fresh());
    const chunkPath = join(f.dir, 'Fixture_states_0002.json'), chunk = JSON.parse(readFileSync(chunkPath, 'utf8'));
    chunk.records[0].bar.v += 1; // field that no content check reads
    const chunkBytes = JSON.stringify(chunk);
    writeFileSync(chunkPath, chunkBytes);
    const manifest = JSON.parse(readFileSync(f.manifestPath, 'utf8'));
    manifest.cacheChunks[1].sha256 = sha(chunkBytes);
    const manifestBytes = JSON.stringify(manifest);
    writeFileSync(f.manifestPath, manifestBytes);
    assert.throws(() => verify({...f, pins: {...f.pins, manifestSha256: sha(manifestBytes)}}), /checkpoint sha256 pin mismatch for Fixture_states_0002\.json/);
    assert.equal(verify({...f, pins: {...f.pins, manifestSha256: sha(manifestBytes), checkpointSha256s: [f.pins.checkpointSha256s[0], sha(chunkBytes)]}}).records.length, 30, 'consistent re-pin passes, so the failure above came from the checkpoint pin');
    assert.throws(() => verify({...f, pins: {...f.pins, manifestSha256: sha(manifestBytes), checkpointSha256s: [f.pins.checkpointSha256s[0]]}}), /checkpoint pin count 1 != manifest\.cacheChunks 2/);

    f = writeCapture(fresh());
    writeFileSync(lib.sourceJsonPathFor(f.manifestPath), readFileSync(lib.sourceJsonPathFor(f.manifestPath), 'utf8') + ' ');
    assert.throws(() => verify(f), /_source\.json sha256 pin mismatch/);
    f = writeCapture(fresh());
    rmSync(lib.sourceJsonPathFor(f.manifestPath));
    assert.throws(() => verify(f), /_source\.json missing/);
    let spec = baseSpec();
    spec.sourceFiles[1].source += '-- edited\n';
    f = writeCapture(fresh(), spec);
    const doc = JSON.parse(readFileSync(lib.sourceJsonPathFor(f.manifestPath), 'utf8'));
    doc.files[1].sha256 = sha(FEATURES_SOURCE); // recorded hash no longer matches its source
    const docBytes = JSON.stringify(doc);
    writeFileSync(lib.sourceJsonPathFor(f.manifestPath), docBytes);
    assert.throws(() => verify({...f, pins: {...f.pins, sourceJsonSha256: sha(docBytes)}}), /_source\.json module src\/Features does not hash/);

    // Content classes (pins refreshed from the written bytes, so only the targeted check can fail).
    spec = baseSpec();
    spec.chunkConfigs = [spec.config, {...structuredClone(spec.config), nodes: spec.config.nodes.map((n, i) => (i === 3 ? {...n, omega: n.omega + 1} : n))}];
    assert.throws(() => verify(writeCapture(fresh(), spec)), /native\.config in Fixture_states_0002\.json differs/);

    spec = baseSpec();
    for (const r of spec.records) r.states.numeric.names = [...STATE_NAMES.slice(0, 48), 'Slow.energy', 'Medium.energy', 'Fast.energy'];
    assert.throws(() => verify(writeCapture(fresh(), spec)), /state names for numeric at record 1 differ .* index 49/);

    spec = baseSpec();
    spec.records[6].states.independent.nodes[2].v += 1e-12;
    assert.throws(() => verify(writeCapture(fresh(), spec)), /independent record 7: nodes\[3\]\.v != vector\[27\]/);
    spec = baseSpec();
    spec.records[20].states.coupled.nodes[23].x = spec.records[20].states.coupled.vector[22];
    assert.throws(() => verify(writeCapture(fresh(), spec)), /coupled record 21: nodes\[24\]\.x != vector\[24\]/);

    spec = baseSpec();
    spec.records[9].bar.availableT += 300;
    assert.throws(() => verify(writeCapture(fresh(), spec)), /bar\.availableT != bar\.t \+ 300 at record 10/);

    spec = baseSpec();
    spec.records[4].feature.volatility = null; // what a NaN becomes in JSON
    assert.throws(() => verify(writeCapture(fresh(), spec)), /feature\.volatility not finite at record 5/);

    spec = baseSpec();
    spec.driveNames = [...lib.DRIVE_NAMES.slice(1), lib.DRIVE_NAMES[0]];
    assert.throws(() => verify(writeCapture(fresh(), spec)), /featureInfo\.driveNames/);

    spec = baseSpec();
    spec.config = {...spec.config, nodes: spec.config.nodes.slice(0, 23)};
    assert.throws(() => verify(writeCapture(fresh(), spec)), /native\.config must have 24 nodes/);
  } finally { for (const d of dirs) rmSync(d, {recursive: true, force: true}); }
});

test('actual saved v2 capture passes every D15 / section 2 check (read-only)', async () => {
  const v = lib.verifySpringInputs(lib.DEFAULT_MANIFEST, {expectedRecords: 2268, expectedChunks: 5});
  assert.equal(v.records.length, 2268);
  assert.deepEqual(v.inputHashes.map(i => i.sha256), [lib.DEFAULT_PINS.manifestSha256, ...lib.DEFAULT_PINS.checkpointSha256s, lib.DEFAULT_PINS.sourceJsonSha256]);
  assert.equal(v.checks.nodeXV.comparisons, 2268 * 3 * 48);
  assert.equal(v.checks.availableT.equalTPlus300, 2268);
  assert.equal(v.checks.sourceJson.modules, 14);
  assert.equal(v.checks.nativeConfig.sha256, '50072f29e88d87a9072751801016463b24fbb1191a1ba836962624bbf3c2249d');
  assert.deepEqual(v.checks.partitions, {training: 1524, validation: 390, evaluation: 354});
  assert.equal(lib.pinFromVerificationDoc().sha256, lib.DEFAULT_PINS.sourceJsonSha256);
  assert.equal((await import('../refit-saved.mjs')).verifyUnchanged(v.inputHashes), true);
});

test('module closure copies only required sibling modules, ignores comments/strings, and refuses forbidden or missing modules', () => {
  const dir = temp('spring-closure-');
  try {
    const src = stubSrc(join(dir, 'ok'), {
      body: `local Helper = require(script.Parent:WaitForChild("SpringHelper"))\n-- require("./Engine") in a comment\nlocal note = "require(Engine) inside a string"\n${INSPECT_BODY}`,
      extra: {SpringHelper: 'local M = if script then require(script.Parent.SpringMath) else require("./SpringMath")\nreturn {}\n', SpringMath: 'return {}\n', Unrelated: 'return {}\n', Engine: 'error("native engine must never load")\n'},
    });
    const closure = lib.resolveModuleClosure(src);
    assert.deepEqual(closure.map(m => m.name), ['SpringHelper', 'SpringMath', 'SpringPolicy', 'SpringState', 'SpringStudy']);
    for (const m of closure) assert.equal(m.sha256, sha(readFileSync(join(src, m.name + '.luau'))));

    const bad = stubSrc(join(dir, 'bad'), {body: `local E = if script then require(script.Parent.Engine) else require("./Engine")\n${INSPECT_BODY}`, extra: {Engine: 'return {}\n'}});
    assert.throws(() => lib.resolveModuleClosure(bad), /Forbidden module Engine required by SpringStudy/);
    for (const name of ['VerifiedStepper', 'Mechanics', 'PhysicsView', 'Learning', 'Features']) {
      const d = stubSrc(join(dir, 'bad' + name), {body: `local X = require("./${name}")\n${INSPECT_BODY}`, extra: {[name]: 'return {}\n'}});
      assert.throws(() => lib.resolveModuleClosure(d), new RegExp(`Forbidden module ${name}`));
    }
    const odd = stubSrc(join(dir, 'odd'), {body: `local X = require(game.ServerStorage.Thing)\n${INSPECT_BODY}`});
    assert.throws(() => lib.resolveModuleClosure(odd), /Unsupported require form in SpringStudy\.luau/);
    const missing = stubSrc(join(dir, 'missing'), {omitStudy: true});
    assert.throws(() => lib.resolveModuleClosure(missing), /SpringStudy\.luau not found/);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test('pipeline with a stub SpringStudy: minimised frozen records reach Luau exactly, write-once outputs carry provenance, reruns are byte-identical', async () => {
  const s = setup({extra: {Unrelated: 'return {}\n'}});
  try {
    const report = await lib.runSpringIndicator(s.opts({keepRunDir: true}));
    assert.equal(report.status, 'complete');
    assert.match(basename(report.resultPath), lib.RESULT_NAME_RE);
    assert.equal(basename(report.resultPath), 'RoAlgoV3_spring_v1_1700000000000.json');
    assert.equal(report.result.chunked, false);
    const bytes = readFileSync(report.resultPath);
    assert.equal(sha(bytes), report.result.sha256);
    assert.ok(bytes.every(b => b === 10 || (b >= 0x20 && b <= 0x7e)), 'result file is printable ASCII');
    const result = JSON.parse(bytes.toString('utf8'));
    assert.equal(result.header, 'Recorded native physics \u00b7 5-minute observations \u00b7 no live simulation.');
    assert.equal(result.recordCount, 30);
    assert.deepEqual(result.keys, {record: 'bar,feature,states', bar: 'availableT,c,day,h,l,label,o,t', feature: 'ready,reset,volatility', states: 'coupled,independent,numeric', state: 'names,vector'});
    assert.equal(result.allRecordsSameKeys, true);
    assert.equal(result.mutationBlocked, true, 'records are frozen inside Luau');
    assert.equal(result.ordered, true);
    const r0 = s.capture.records[0];
    assert.deepEqual(result.echo.bar, {t: r0.bar.t, o: r0.bar.o, h: r0.bar.h, l: r0.bar.l, c: r0.bar.c, availableT: r0.bar.availableT, day: r0.bar.day, label: r0.bar.label});
    assert.deepEqual(result.echo.feature, {reset: true, ready: false, volatility: r0.feature.volatility});
    result.echo.numericVector.forEach((v, j) => assert.ok(Object.is(v, r0.states.numeric.vector[j]), `numeric vector[${j + 1}] round trip`));
    assert.deepEqual(result.echo.coupledNames, STATE_NAMES);
    assert.deepEqual(result.split, {trainEndT: DAY_B, validationEndT: DAY_B + 1500, testStartT: DAY_B + 1500});
    assert.deepEqual(result.descriptor, {schema: 'stub-descriptor', firstName: 'Fast01.x', lastName: 'Slow.energy', drive1: 'trend'});
    assert.equal(result.protocolId, PROTOCOL);
    assert.equal(result.warmup, 12);
    // Provenance
    const p = result.provenance;
    assert.equal(p.newNativeSteps, 0);
    assert.equal(p.historicalNativeSteps, 30 * 12);
    assert.deepEqual(p.inputHashes.map(i => i.sha256), [s.capture.pins.manifestSha256, ...s.capture.pins.checkpointSha256s, s.capture.pins.sourceJsonSha256]);
    assert.deepEqual(Object.keys(p.srcHashes).sort(), ['src/SpringPolicy.luau', 'src/SpringState.luau', 'src/SpringStudy.luau'], 'only the closure is copied (Unrelated.luau is not)');
    for (const [k, v] of Object.entries(p.srcHashes)) assert.equal(v, sha(readFileSync(join(s.srcDir, basename(k)))));
    assert.equal(p.harness['spring-runner/SpringJson.luau'], sha(readFileSync(join(lib.RUNNER_DIR, 'SpringJson.luau'))));
    assert.equal(p.tools['spring-runner-lib.mjs'], sha(readFileSync(join(ROOT, 'spring-runner-lib.mjs'))));
    assert.equal(p.tools['refit-saved.mjs'], sha(readFileSync(join(ROOT, 'refit-saved.mjs'))));
    assert.equal(p.luau.sha256, sha(readFileSync(LUAU)));
    assert.equal(p.luau.version, lib.luauIdentity().version, 'the recorded Luau version (0.741 in the original runs; set LUAU_VERSION if your install folder is not named luau-<version>)');
    assert.deepEqual(p.luau.argv, ['Runner.luau'], 'D19: no --codegen or other flags');
    assert.equal(p.protocol.id, PROTOCOL);
    assert.deepEqual(p.protocol.table, {id: PROTOCOL, stub: true, policy: {warmup: 12}}, 'the protocol table Luau actually used (SpringPolicy.protocol) is recorded');
    assert.equal(p.protocol.sha256, sha(lib.stableStringify(p.protocol.table)));
    assert.deepEqual(p.data.minimisation.omitted.bar, ['contexts', 'minute', 'n', 'v', 'vwap']);
    assert.deepEqual(p.data.minimisation.omitted.feature, ['contextMissing', 'drive', 'names', 'raw', 'regime', 't']);
    assert.deepEqual(p.data.minimisation.omitted.state, ['banks', 'energy', 'nodes']);
    // The temp harness holds only allowlisted data.
    const data = readdirSync(join(report.runDir, 'data')).map(n => readFileSync(join(report.runDir, 'data', n), 'utf8')).join('\n');
    for (const forbidden of ['contexts', 'drive', 'force', 'raw', 'vwap', 'regime', 'energy=', 'nodes']) assert.ok(!data.includes(forbidden), `data modules must not contain ${forbidden}`);
    assert.deepEqual(readdirSync(join(report.runDir, 'src')).sort(), ['SpringPolicy.luau', 'SpringState.luau', 'SpringStudy.luau']);
    // Report files
    assert.deepEqual(listFiles(s.opts().reportsDir), ['RoAlgoV3_spring_v1_1700000000000', ...['post-write-verification.json', 'report.json', 'report.md'].map(n => join('RoAlgoV3_spring_v1_1700000000000', n))].sort());
    const reportJson = JSON.parse(readFileSync(join(report.reportDir, 'report.json'), 'utf8'));
    assert.equal(reportJson.result.sha256, report.result.sha256);
    assert.equal(reportJson.luauHarness.inputRecordsFrozen, true);
    assert.equal(JSON.parse(readFileSync(join(report.reportDir, 'post-write-verification.json'), 'utf8')).status, 'unchanged');
    assert.match(readFileSync(join(report.reportDir, 'report.md'), 'utf8'), /zero new native steps/);
    // Determinism: a second run (new id) produces byte-identical result content.
    const again = await lib.runSpringIndicator(s.opts({nowMs: 1700000000001}));
    assert.equal(readFileSync(again.resultPath, 'utf8'), bytes.toString('utf8'));
    assert.ok(!existsSync(again.runDir), 'temp run dir removed after success unless kept');
  } finally { s.cleanup(); }
});

test('write-once: an existing result or run id is never overwritten and nothing else is written', async () => {
  const s = setup();
  try {
    const first = await lib.runSpringIndicator(s.opts());
    const resultBytes = readFileSync(first.resultPath), outBefore = listFiles(s.opts().outDir), reportsBefore = listFiles(s.opts().reportsDir);
    await assert.rejects(lib.runSpringIndicator(s.opts()), /Refusing to overwrite existing result/);
    rmSync(first.resultPath); // result gone but its run directory remains -> still refused
    await assert.rejects(lib.runSpringIndicator(s.opts()), /Refusing to overwrite existing run directory/);
    writeFileSync(first.resultPath, resultBytes);
    assert.deepEqual(listFiles(s.opts().outDir), outBefore);
    assert.deepEqual(listFiles(s.opts().reportsDir), reportsBefore);
    assert.deepEqual(readFileSync(first.resultPath), resultBytes);
  } finally { s.cleanup(); }
});

const BIG_BODY = `function SpringStudy.evaluate(records, split, descriptor, protocol)
	local rows = {}
	for i = 1, 240 do rows[i] = {index = i, t = records[(i - 1) % #records + 1].bar.t, label = "row " .. i .. " \\u{2265} x", values = {i / 3, -i / 7, i * 1e-9}} end
	local runs = {}
	for k = 1, 3 do
		local runRows = {}
		for i = 1, 90 do runRows[i] = {i = i, payload = string.rep(string.char(96 + k), 40)} end
		runs[k] = {id = "run" .. k, rows = runRows}
	end
	local blocks = {}
	for _, name in {"alpha", "beta", "gamma", "delta", "epsilon"} do blocks[name] = string.rep(name, 300) end
	return {schema = "roalgo-spring-indicator-v1", rows = rows, runs = runs, blocks = blocks, small = {ok = true}}
end`;

test('chunking: results above the threshold become sha256-referenced bridge-loadable parts that reassemble exactly', async () => {
  const s = setup({body: BIG_BODY});
  try {
    const single = await lib.runSpringIndicator(s.opts());
    assert.equal(single.result.chunked, false);
    const threshold = 4096;
    const chunked = await lib.runSpringIndicator(s.opts({nowMs: 1700000000002, threshold}));
    assert.equal(chunked.result.chunked, true);
    assert.ok(chunked.result.parts.length >= 5, `expected several parts, got ${chunked.result.parts.length}`);
    for (const file of [chunked.result, ...chunked.result.parts]) {
      assert.match(file.name, lib.RESULT_NAME_RE);
      const bytes = readFileSync(file.path);
      assert.ok(bytes.length <= threshold, `${file.name} is ${bytes.length} bytes`);
      assert.equal(sha(bytes), file.sha256);
      assert.ok(bytes.every(b => b === 10 || (b >= 0x20 && b <= 0x7e)));
      JSON.parse(bytes.toString('utf8')); // every part is standalone JSON (GET /saved re-parses it)
    }
    const main = JSON.parse(readFileSync(chunked.resultPath, 'utf8'));
    assert.equal(main.$springChunks.partCount, chunked.result.parts.length);
    assert.equal(main.$springChunks.logicalSha256, chunked.result.logicalSha256);
    const text = readFileSync(chunked.resultPath, 'utf8') + chunked.result.parts.map(p => readFileSync(p.path, 'utf8')).join('');
    for (const part of chunked.result.parts) assert.ok(text.includes(part.sha256), `part ${part.name} is referenced by sha256`);
    assert.ok(text.includes('"$springChunkedArray"') && text.includes('"$springChunk"'), 'both array slicing and member externalisation exercised');
    const a = lib.readSpringResult(single.resultPath), b = lib.readSpringResult(chunked.resultPath);
    assert.deepEqual(b, a);
    assert.equal(chunked.result.logicalSha256, single.result.logicalSha256);
    assert.equal(b.rows.length, 240);
    // A tampered part is rejected.
    const victim = chunked.result.parts[1];
    writeFileSync(victim.path, readFileSync(victim.path, 'utf8').replace(/"index":2/, '"index":9'));
    assert.throws(() => lib.readSpringResult(chunked.resultPath), /sha256\/bytes mismatch/);
    // Planner edge cases.
    assert.throws(() => lib.planOutput({schema: 'x', blob: 'y'.repeat(5000)}, {stem: 'S', threshold}), /Scalar at \/blob is larger/);
    assert.throws(() => lib.planOutput({schema: 'x', $springChunk: 1}, {stem: 'S', threshold}), /reserved chunk-marker prefix/);
    assert.throws(() => lib.planOutput({schema: 'x'}, {stem: 'bad.name', threshold}), /does not match/);
  } finally { s.cleanup(); }
});

test('UTF-8 and ASCII safety: StringDecoder keeps split multi-byte log characters, raw non-ASCII @@JSON is rejected', async () => {
  const dir = temp('spring-utf8-');
  try {
    const write = (name, source) => { const p = join(dir, name); writeFileSync(p, source); return p; };
    // Odd ASCII prefix + mixed 2- and 3-byte characters: pipe chunk boundaries must split characters.
    const ok = write('ok.luau', `print("x" .. string.rep("\\u{00B7}\\u{2265}", 100000))\nprint("@@HARNESS {}")\nprint("@@JSON {\\"a\\":\\"\\\\u00b7\\"}")\n`);
    const run = await lib.runLuauHarness(ok, {timeoutMs: 30000});
    assert.equal(run.logs.length, 1);
    assert.equal(run.logs[0].length, 1 + 200000);
    assert.equal(run.logs[0], 'x' + '\u00b7\u2265'.repeat(100000));
    assert.ok(!run.logs[0].includes('\ufffd'), 'no replacement characters');
    assert.deepEqual(run.result, {a: '\u00b7'});
    const raw = write('raw.luau', `print("@@HARNESS {}")\nprint("@@JSON {\\"a\\":\\"\\u{00B7}\\"}")\n`);
    await assert.rejects(lib.runLuauHarness(raw, {timeoutMs: 30000}), /@@JSON output is not printable ASCII \(D18\): code unit U\+00b7/);
    const twice = write('twice.luau', 'print("@@HARNESS {}")\nprint("@@JSON {}")\nprint("@@JSON {}")\n');
    await assert.rejects(lib.runLuauHarness(twice, {timeoutMs: 30000}), /more than one @@JSON/);
    const none = write('none.luau', 'print("@@HARNESS {}")\nprint("hello")\n');
    await assert.rejects(lib.runLuauHarness(none, {timeoutMs: 30000}), /printed no @@JSON result/);
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test('errors propagate: Luau errors verbatim, timeouts kill the process, rejected or malformed results write nothing', async () => {
  const dir = temp('spring-errors-');
  try {
    const loop = join(dir, 'loop.luau');
    writeFileSync(loop, 'while true do end\n');
    const t0 = Date.now();
    await assert.rejects(lib.runLuauHarness(loop, {timeoutMs: 1500}), /timed out after 1500 ms; process killed/);
    assert.ok(Date.now() - t0 < 15000);
  } finally { rmSync(dir, {recursive: true, force: true}); }
  const cases = [
    {body: 'function SpringStudy.evaluate() error("stub failure: boom \\u{2265} 0.72") end', match: /--- luau stderr \(verbatim\) ---\n.*stub failure: boom \u2265 0\.72/s},
    {body: 'function SpringStudy.evaluate() return {schema = "roalgo-spring-indicator-v1", validateOk = false} end', match: /SpringStudy\.validateResult rejected the result: stub validator says no/},
    {body: 'function SpringStudy.evaluate() return {schema = "something-else"} end', match: /result schema "something-else" != "roalgo-spring-indicator-v1"/},
    {body: 'function SpringStudy.evaluate() return {schema = "roalgo-spring-indicator-v1", provenance = {}} end', match: /already has a provenance key/},
    {body: 'function SpringStudy.evaluate() return {schema = "roalgo-spring-indicator-v1", newNativeSteps = 12} end', match: /reports native steps/},
    {body: 'function SpringStudy.evaluate() return {schema = "roalgo-spring-indicator-v1", bad = 0 / 0} end', match: /non-finite number at \$\.bad/},
    {body: 'function SpringStudy.evaluate(records) records[1].bar.c = 1 return {schema = "roalgo-spring-indicator-v1"} end', match: /readonly/},
    {body: INSPECT_BODY, policy: STUB_POLICY.replace('{id = "spring-consensus-v1", stub', '{id = "spring-consensus-v9", stub'), match: /SpringPolicy\.protocol returned a different protocol id/},
  ];
  for (const c of cases) {
    const s = setup({body: c.body, policy: c.policy});
    try {
      await assert.rejects(lib.runSpringIndicator(s.opts()), c.match);
      assert.deepEqual(listFiles(s.opts().outDir), []);
      assert.deepEqual(listFiles(s.opts().reportsDir), []);
    } finally { s.cleanup(); }
  }
  const missing = setup({omitStudy: true});
  try { await assert.rejects(lib.runSpringIndicator(missing.opts()), /SpringStudy\.luau not found/); } finally { missing.cleanup(); }
});

test('CLI: refuses unknown protocols, unknown flags, a missing --protocol and unpinned manifests, writing nothing', () => {
  const s = setup();
  try {
    const out = join(s.dir, 'cli-out'), rep = join(s.dir, 'cli-reports');
    const cli = args => spawnSync(NODE, [join(ROOT, 'run-spring-indicator.mjs'), ...args], {encoding: 'utf8', timeout: 120000, cwd: s.dir});
    let r = cli(['--manifest', s.capture.manifestPath, '--protocol', 'spring-consensus-v2', '--out-dir', out, '--reports-dir', rep]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Unknown protocol 'spring-consensus-v2'; supported: spring-consensus-v1/);
    r = cli(['--protocol', PROTOCOL, '--bogus', 'x', '--out-dir', out]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Unknown argument '--bogus'/);
    r = cli(['--manifest', s.capture.manifestPath, '--out-dir', out]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /--protocol is required/);
    // The CLI always uses the frozen D15 pins, so a different capture is refused before anything is written.
    r = cli(['--manifest', s.capture.manifestPath, '--protocol', PROTOCOL, '--out-dir', out, '--reports-dir', rep]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /manifest sha256 pin mismatch for Fixture\.json/);
    assert.ok(!existsSync(out) && !existsSync(rep));
    assert.deepEqual(lib.parseCliArgs(['--manifest=a/b.json', '--protocol', PROTOCOL, '--out-dir', 'o', '--timeout-ms', '5'], 'C:/base'),
      {manifestPath: join('C:/base', 'a/b.json'), protocolId: PROTOCOL, outDir: join('C:/base', 'o'), timeoutMs: 5});
    assert.throws(() => lib.parseCliArgs(['--protocol', PROTOCOL, '--protocol', PROTOCOL]), /more than once/);
    assert.throws(() => lib.parseCliArgs(['--protocol']), /requires a value/);
    assert.throws(() => lib.parseCliArgs(['--protocol', PROTOCOL, '--timeout-ms', '0']), /positive integer/);
    assert.throws(() => lib.getProtocol('nope'), /Unknown protocol/);
    assert.ok(Object.isFrozen(lib.PROTOCOLS) && Object.isFrozen(lib.PROTOCOLS['spring-consensus-v1']));
  } finally { s.cleanup(); }
});

test('no file under indicator-v3/results, indicator-v2 or indicator-v3/spring-runs changed during these tests', () => {
  const after = GUARDED.map(snapshot);
  GUARDED.forEach((dir, i) => assert.deepEqual(after[i], BEFORE[i], `files changed under ${dir}`));
  assert.equal(existsSync(join(ROOT, 'spring-runs')), SPRING_RUNS_EXISTED);
});
