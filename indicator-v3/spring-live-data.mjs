// Spring live forward test, W1 data lane (spring-live-contract.md: L1, L9, L10; module contract W1).
// Pure and memoised. It serves the continuous 2024-11-18..2026-10-02 SPY dataset in pages, built by the UNMODIFIED
// indicator-v2 loader (imported, never edited), and the saved 2024 per-record vectors from the pinned v2 checkpoints.
// It never writes a file, never starts a server and never touches Studio.
import {readFileSync} from 'node:fs';
import {dirname, join, basename, win32} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {loadDataset as loadV2Dataset} from '../indicator-v2/bridge.mjs';

export const ROOT = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_MANIFEST = join(ROOT, '../indicator-v2/results/RoAlgoV2_SPY_1791205420530.json');
export const SCHEMA = 'roalgo-spring-live-data-v1';
export const FORMAT = 'roalgo-v2-dataset-schema-2-paged';
export const CAPTURE_CHECK_SCHEMA = 'roalgo-spring-live-capture-check-1';
export const PAGE_SIZE = 512;
export const CAPTURE_CHECK_MAX = 512;
export const VARIANTS = Object.freeze(['coupled', 'independent', 'numeric']);
export const CONTEXT_NAMES = Object.freeze(['peerFive', 'spyHour', 'qqqHour', 'iwmHour', 'tltHour', 'spyDaily', 'qqqDaily']);

// L1: one continuous v2 query; it reproduces the capture split and prehistory exactly.
export const LIVE_QUERY = Object.freeze({symbol: 'SPY', train: 20, validation: 5, test: 444, end: '2026-10-02'});
// The 2024 capture request (manifest metadata.requestedSplits); its dataHash proves the source CSVs are unchanged.
export const CAPTURE_QUERY = Object.freeze({symbol: 'SPY', train: 20, validation: 5, test: 5, end: '2024-12-31'});

const deepFreeze = value => {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
};

// Measured 2026-10-05 with the v2 loader on the local cache (measured during development, then re-measured).
export const EXPECT = deepFreeze({
  sessions: 469,
  bars: 36402,
  captureRows: 2268,
  captureSessions: 30,
  liveStartIndex: 2269,
  liveStartT: 1735828200,
  liveStartDay: '2025-01-02',
  liveRows: 34134,
  liveSessions: 439,
  captureDataHash: '789e6e64453e3c019e365b17604800e2f7750b04de85cfa827cef7beccec49d4',
  liveDataHash: 'b8a3ce225720691e172ab8216b85bcdff634fb1172ced5325db6d5d4fbb41a26',
  // sha256 of indicator-v2/bridge.mjs = the capture manifest's metadata.sourceCodeHashes.bridge.
  v2BridgeSha256: '13b18e8ee06a4b0a38e12c1e75f98d245d4eabc8d57ae910e78e55f73c9a2456',
  split: {trainEndT: 1734445800, validationEndT: 1735050600, testStartT: 1735050600},
  partitions: {training: 1524, validation: 390, evaluation: 34488},
  firstSession: '2024-11-18',
  lastSession: '2026-10-02',
  firstLabel: '2024-11-18 09:30 ET',
  lastLabel: '2026-10-02 15:55 ET',
  prehistoryCount: 2234,
  prehistoryFirst: '2016-01-04',
  prehistoryLast: '2024-11-15',
  intradayGaps: 0,
  earlyCloseDays: ['2024-11-29', '2024-12-24', '2025-07-03', '2025-11-28', '2025-12-24'],
  fullSessionBars: 78,
  earlyCloseBars: 42,
  pageCount: 72,
  lastPageBars: 50,
});

