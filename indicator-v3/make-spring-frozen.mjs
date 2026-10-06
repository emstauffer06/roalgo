// Generates src/SpringFrozenV1.luau, the frozen 2024 inputs of the live forward test (spring-live-contract.md W3,
// decisions L5/L12). Read-only over its inputs: the sha-pinned 2024 spring result and the pinned v2 capture.
//   calibration, baselineCalibration, descriptor  <- results/RoAlgoV3_spring_v1_1791220038839.json (sha256 3fdcd3b5...)
//   nativeConfig2024                             <- manifest native.config (verified identical in all 5 checkpoints)
//   frozenState                                  <- checkpoint record 12, states.coupled.vector[1..48] at full precision
//                                                   (the stored result.frozenState is rounded to 6 digits; L5)
//   pins                                         <- string.pack("<d") little-endian lowercase hex of the exact doubles,
//                                                   plus the eligible node ids and the 48 active flags
//   rowDigests2024                               <- per-row FNV-1a digests (spring-row-digest-1) of the stored rows of
//                                                   all 7 runs, for the L20 lead-in decision-row gate
// bundleFnv32 (printed, not stored) is the FNV-1a of the whole bundle's pack encoding; SpringLiveSession compiles it in.
// The module is written with luauLiteral (round-trip decimals) and deep-frozen at load. The generator is
// deterministic, writes with flag 'wx', reports "unchanged" for an identical existing file and refuses to
// overwrite a different one. It never starts Studio, never steps physics and never edits its inputs.
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import {join, resolve, basename} from 'node:path';
import {fileURLToPath} from 'node:url';
import {verifySpringInputs, luauLiteral, sha256, stableStringify, ROOT, DEFAULT_MANIFEST, DEFAULT_PINS} from './spring-runner-lib.mjs';

export const FROZEN_SCHEMA = 'spring-frozen-v1';
export const PROTOCOL_ID = 'spring-consensus-v1';
export const RESULT_NAME = 'RoAlgoV3_spring_v1_1791220038839.json';
export const RESULT_SHA256 = '3fdcd3b57e0b9224117169c24a23ee8724efbfc968b7811f06a682f2bd0a5d6d';
export const DEFAULT_RESULT = join(ROOT, 'results', RESULT_NAME);
export const DEFAULT_OUT = join(ROOT, 'src', 'SpringFrozenV1.luau');
export const FROZEN_RECORD_INDEX = 12;
export const FROZEN_SAMPLE_ID = 'coupled:12';
const PHYSICAL_RUNS = ['coupled', 'zero', 'frozen', 'independent', 'numeric'];

export const hexDouble = x => {
  if (typeof x !== 'number') throw new Error(`hexDouble: number required, got ${typeof x}`);
  const b = Buffer.alloc(8);
  b.writeDoubleLE(x);
  return b.toString('hex');
};
export const hexDoubles = xs => {
  const b = Buffer.alloc(8 * xs.length);
  xs.forEach((x, i) => {
    if (typeof x !== 'number') throw new Error(`hexDoubles: number required at ${i + 1}`);
    b.writeDoubleLE(x, 8 * i);
  });
  return b.toString('hex');
};
// Luau r6: tonumber(string.format("%.6g", x)); 0 stays 0.
const r6 = x => (x === 0 ? 0 : Number(x.toPrecision(6)));

