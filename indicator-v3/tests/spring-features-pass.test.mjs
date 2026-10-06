// SpringFeaturesPass (spring-live-contract.md section 1b, L15) against the verified 2024 capture.
//   node --test tests/spring-features-pass.test.mjs     (cwd anywhere; reads indicator-v2 read-only; temp files in os.tmpdir())
// Studio is never involved. The test
//   1. runs tests/SpringFeaturesPass.spec.luau (the fake-Features spec) and pins its test count;
//   2. extracts the CAPTURE-TIME Features and Regime sources from the saved _source.json and verifies their sha256
//      against the file's own record, the run manifest's sourceHashes and the pins below;
//   3. builds the 2024 dataset with the unchanged v2 bridge loadDataset, writes it as Luau data modules in a temp
//      directory next to those two sources and a byte copy of src/SpringFeaturesPass.luau, and runs the pass in luau.exe
//      (no --codegen) in pages of 512 bars;
//   4. requires ALL 2,268 t, drive[8], volatility, regime[3], ready and reset values to equal the saved capture values
//      (feature.* in the five _states_000N.json files, whose own sha256 are checked against the manifest receipts)
//      BIT FOR BIT, compared as hex of the IEEE double, and the pass digest to equal a digest an independent Node
//      implementation builds from the SAVED values;
//   5. shows the comparison can fail: a flipped last bit or sign of zero in the saved values, a changed Features
//      source and a lossy pass module are each caught.
// Nothing is written under indicator-v3 or indicator-v2.
import test, {after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync} from 'node:fs';
import {join, dirname, resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const V3 = resolve(here, '..');
const V2 = resolve(V3, '../indicator-v2');
const LUAU = (process.env.LUAU_EXE||'luau');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const hexD = v => { const b = Buffer.allocUnsafe(8); b.writeDoubleLE(v); return b.toString('hex'); };

// Pinned identities (measured 2026-10-05; the first four are the same pins tests/spring-v2-copies.test.mjs uses).
const RUN = 'RoAlgoV2_SPY_1791205420530';
const SOURCE_JSON = join(V2, 'results', `${RUN}_source.json`);
const SOURCE_JSON_SHA = 'ecbee1e2e639acd7e9b51d0b81a0d9541e24cc1ec23fdc4e033a2860a16dee58';
const MANIFEST = join(V2, 'results', `${RUN}.json`);
const MANIFEST_SHA = 'bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828';
const CAPTURE = {
  'src/Features': 'c1ac95b23491d9fb76cc574e72a556d9c2ad621d934fa90ee798256c8e066c76',
  'src/Regime': '5b8ac36eac95fb2e9f7c100c89202bbe9267f24ff0787fafbdf8bbe35bdb0d4f',
};
const DATA_HASH = '789e6e64453e3c019e365b17604800e2f7750b04de85cfa827cef7beccec49d4';
const QUERY = {symbol: 'SPY', train: 20, validation: 5, test: 5, end: '2024-12-31'}; // the 2024 capture's query
const RECORDS = 2268;
const PAGE = 512;
const SPEC_TESTS = 22; // the number of tests tests/SpringFeaturesPass.spec.luau prints; update with the spec
const PASS_SRC = join(V3, 'src/SpringFeaturesPass.luau');

const workRoot = mkdtempSync(join(tmpdir(), 'roalgo-features-pass-'));
after(() => rmSync(workRoot, {recursive: true, force: true}));

// ---------------------------------------------------------------------------------------------------------------------
function runLuau(script, args = []) {
  const started = process.hrtime.bigint();
  const child = spawnSync(LUAU, [script, ...(args.length ? ['-a', ...args] : [])], {
    encoding: 'utf8', windowsHide: true, maxBuffer: 512 * 1024 * 1024, timeout: 10 * 60 * 1000});
  assert.ifError(child.error);
  return {status: child.status, stdout: child.stdout, stderr: child.stderr, wallSeconds: Number(process.hrtime.bigint() - started) / 1e9};
}

// Luau literal for the dataset (numbers by JS shortest round-trip text, which Luau parses back to the same double).
function luaLiteral(v) {
  if (v === null || v === undefined) return 'nil';
  if (typeof v === 'number') {
    assert.ok(Number.isFinite(v), 'dataset numbers are finite');
    return Object.is(v, -0) ? '-0' : String(v);
  }
  if (typeof v === 'string') { assert.match(v, /^[ -~]*$/); assert.ok(!v.includes('\\')); return JSON.stringify(v); }
  if (typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) return '{' + v.map(luaLiteral).join(',') + '}';
  return '{' + Object.entries(v).map(([k, x]) => '[' + JSON.stringify(k) + ']=' + luaLiteral(x)).join(',') + '}';
}

// One line per bar, the same text from either side: i|t|drive x8|volatility|regime x3|ready|reset (doubles as IEEE hex).
const rowText = (i, t, drive, volatility, regime, ready, reset) =>
  [i, hexD(t), drive.map(hexD).join(','), hexD(volatility), regime.map(hexD).join(','), ready ? 1 : 0, reset ? 1 : 0].join('|');
const FIELDS = ['t', 'drive', 'volatility', 'regime', 'ready', 'reset'];

// Compares two lists of row lines field by field. Returns counts (never throws) so a test can assert on them.
function compareRows(actual, expected) {
  const result = {rows: expected.length, actualRows: actual.length, mismatchedRows: 0, fields: Object.fromEntries(FIELDS.map(f => [f, 0])), values: 0, zeroSignOnly: 0, first: null};
  for (let i = 0; i < Math.max(actual.length, expected.length); i++) {
    const a = (actual[i] ?? '').split('|'), e = (expected[i] ?? '').split('|');
    let bad = false;
    FIELDS.forEach((field, k) => {
      if (a[k + 1] === e[k + 1]) return;
      bad = true; result.fields[field]++;
      const av = (a[k + 1] ?? '').split(','), ev = (e[k + 1] ?? '').split(',');
      for (let j = 0; j < Math.max(av.length, ev.length); j++) {
        if (av[j] === ev[j]) continue;
        result.values++;
        const zeros = ['0000000000000000', '0000000000000080']; // +0 and -0 as little-endian hex
        if (zeros.includes(av[j]) && zeros.includes(ev[j])) result.zeroSignOnly++;
        result.first ??= {row: i + 1, field, actual: av[j], expected: ev[j]};
      }
    });
    if (bad) result.mismatchedRows++;
  }
  return result;
}

// The canonical digest stream of SpringFeaturesPass (see its header), rebuilt from the saved values in Node.
function nodeDigest(rows) {
  const R = rows.length ? rows[0].regime.length : 0;
  const parts = [];
  const head = Buffer.alloc(12);
  head.write('SFP1', 0, 'latin1'); head.writeUInt32LE(rows.length, 4); head.writeUInt16LE(8, 8); head.writeUInt16LE(R, 10);
  parts.push(head);
  for (const r of rows) {
    const b = Buffer.alloc((1 + 8 + 1 + R) * 8 + 1);
    let o = 0;
    const w = v => { b.writeDoubleLE(v, o); o += 8; };
    w(r.t); r.drive.forEach(w); w(r.volatility); r.regime.forEach(w);
    b.writeUInt8((r.ready ? 1 : 0) + (r.reset ? 2 : 0), o);
    parts.push(b);
  }
  return `sfp1-hex:${rows.length}:${sha(Buffer.concat(parts))}`;
}

// ---------------------------------------------------------------------------------------------------------------------
// The Luau runner. Mode "full": Features alone (baseline), the pass in pages of 512, the pass bar by bar. Mode "pages":
// only the pass in pages (used by the negative controls).
const RUNNER = `
local mode = ...
local Features = require("./Features")
local Pass = require("./SpringFeaturesPass")
local data = require("./data2024")
local bars = data.bars
local clock = os.clock
local function hex(v)
	return (string.gsub(string.pack("<d", v), ".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function hexes(list) local out = {} for j, v in list do out[j] = hex(v) end return table.concat(out, ",") end
local function rowLine(i, r)
	return table.concat({ i, hex(r.t), hexes(r.drive), hex(r.volatility), hexes(r.regime or {}), r.ready and 1 or 0, r.reset and 1 or 0 }, "|")
end
local function newFeatures() return Features.new(data.prehistory, { symbol = "SPY" }) end
local function meta(key, value) print("@@META " .. key .. "=" .. tostring(value)) end

meta("bars", #bars)
if mode == "full" then
	local f = newFeatures()
	local t0 = clock()
	for _, bar in bars do f:step(bar) end
	meta("seconds_features_alone", string.format("%.4f", clock() - t0))
end

local yields, progress = {}, {}
local pass = Pass.new({
	features = newFeatures(), yieldEvery = 512,
	yield = function(count) table.insert(yields, count) end,
	onProgress = function(count) table.insert(progress, count) end,
})
local t0 = clock()
pass:pushPage(table.move(bars, 1, ${PAGE}, 1, {})) -- the first step fits the HMM; memory per bar is measured after the first page
local tFirst = clock() - t0
collectgarbage(); collectgarbage()
local mem1 = collectgarbage("count")
local t1 = clock()
for first = ${PAGE} + 1, #bars, ${PAGE} do
	pass:pushPage(table.move(bars, first, math.min(first + ${PAGE} - 1, #bars), 1, {}))
end
local seconds = tFirst + (clock() - t1)
collectgarbage(); collectgarbage()
meta("seconds_pass_pages", string.format("%.4f", seconds))
meta("kb_per_bar", string.format("%.4f", (collectgarbage("count") - mem1) / (#bars - ${PAGE})))
meta("count", pass:count())
meta("yields", table.concat(yields, ","))
meta("progress", table.concat(progress, ","))
local stats = pass:stats()
meta("callback_errors", stats.callbackErrors)
meta("failure", tostring(stats.failure))
meta("regime_size", stats.regimeSize)
local d0 = clock()
local digest = pass:digest()
meta("seconds_digest", string.format("%.4f", clock() - d0))
meta("digest", digest)

if mode == "full" then
	local single = Pass.new({ features = newFeatures(), yield = false })
	local t1 = clock()
	for _, bar in bars do single:push(bar) end
	meta("seconds_pass_single_push", string.format("%.4f", clock() - t1))
	local same = single:count() == pass:count() and single:digest() == digest
	for i = 1, pass:count() do
		if rowLine(i, single:get(i)) ~= rowLine(i, pass:get(i)) then same = false break end
	end
	meta("push_equals_pages", same)
end
for i = 1, pass:count() do print("ROW|" .. rowLine(i, pass:get(i))) end
`;

function makeDir(name, {features, regime, pass, data}) {
  const dir = join(workRoot, name);
  mkdirSync(dir);
  writeFileSync(join(dir, 'Features.luau'), features);
  writeFileSync(join(dir, 'Regime.luau'), regime);
  writeFileSync(join(dir, 'SpringFeaturesPass.luau'), pass);
  writeFileSync(join(dir, 'data2024.luau'), data);
  writeFileSync(join(dir, 'runner.luau'), RUNNER);
  return dir;
}
function parseOutput(run) {
  const meta = {}, rows = [];
  for (const line of run.stdout.split(/\r?\n/)) {
    if (line.startsWith('@@META ')) { const i = line.indexOf('='); meta[line.slice(7, i)] = line.slice(i + 1); }
    else if (line.startsWith('ROW|')) rows.push(line.slice(4));
  }
  return {meta, rows};
}

// ---------------------------------------------------------------------------------------------------------------------
// Everything below is built once, lazily, and shared by the tests.
let memo;
async function real() {
  if (memo) return memo;
  memo = (async () => {
    // capture-time sources, verified
    const sourceBytes = readFileSync(SOURCE_JSON);
    assert.equal(sha(sourceBytes), SOURCE_JSON_SHA, '_source.json is the pinned capture source');
    const files = Object.fromEntries(JSON.parse(sourceBytes.toString('utf8')).files.map(f => [f.path, f]));
    const manifestBytes = readFileSync(MANIFEST);
    assert.equal(sha(manifestBytes), MANIFEST_SHA, 'the run manifest is the pinned one');
    const manifest = JSON.parse(manifestBytes.toString('utf8'));
    const sources = {};
    for (const path of Object.keys(CAPTURE)) {
      const text = files[path].source;
      const measured = sha(Buffer.from(text, 'utf8'));
      assert.equal(measured, files[path].sha256, `${path}: source matches the hash recorded beside it`);
      assert.equal(measured, manifest.sourceHashes[path], `${path}: matches manifest.sourceHashes`);
      assert.equal(measured, CAPTURE[path], `${path}: matches the pin`);
      sources[path] = text;
    }
    // the 2024 dataset, built by the unchanged v2 loader
    const {loadDataset} = await import(pathToFileURL(join(V2, 'bridge.mjs')).href);
    const dataset = loadDataset({...QUERY});
    assert.equal(dataset.metadata.dataHash, DATA_HASH, 'the dataset hash reproduces');
    assert.equal(dataset.metadata.dataHash, manifest.metadata.dataHash, 'and equals the capture manifest dataHash');
    assert.equal(dataset.bars.length, RECORDS);
    const dataModule = 'return ' + luaLiteral({bars: dataset.bars, prehistory: dataset.prehistory});
    // the saved capture values, from the states files whose hashes the manifest recorded
    const saved = [];
    manifest.cacheChunks.forEach((chunk, k) => {
      const name = `${RUN}_states_${String(k + 1).padStart(4, '0')}.json`;
      const bytes = readFileSync(join(V2, 'results', name));
      assert.equal(sha(bytes), chunk.sha256, `${name} matches the manifest receipt`);
      const states = JSON.parse(bytes.toString('utf8'));
      assert.equal(states.firstIndex, saved.length + 1, `${name} starts where the previous chunk ended`);
      for (const record of states.records) saved.push(record);
      assert.equal(states.lastIndex, saved.length);
    });
    assert.equal(saved.length, RECORDS);
    const expected = saved.map((r, i) => {
      assert.equal(r.feature.t, r.bar.t, `record ${i + 1}: feature.t is the bar's t`);
      assert.equal(r.bar.t, dataset.bars[i].t, `record ${i + 1}: the rebuilt bar is the captured bar`);
      return {t: r.bar.t, drive: r.feature.drive, volatility: r.feature.volatility, regime: r.feature.regime, ready: r.feature.ready, reset: r.feature.reset};
    });
    const expectedLines = expected.map((r, i) => rowText(i + 1, r.t, r.drive, r.volatility, r.regime, r.ready, r.reset));
    // the real run
    const passSource = readFileSync(PASS_SRC, 'utf8');
    const dir = makeDir('real', {features: sources['src/Features'], regime: sources['src/Regime'], pass: passSource, data: dataModule});
    assert.equal(sha(readFileSync(join(dir, 'SpringFeaturesPass.luau'))), sha(readFileSync(PASS_SRC)), 'the temp copy is a byte copy of src/SpringFeaturesPass.luau');
    const run = runLuau(join(dir, 'runner.luau'), ['full']);
    return {sources, passSource, dataModule, dataset, expected, expectedLines, run, ...parseOutput(run), dir};
  })();
  return memo;
}

// ---------------------------------------------------------------------------------------------------------------------
test('the Luau spec passes with the pinned test count', () => {
  const run = runLuau(join(here, 'SpringFeaturesPass.spec.luau'));
  assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}`);
  assert.ok(!/FAIL/.test(run.stdout + run.stderr));
  assert.equal((run.stdout.match(/^PASS /gm) ?? []).length, SPEC_TESTS);
  assert.match(run.stdout, new RegExp(`^SpringFeaturesPass: ${SPEC_TESTS} tests passed$`, 'm'));
  console.log(run.stdout.trim().split('\n').pop(), `(${run.wallSeconds.toFixed(2)} s)`);
});

test('the module requires nothing, so it cannot bind to the wrong Features, and has no physics or Engine access', () => {
  const bytes = readFileSync(PASS_SRC);
  assert.ok(!bytes.includes(13), 'LF line endings only');
  const code = bytes.toString('utf8').replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '').replace(/--[^\n]*/g, '');
  assert.ok(!/\brequire\b/.test(code) && !/script\.Parent/.test(code), 'no require of any sibling');
  for (const word of ['StepPhysics', 'Engine', 'VerifiedStepper', 'GetService', 'HttpService', 'workspace', 'game', 'Instance']) {
    assert.ok(!new RegExp(`\\b${word}\\b`).test(code), `no ${word} in code`);
  }
  assert.ok(/\bDRIVE_SIZE = 8\b/.test(code), 'the drive width is fixed at 8');
});

test('capture-time Features and Regime sources verify against the manifest', async () => {
  const r = await real();
  for (const path of Object.keys(CAPTURE)) assert.equal(sha(Buffer.from(r.sources[path], 'utf8')), CAPTURE[path]);
  // a different Features (the v3, 12-drive one) is not the capture one: its hash cannot satisfy the pin
  const v3Features = readFileSync(join(V3, 'src/Features.luau'));
  assert.notEqual(sha(v3Features), CAPTURE['src/Features'], 'v3 Features is a different file from the capture-time one');
});

test('real data: all 2,268 bars match the saved capture bit for bit, as hex', async () => {
  const r = await real();
  assert.equal(r.run.status, 0, `${r.run.stdout.slice(-2000)}\n${r.run.stderr}`);
  assert.equal(r.meta.failure, 'nil', 'the pass did not fail');
  assert.equal(r.meta.count, String(RECORDS));
  assert.equal(r.rows.length, RECORDS);
  assert.equal(r.meta.regime_size, '3');
  const cmp = compareRows(r.rows, r.expectedLines);
  console.log('compared', cmp.rows, 'rows x (t, drive[8], volatility, regime[3], ready, reset) =', cmp.rows * 14, 'values; mismatched rows', cmp.mismatchedRows, JSON.stringify(cmp.fields));
  assert.deepEqual(cmp, {rows: RECORDS, actualRows: RECORDS, mismatchedRows: 0, fields: Object.fromEntries(FIELDS.map(f => [f, 0])), values: 0, zeroSignOnly: 0, first: null},
    `first difference: ${JSON.stringify(cmp.first)}`);
  // the comparison is not vacuous: the values vary and the flags both occur
  const flags = r.expected.reduce((a, x) => { a.ready += x.ready ? 1 : 0; a.reset += x.reset ? 1 : 0; return a; }, {ready: 0, reset: 0});
  assert.deepEqual(flags, {ready: RECORDS - 11, reset: 1}, 'ready after 12 observations, one reset (record 1)');
  assert.ok(new Set(r.expected.map(x => x.drive[0])).size > 2000 && new Set(r.expected.map(x => x.volatility)).size > 2000);
});

test('real data: the digest equals one built independently from the saved values', async () => {
  const r = await real();
  const fromSaved = nodeDigest(r.expected);
  assert.equal(r.meta.digest, fromSaved);
  assert.match(r.meta.digest, /^sfp1-hex:2268:[0-9a-f]{64}$/);
  console.log('digest', r.meta.digest);
});

test('real data: pages of 512, yields and progress at the 512 cadence, and bar by bar gives the same pass', async () => {
  const r = await real();
  assert.equal(r.meta.yields, '512,1024,1536,2048', 'yield after bars 512, 1024, 1536, 2048 (the 220-bar last page adds none)');
  assert.equal(r.meta.progress, r.meta.yields);
  assert.equal(r.meta.callback_errors, '0');
  assert.equal(r.meta.push_equals_pages, 'true', 'push() one bar at a time stores exactly what pushPage() stores');
});

test('real data: timing and memory (measured, luau.exe 0.741 without --codegen)', async () => {
  const r = await real();
  const s = k => Number(r.meta[k]);
  const line = {
    features_alone_s: s('seconds_features_alone'), pass_pages_s: s('seconds_pass_pages'), pass_single_push_s: s('seconds_pass_single_push'),
    digest_s: s('seconds_digest'), kb_per_bar: s('kb_per_bar'), wall_s: Number(r.run.wallSeconds.toFixed(2)),
  };
  console.log('timing', JSON.stringify(line));
  console.log(`pass: ${(s('seconds_pass_pages') / RECORDS * 1e6).toFixed(1)} us per bar including the one-time HMM fit (Features alone ${(s('seconds_features_alone') / RECORDS * 1e6).toFixed(1)} us); the full 36,402-bar window is measured by the opt-in test below`);
  for (const [k, v] of Object.entries(line)) assert.ok(Number.isFinite(v) && v >= 0, k);
  // The pass is a thin wrapper around Features: it must stay within a small multiple of Features itself.
  assert.ok(s('seconds_pass_pages') < 3 * s('seconds_features_alone') + 0.5, 'pass overhead over Features is bounded');
  assert.ok(line.kb_per_bar < 0.8, `flat storage (14 numbers per bar, 16 bytes each, plus array slack): ${line.kb_per_bar} KB per bar`);
});

// ---------------------------------------------------------------------------------------------------------------------
// Negative controls: the comparison above can fail, and fails for the right reasons.
test('negative control: one flipped last bit, or one sign of zero, in the saved values is caught', async () => {
  const r = await real();
  const flipBit = line => { // flip the lowest bit of drive[3] in an expected row
    const f = line.split('|'), d = f[2].split(',');
    const b = Buffer.from(d[2], 'hex'); b[0] ^= 1; d[2] = b.toString('hex'); f[2] = d.join(','); return f.join('|');
  };
  const tampered = r.expectedLines.slice();
  tampered[1000] = flipBit(tampered[1000]);
  let cmp = compareRows(r.rows, tampered);
  assert.equal(cmp.mismatchedRows, 1); assert.equal(cmp.fields.drive, 1); assert.equal(cmp.values, 1);
  assert.equal(cmp.first.row, 1001); assert.equal(cmp.first.field, 'drive'); assert.equal(cmp.zeroSignOnly, 0);
  // sign of zero: record 1's drive[4] is +0 in the capture; claim it is -0
  const zeroLine = r.expected[0].drive[3];
  assert.ok(Object.is(zeroLine, 0), 'the first record has a +0 drive value to flip');
  const flipZero = r.expectedLines.slice();
  const f = flipZero[0].split('|'), d = f[2].split(','); d[3] = '0000000000000080'; f[2] = d.join(','); flipZero[0] = f.join('|');
  cmp = compareRows(r.rows, flipZero);
  assert.equal(cmp.mismatchedRows, 1); assert.equal(cmp.zeroSignOnly, 1);
  // a missing and an extra row
  assert.ok(compareRows(r.rows.slice(0, -1), r.expectedLines).actualRows === RECORDS - 1 && compareRows(r.rows.slice(0, -1), r.expectedLines).mismatchedRows === 1);
});

test('negative control: a Features source changed in one constant is not the capture one, and the run shows it', async () => {
  const r = await real();
  const original = r.sources['src/Features'];
  const needle = 'options.alpha or 0.05,';
  assert.equal(original.split(needle).length, 2, 'the constant occurs exactly once');
  const changed = original.replace(needle, 'options.alpha or 0.0500001,');
  assert.notEqual(sha(Buffer.from(changed, 'utf8')), CAPTURE['src/Features'], 'the hash gate rejects the changed source');
  const dir = makeDir('control-features', {features: changed, regime: r.sources['src/Regime'], pass: r.passSource, data: r.dataModule});
  const run = runLuau(join(dir, 'runner.luau'), ['pages']);
  assert.equal(run.status, 0, run.stderr);
  const out = parseOutput(run);
  assert.equal(out.rows.length, RECORDS);
  const cmp = compareRows(out.rows, r.expectedLines);
  console.log('changed Features: mismatched rows', cmp.mismatchedRows, 'of', cmp.rows, JSON.stringify(cmp.fields));
  assert.ok(cmp.mismatchedRows > 2000 && cmp.fields.drive > 2000 && cmp.fields.volatility > 2000, 'drive and volatility differ almost everywhere');
  assert.notEqual(out.meta.digest, r.meta.digest, 'and the digest differs');
});

test('negative control: a lossy pass module (drives rounded to float32) is caught', async () => {
  const r = await real();
  const needle = 'for j = 1, DRIVE do drive[base + j] = source[j] end';
  assert.equal(r.passSource.split(needle).length, 2);
  const lossy = r.passSource.replace(needle, 'for j = 1, DRIVE do drive[base + j] = string.unpack("<f", string.pack("<f", source[j])) end');
  const dir = makeDir('control-pass', {features: r.sources['src/Features'], regime: r.sources['src/Regime'], pass: lossy, data: r.dataModule});
  const run = runLuau(join(dir, 'runner.luau'), ['pages']);
  assert.equal(run.status, 0, run.stderr);
  const out = parseOutput(run);
  const cmp = compareRows(out.rows, r.expectedLines);
  console.log('lossy pass: mismatched rows', cmp.mismatchedRows, 'of', cmp.rows, JSON.stringify(cmp.fields));
  assert.ok(cmp.fields.drive > 2000, 'drives differ');
  assert.equal(cmp.fields.t + cmp.fields.volatility + cmp.fields.regime + cmp.fields.ready + cmp.fields.reset, 0, 'and only drives');
  assert.notEqual(out.meta.digest, r.meta.digest);
});

// ---------------------------------------------------------------------------------------------------------------------
// Opt-in: the whole live window (contract L1: 36,402 bars, 2024-11-18 to 2026-10-02) through the pass in luau.exe.
//   SPRING_FEATURES_FULL=1 node --test tests/spring-features-pass.test.mjs
// It writes about 65 MB of Luau data into the temp directory and takes about half a minute.
const LIVE_QUERY = {symbol: 'SPY', train: 20, validation: 5, test: 444, end: '2026-10-02'};
const LIVE_DATA_HASH = 'b8a3ce225720691e172ab8216b85bcdff634fb1172ced5325db6d5d4fbb41a26';
const LIVE_BARS = 36402;
const LIVE_DIGEST = 'sfp1-hex:36402:8b1dffdb7cf50c5280e454969d511fd377b775edb1da9b34b78ce4e2a764c787';
const FULL_RUNNER = `
local Features = require("./Features")
local Pass = require("./SpringFeaturesPass")
local clock = os.clock
local bars = require("./index")
local prehistory = require("./prehistory")
local function hex(v)
	return (string.gsub(string.pack("<d", v), ".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function hexes(list) local out = {} for j, v in list do out[j] = hex(v) end return table.concat(out, ",") end
local function rowLine(i, r)
	return table.concat({ i, hex(r.t), hexes(r.drive), hex(r.volatility), hexes(r.regime or {}), r.ready and 1 or 0, r.reset and 1 or 0 }, "|")
end
local function meta(key, value) print("@@META " .. key .. "=" .. tostring(value)) end
local function newFeatures() return Features.new(prehistory, { symbol = "SPY" }) end
meta("bars", #bars)
local f = newFeatures()
local a = clock()
for _, bar in bars do f:step(bar) end
meta("seconds_features_alone", string.format("%.4f", clock() - a))
f = nil
local yields = 0
local pass = Pass.new({ features = newFeatures(), yieldEvery = 512, yield = function() yields += 1 end })
collectgarbage(); collectgarbage()
local mem0 = collectgarbage("count")
a = clock()
for first = 1, #bars, ${PAGE} do pass:pushPage(table.move(bars, first, math.min(first + ${PAGE} - 1, #bars), 1, {})) end
meta("seconds_pass_pages", string.format("%.4f", clock() - a))
collectgarbage(); collectgarbage()
meta("mb_pass", string.format("%.3f", (collectgarbage("count") - mem0) / 1024))
meta("count", pass:count())
meta("yields", yields)
meta("failure", tostring(pass:failure()))
local resets, notReady = 0, 0
for i = 1, pass:count() do
	local r = pass:get(i)
	if r.reset then resets += 1 end
	if not r.ready then notReady += 1 end
end
meta("resets", resets)
meta("not_ready", notReady)
a = clock()
local digest = pass:digest()
meta("seconds_digest", string.format("%.4f", clock() - a))
meta("digest", digest)
local single = Pass.new({ features = newFeatures(), yield = false })
for _, bar in bars do single:push(bar) end
meta("push_equals_pages", single:digest() == digest)
for i = 1, ${RECORDS} do print("ROW|" .. rowLine(i, pass:get(i))) end
`;
test('opt-in: the full 36,402-bar live window through the pass; rows 1-2268 equal the saved 2024 capture bit for bit',
  {skip: process.env.SPRING_FEATURES_FULL === '1' ? false : 'set SPRING_FEATURES_FULL=1 to run (about 65 MB of temp Luau data, about 30 s)'},
  async () => {
    const r = await real();
    const {loadDataset} = await import(pathToFileURL(join(V2, 'bridge.mjs')).href);
    const live = loadDataset({...LIVE_QUERY});
    assert.equal(live.metadata.dataHash, LIVE_DATA_HASH, 'the live dataset hash is the one the live contract pins');
    assert.equal(live.bars.length, LIVE_BARS);
    assert.deepEqual(live.bars.slice(0, RECORDS), r.dataset.bars, 'the first 2,268 live bars are the capture bars');
    const dir = join(workRoot, 'full');
    mkdirSync(dir);
    const CH = 4096;
    let chunks = 0;
    for (let i = 0; i < live.bars.length; i += CH, chunks++) writeFileSync(join(dir, `bars${chunks}.luau`), 'return ' + luaLiteral(live.bars.slice(i, i + CH)));
    writeFileSync(join(dir, 'prehistory.luau'), 'return ' + luaLiteral(live.prehistory));
    writeFileSync(join(dir, 'index.luau'), `local out = {}\nfor k = 0, ${chunks - 1} do for _, b in require("./bars" .. k) do out[#out + 1] = b end end\nreturn out\n`);
    writeFileSync(join(dir, 'Features.luau'), r.sources['src/Features']);
    writeFileSync(join(dir, 'Regime.luau'), r.sources['src/Regime']);
    writeFileSync(join(dir, 'SpringFeaturesPass.luau'), r.passSource);
    writeFileSync(join(dir, 'runner.luau'), FULL_RUNNER);
    const run = runLuau(join(dir, 'runner.luau'));
    assert.equal(run.status, 0, `${run.stdout.slice(-1500)}\n${run.stderr}`);
    const out = parseOutput(run);
    const m = out.meta;
    assert.equal(m.bars, String(LIVE_BARS)); assert.equal(m.count, String(LIVE_BARS)); assert.equal(m.failure, 'nil');
    assert.equal(m.yields, String(Math.floor(LIVE_BARS / 512)), 'one yield per 512 bars');
    assert.equal(m.resets, '1', 'one reset, at the first bar'); assert.equal(m.not_ready, '11', '11 not-ready bars (ready after 12 observations)');
    assert.equal(m.push_equals_pages, 'true');
    assert.equal(m.digest, LIVE_DIGEST, 'the digest of all 36,402 bars is the recorded receipt');
    assert.equal(out.rows.length, RECORDS);
    const cmp = compareRows(out.rows, r.expectedLines);
    assert.equal(cmp.mismatchedRows, 0, `rows 1-2268 of the live run differ from the saved capture: ${JSON.stringify(cmp.first)}`);
    console.log('full window', JSON.stringify({bars: LIVE_BARS, features_alone_s: Number(m.seconds_features_alone), pass_pages_s: Number(m.seconds_pass_pages), digest_s: Number(m.seconds_digest), mb_pass: Number(m.mb_pass), yields: Number(m.yields), wall_s: Number(run.wallSeconds.toFixed(1))}));
    console.log('digest', m.digest);
  });