// D15 pins (same values as spring-runner-lib DEFAULT_PINS): manifest bytes and the five checkpoint files.
export const CAPTURE_PINS = deepFreeze({
  manifestSha256: 'bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828',
  checkpointSha256s: [
    'd75e3a65a34750e2e54bf394a6d3ac5c1eae63810a1724e911bac2b80640b74a',
    '7ef24f376cdc10d6784ade62d2a61e104d7f063d85a631aa61d9f8a34f4a69f5',
    '55c352c0a752ce6c58713030463c3543a557e7a4d62f4d8ee4e472a5d932cab0',
    'b79751d37ba5c6cc193983437e4e63c2b155cfcf4f910386042a50a7235b7ca3',
    '109aab90b951a60623db3c683dff06dba0e1a293dd2954d420fe1db243bdfa76',
  ],
  records: 2268,
});

export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

// Exact doubles as lowercase hex of little-endian IEEE-754 bytes: equal to Luau
// string.pack("<" .. string.rep("d", n), ...) hexed byte by byte (the L10 storage convention).
export function hexDoubles(values) {
  const buffer = Buffer.alloc(8 * values.length);
  values.forEach((value, i) => buffer.writeDoubleLE(value, 8 * i));
  return buffer.toString('hex');
}
export function unhexDoubles(hex) {
  if (typeof hex !== 'string' || hex.length % 16 !== 0 || !/^[0-9a-f]*$/.test(hex)) throw new TypeError('hex doubles must be lowercase hex, 16 chars per value');
  const buffer = Buffer.from(hex, 'hex'), out = [];
  for (let i = 0; i < buffer.length; i += 8) out.push(buffer.readDoubleLE(i));
  return out;
}

// Input errors carry status 400; data-integrity errors carry status 500 (the server fails closed on them).
const inputError = message => Object.assign(new RangeError(message), {status: 400});
const dataError = message => Object.assign(new Error('Spring live data check failed: ' + message), {status: 500});
const sameJson = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const sameSplit = (a, b) => ['trainEndT', 'validationEndT', 'testStartT'].every(k => a?.[k] === b[k]) && Object.keys(a ?? {}).length === 3;