// ---------------------------------------------------------------------------------------------------------------
// spring-pack-1: a byte encoding of JSON-like values that SpringLiveSession.packValue reproduces byte for byte.
//   number  'n' + 8 bytes little-endian IEEE double ('N' for NaN); with signedZero=false, -0 is written as +0
//   string  's' + u32le byte length + UTF-8 bytes
//   boolean 't' | 'f'
//   array   'a' + u32le n + items     (non-empty array; in Luau a table whose keys are exactly 1..n, n > 0)
//   map     'm' + u32le key count + (string key, value) pairs in byte order of the keys (an empty array is an empty map)
// fnv1a32 is FNV-1a 32-bit (offset 2166136261, prime 16777619); hex32 is %08x of the result.
// ---------------------------------------------------------------------------------------------------------------
export const PACK_SCHEME = 'spring-pack-1';
export const ROW_DIGEST_SCHEME = 'spring-row-digest-1';
// The decision and ledger fields of a compact row (everything except the 6-digit diagnostics ok/rs/s/b/c/su/bl/st).
export const ACTION_FIELDS = ['ia', 'is', 'ir', 'fa', 'fs', 'fr', 'ov', 'rc', 'pe', 'po', 'hb', 'eq', 'sp', 'tg', 'ex'];
const u32le = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b; };
export function packValue(value, {signedZero = true} = {}, path = '$') {
  const parts = [];
  const walk = (v, p) => {
    switch (typeof v) {
      case 'number': {
        if (Number.isNaN(v)) { parts.push(Buffer.from('N')); return; }
        const b = Buffer.alloc(9);
        b.write('n', 0, 'latin1');
        b.writeDoubleLE(!signedZero && v === 0 ? 0 : v, 1);
        parts.push(b);
        return;
      }
      case 'string': { const s = Buffer.from(v, 'utf8'); parts.push(Buffer.from('s'), u32le(s.length), s); return; }
      case 'boolean': parts.push(Buffer.from(v ? 't' : 'f')); return;
      case 'object':
        if (v === null) throw new Error(`packValue: null at ${p}`);
        if (Array.isArray(v) && v.length > 0) {
          parts.push(Buffer.from('a'), u32le(v.length));
          for (let i = 0; i < v.length; i++) {
            if (!(i in v)) throw new Error(`packValue: sparse array at ${p}[${i}]`);
            walk(v[i], `${p}[${i}]`);
          }
          return;
        }
        {
          const keys = Array.isArray(v) ? [] : Object.keys(v).sort((a, b) => Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8')));
          parts.push(Buffer.from('m'), u32le(keys.length));
          for (const k of keys) {
            if (v[k] === undefined) throw new Error(`packValue: undefined at ${p}.${k}`);
            const s = Buffer.from(k, 'utf8');
            parts.push(Buffer.from('s'), u32le(s.length), s);
            walk(v[k], `${p}.${k}`);
          }
        }
        return;
      default: throw new Error(`packValue: unsupported ${typeof v} at ${p}`);
    }
  };
  walk(value, path);
  return Buffer.concat(parts);
}
export function fnv1a32(bytes, h = 2166136261) {
  for (let k = 0; k < bytes.length; k++) h = Math.imul(h ^ bytes[k], 16777619) >>> 0;
  return h >>> 0;
}
export const hex32 = h => (h >>> 0).toString(16).padStart(8, '0');
// One compact row: FNV-1a of its pack encoding (signed zero ignored, as JSON cannot keep it).
export const rowDigest = row => fnv1a32(packValue(row, {signedZero: false}));
export function actionDigest(row) {
  const picked = {};
  for (const key of ACTION_FIELDS) if (row[key] !== undefined) picked[key] = row[key];
  return fnv1a32(packValue(picked, {signedZero: false}));
}
// FNV-1a over the u32le bytes of a list of digests (rows of one run over a range, or the 7 runs of one row).
export const combineDigests = list => fnv1a32(Buffer.concat(list.map(u32le)));

// Per-row digests of the stored 2024 rows of all 7 runs (leadInRows=0 continuous ledgers), for the L20 lead-in gate.
export function buildRowDigests2024(result) {
  const runs = result.runs.map(r => r.id);
  const count = result.recordCount;
  for (const run of result.runs) if (run.fullHistory?.rows?.length !== count) fail(`run ${run.id} must hold ${count} rows`);
  const rd = result.runs.map(run => run.fullHistory.rows.map(rowDigest));
  const ad = result.runs.map(run => run.fullHistory.rows.map(actionDigest));
  let rows = '', actions = '';
  for (let i = 0; i < count; i++) {
    rows += hex32(combineDigests(rd.map(list => list[i])));
    actions += hex32(combineDigests(ad.map(list => list[i])));
  }
  const sessions = [];
  result.timeline.forEach((t, i) => {
    if (sessions.length === 0 || sessions.at(-1).day !== t.d) sessions.push({day: t.d, first: i + 1, last: i + 1});
    else sessions.at(-1).last = i + 1;
  });
  for (const s of sessions) {
    s.runs = {};
    runs.forEach((id, k) => { s.runs[id] = hex32(combineDigests(rd[k].slice(s.first - 1, s.last))); });
  }
  return {
    scheme: ROW_DIGEST_SCHEME, pack: PACK_SCHEME, runIds: runs, count, rows, actions, actionFields: ACTION_FIELDS, sessions,
    source: `results/${RESULT_NAME} runs[*].fullHistory.rows (continuous leadInRows=0 ledgers of all 7 runs)`,
  };
}
const sameJson = (a, b) => stableStringify(a) === stableStringify(b);

function fail(message) { throw new Error('make-spring-frozen: ' + message); }

export function buildSpringFrozen({resultPath = DEFAULT_RESULT, resultSha256 = RESULT_SHA256, manifestPath = DEFAULT_MANIFEST, verified} = {}) {
  const bytes = readFileSync(resultPath);
  const foundSha = sha256(bytes);
  if (foundSha !== resultSha256) fail(`result sha256 pin mismatch for ${basename(resultPath)}: pinned ${resultSha256}, found ${foundSha}`);
  const result = JSON.parse(bytes.toString('utf8'));
  if (result.schema !== 'roalgo-spring-indicator-v1') fail(`result schema ${result.schema}`);
  if (result.protocol?.id !== PROTOCOL_ID) fail(`result protocol ${result.protocol?.id}`);
  if (result.recordCount !== 2268) fail(`result recordCount ${result.recordCount} != 2268`);
  const cal = result.calibration, base = result.baselineCalibration;
  if (cal?.schema !== 'spring-calibration-v1' || cal.available !== true || cal.protocolId !== PROTOCOL_ID) fail('calibration missing or unavailable');
  if (cal.firstSampleId !== FROZEN_SAMPLE_ID) fail(`calibration.firstSampleId ${cal.firstSampleId} != ${FROZEN_SAMPLE_ID}`);
  if (!Array.isArray(cal.coordinates) || cal.coordinates.length !== 48) fail('calibration must hold 48 coordinates');
  if (base?.schema !== 'spring-ema-baseline-calibration-v1' || base.available !== true || base.coordinates?.length !== 3) fail('baseline calibration missing or unavailable');
  if (result.descriptor?.schema !== 'spring-v2-descriptor-1') fail('descriptor missing');
  for (const run of result.runs) {
    const expected = PHYSICAL_RUNS.includes(run.id) ? cal.thresholds : run.id === 'ema_baseline' ? base.thresholds : undefined;
    if (expected === undefined ? run.thresholds !== undefined : !sameJson(run.thresholds, expected)) fail(`run ${run.id} thresholds differ from its calibration`);
  }

  verified = verified ?? verifySpringInputs(manifestPath, {expectedRecords: 2268, expectedChunks: 5});
  const manifestSha = verified.inputHashes[0].sha256;
  if (manifestSha !== DEFAULT_PINS.manifestSha256) fail(`manifest sha256 ${manifestSha} is not the pinned capture`);
  if (result.provenance?.nativeConfigSha256 !== verified.nativeConfigSha256) fail('result provenance nativeConfigSha256 differs from the verified capture');
  if (result.provenance?.pins?.manifestSha256 !== manifestSha) fail('result provenance manifest pin differs from the verified capture');
  const record = verified.records[FROZEN_RECORD_INDEX - 1];
  if (record.bar.t !== result.timeline[FROZEN_RECORD_INDEX - 1].t) fail('record 12 timestamp differs from the result timeline');
  const vector = record.states.coupled.vector;
  const x = vector.slice(0, 24), v = vector.slice(24, 48);
  if (![...x, ...v].every(Number.isFinite)) fail('record 12 coupled x/v must be finite');
  const stored = result.frozenState;
  if (stored?.sampleId !== FROZEN_SAMPLE_ID || !x.every((value, i) => r6(value) === stored.x[i]) || !v.every((value, i) => r6(value) === stored.v[i]))
    fail('record 12 full-precision state does not round to the stored 6-digit frozenState');

  const t = cal.thresholds, bt = base.thresholds;
  const frozen = {
    schema: FROZEN_SCHEMA,
    protocolId: PROTOCOL_ID,
    resultName: RESULT_NAME,
    resultSha256: foundSha,
    calibration: cal,
    baselineCalibration: base,
    descriptor: result.descriptor,
    nativeConfig2024: verified.nativeConfig,
    frozenState: {sampleId: FROZEN_SAMPLE_ID, recordIndex: FROZEN_RECORD_INDEX, t: record.bar.t, x, v,
      source: 'v2 checkpoint record 12 states.coupled.vector[1..48], full precision (result.frozenState is its 6-digit display copy)'},
    pins: {
      entry: hexDouble(t.entry), exit: hexDouble(t.exit), bankDeadband: hexDouble(t.bankDeadband), unclamped: hexDouble(t.unclamped),
      baseEntry: hexDouble(bt.entry), baseExit: hexDouble(bt.exit), baseDeadband: hexDouble(bt.bankDeadband), baseUnclamped: hexDouble(bt.unclamped),
      frozenState: hexDoubles([...x, ...v]),
      calibrationStd: hexDoubles(cal.coordinates.map(c => c.std)),
      baselineStd: hexDoubles(base.coordinates.map(c => c.std)),
      // Which nodes vote and which coordinates are active (decision-determining, not doubles).
      eligible: cal.eligible.map(bank => bank.join(',')).join('|'),
      active: cal.coordinates.map(c => (c.active ? '1' : '0')).join(''),
    },
    rowDigests2024: buildRowDigests2024(result),
    canonicalSha256: {
      calibration: sha256(stableStringify(cal)), baselineCalibration: sha256(stableStringify(base)),
      descriptor: sha256(stableStringify(result.descriptor)), protocol: sha256(stableStringify(result.protocol)),
      nativeConfig: verified.nativeConfigSha256,
    },
    sources: {
      manifest: {name: basename(verified.inputHashes[0].path), sha256: manifestSha},
      checkpoints: verified.inputHashes.slice(1, 6).map(h => ({name: basename(h.path), sha256: h.sha256})),
      sourceJson: {name: basename(verified.inputHashes[6].path), sha256: verified.inputHashes[6].sha256},
      generator: 'make-spring-frozen.mjs',
    },
  };
  const text = renderSpringFrozen(frozen);
  // The whole bundle's FNV-1a over its exact pack encoding; SpringLiveSession compiles this value in (FROZEN_BUNDLE_FNV32)
  // so that an edited SpringFrozenV1 is refused even when its own pins were edited to match.
  const bundleFnv32 = hex32(fnv1a32(packValue(frozen)));
  return {text, sha256: sha256(text), bytes: Buffer.byteLength(text), frozen, resultSha256: foundSha, bundleFnv32};
}

// The module text for a frozen bundle (deterministic; also used by tests to render deliberately edited bundles).
export function renderSpringFrozen(frozen) {
  return [
    '-- SpringFrozenV1: frozen 2024 spring-consensus-v1 inputs for the live forward test (spring-live-contract.md W3, L5).',
    '-- GENERATED by make-spring-frozen.mjs. Do not edit; regenerate instead (the generator refuses to overwrite a different file).',
    `-- Source: results/${frozen.resultName} (sha256 ${frozen.resultSha256}),`,
    `-- capture manifest sha256 ${frozen.sources.manifest.sha256}; frozenState = checkpoint record 12 coupled x/v at full precision.`,
    '-- pins = string.pack("<d") little-endian lowercase hex of the exact doubles (multi-value pins concatenate them in order).',
    '-- rowDigests2024 = spring-row-digest-1 digests of the stored 2024 rows of all 7 runs (L20 lead-in decision-row gate).',
    'local function deepFreeze(t)',
    '\tfor _, v in t do',
    '\t\tif type(v) == "table" then deepFreeze(v) end',
    '\tend',
    '\tif not table.isfrozen(t) then table.freeze(t) end',
    '\treturn t',
    'end',
    '',
    'return deepFreeze(' + luauLiteral(frozen) + ')',
    '',
  ].join('\n');
}

// Write-once: identical existing bytes -> "unchanged"; different existing bytes -> refuse.
export function writeSpringFrozen(text, outPath = DEFAULT_OUT) {
  const path = resolve(outPath);
  if (existsSync(path)) {
    const existing = readFileSync(path);
    if (existing.equals(Buffer.from(text, 'utf8'))) return {status: 'unchanged', path, sha256: sha256(existing), bytes: existing.length};
    fail(`refusing to overwrite a different existing file ${path} (existing sha256 ${sha256(existing)}, generated ${sha256(text)})`);
  }
  writeFileSync(path, text, {flag: 'wx'});
  return {status: 'written', path, sha256: sha256(text), bytes: Buffer.byteLength(text)};
}

function parseArgs(argv) {
  const options = {out: DEFAULT_OUT, check: false};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--check') options.check = true;
    else if (argv[i] === '--out' && argv[i + 1]) options.out = resolve(argv[++i]);
    else throw new Error(`Unknown argument ${argv[i]}. Usage: node make-spring-frozen.mjs [--out <path>] [--check]`);
  }
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const built = buildSpringFrozen();
    if (options.check) {
      const same = existsSync(options.out) && readFileSync(options.out).equals(Buffer.from(built.text, 'utf8'));
      console.log(JSON.stringify({status: same ? 'match' : 'differs', path: options.out, generatedSha256: built.sha256, bundleFnv32: built.bundleFnv32}));
      process.exitCode = same ? 0 : 1;
    } else {
      console.log(JSON.stringify({...writeSpringFrozen(built.text, options.out), bundleFnv32: built.bundleFnv32}));
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
