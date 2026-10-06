// SpringLiveSession against the verified 2024 capture (spring-live-contract.md W3; L1, L2, L5, L6, L7, L10, L12).
//   node --test tests/SpringLiveSession.test.mjs
// Builds Luau data modules in an OS temp directory from the pinned v2 capture (verifySpringInputs), copies the real
// src modules beside them and runs luau.exe (no --codegen, D19). Nothing is written under indicator-v3 except by
// the generator check, which writes only inside its own temp directory.
import {test, before, after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, existsSync} from 'node:fs';
import {join, dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {spawnSync} from 'node:child_process';
import {verifySpringInputs, luauLiteral, runLuauHarness, sha256, stableStringify, luauRequires, resolveModuleClosure, LUAU_PATH} from '../spring-runner-lib.mjs';
import {buildSpringFrozen, writeSpringFrozen, renderSpringFrozen, hexDouble, rowDigest, actionDigest, combineDigests, hex32,
  RESULT_SHA256, DEFAULT_RESULT, DEFAULT_OUT, ACTION_FIELDS} from '../make-spring-frozen.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'src');
const MODULES = ['SpringLiveSession', 'SpringFrozenV1', 'SpringPolicy', 'SpringState', 'SpringSignals', 'Execution', 'SpringStudy'];
const DECISION_MODULES = ['SpringPolicy', 'SpringState', 'SpringSignals', 'Execution', 'SpringStudy'];
const RUN_IDS = ['coupled', 'zero', 'frozen', 'independent', 'numeric', 'ema_baseline', 'no_trade'];
const STORED = ['coupled', 'independent', 'numeric', 'ema_baseline'];
const KIND = {coupled: 'live_native', zero: 'artificial_intervention', frozen: 'artificial_intervention', independent: 'live_native',
  numeric: 'numerical', ema_baseline: 'market_baseline', no_trade: 'no_trade'};
const BAR_FIELDS = ['t', 'o', 'h', 'l', 'c', 'availableT', 'day', 'label'];
const TIMEOUT = 10 * 60 * 1000;

let work, verified, result, resultBytes;
const outputs = {};

const COMMON = `
local SpringJson = require("./SpringJson")
local SpringLiveSession = require("./src/SpringLiveSession")
local SpringFrozenV1 = require("./src/SpringFrozenV1")
local Config = require("./data/Config")
local RecIndex = require("./data/RecIndex")
local C = { Session = SpringLiveSession, Frozen = SpringFrozenV1, Config = Config, Json = SpringJson }
local function deepFreeze(t)
	for _, v in t do if type(v) == "table" then deepFreeze(v) end end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end
local function deepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in v do out[k] = deepCopy(x) end
	return out
end
C.deepFreeze, C.deepCopy = deepFreeze, deepCopy
local NAMES = SpringFrozenV1.descriptor.stateNames
local cache = nil
-- Step inputs from the verified 2024 capture, deep-frozen so any write by the session raises.
function C.records()
	if cache then return cache end
	local out = table.create(RecIndex.count)
	for m = 1, RecIndex.modules do
		for _, r in require(string.format("./data/LiveRec%04d", m)) do
			out[#out + 1] = deepFreeze({ bar = r.bar, feature = r.feature, states = {
				coupled = { names = NAMES, vector = r.states.coupled }, independent = { names = NAMES, vector = r.states.independent },
				numeric = { names = NAMES, vector = r.states.numeric } } })
		end
	end
	assert(#out == RecIndex.count, "loaded " .. #out .. " records")
	cache = out
	return out
end
-- The saved 2024 record i in the data lane's captureCheck shape {index, t, drive, reset, coupled, independent, numeric}.
function C.saved(i)
	local r = C.records()[i]
	if r == nil then return nil end
	return { index = i, t = r.bar.t, drive = r.feature.drive, reset = r.feature.reset,
		coupled = r.states.coupled.vector, independent = r.states.independent.vector, numeric = r.states.numeric.vector }
end
function C.options(over)
	local o = { engineConfig = Config.nativeConfig, driveNames = Config.driveNames, planSha256 = string.rep("5a", 32), leadInRows = 0 }
	for k, v in over or {} do o[k] = v end
	return o
end
function C.session(over) return SpringLiveSession.new(C.options(over)) end
function C.allRows(session)
	local out = {}
	for _, id in SpringLiveSession.RUN_IDS do out[id] = session:rows(id) end
	return out
end
function C.trades(session)
	local out = {}
	for _, id in SpringLiveSession.RUN_IDS do out[id] = session:trades(id) end
	return out
end
function C.emit(harness, value)
	print("@@HARNESS " .. SpringJson.encode(harness))
	print("@@JSON " .. SpringJson.encode(value))
end
return C
`;

const RUNNERS = {
  replay: `
local C = require("./Common")
local inputs = C.records()
collectgarbage("collect")
local heap0 = collectgarbage("count")
local t0 = os.clock()
local session = C.session({ leadInRows = 0 })
for _, input in inputs do session:step(input) end
local seconds = os.clock() - t0
collectgarbage("collect")
local heapKB = collectgarbage("count") - heap0
local display = {}
for _, index in { 1, 12, 13, 500, 1915, 2268 } do
	for _, id in C.Session.RUN_IDS do display[#display + 1] = session:displayRow(id, index) end
end
local t1 = os.clock()
local chunk = session:drainChunk()
local drainSeconds = os.clock() - t1
C.emit({ records = #inputs, rows = session:rowCount(), stepSeconds = seconds, sessionHeapKB = heapKB, drainSeconds = drainSeconds },
	{ rows = C.allRows(session), summary = session:summary(), trades = C.trades(session), comparisons = session:comparisons(),
		evidence = session:evidence(), runs = session:runs(), display = display, reproducibility = session:reproducibility(),
		chunk = { checks = chunk.checks, atEnd = chunk.atEnd, firstIndex = chunk.firstIndex, lastIndex = chunk.lastIndex } })
`,
  partitions: `
local C = require("./Common")
local inputs = C.records()
local function ledger(leadIn, last)
	local session = C.session({ leadInRows = leadIn })
	for i = 1, last do session:step(inputs[i]) end
	return session, { summary = session:summary(), trades = C.trades(session) }
end
local _, training = ledger(0, 1524)
local _, validation = ledger(1524, 1914)
local evaluationSession, evaluation = ledger(1914, 2268)
evaluation.partitionAt = { [1] = evaluationSession:displayRow("coupled", 1914).partition, [2] = evaluationSession:displayRow("coupled", 1915).partition }
C.emit({ rows = evaluationSession:rowCount() }, { training = training, validation = validation, evaluation = evaluation })
`,
  leadin: `
local C = require("./Common")
local inputs = C.records()
local function session(saved)
	local s = C.session({ leadInRows = 2268, saved2024 = saved })
	for _, input in inputs do s:step(input) end
	return s
end
local exact = session(C.saved)
local numeric = session(function(i)
	local r = C.saved(i)
	if i == 2000 then local v = table.clone(r.numeric); v[10] += 1e-13; r.numeric = v end
	return r
end)
local native = session(function(i)
	local r = C.saved(i)
	if i == 777 then local v = table.clone(r.coupled); v[3] += 0.0025; r.coupled = v end
	return r
end)
local within = session(function(i)
	local r = C.saved(i)
	if i == 1500 then local v = table.clone(r.independent); v[30] -= 0.0015; r.independent = v end
	return r
end)
-- Live inputs that differ from the saved capture at one row (what a re-captured state would look like).
local function perturbed(at, variant, k, delta, leadIn)
	local s = C.session({ leadInRows = leadIn or 2268, saved2024 = C.saved })
	for i, input in inputs do
		if i == at then
			local states = table.clone(input.states)
			local vector = table.clone(states[variant].vector)
			vector[k] += delta
			states[variant] = { names = states[variant].names, vector = vector }
			input = { bar = input.bar, feature = input.feature, states = states }
		end
		s:step(input)
	end
	return s:reproducibility()
end
local partial = C.session({ leadInRows = 100, saved2024 = C.saved })
for i = 1, 120 do partial:step(inputs[i]) end
C.emit({ rows = exact:rowCount() }, { rows = C.allRows(exact), summary = exact:summary(), evidence = exact:evidence(),
	reproducibility = { exact = exact:reproducibility(), numeric = numeric:reproducibility(), native = native:reproducibility(),
		within = within:reproducibility(), dx = perturbed(500, "coupled", 4, 1e-3), dv = perturbed(900, "independent", 38, -2e-3),
		energy = perturbed(700, "coupled", 50, 1e-3), partial = partial:reproducibility() },
	partitions = { exact:displayRow("coupled", 1).partition, exact:displayRow("coupled", 2268).partition } })
`,
  chunks: `
local C = require("./Common")
local inputs = C.records()
local session = C.session({ leadInRows = 1000, runId = "regen-test" })
local chunks, sessions, prevDay = {}, 0, nil
for _, input in inputs do
	if prevDay ~= nil and input.bar.day ~= prevDay then
		sessions += 1
		if sessions == 5 then chunks[#chunks + 1] = session:drainChunk(); sessions = 0 end
	end
	prevDay = input.bar.day
	session:step(input)
end
chunks[#chunks + 1] = session:drainChunk()
C.emit({ chunks = #chunks, rows = session:rowCount() }, { chunks = chunks, rows = C.allRows(session), summary = session:summary(),
	comparisons = session:comparisons() })
`,
  regen: `
local C = require("./Common")
local Index = require("./chunkdata/Index")
local function load()
	local out = {}
	for k = 1, Index.count do out[k] = C.deepCopy(require(string.format("./chunkdata/Chunk%03d", k))) end
	return out
end
local opts = { leadInRows = 1000, runId = "regen-test" }
local clean, report = C.Session.regenerate(C.options(opts), load())
local function tamper(edit, over)
	local chunks = load()
	edit(chunks)
	local _, r = C.Session.regenerate(C.options(over or opts), chunks)
	r.firstDifference = r.firstDifference and { index = r.firstDifference.index, run = r.firstDifference.run } or nil
	return r
end
local decisionRows = clean:reproducibility().decisionRows
local reports = {
	clean = report,
	row = tamper(function(c) c[3].rows.coupled[7].s += 1e-6 end),
	state = tamper(function(c)
		local h = c[1].states.coupled[10]
		c[1].states.coupled[10] = string.sub(h, 1, 14) .. "40" .. string.sub(h, 17)
	end),
	digest = tamper(function(c) c[4].checks.frozen.digest = "00000000" end),
	equity = tamper(function(c) c[5].atEnd.equity.zero = string.rep("0", 16) end),
	plan = tamper(function() end, { leadInRows = 1000, runId = "regen-test", planSha256 = string.rep("0", 64) }),
}
reports.clean.firstDifference = nil
C.emit({ rows = clean:rowCount() }, { reports = reports, rows = C.allRows(clean), summary = clean:summary(), comparisons = clean:comparisons(),
	decisionRows = decisionRows })
`,
  pins: `
local C = require("./Common")
local F = C.Frozen
local function tampered(edit) local c = C.deepCopy(F); edit(c); return C.deepFreeze(c) end
local function try(name, over)
	local ok, err = pcall(C.Session.new, C.options(over))
	return { name = name, ok = ok, err = if ok then nil else tostring(err) }
end
local function config(edit) local c = C.deepCopy(C.Config.nativeConfig); edit(c); return c end
local swapped = table.clone(C.Config.driveNames)
swapped[7], swapped[8] = swapped[8], swapped[7]
C.emit({ cases = 15 }, {
	try("accepted", {}),
	try("unfrozen", { frozen = C.deepCopy(F) }),
	try("entry", { frozen = tampered(function(c) c.calibration.thresholds.entry += 1e-15 end) }),
	try("exit", { frozen = tampered(function(c) c.calibration.thresholds.exit += 1e-16 end) }),
	try("bankDeadband", { frozen = tampered(function(c) c.calibration.thresholds.bankDeadband += 1e-16 end) }),
	try("baseEntry", { frozen = tampered(function(c) c.baselineCalibration.thresholds.entry += 1e-15 end) }),
	try("frozenState", { frozen = tampered(function(c) c.frozenState.v[24] += 1e-15 end) }),
	try("calibrationStd", { frozen = tampered(function(c) c.calibration.coordinates[40].std *= 1 + 1e-12 end) }),
	try("pinEdited", { frozen = tampered(function(c) c.pins.exit = c.pins.entry end) }),
	try("resultSha", { frozen = tampered(function(c) c.resultSha256 = string.rep("a", 64) end) }),
	try("descriptor", { frozen = tampered(function(c) c.descriptor.nodes[9].y += 1 end) }),
	try("nodeDamping", { engineConfig = config(function(c) c.nodes[7].c *= 1 + 1e-12 end) }),
	try("edgeStiffness", { engineConfig = config(function(c) c.edges[3].k += 1e-9 end) }),
	try("projection", { engineConfig = config(function(c) c.nodes[1].projection[3], c.nodes[1].projection[2] = c.nodes[1].projection[2], c.nodes[1].projection[3] end) }),
	try("driveNames", { driveNames = swapped }),
})
`,
};

async function luau(name) {
  if (outputs[name]) return outputs[name];
  const path = join(work, name + '.luau');
  if (!existsSync(path)) writeFileSync(path, RUNNERS[name].trimStart(), {flag: 'wx'});
  const run = await runLuauHarness(path, {cwd: work, timeoutMs: TIMEOUT});
  outputs[name] = run;
  return run;
}
const storedRun = id => result.runs.find(r => r.id === id);
const r6 = x => (x === 0 ? 0 : Number(x.toPrecision(6)));
function rowDiffs(mine, stored) {
  let diff = 0, first = null;
  const n = Math.max(mine.length, stored.length);
  for (let i = 0; i < n; i++) if (!isDeepStrictEqual(mine[i], stored[i])) { diff++; first ??= {index: i + 1, mine: mine[i], stored: stored[i]}; }
  return {diff, first};
}

before(() => {
  resultBytes = readFileSync(DEFAULT_RESULT);
  assert.equal(sha256(resultBytes), RESULT_SHA256, 'the pinned 2024 result');
  result = JSON.parse(resultBytes.toString('utf8'));
  verified = verifySpringInputs(undefined, {expectedRecords: 2268, expectedChunks: 5});
  work = mkdtempSync(join(tmpdir(), 'spring-live-session-'));
  mkdirSync(join(work, 'src'));
  mkdirSync(join(work, 'data'));
  for (const m of MODULES) copyFileSync(join(SRC, m + '.luau'), join(work, 'src', m + '.luau'));
  copyFileSync(join(ROOT, 'spring-runner', 'SpringJson.luau'), join(work, 'SpringJson.luau'));
  const records = verified.records.map(r => ({
    bar: Object.fromEntries(BAR_FIELDS.map(k => [k, r.bar[k]])),
    feature: {reset: r.feature.reset, ready: r.feature.ready, volatility: r.feature.volatility, drive: r.feature.drive},
    states: {coupled: r.states.coupled.vector, independent: r.states.independent.vector, numeric: r.states.numeric.vector},
  }));
  let modules = 0;
  for (let k = 0; k < records.length; k += 64)
    writeFileSync(join(work, 'data', `LiveRec${String(++modules).padStart(4, '0')}.luau`), 'return ' + luauLiteral(records.slice(k, k + 64)) + '\n', {flag: 'wx'});
  writeFileSync(join(work, 'data', 'RecIndex.luau'), 'return ' + luauLiteral({modules, count: records.length}) + '\n', {flag: 'wx'});
  writeFileSync(join(work, 'data', 'Config.luau'), 'return ' + luauLiteral({nativeConfig: verified.nativeConfig, driveNames: verified.driveNames}) + '\n', {flag: 'wx'});
  writeFileSync(join(work, 'Common.luau'), COMMON.trimStart(), {flag: 'wx'});
});
after(() => {
  if (work && !process.env.SPRING_LIVE_KEEP) rmSync(work, {recursive: true, force: true});
  else if (work) console.log('kept', work);
});

test('make-spring-frozen: deterministic module equal to src/SpringFrozenV1.luau, pinned to the 2024 result and record 12', () => {
  const built = buildSpringFrozen({verified});
  const onDisk = readFileSync(DEFAULT_OUT);
  assert.ok(onDisk.equals(Buffer.from(built.text, 'utf8')), 'regenerating gives the committed bytes');
  assert.ok(!built.text.includes('\r'), 'LF line endings');
  const f = built.frozen, t = result.calibration.thresholds, bt = result.baselineCalibration.thresholds;
  assert.equal(f.resultSha256, RESULT_SHA256);
  assert.deepEqual(
    [f.pins.entry, f.pins.exit, f.pins.bankDeadband, f.pins.unclamped, f.pins.baseEntry, f.pins.baseExit, f.pins.baseDeadband],
    ['c58d3570b4debc3f', '98fffc64a2fba93f', 'c58d3570b4de9c3f', 'c58d3570b4debc3f', 'd38a558f6b05be3f', 'f1fccccde004ab3f', 'd38a558f6b059e3f'],
    'the hex pins measured by the scout');
  assert.equal(f.pins.entry, hexDouble(t.entry));
  assert.equal(f.pins.baseUnclamped, hexDouble(bt.unclamped));
  // Frozen state: checkpoint record 12 at full precision, whose 6-digit copy is the stored result.frozenState.
  const v12 = verified.records[11].states.coupled.vector;
  assert.deepEqual(f.frozenState.x, v12.slice(0, 24));
  assert.deepEqual(f.frozenState.v, v12.slice(24, 48));
  assert.deepEqual(f.frozenState.x.map(r6), result.frozenState.x);
  assert.ok(f.frozenState.x.some((x, i) => x !== result.frozenState.x[i]), 'full precision, not the 6-digit copy');
  const packed = Buffer.alloc(384);
  [...v12.slice(0, 48)].forEach((x, i) => packed.writeDoubleLE(x, 8 * i));
  assert.equal(f.pins.frozenState, packed.toString('hex'));
  assert.deepEqual(f.nativeConfig2024, verified.nativeConfig);
  assert.deepEqual(f.calibration, result.calibration);
  assert.deepEqual(f.baselineCalibration, result.baselineCalibration);
  assert.deepEqual(f.descriptor, result.descriptor);
  // Canonical hashes measured by the live scout (pins.mjs).
  assert.equal(f.canonicalSha256.calibration, 'de59c9f4b3004a8830a0a818743f3f31303c603f37c2f61d2a8f68173aee4dae');
  assert.equal(f.canonicalSha256.descriptor, 'd83763eb4fc89670923f88478df399bf06cb8a341979d385de8f0c8701c8381f');
  assert.equal(f.canonicalSha256.baselineCalibration, '60bbd01fed34bd68272aefbb9d0111737a10ea174dfdd0bee6ee0a2d804444f9');
  assert.equal(f.canonicalSha256.protocol, '02e2a7fe88b1fbc5ba8dd504c2202efe76c2837c0fb9f944f1907f95375c3690');
  assert.equal(f.canonicalSha256.nativeConfig, '50072f29e88d87a9072751801016463b24fbb1191a1ba836962624bbf3c2249d');
  // Decision-determining non-doubles are pinned too (which nodes vote, which coordinates are active).
  assert.equal(f.pins.eligible, '1,4,7|9,11,12,14,15|17,19,20,22,23');
  assert.equal(f.pins.active, result.calibration.coordinates.map(c => (c.active ? '1' : '0')).join(''));
  // The values compiled into SpringLiveSession equal the generator's: the bundle digest and the threshold pins.
  const source = readFileSync(join(SRC, 'SpringLiveSession.luau'), 'utf8');
  assert.equal(source.match(/local FROZEN_BUNDLE_FNV32 = "([0-9a-f]{8})"/)[1], built.bundleFnv32, 'FROZEN_BUNDLE_FNV32 in SpringLiveSession');
  const compiled = source.match(/local EXPECTED_PINS = table\.freeze\(\{([\s\S]*?)\}\)/)[1];
  const pairs = Object.fromEntries([...compiled.matchAll(/(\w+) = "([^"]*)"/g)].map(m => [m[1], m[2]]));
  assert.deepEqual(Object.keys(pairs).sort(), ['bankDeadband', 'baseDeadband', 'baseEntry', 'baseExit', 'baseUnclamped', 'eligible', 'entry', 'exit', 'unclamped']);
  for (const [key, value] of Object.entries(pairs)) assert.equal(value, f.pins[key], `EXPECTED_PINS.${key}`);
  // L20 row digests: one per stored row, the 7 runs in result order, sessions that partition 1..2268 by trading day.
  const d = f.rowDigests2024;
  assert.deepEqual(d.runIds, RUN_IDS);
  assert.equal(d.count, 2268);
  assert.equal(d.rows.length, 8 * 2268);
  assert.equal(d.actions.length, 8 * 2268);
  assert.deepEqual(d.actionFields, ACTION_FIELDS);
  assert.equal(d.sessions.length, 30);
  assert.deepEqual(d.sessions.map(s => s.last - s.first + 1).filter(n => n !== 78), [42, 42], 'two early closes');
  assert.equal(d.sessions.at(-1).last, 2268);
  const row1 = hex32(combineDigests(result.runs.map(r => rowDigest(r.fullHistory.rows[0]))));
  assert.equal(d.rows.slice(0, 8), row1);
  assert.equal(d.sessions[0].runs.zero, hex32(combineDigests(storedRun('zero').fullHistory.rows.slice(0, 78).map(rowDigest))));
  console.log(`SpringFrozenV1: ${built.bytes} bytes, bundle FNV-1a ${built.bundleFnv32}`);
});

test('make-spring-frozen: write-once (unchanged / refuses a different file) and refuses a result whose sha256 differs', () => {
  const dir = mkdtempSync(join(tmpdir(), 'spring-frozen-gen-'));
  try {
    const built = buildSpringFrozen({verified});
    const out = join(dir, 'SpringFrozenV1.luau');
    assert.equal(writeSpringFrozen(built.text, out).status, 'written');
    assert.equal(writeSpringFrozen(built.text, out).status, 'unchanged');
    writeFileSync(out, built.text.replace('deepFreeze(', 'deepFreeze( '));
    assert.throws(() => writeSpringFrozen(built.text, out), /refusing to overwrite a different existing file/);
    assert.equal(readFileSync(out, 'utf8'), built.text.replace('deepFreeze(', 'deepFreeze( '), 'the different file is left as it was');
    const copy = join(dir, 'result.json');
    writeFileSync(copy, Buffer.concat([resultBytes, Buffer.from(' ')]));
    assert.throws(() => buildSpringFrozen({resultPath: copy, verified}), /result sha256 pin mismatch/);
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

test('fences: SpringLiveSession requires only the allowed modules; the decision modules are byte-identical to 2024', () => {
  const source = readFileSync(join(SRC, 'SpringLiveSession.luau'), 'utf8');
  assert.deepEqual(luauRequires(source, 'SpringLiveSession').sort(), ['Execution', 'SpringFrozenV1', 'SpringPolicy', 'SpringSignals', 'SpringState', 'SpringStudy']);
  const closure = resolveModuleClosure(SRC, ['SpringLiveSession']).map(m => m.name);
  assert.deepEqual(closure, ['Execution', 'SpringFrozenV1', 'SpringLiveSession', 'SpringPolicy', 'SpringSignals', 'SpringState', 'SpringStudy']);
  for (const m of DECISION_MODULES)
    assert.equal(sha256(readFileSync(join(SRC, m + '.luau'))), result.provenance.srcHashes[`src/${m}.luau`], `${m} unchanged since the 2024 result`);
  for (const file of ['src/SpringLiveSession.luau', 'src/SpringFrozenV1.luau', 'tests/SpringLiveSession.spec.luau', 'tests/SpringLiveSession.test.mjs', 'make-spring-frozen.mjs'])
    assert.ok(!readFileSync(join(ROOT, file)).includes(0x0d), `${file} uses LF line endings`);
});

test('leadInRows=0: the session reproduces all 2,268 stored 2024 rows of all 7 runs with 0 differences', async () => {
  const {result: out, harness} = await luau('replay');
  assert.equal(harness.records, 2268);
  assert.equal(harness.rows, 2268);
  let total = 0;
  for (const id of RUN_IDS) {
    const stored = storedRun(id);
    const {diff, first} = rowDiffs(out.rows[id], stored.fullHistory.rows);
    assert.equal(out.rows[id].length, 2268, `${id} row count`);
    assert.equal(diff, 0, `${id}: ${diff} differing rows; first ${JSON.stringify(first)?.slice(0, 800)}`);
    total += out.rows[id].length;
    assert.deepEqual(out.summary.runs[id], stored.fullHistory.summary, `${id} continuous-ledger summary`);
    assert.deepEqual(out.trades[id], stored.fullHistory.trades, `${id} trades`);
  }
  assert.equal(total, 7 * 2268);
  for (const [key, value] of Object.entries(result.comparisons)) {
    assert.deepEqual(out.comparisons[key].all, value.all, `${key} paired comparison`);
    assert.deepEqual(out.comparisons[key].forward_test, value.all, `${key}: with no lead-in the forward test is every row`);
    assert.equal(out.comparisons[key].calibration_lead_in.rows, 0);
  }
  assert.deepEqual(out.evidence.physicsDependenceCounts, result.evidence.physicsDependenceCounts);
  assert.equal(out.evidence.physicsDependence, result.evidence.physicsDependence);
  assert.deepEqual(out.evidence.fixtureCheck, result.evidence.fixtureCheck);
  assert.equal(out.evidence.implementationStatus, 'pass');
  assert.equal(out.evidence.marketEvidence, 'forward_test_predeclared');
  assert.equal(out.reproducibility.status, 'not_checked');
  // Sub-periods of the one ledger: 2024-Q4 and 2024 are the whole ledger here.
  assert.equal(out.summary.periods.coupled.quarters.length, 1);
  assert.equal(out.summary.periods.coupled.quarters[0].netReturn, storedRun('coupled').fullHistory.summary.netReturn);
  assert.equal(out.summary.primaryCriterion.coupledNetReturn, storedRun('coupled').fullHistory.summary.netReturn);
  assert.equal(out.summary.primaryCriterion.emaBaselineNetReturn, storedRun('ema_baseline').fullHistory.summary.netReturn);
  // Runs (L5/L12) and display rows through SpringStudy.displayRow.
  assert.deepEqual(out.runs.map(r => [r.id, r.kind, r.rowCount]), RUN_IDS.map(id => [id, KIND[id], 2268]));
  for (const row of out.display) {
    const i = row.index, stored = storedRun(row.runId);
    assert.equal(row.partition, 'forward_test');
    assert.equal(row.runKind, KIND[row.runId]);
    assert.equal(row.t, result.timeline[i - 1].t);
    assert.equal(row.label, result.timeline[i - 1].l);
    assert.equal(row.final.action, stored.fullHistory.rows[i - 1].fa);
    assert.equal(row.equity, stored.fullHistory.rows[i - 1].eq);
    const states = result.states[row.runId];
    if (states) {
      assert.deepEqual(row.x, states.x[i - 1], `${row.runId}:${i} x`);
      assert.deepEqual(row.v, states.v[i - 1], `${row.runId}:${i} v`);
    } else if (row.runId === 'frozen') {
      assert.deepEqual(row.x, result.frozenState.x);
      assert.deepEqual(row.v, result.frozenState.v);
    } else if (row.runId === 'zero') {
      assert.deepEqual(row.x, Array(24).fill(0));
    } else {
      assert.equal(row.x, undefined);
    }
  }
  // No lead-in, so the L20 gate is not checked (and no shadow session ran).
  assert.equal(out.reproducibility.decisionRows.status, 'not_checked');
  assert.equal(out.summary.primaryCriterion.leadInValidation.decisionRows.status, 'not_checked');
  // One chunk over all 2268 rows: end equities are the stored final equities bit for bit, and the Luau checks of all
  // 7 runs equal the JS spring-row-digest-1 digest and counts of the stored rows.
  assert.deepEqual([out.chunk.firstIndex, out.chunk.lastIndex], [1, 2268]);
  assert.deepEqual(Object.keys(out.chunk.checks).sort(), [...RUN_IDS].sort());
  for (const id of RUN_IDS) {
    const stored = storedRun(id).fullHistory;
    assert.ok(Object.is(Buffer.from(out.chunk.atEnd.equity[id], 'hex').readDoubleLE(0), stored.summary.finalEquity), `${id} atEnd.equity`);
    const check = out.chunk.checks[id];
    assert.equal(check.digest, hex32(combineDigests(stored.rows.map(rowDigest))), `${id} checks.digest equals the JS digest of the stored rows`);
    assert.equal(check.finalActions, stored.rows.filter(r => r.fa !== 'HOLD').length, `${id} finalActions`);
    assert.equal(check.fills, stored.rows.reduce((n, r) => n + (r.ex ? r.ex.length : 0), 0), `${id} fills`);
  }
  assert.ok(out.chunk.checks.coupled.fills > 0 && out.chunk.checks.ema_baseline.fills > 0, 'the traded runs have fills');
  assert.notEqual(Buffer.from(out.chunk.atEnd.equity.coupled, 'hex').readDoubleLE(0), 1);
  console.log(`replay: ${harness.stepSeconds.toFixed(3)} s for 2268 bars x 7 runs; session heap ${(harness.sessionHeapKB / 1024).toFixed(1)} MB` +
    ` (${(harness.sessionHeapKB / 2268).toFixed(2)} KB per bar); one 2268-row drain ${harness.drainSeconds.toFixed(3)} s`);
});

test('lead-in and boundary: the forward ledger reproduces the stored 2024 partition ledgers (warm-up, reset, flat start)', async () => {
  const {result: out} = await luau('partitions');
  assert.deepEqual(result.split.ranges, [[1, 1524], [1525, 1914], [1915, 2268]], 'partition ranges of the 2024 result');
  for (const [name, partition] of [['training', 'training_retrospective'], ['validation', 'validation'], ['evaluation', 'evaluation']]) {
    for (const id of RUN_IDS) {
      const stored = storedRun(id).partitions[partition];
      assert.deepEqual(out[name].summary.runs[id], stored.summary, `${id} ${partition} summary`);
      assert.deepEqual(out[name].trades[id], stored.trades, `${id} ${partition} trades`);
    }
  }
  assert.deepEqual(out.evaluation.partitionAt, ['calibration_lead_in', 'forward_test']);
  assert.equal(out.evaluation.summary.forwardRows, 354);
  assert.equal(out.evaluation.summary.runs.coupled.firstT, result.timeline[1914].t);
});

test('a full 2024 lead-in is flat and untraded, keeps the policy intents, and compares the states with saved2024 (L2, L3b)', async () => {
  const {result: out} = await luau('leadin');
  for (const id of RUN_IDS) {
    const rows = out.rows[id], stored = storedRun(id).fullHistory.rows;
    assert.equal(rows.length, 2268);
    rows.forEach((r, k) => {
      assert.ok(r.fa === 'HOLD' && r.fr === 'lead_in_not_traded' && r.fs === 'lead_in', `${id}:${k + 1} final`);
      assert.ok(r.po === 0 && r.eq === 1 && r.hb === 0 && r.ex === undefined && r.pe === undefined, `${id}:${k + 1} untraded`);
      assert.equal(r.ov === true, r.ia !== 'HOLD', `${id}:${k + 1} overridden exactly when an intent was not traded`);
    });
    // Until the first stored entry intent the 2024 context was flat as well, so every policy field is identical.
    const firstEntry = stored.findIndex(r => r.ia !== 'HOLD');
    const upto = firstEntry < 0 ? stored.length : firstEntry + 1;
    const policyFields = r => ({ok: r.ok, rs: r.rs, s: r.s, b: r.b, c: r.c, su: r.su, bl: r.bl, st: r.st, ia: r.ia, is: r.is, ir: r.ir});
    for (let k = 0; k < upto; k++) assert.deepEqual(policyFields(rows[k]), policyFields(stored[k]), `${id}:${k + 1} intent before the first entry`);
    if (id === 'zero' || id === 'no_trade') {
      // These never left flat in 2024: the lead-in rows equal the stored rows except the final source and reason.
      rows.forEach((r, k) => {
        const {fs: _a, fr: _b, ...mine} = r, {fs: _c, fr: _d, ...theirs} = stored[k];
        assert.deepEqual(mine, theirs, `${id}:${k + 1}`);
      });
    }
  }
  assert.ok(out.rows.coupled.filter(r => r.ia !== 'HOLD').length > 0, 'lead-in intents are shown');
  assert.deepEqual(out.partitions, ['calibration_lead_in', 'calibration_lead_in']);
  assert.deepEqual(out.summary.runs, [], 'no ledger exists during the lead-in (SpringJson writes an empty table as [])');
  assert.equal(out.evidence.forwardRows, 0);
  assert.equal(out.evidence.leadInRows, 2268);
  const {exact, numeric, native, within} = out.reproducibility;
  assert.equal(exact.status, 'pass');
  assert.equal(exact.compared, 2268);
  assert.deepEqual(exact.maxAbs, {coupled: 0, independent: 0, numeric: 0});
  assert.equal(exact.drivesExact, true);
  assert.equal(exact.label, 'lead-in re-capture matches the 2024 calibration capture (numeric exact; native within 0.002)');
  assert.equal(numeric.status, 'differs');
  assert.equal(numeric.firstExceeded.index, 2000);
  assert.equal(numeric.label, 're-captured physics differs from the 2024 calibration capture');
  assert.equal(native.status, 'differs');
  assert.deepEqual([native.firstExceeded.index, native.firstExceeded.variant], [777, 'coupled']);
  assert.ok(Math.abs(native.maxAbs.coupled - 0.0025) < 1e-12);
  assert.equal(within.status, 'pass');
  assert.ok(Math.abs(within.maxAbs.independent - 0.0015) < 1e-12);
  // L20 decision-row gate: the leadInRows=0 shadow reproduces every stored 2024 row of all 7 runs (Luau digests of the
  // shadow rows equal the JS digests of the stored rows), per row and per 2024 session.
  const rows = exact.decisionRows;
  assert.equal(rows.status, 'pass', JSON.stringify(rows));
  assert.deepEqual([rows.compared, rows.target, rows.expectedRows, rows.rowDifferences, rows.actionRowDifferences, rows.sessionsCompared],
    [2268, 2268, 2268, 0, 0, 30]);
  assert.deepEqual(rows.sessionsDiffering, Object.fromEntries(RUN_IDS.map(id => [id, 0])));
  assert.equal(rows.label, 'all 2268 lead-in decision and ledger rows equal the offline 2024 result (0 differences)');
  assert.deepEqual(out.summary.runs, [], 'still no ledger: the gate is reported in reproducibility(), and beside the headline once one exists');
  // dx and dv per variant (L20), and what a re-captured difference does to the decision rows.
  const {dx, dv, energy, partial} = out.reproducibility;
  assert.ok(Math.abs(dx.maxAbsX.coupled - 1e-3) < 1e-12 && dx.maxAbsV.coupled === 0 && dx.maxAbsEnergy.coupled === 0, JSON.stringify(dx.maxAbsX));
  assert.equal(dx.status, 'pass', 'within the 0.002 native tolerance');
  assert.equal(dx.decisionRows.status, 'differs');
  assert.equal(dx.decisionRows.firstDifferentRow, 500);
  assert.ok(dx.decisionRows.rowDifferences >= 1);
  assert.ok(dx.decisionRows.sessionsDiffering.coupled >= 1);
  for (const id of RUN_IDS.filter(id => id !== 'coupled')) assert.equal(dx.decisionRows.sessionsDiffering[id], 0, `${id} is not affected by a coupled state`);
  assert.match(dx.decisionRows.label, /^\d+ of 2268 lead-in rows differ from the offline 2024 result/);
  assert.ok(Math.abs(dv.maxAbsV.independent - 2e-3) < 1e-12 && dv.maxAbsX.independent === 0 && dv.maxAbsX.coupled === 0);
  assert.equal(dv.decisionRows.firstDifferentRow, 900);
  assert.ok(dv.decisionRows.sessionsDiffering.independent >= 1 && dv.decisionRows.sessionsDiffering.coupled === 0);
  // Bank energies never enter a decision: the state gate sees the difference, the decision rows do not.
  assert.ok(Math.abs(energy.maxAbsEnergy.coupled - 1e-3) < 1e-12 && energy.maxAbsXV.coupled === 0 && energy.status === 'pass');
  assert.equal(energy.decisionRows.status, 'pass');
  assert.equal(energy.decisionRows.rowDifferences, 0);
  // A shorter lead-in compares only its own rows.
  assert.equal(partial.decisionRows.status, 'partial');
  assert.deepEqual([partial.decisionRows.compared, partial.decisionRows.rowDifferences, partial.decisionRows.sessionsCompared], [100, 0, 1]);
  assert.equal(partial.status, 'pass');
  assert.equal(partial.compared, 100);
});

test('chunks (L10) carry exact inputs and 4 stored runs; JSON round trip + regenerate gives 0 differences for all 7 runs', async () => {
  const {result: out, harness} = await luau('chunks');
  const chunks = out.chunks;
  assert.equal(harness.chunks, 6, '30 sessions in chunks of 5');
  let next = 1;
  chunks.forEach((chunk, k) => {
    assert.equal(chunk.schema, 'roalgo-spring-live-chunk-1');
    assert.equal(chunk.seq, k + 1);
    assert.equal(chunk.firstIndex, next);
    assert.equal(chunk.count, chunk.lastIndex - chunk.firstIndex + 1);
    assert.equal(chunk.leadInRows, 1000);
    assert.equal(chunk.runId, 'regen-test');
    assert.equal(chunk.frozenResultSha256, RESULT_SHA256);
    assert.deepEqual(Object.keys(chunk.rows).sort(), [...STORED].sort(), 'rows only for the four stored runs');
    assert.deepEqual(Object.keys(chunk.checks).sort(), [...RUN_IDS].sort(), 'checks for all 7 runs');
    for (const id of RUN_IDS) {
      const rows = out.rows[id].slice(chunk.firstIndex - 1, chunk.lastIndex);
      assert.equal(chunk.checks[id].digest, hex32(combineDigests(rows.map(rowDigest))), `chunk ${k + 1} ${id} checks.digest`);
      assert.equal(chunk.checks[id].finalActions, rows.filter(r => r.fa !== 'HOLD').length);
      assert.equal(chunk.checks[id].fills, rows.reduce((n, r) => n + (r.ex ? r.ex.length : 0), 0));
    }
    assert.equal(new Set(chunk.bars.map(b => b.day)).size, 5, 'five sessions per chunk');
    for (let j = 0; j < chunk.count; j++) {
      const i = chunk.firstIndex + j, record = verified.records[i - 1];
      assert.deepEqual(Object.keys(chunk.bars[j]).sort(), [...BAR_FIELDS].sort());
      for (const key of BAR_FIELDS) assert.equal(chunk.bars[j][key], record.bar[key]);
      assert.deepEqual(chunk.features[j], {reset: record.feature.reset, ready: record.feature.ready, volatility: record.feature.volatility, drive: record.feature.drive});
      for (const variant of ['coupled', 'independent', 'numeric']) {
        const hex = chunk.states[variant][j];
        assert.match(hex, /^[0-9a-f]{816}$/);
        const buf = Buffer.from(hex, 'hex');
        const decoded = Array.from({length: 51}, (_, n) => buf.readDoubleLE(8 * n));
        assert.ok(decoded.every((x, n) => Object.is(x, record.states[variant].vector[n])), `${variant}:${i} hex is the exact capture vector`);
      }
      for (const id of STORED) assert.deepEqual(chunk.rows[id][j], out.rows[id][i - 1]);
    }
    next = chunk.lastIndex + 1;
  });
  assert.equal(next, 2269);
  // Through JSON as a server would store them, then back into Luau as data modules.
  const dir = join(work, 'chunkdata');
  mkdirSync(dir);
  chunks.forEach((chunk, k) => {
    const text = JSON.stringify(chunk);
    writeFileSync(join(dir, `chunk_${k + 1}.json`), text, {flag: 'wx'});
    const back = JSON.parse(readFileSync(join(dir, `chunk_${k + 1}.json`), 'utf8'));
    writeFileSync(join(dir, `Chunk${String(k + 1).padStart(3, '0')}.luau`), 'return ' + luauLiteral(back) + '\n', {flag: 'wx'});
  });
  writeFileSync(join(dir, 'Index.luau'), 'return ' + luauLiteral({count: chunks.length}) + '\n', {flag: 'wx'});
  const {result: regen} = await luau('regen');
  const clean = regen.reports.clean;
  assert.equal(clean.pass, true, JSON.stringify(clean).slice(0, 1000));
  assert.equal(clean.rows, 2268);
  assert.equal(clean.chunks, 6);
  assert.equal(clean.totalRowDifferences, 0);
  assert.deepEqual(clean.chunkFieldMismatches, []);
  for (const id of RUN_IDS) {
    const {diff, first} = rowDiffs(regen.rows[id], out.rows[id]);
    assert.equal(diff, 0, `${id} regenerated: ${diff} differing rows; first ${JSON.stringify(first)?.slice(0, 600)}`);
    assert.equal(regen.rows[id].length, 2268);
  }
  assert.deepEqual(regen.summary, out.summary);
  assert.deepEqual(regen.comparisons, out.comparisons);
  // Replaying from chunks re-derives the L20 decision-row gate over the 1000-row lead-in (0 differences).
  assert.deepEqual([regen.decisionRows.status, regen.decisionRows.compared, regen.decisionRows.rowDifferences], ['partial', 1000, 0]);
  assert.equal(out.summary.primaryCriterion.leadInValidation.decisionRows.status, 'partial');
  const {row, state, digest, equity, plan} = regen.reports;
  assert.equal(row.pass, false);
  assert.equal(row.rowDifferences.coupled, 1);
  assert.equal(row.firstDifference.index, chunks[2].firstIndex + 6);
  assert.equal(state.pass, false);
  assert.ok(state.totalRowDifferences > 0 && state.firstDifference.index === 10);
  assert.equal(digest.pass, false);
  assert.equal(digest.totalRowDifferences, 0);
  assert.deepEqual(digest.chunkFieldMismatches, ['chunk 4 checks']);
  assert.equal(equity.pass, false);
  assert.deepEqual(equity.chunkFieldMismatches, ['chunk 5 atEnd']);
  assert.equal(plan.pass, false);
  assert.match(plan.problems[0], /plan/);
});

test('an edited SpringFrozenV1 (values and its own pins edited together) or a drifted SpringSignals is refused in Luau', () => {
  const built = buildSpringFrozen({verified});
  const PROBE = [
    'local F = require("./src/SpringFrozenV1")',
    'local L = require("./src/SpringLiveSession")',
    'local function copy(v) if type(v) ~= "table" then return v end local o = {} for k, x in v do o[k] = copy(x) end return o end',
    'local ok, err = pcall(L.new, { engineConfig = copy(F.nativeConfig2024), driveNames = table.clone(F.descriptor.driveNames),',
    '\tplanSha256 = string.rep("a", 64), leadInRows = 0 })',
    'print("@@RESULT " .. (if ok then "ACCEPTED" else "REFUSED " .. tostring(err)))',
    '',
  ].join('\n');
  const compiled = /differs from the 2024 value compiled into SpringLiveSession/;
  const bundle = /frozen bundle digest [0-9a-f]{8} differs from the digest compiled into SpringLiveSession \(2b302cc9\)/;
  const cases = [
    ['shipped', f => f, null, /^ACCEPTED$/],
    ['entry and its pin', f => { f.calibration.thresholds.entry *= 1 + 1e-9; f.pins.entry = hexDouble(f.calibration.thresholds.entry); }, null, compiled],
    ['eligible and its pin', f => { f.calibration.eligible[1] = [1, 7]; f.pins.eligible = '1,7|9,11,12,14,15|17,19,20,22,23'; }, null, compiled],
    ['active and its pin', f => { f.calibration.coordinates[27].active = false; f.pins.active = f.calibration.coordinates.map(c => (c.active ? '1' : '0')).join(''); }, null, bundle],
    ['thresholds.rank', f => { f.calibration.thresholds.rank = 900; }, null, bundle],
    ['calibration.n', f => { f.calibration.n = 1500; }, null, bundle],
    ['a calibration mean', f => { f.calibration.coordinates[2].mean += 0.5; }, null, bundle],
    ['frozenState.t', f => { f.frozenState.t += 300; }, null, bundle],
    ['one 2024 row digest', f => { const r = f.rowDigests2024.rows; f.rowDigests2024.rows = r.slice(0, 40) + (r[40] === '0' ? '1' : '0') + r.slice(41); }, null, bundle],
    ['SpringSignals score negated', f => f, s => s.replace('local score = (bankScores[1] + bankScores[2] + bankScores[3]) / 3',
      'local score = -(bankScores[1] + bankScores[2] + bankScores[3]) / 3'), /fixture self-check failed/],
  ];
  const outcomes = {};
  for (const [name, edit, signals, expected] of cases) {
    const dir = join(work, 'tamper-' + name.replace(/\W+/g, '-'));
    mkdirSync(join(dir, 'src'), {recursive: true});
    for (const m of MODULES) if (m !== 'SpringFrozenV1') copyFileSync(join(SRC, m + '.luau'), join(dir, 'src', m + '.luau'));
    const frozen = structuredClone(built.frozen);
    edit(frozen);
    writeFileSync(join(dir, 'src', 'SpringFrozenV1.luau'), renderSpringFrozen(frozen), {flag: 'wx'});
    if (signals) {
      const original = readFileSync(join(SRC, 'SpringSignals.luau'), 'utf8');
      const drifted = signals(original);
      assert.notEqual(drifted, original, 'the drift was applied');
      writeFileSync(join(dir, 'src', 'SpringSignals.luau'), drifted);
    }
    writeFileSync(join(dir, 'probe.luau'), PROBE, {flag: 'wx'});
    const run = spawnSync(LUAU_PATH, ['probe.luau'], {cwd: dir, encoding: 'utf8', timeout: 120000});
    const line = (run.stdout.match(/^@@RESULT (.*)$/m) || [])[1] ?? `no result: ${run.stdout}${run.stderr}`;
    outcomes[name] = line;
    assert.match(line.replace(/^REFUSED /, ''), expected, `${name}: ${line}`);
    if (name !== 'shipped') assert.match(line, /^REFUSED SpringLiveSession: /, name);
  }
  console.log('tampered bundles:', JSON.stringify(outcomes, null, 1));
});

test('pin failures: SpringLiveSession.new refuses tampered frozen inputs, a different rig config and drive order', async () => {
  const {result: cases} = await luau('pins');
  const byName = Object.fromEntries(cases.map(c => [c.name, c]));
  assert.equal(byName.accepted.ok, true, byName.accepted.err);
  const expected = {
    unfrozen: /deep-frozen/, entry: /hex pin mismatch for entry/, exit: /hex pin mismatch for exit/,
    bankDeadband: /hex pin mismatch for bankDeadband/, baseEntry: /hex pin mismatch for baseEntry/,
    frozenState: /hex pin mismatch for frozenState/, calibrationStd: /hex pin mismatch for calibrationStd/,
    pinEdited: /differs from the shipped SpringFrozenV1 pin/, resultSha: /not the pinned 2024 result/,
    descriptor: /describe\(\) differs from the frozen 2024 descriptor/, nodeDamping: /engineConfig\.nodes\.7\.c/,
    edgeStiffness: /engineConfig\.edges\.3\.k/, projection: /engine config differs/, driveNames: /describe rejected/,
  };
  for (const [name, pattern] of Object.entries(expected)) {
    assert.equal(byName[name].ok, false, `${name} must be refused`);
    assert.match(byName[name].err, pattern, `${name}: ${byName[name].err}`);
  }
  assert.equal(cases.length, Object.keys(expected).length + 1);
});