// Builds and validates the live dataset with an injectable loader (tests inject tampered loaders).
export function buildLive(load = loadV2Dataset, expect = EXPECT) {
  const started = performance.now();
  const fail = message => { throw dataError(message); };

  const capture = load({...CAPTURE_QUERY});
  if (capture?.metadata?.dataHash !== expect.captureDataHash) fail(`capture dataHash ${capture?.metadata?.dataHash} != ${expect.captureDataHash}`);
  if (!Array.isArray(capture.bars) || capture.bars.length !== expect.captureRows) fail(`capture bars ${capture.bars?.length} != ${expect.captureRows}`);
  if (!sameSplit(capture.split, expect.split)) fail(`capture split ${JSON.stringify(capture.split)} differs from EXPECT.split`);

  const d = load({...LIVE_QUERY});
  const m = d?.metadata ?? fail('live dataset has no metadata');
  if (m.dataHash !== expect.liveDataHash) fail(`live dataHash ${m.dataHash} != ${expect.liveDataHash}`);
  if (m.sourceCodeHashes?.bridge !== expect.v2BridgeSha256) fail(`v2 bridge sha256 ${m.sourceCodeHashes?.bridge} != capture bridge ${expect.v2BridgeSha256}`);
  if (!sameJson(m.requestedSplits, {...LIVE_QUERY})) fail(`requestedSplits ${JSON.stringify(m.requestedSplits)} != LIVE_QUERY`);
  const bars = d.bars, n = bars?.length;
  if (!Array.isArray(bars) || n !== expect.bars || m.bars !== expect.bars) fail(`bars ${n}/${m.bars} != ${expect.bars}`);
  if (!sameSplit(d.split, expect.split)) fail(`live split ${JSON.stringify(d.split)} differs from the capture split`);
  if (m.sessionCount !== expect.sessions || m.sessions?.length !== expect.sessions) fail(`sessions ${m.sessionCount} != ${expect.sessions}`);
  if (m.sessions[0] !== expect.firstSession || m.sessions.at(-1) !== expect.lastSession) fail(`session range ${m.sessions[0]}..${m.sessions.at(-1)}`);
  if (m.first !== expect.firstLabel || m.last !== expect.lastLabel) fail(`label range ${m.first}..${m.last}`);
  if (m.prehistoryCount !== expect.prehistoryCount || m.prehistoryFirst !== expect.prehistoryFirst || m.prehistoryLast !== expect.prehistoryLast)
    fail(`prehistory ${m.prehistoryCount} ${m.prehistoryFirst}..${m.prehistoryLast}`);
  if (d.prehistory?.targetDaily?.length !== expect.prehistoryCount) fail('prehistory.targetDaily count');
  if (!sameJson(d.prehistory, capture.prehistory)) fail('live prehistory differs from the capture prehistory');
  if (!sameJson(m.earlyCloseDays, expect.earlyCloseDays)) fail(`earlyCloseDays ${JSON.stringify(m.earlyCloseDays)}`);
  if (m.intradayGaps !== expect.intradayGaps) fail(`metadata.intradayGaps ${m.intradayGaps}`);

  // Every bar: integer 5-minute grid, strictly increasing, availableT = t + 300, exactly the seven contexts,
  // no intraday gap, and whole sessions of 78 bars (42 on the declared early closes).
  const sessionSet = new Set(m.sessions), earlySet = new Set(expect.earlyCloseDays), perDay = new Map();
  const partitions = {training: 0, validation: 0, evaluation: 0};
  let gaps = 0;
  for (let i = 0; i < n; i++) {
    const b = bars[i];
    if (!Number.isInteger(b.t) || b.t % 300 !== 0) fail(`bar ${i + 1}: t ${b.t} is not on the 5-minute grid`);
    if (i > 0 && b.t <= bars[i - 1].t) fail(`bar ${i + 1}: t not strictly increasing`);
    if (b.availableT !== b.t + 300) fail(`bar ${i + 1}: availableT ${b.availableT} != t + 300`);
    if (!sessionSet.has(b.day)) fail(`bar ${i + 1}: day ${b.day} is not a selected session`);
    const keys = Object.keys(b.contexts ?? {});
    if (keys.length !== CONTEXT_NAMES.length || !CONTEXT_NAMES.every(k => b.contexts[k] && typeof b.contexts[k] === 'object'))
      fail(`bar ${i + 1}: contexts ${keys.join(',')} != ${CONTEXT_NAMES.join(',')}`);
    if (i > 0 && b.day === bars[i - 1].day && b.t - bars[i - 1].t !== 300) gaps++;
    perDay.set(b.day, (perDay.get(b.day) ?? 0) + 1);
    partitions[b.t < d.split.trainEndT ? 'training' : b.t < d.split.validationEndT ? 'validation' : 'evaluation']++;
  }
  if (gaps !== expect.intradayGaps) fail(`recounted intraday gaps ${gaps}`);
  if (perDay.size !== expect.sessions) fail(`bar days ${perDay.size} != sessions ${expect.sessions}`);
  for (const [day, count] of perDay) {
    const want = earlySet.has(day) ? expect.earlyCloseBars : expect.fullSessionBars;
    if (count !== want) fail(`session ${day} has ${count} bars, expected ${want}`);
  }
  if (!sameJson(partitions, expect.partitions)) fail(`partitions ${JSON.stringify(partitions)}`);

  // L1: rows 1..captureRows are the capture bars (same loader, same inputs); 2025 starts at liveStartIndex.
  for (let i = 0; i < expect.captureRows; i++)
    if (JSON.stringify(bars[i]) !== JSON.stringify(capture.bars[i])) fail(`lead-in bar ${i + 1} differs from the capture dataset bar`);
  const start = bars[expect.liveStartIndex - 1];
  if (expect.liveStartIndex !== expect.captureRows + 1) fail('liveStartIndex must follow the capture rows');
  if (start.t !== expect.liveStartT || start.day !== expect.liveStartDay) fail(`live start bar ${start.t} ${start.day}`);
  if (bars[expect.captureRows - 1].day >= expect.liveStartDay) fail('the last lead-in bar is not before the live start day');
  if (n - expect.captureRows !== expect.liveRows) fail(`live rows ${n - expect.captureRows}`);
  if (m.sessions.filter(s => s >= expect.liveStartDay).length !== expect.liveSessions) fail('live session count');
  const pageCount = Math.ceil(n / PAGE_SIZE);
  if (pageCount !== expect.pageCount || n - (pageCount - 1) * PAGE_SIZE !== expect.lastPageBars) fail(`pageCount ${pageCount}`);

  deepFreeze(d);
  return Object.freeze({dataset: d, datasetId: m.dataHash, captureDataHash: capture.metadata.dataHash, pageCount, loadMs: performance.now() - started});
}

let liveMemo, manifestMemo, captureMemo;
// Memoised; a failure is not cached, so a later call re-checks (and fails again if the data is wrong).
export function loadLive() {
  return (liveMemo ??= buildLive());
}

export function liveManifest() {
  if (manifestMemo) return manifestMemo;
  const live = loadLive(), d = live.dataset;
  manifestMemo = Object.freeze({
    schema: SCHEMA,
    format: FORMAT,
    datasetId: live.datasetId,
    captureDataHash: live.captureDataHash,
    query: LIVE_QUERY,
    split: d.split,
    prehistory: d.prehistory,
    pageSize: PAGE_SIZE,
    pageCount: live.pageCount,
    bars: d.bars.length,
    captureRows: EXPECT.captureRows,
    liveStartIndex: EXPECT.liveStartIndex,
    liveStartT: EXPECT.liveStartT,
    note: 'records 1..2268 equal the 2024 capture bars (calibration lead-in); the 2025-2026 forward test begins at 2269',
    metadata: d.metadata,
  });
  return manifestMemo;
}

export function parsePageIndex(k, pageCount = EXPECT.pageCount) {
  if (!Number.isSafeInteger(k) || k < 1 || k > pageCount) throw inputError(`page index must be an integer in 1..${pageCount}`);
  return k;
}

export function livePage(k) {
  const live = loadLive();
  parsePageIndex(k, live.pageCount);
  const bars = live.dataset.bars, first = (k - 1) * PAGE_SIZE, last = Math.min(first + PAGE_SIZE, bars.length);
  return Object.freeze({datasetId: live.datasetId, page: k, pageCount: live.pageCount, firstIndex: first + 1, lastIndex: last, bars: Object.freeze(bars.slice(first, last))});
}

export function expectedStateNames(config) {
  return [...config.nodes.map(node => node.name + '.x'), ...config.nodes.map(node => node.name + '.v'), ...config.bankNames.map(bank => bank + '.energy')];
}

export function parseCaptureRange(first, last, captureRows = EXPECT.captureRows) {
  if (!Number.isSafeInteger(first) || !Number.isSafeInteger(last)) throw inputError('first and last must be integers');
  if (first < 1 || last > captureRows || first > last) throw inputError(`need 1 <= first <= last <= ${captureRows}`);
  if (last - first + 1 > CAPTURE_CHECK_MAX) throw inputError(`at most ${CAPTURE_CHECK_MAX} records per call`);
  return [first, last];
}

// Reads the pinned v2 capture: the manifest bytes must equal the pin, manifest.cacheChunks must equal the pinned
// checkpoint list, and each checkpoint's bytes must hash to its cacheChunks sha256 BEFORE the file is parsed.
export function openCapture({manifestPath = DEFAULT_MANIFEST, pins = CAPTURE_PINS} = {}) {
  const fail = message => { throw dataError(message); };
  const manifestBytes = readFileSync(manifestPath), manifestSha256 = sha256(manifestBytes);
  if (manifestSha256 !== pins.manifestSha256) fail(`manifest sha256 ${manifestSha256} != pinned ${pins.manifestSha256}`);
  const manifest = JSON.parse(manifestBytes.toString('utf8'));
  const chunks = manifest.cacheChunks;
  if (!Array.isArray(chunks) || chunks.length !== pins.checkpointSha256s.length) fail(`manifest.cacheChunks has ${chunks?.length} entries, pinned ${pins.checkpointSha256s.length}`);
  const config = manifest.native?.config;
  if (!Array.isArray(config?.nodes) || config.nodes.length !== 24 || !Array.isArray(config.bankNames) || config.bankNames.length !== 3) fail('manifest.native.config shape');
  const names = Object.freeze(expectedStateNames(config));
  const stem = basename(manifestPath, '.json'), dir = dirname(manifestPath), records = [];
  const checkpointSha256s = [];
  chunks.forEach((entry, i) => {
    if (entry?.ok !== true || entry.sha256 !== pins.checkpointSha256s[i]) fail(`manifest.cacheChunks[${i}] sha256 ${entry?.sha256} != pinned ${pins.checkpointSha256s[i]}`);
    const file = win32.basename(String(entry.path ?? ''));
    if (file !== `${stem}_states_${String(i + 1).padStart(4, '0')}.json`) fail(`manifest.cacheChunks[${i}] names ${file}`);
    const bytes = readFileSync(join(dir, file)), found = sha256(bytes);
    if (found !== entry.sha256) fail(`checkpoint ${file} sha256 ${found} != manifest.cacheChunks ${entry.sha256}`);
    checkpointSha256s.push(found);
    const checkpoint = JSON.parse(bytes.toString('utf8'));
    const list = checkpoint.records;
    if (checkpoint.firstIndex !== records.length + 1 || !Array.isArray(list) || checkpoint.lastIndex !== checkpoint.firstIndex + list.length - 1)
      fail(`checkpoint ${file} indices ${checkpoint.firstIndex}..${checkpoint.lastIndex} (${list?.length} records) do not continue at ${records.length + 1}`);
    list.forEach((record, j) => {
      const index = checkpoint.firstIndex + j, t = record?.bar?.t, drive = record?.feature?.drive, reset = record?.feature?.reset;
      if (!Number.isInteger(t)) fail(`record ${index}: bar.t`);
      if (!Array.isArray(drive) || drive.length !== 8 || !drive.every(Number.isFinite)) fail(`record ${index}: feature.drive must be 8 finite numbers`);
      if (typeof reset !== 'boolean') fail(`record ${index}: feature.reset must be boolean`);
      const row = {index, t, drive: Object.freeze([...drive]), reset};
      const hex = {drive: hexDoubles(drive)};
      for (const variant of VARIANTS) {
        const state = record.states?.[variant], vector = state?.vector;
        if (!Array.isArray(vector) || vector.length !== 51 || !vector.every(Number.isFinite)) fail(`record ${index}: states.${variant}.vector must be 51 finite numbers`);
        if (!sameJson(state.names, names)) fail(`record ${index}: states.${variant}.names differ from the names rebuilt from native.config`);
        row[variant] = Object.freeze([...vector]);
        hex[variant] = hexDoubles(vector);
      }
      row.hex = Object.freeze(hex);
      records.push(Object.freeze(row));
    });
  });
  if (records.length !== pins.records) fail(`capture has ${records.length} records, pinned ${pins.records}`);
  return Object.freeze({
    manifestSha256, checkpointSha256s: Object.freeze(checkpointSha256s), names, records: records.length,
    check(first, last) {
      parseCaptureRange(first, last, records.length);
      return Object.freeze({
        schema: CAPTURE_CHECK_SCHEMA, manifestSha256, captureRows: records.length, first, last, count: last - first + 1,
        names, records: Object.freeze(records.slice(first - 1, last)),
      });
    },
  });
}

// Returns {schema, manifestSha256, captureRows, first, last, count, names[51],
//   records: [{index, t, drive[8], reset, coupled[51], independent[51], numeric[51], hex:{drive, coupled, independent, numeric}}]}.
export function captureCheck(first, last) {
  parseCaptureRange(first, last);
  return (captureMemo ??= openCapture()).check(first, last);
}
