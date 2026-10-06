// W1 data lane tests (spring-live-contract.md section 2, W1; decisions L1, L9, L10). Run: node --test tests/spring-live-data.test.mjs
// Every server test uses port 0 and an OS temp results root; nothing is written under results/ or indicator-v2.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import {spawn} from 'node:child_process';
import {readFileSync, readdirSync, statSync, existsSync, mkdtempSync, rmSync, writeFileSync, mkdirSync} from 'node:fs';
import {join, dirname, relative} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';

const HERE = dirname(fileURLToPath(import.meta.url));
const V3 = join(HERE, '..');
const V2 = join(V3, '../indicator-v2');
const RESULTS = join(V3, 'results');
const STEM = 'RoAlgoV2_SPY_1791205420530';
const MANIFEST = join(V2, 'results', STEM + '.json');
const SERVER_FILE = join(V3, 'spring-live-server.mjs');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');

// Snapshot of results/ and indicator-v2 BEFORE any module under test is imported (checked by the last test).
function snapshot(root) {
  const out = {};
  if (!existsSync(root)) return out;
  const walk = dir => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name), rel = relative(root, path).split('\\').join('/'), st = statSync(path);
      if (st.isDirectory()) { out[rel + '/'] = 'dir'; walk(path); }
      else out[rel] = `${st.size}:${sha(readFileSync(path))}`;
    }
  };
  walk(root);
  return out;
}
const BEFORE = {results: snapshot(RESULTS), v2: snapshot(V2)};
const TMP = mkdtempSync(join(os.tmpdir(), 'spring-live-test-'));
test.after(() => rmSync(TMP, {recursive: true, force: true}));

const data = await import('../spring-live-data.mjs');
const server = await import('../spring-live-server.mjs');
const v2 = await import('../../indicator-v2/bridge.mjs');
const runnerLib = await import('../spring-runner-lib.mjs');

// Independent read of the saved capture (not through the module under test).
let savedMemo;
function saved() {
  if (savedMemo) return savedMemo;
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'));
  const records = [];
  for (let k = 1; k <= 5; k++) records.push(...JSON.parse(readFileSync(join(V2, 'results', `${STEM}_states_000${k}.json`), 'utf8')).records);
  return (savedMemo = {manifest, records});
}
const readHexDoubles = hex => { const b = Buffer.from(hex, 'hex'), out = []; for (let i = 0; i < b.length; i += 8) out.push(b.readDoubleLE(i)); return out; };
const status400 = error => error?.status === 400;

// ---------------------------------------------------------------------------------------------------------------
test('contract constants: LIVE_QUERY, PAGE_SIZE, EXPECT and the capture pins', () => {
  assert.deepEqual({...data.LIVE_QUERY}, {symbol: 'SPY', train: 20, validation: 5, test: 444, end: '2026-10-02'});
  assert.ok(Object.isFrozen(data.LIVE_QUERY));
  assert.equal(data.PAGE_SIZE, 512);
  const E = data.EXPECT;
  assert.ok(Object.isFrozen(E) && Object.isFrozen(E.split) && Object.isFrozen(E.earlyCloseDays));
  assert.equal(E.sessions, 469);
  assert.equal(E.bars, 36402);
  assert.equal(E.captureRows, 2268);
  assert.equal(E.liveStartIndex, 2269);
  assert.equal(E.liveStartT, 1735828200);
  assert.equal(new Date(E.liveStartT * 1000).toISOString(), '2025-01-02T14:30:00.000Z');
  assert.match(E.captureDataHash, /^789e6e64[0-9a-f]{49}cec49d4$/);
  assert.match(E.liveDataHash, /^b8a3ce22[0-9a-f]{49}bb41a26$/);
  const {manifest} = saved();
  assert.deepEqual({...E.split}, manifest.split, 'EXPECT.split must be the capture split');
  assert.deepEqual({...data.CAPTURE_QUERY}, manifest.metadata.requestedSplits);
  assert.equal(E.v2BridgeSha256, manifest.metadata.sourceCodeHashes.bridge);
  assert.equal(E.v2BridgeSha256, sha(readFileSync(join(V2, 'bridge.mjs'))), 'indicator-v2/bridge.mjs is the capture-time bridge');
  assert.equal(data.CAPTURE_PINS.manifestSha256, runnerLib.DEFAULT_PINS.manifestSha256);
  assert.deepEqual([...data.CAPTURE_PINS.checkpointSha256s], [...runnerLib.DEFAULT_PINS.checkpointSha256s]);
  assert.deepEqual([...data.CAPTURE_PINS.checkpointSha256s], manifest.cacheChunks.map(c => c.sha256));
  assert.equal(data.CAPTURE_PINS.records, 2268);
});

test('the capture dataHash reproduces from the unmodified v2 loader', () => {
  const {manifest} = saved();
  const capture = v2.loadDataset({...data.CAPTURE_QUERY});
  assert.equal(capture.metadata.dataHash, manifest.metadata.dataHash);
  assert.equal(capture.metadata.dataHash, data.EXPECT.captureDataHash);
  assert.equal(capture.bars.length, 2268);
  assert.deepEqual(capture.split, manifest.split);
});

test('loadLive: EXPECT holds on the live dataset (recounted here), memoised and frozen; manifest shape', t => {
  const t0 = performance.now();
  const live = data.loadLive();
  const firstMs = performance.now() - t0;
  const t1 = performance.now();
  assert.equal(data.loadLive(), live, 'memoised: the same object');
  const secondMs = performance.now() - t1;
  assert.ok(secondMs < 5, `memoised call took ${secondMs} ms`);
  t.diagnostic(`loadLive first call ${firstMs.toFixed(0)} ms (module-measured ${live.loadMs.toFixed(0)} ms), second ${secondMs.toFixed(3)} ms`);

  const d = live.dataset, E = data.EXPECT, {manifest} = saved();
  assert.equal(live.datasetId, E.liveDataHash);
  assert.equal(d.metadata.dataHash, E.liveDataHash);
  assert.equal(live.captureDataHash, E.captureDataHash);
  assert.equal(d.bars.length, 36402);
  assert.equal(d.metadata.sessionCount, 469);
  assert.equal(new Set(d.bars.map(b => b.day)).size, 469);
  assert.deepEqual(d.split, manifest.split);
  assert.equal(d.bars[0].label, '2024-11-18 09:30 ET');
  assert.equal(d.bars[2267].label, '2024-12-31 15:55 ET');
  assert.equal(d.bars[2268].t, 1735828200);
  assert.equal(d.bars[2268].label, '2025-01-02 09:30 ET');
  assert.equal(d.bars.at(-1).label, '2026-10-02 15:55 ET');
  const part = {training: 0, validation: 0, evaluation: 0, live: 0};
  for (const b of d.bars) {
    part[b.t < d.split.trainEndT ? 'training' : b.t < d.split.validationEndT ? 'validation' : 'evaluation']++;
    if (b.t >= E.liveStartT) part.live++;
    assert.equal(b.availableT, b.t + 300);
  }
  assert.deepEqual(part, {training: 1524, validation: 390, evaluation: 34488, live: 34134});
  assert.equal(d.bars.findIndex(b => b.t >= E.liveStartT) + 1, E.liveStartIndex);
  assert.deepEqual(d.prehistory, v2.loadDataset({...data.CAPTURE_QUERY}).prehistory, 'prehistory identical to the capture');
  assert.equal(d.prehistory.targetDaily.length, 2234);
  assert.ok(Object.isFrozen(d.bars) && Object.isFrozen(d.bars[0]) && Object.isFrozen(d.bars[0].contexts.spyHour), 'memo is deep-frozen');

  const m = data.liveManifest();
  assert.equal(data.liveManifest(), m);
  for (const key of ['schema', 'datasetId', 'query', 'split', 'prehistory', 'pageSize', 'pageCount', 'bars', 'captureRows', 'liveStartIndex', 'liveStartT', 'metadata'])
    assert.ok(Object.hasOwn(m, key), 'manifest key ' + key);
  assert.equal(m.schema, 'roalgo-spring-live-data-v1');
  assert.equal(m.datasetId, E.liveDataHash);
  assert.deepEqual({...m.query}, {...data.LIVE_QUERY});
  assert.equal(m.pageSize, 512);
  assert.equal(m.pageCount, 72);
  assert.equal(m.bars, 36402);
  assert.equal(m.captureRows, 2268);
  assert.equal(m.liveStartIndex, 2269);
  assert.equal(m.liveStartT, 1735828200);
  assert.equal(m.metadata, d.metadata, 'v2 metadata unchanged');
  assert.equal(m.prehistory, d.prehistory);
  t.diagnostic(`manifest ${Buffer.byteLength(JSON.stringify(m))} bytes`);
});

test('buildLive fails closed on tampered loader output (and accepts the real loader)', () => {
  const real = q => v2.loadDataset(q);
  const isLive = q => Number(q.test) === 444;
  const onLive = fn => q => (isLive(q) ? fn(real(q)) : real(q));
  const withBar = (d, i, patch) => ({...d, bars: d.bars.map((b, k) => (k === i ? patch(b) : b))});
  assert.equal(data.buildLive(real).datasetId, data.EXPECT.liveDataHash);
  const cases = {
    'capture dataHash': q => (isLive(q) ? real(q) : {...real(q), metadata: {...real(q).metadata, dataHash: '0'.repeat(64)}}),
    'live dataHash': onLive(d => ({...d, metadata: {...d.metadata, dataHash: 'f'.repeat(64)}})),
    'v2 bridge hash': onLive(d => ({...d, metadata: {...d.metadata, sourceCodeHashes: {...d.metadata.sourceCodeHashes, bridge: 'e'.repeat(64)}}})),
    'missing context': onLive(d => withBar(d, 20000, b => { const contexts = {...b.contexts}; delete contexts.tltHour; return {...b, contexts}; })),
    'availableT': onLive(d => withBar(d, 30000, b => ({...b, availableT: b.availableT + 300}))),
    'dropped bar': onLive(d => ({...d, bars: d.bars.filter((_, k) => k !== 31000)})),
    'split': onLive(d => ({...d, split: {...d.split, trainEndT: d.split.trainEndT + 300}})),
    'lead-in bar differs from capture': onLive(d => withBar(d, 4, b => ({...b, c: b.c + 0.01}))),
    'prehistory': onLive(d => ({...d, prehistory: {targetDaily: d.prehistory.targetDaily.slice(1)}})),
    'session length': onLive(d => ({...d, bars: d.bars.map((b, k) => (k === d.bars.length - 1 ? {...b, day: '2026-10-01'} : b))})),
    'bar order': onLive(d => ({...d, bars: d.bars.map((b, k, all) => (k === 25000 ? all[25001] : k === 25001 ? all[25000] : b))})),
  };
  for (const [name, loader] of Object.entries(cases))
    assert.throws(() => data.buildLive(loader), error => error.status === 500 && /Spring live data check failed/.test(error.message), name);
});

test('pages partition 1..36402 exactly with no overlap; bad page indices are rejected', () => {
  const d = data.loadLive().dataset;
  let next = 1;
  const seen = new Set();
  for (let k = 1; k <= 72; k++) {
    const p = data.livePage(k);
    assert.equal(p.page, k);
    assert.equal(p.pageCount, 72);
    assert.equal(p.datasetId, data.EXPECT.liveDataHash);
    assert.equal(p.firstIndex, next, `page ${k} starts where page ${k - 1} ended`);
    assert.equal(p.bars.length, k < 72 ? 512 : 50);
    assert.equal(p.lastIndex, p.firstIndex + p.bars.length - 1);
    p.bars.forEach((b, i) => {
      assert.equal(b, d.bars[p.firstIndex - 1 + i], 'unmodified v2 bar object');
      assert.ok(!seen.has(b.t), 'no overlap');
      seen.add(b.t);
    });
    next = p.lastIndex + 1;
  }
  assert.equal(next - 1, 36402);
  assert.equal(seen.size, 36402);
  assert.deepEqual(Object.keys(data.livePage(1).bars[0]), ['t', 'o', 'h', 'l', 'c', 'v', 'n', 'vwap', 'day', 'label', 'minute', 'availableT', 'contexts']);
  for (const bad of [0, 73, -1, 1.5, NaN, Infinity, '1', null, undefined, 2 ** 53])
    assert.throws(() => data.livePage(bad), status400, String(bad));
});

test('calendar: 18 closures and 3 early closes in 2025-01-02..2026-10-02 (and the 2024 lead-in)', t => {
  const d = data.loadLive().dataset;
  const CLOSURES = ['2025-01-09', '2025-01-20', '2025-02-17', '2025-04-18', '2025-05-26', '2025-06-19', '2025-07-04', '2025-09-01', '2025-11-27',
    '2025-12-25', '2026-01-01', '2026-01-19', '2026-02-16', '2026-04-03', '2026-05-25', '2026-06-19', '2026-07-03', '2026-09-07'];
  const EARLY = ['2025-07-03', '2025-11-28', '2025-12-24'];
  assert.equal(CLOSURES.length, 18);
  const counts = new Map(), lastLabel = new Map();
  for (const b of d.bars) { counts.set(b.day, (counts.get(b.day) ?? 0) + 1); lastLabel.set(b.day, b.label); }
  const weekdays = (lo, hi) => {
    const out = [];
    for (let x = new Date(lo + 'T12:00:00Z'); x <= new Date(hi + 'T12:00:00Z'); x.setUTCDate(x.getUTCDate() + 1))
      if (x.getUTCDay() > 0 && x.getUTCDay() < 6) out.push(x.toISOString().slice(0, 10));
    return out;
  };
  const liveDays = weekdays('2025-01-02', '2026-10-02');
  assert.deepEqual(liveDays.filter(day => !counts.has(day)), CLOSURES, 'weekdays without a session are exactly the NYSE closures');
  const liveSessions = [...counts.keys()].filter(day => day >= '2025-01-02');
  assert.equal(liveSessions.length, 439);
  assert.deepEqual(liveSessions.filter(day => counts.get(day) !== 78), EARLY);
  for (const day of EARLY) { assert.equal(counts.get(day), 42); assert.equal(lastLabel.get(day), `${day} 12:55 ET`); }
  for (const day of liveSessions.filter(x => !EARLY.includes(x))) assert.equal(lastLabel.get(day), `${day} 15:55 ET`);
  // The 2024 lead-in: 30 sessions, closed 11-28 and 12-25, early closes 11-29 and 12-24.
  const leadDays = weekdays('2024-11-18', '2024-12-31');
  assert.deepEqual(leadDays.filter(day => !counts.has(day)), ['2024-11-28', '2024-12-25']);
  assert.deepEqual([...counts.keys()].filter(day => day < '2025-01-01' && counts.get(day) !== 78), ['2024-11-29', '2024-12-24']);
  assert.deepEqual(d.metadata.earlyCloseDays, ['2024-11-29', '2024-12-24', ...EARLY]);

  // The raw cache agrees: no SPY rows at all on the closures, and the late-session volume collapses only on the early closes.
  const raw = v2.parseCSV(readFileSync(join(V3, '../data/alpaca-supplement-2016-01-01_2026-10-02/five-minute/SPY.csv'), 'utf8'));
  const byDay = new Map();
  for (const b of raw) {
    const x = v2.nyTime(b.t);
    if (x.day < '2025-01-02' || x.day > '2026-10-02') continue;
    if (!byDay.has(x.day)) byDay.set(x.day, []);
    byDay.get(x.day).push({...b, minute: x.minute});
  }
  for (const day of CLOSURES) assert.equal(byDay.get(day)?.length ?? 0, 0, `cache rows on closure ${day}`);
  const perBar = (rows, lo, hi) => { const s = rows.filter(r => r.minute >= lo && r.minute < hi); return s.reduce((a, r) => a + r.v, 0) / Math.max(1, s.length); };
  let minFull = Infinity, maxEarly = -Infinity;
  for (const day of liveSessions) {
    const rows = byDay.get(day), ratio = perBar(rows, 930, 960) / perBar(rows, 720, 780);
    if (EARLY.includes(day)) maxEarly = Math.max(maxEarly, ratio); else minFull = Math.min(minFull, ratio);
  }
  t.diagnostic(`last-30-min / noon per-bar volume: full sessions min ${minFull.toFixed(3)}, early closes max ${maxEarly.toFixed(3)}`);
  assert.ok(maxEarly < 0.5, 'the listed early closes really closed early');
  assert.ok(minFull > 0.5, 'no unlisted early close among the full sessions');
});

test('the first 2268 page bars deep-equal the capture bars', () => {
  const {records} = saved();
  assert.equal(records.length, 2268);
  const pageBars = [];
  for (let k = 1; k <= 5; k++) pageBars.push(...data.livePage(k).bars);
  for (let i = 0; i < 2268; i++) assert.deepStrictEqual(pageBars[i], records[i].bar, `bar ${i + 1}`);
  assert.equal(pageBars[2268].t, data.EXPECT.liveStartT);
});

test('captureCheck returns the saved checkpoint vectors exactly (values and exact hex)', () => {
  const {records} = saved();
  const names = records[0].states.coupled.names;
  assert.equal(data.hexDoubles([0.11277320613367355]), 'c58d3570b4debc3f', 'Luau string.pack("<d") byte order');
  const seen = [];
  for (const [first, last] of [[1, 512], [513, 1024], [1025, 1536], [1537, 2048], [2049, 2268], [500, 1011]]) {
    const r = data.captureCheck(first, last);
    assert.equal(r.schema, 'roalgo-spring-live-capture-check-1');
    assert.equal(r.manifestSha256, data.CAPTURE_PINS.manifestSha256);
    assert.equal(r.first, first);
    assert.equal(r.last, last);
    assert.equal(r.count, last - first + 1);
    assert.equal(r.records.length, last - first + 1);
    assert.deepEqual([...r.names], names);
    r.records.forEach((rec, i) => {
      const index = first + i, s = records[index - 1];
      assert.deepEqual(Object.keys(rec), ['index', 't', 'drive', 'reset', 'coupled', 'independent', 'numeric', 'hex']);
      assert.equal(rec.index, index);
      assert.equal(rec.t, s.bar.t);
      assert.equal(rec.reset, s.feature.reset);
      assert.deepStrictEqual([...rec.drive], s.feature.drive);
      assert.deepStrictEqual(readHexDoubles(rec.hex.drive), s.feature.drive);
      for (const v of ['coupled', 'independent', 'numeric']) {
        assert.deepStrictEqual([...rec[v]], s.states[v].vector, `${v} ${index}`);
        assert.deepStrictEqual(readHexDoubles(rec.hex[v]), s.states[v].vector, `${v} hex ${index}`);
      }
      if (first <= 2049) seen[index] = true;
    });
  }
  assert.equal(seen.filter(Boolean).length, 2268);
  assert.equal(records.filter(r => r.feature.reset).length, 1);
  assert.equal(data.captureCheck(1, 1).records[0].reset, true);
  for (const [a, b] of [[0, 1], [1, 0], [2, 1], [1, 513], [2268, 2269], [1.5, 2], ['1', 2], [1, null], [NaN, 3]])
    assert.throws(() => data.captureCheck(a, b), status400, `${a}..${b}`);
});

test('openCapture verifies the manifest pin and every checkpoint sha256 before parsing', () => {
  const dir = join(TMP, 'fake-capture');
  mkdirSync(dir, {recursive: true});
  const config = {nodes: Array.from({length: 24}, (_, i) => ({index: i + 1, name: 'N' + String(i + 1).padStart(2, '0')})), bankNames: ['A', 'B', 'C']};
  const names = data.expectedStateNames(config);
  const record = (t, k) => ({bar: {t}, feature: {drive: Array.from({length: 8}, (_, j) => j + k / 7), reset: t === 300},
    states: Object.fromEntries(['coupled', 'independent', 'numeric'].map((v, n) => [v, {names, vector: Array.from({length: 51}, (_, j) => (j + n) * 0.1 + k)}]))});
  const write = (chunks, {indexShift = 0, nameBreak = false} = {}) => {
    const files = [[record(300, 1), record(600, 2)], [record(900, 3)]];
    if (nameBreak) files[1][0].states.numeric.names = [...names].reverse();
    const shas = files.map((recs, i) => {
      const firstIndex = (i === 0 ? 1 : 3) + (i === 1 ? indexShift : 0);
      const text = JSON.stringify({firstIndex, lastIndex: firstIndex + recs.length - 1, records: recs}, null, 2);
      writeFileSync(join(dir, `fake_states_000${i + 1}.json`), text);
      return sha(text);
    });
    const manifest = JSON.stringify({cacheChunks: (chunks ?? shas).map((s, i) => ({ok: true, path: `C:\\elsewhere\\fake_states_000${i + 1}.json`, sha256: s})), native: {config}});
    writeFileSync(join(dir, 'fake.json'), manifest);
    return {shas, manifestSha256: sha(manifest)};
  };
  const open = pins => data.openCapture({manifestPath: join(dir, 'fake.json'), pins});
  const fails = (fn, re) => assert.throws(fn, error => error.status === 500 && re.test(error.message));

  let w = write();
  const good = open({manifestSha256: w.manifestSha256, checkpointSha256s: w.shas, records: 3});
  const r = good.check(1, 3);
  assert.deepEqual(r.records.map(x => x.index), [1, 2, 3]);
  assert.deepEqual([...r.records[2].numeric], record(900, 3).states.numeric.vector);

  // A whitespace-only edit parses to identical values: only the sha256 check can catch it.
  writeFileSync(join(dir, 'fake_states_0002.json'), readFileSync(join(dir, 'fake_states_0002.json'), 'utf8') + ' ');
  fails(() => open({manifestSha256: w.manifestSha256, checkpointSha256s: w.shas, records: 3}), /checkpoint fake_states_0002\.json sha256/);

  w = write();
  fails(() => open({manifestSha256: '0'.repeat(64), checkpointSha256s: w.shas, records: 3}), /manifest sha256/);
  fails(() => open({manifestSha256: w.manifestSha256, checkpointSha256s: [w.shas[0], '1'.repeat(64)], records: 3}), /cacheChunks\[1\] sha256/);
  fails(() => open({manifestSha256: w.manifestSha256, checkpointSha256s: w.shas, records: 4}), /capture has 3 records, pinned 4/);
  w = write(undefined, {indexShift: 1});
  fails(() => open({manifestSha256: w.manifestSha256, checkpointSha256s: w.shas, records: 3}), /do not continue at 3/);
  w = write(undefined, {nameBreak: true});
  fails(() => open({manifestSha256: w.manifestSha256, checkpointSha256s: w.shas, records: 3}), /names differ/);
});

// ---------------------------------------------------------------------------------------------------------------
// Server
function call(port, method, path, {headers = {}, body} = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({host: '127.0.0.1', port, method, path, headers, agent: false}, res => {
      const parts = [];
      res.on('data', part => parts.push(part));
      res.on('end', () => {
        const text = Buffer.concat(parts).toString('utf8');
        let json;
        try { json = JSON.parse(text); } catch { json = undefined; }
        resolve({status: res.statusCode, headers: res.headers, text, json});
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}
const postJson = (port, value, headers = {}) => {
  const body = typeof value === 'string' ? value : JSON.stringify(value);
  return call(port, 'POST', '/spring-live/chunk', {headers: {'content-type': 'application/json', 'content-length': Buffer.byteLength(body), ...headers}, body});
};

test('server routes: health, manifest, page, capture-check, host/origin checks and route validation', async t => {
  const root = join(TMP, 'routes-root');
  const running = await server.start({port: 0, resultsRoot: root});
  try {
    const port = running.port;
    let r = await call(port, 'GET', '/health');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, {ok: true, app: 'RoAlgo Spring Live', schema: 'roalgo-spring-live-server-1'});
    assert.equal((await call(port, 'GET', '/health?x=1')).status, 400);

    r = await call(port, 'GET', '/spring-live/manifest');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, JSON.parse(JSON.stringify(data.liveManifest())));
    t.diagnostic(`GET /spring-live/manifest ${Buffer.byteLength(r.text)} bytes`);
    assert.equal((await call(port, 'GET', '/spring-live/manifest?page=1')).status, 400);

    r = await call(port, 'GET', '/spring-live/page?index=1');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, JSON.parse(JSON.stringify(data.livePage(1))));
    t.diagnostic(`GET page 1 ${Buffer.byteLength(r.text)} bytes`);
    r = await call(port, 'GET', '/spring-live/page?index=72');
    assert.equal(r.json.lastIndex, 36402);
    assert.equal(r.json.bars.length, 50);
    for (const q of ['index=0', 'index=73', 'index=1.5', 'index=-1', 'index=01', 'index=%2B1', 'index=1e1', 'index=abc', 'index=', 'index=%201', '', 'index=1&index=2', 'index=1&extra=1', 'page=1'])
      assert.equal((await call(port, 'GET', '/spring-live/page?' + q)).status, 400, 'page ' + q);

    r = await call(port, 'GET', '/spring-live/capture-check?first=1&last=78');
    assert.equal(r.status, 200);
    assert.equal(r.json.count, 78);
    assert.deepEqual(r.json.records[77].numeric, saved().records[77].states.numeric.vector);
    t.diagnostic(`GET capture-check 1..78 ${Buffer.byteLength(r.text)} bytes`);
    r = await call(port, 'GET', '/spring-live/capture-check?first=1757&last=2268');
    assert.equal(r.status, 200);
    assert.equal(r.json.records.length, 512);
    t.diagnostic(`GET capture-check 512 records ${Buffer.byteLength(r.text)} bytes`);
    for (const q of ['first=0&last=1', 'first=1&last=2269', 'first=5&last=4', 'first=1&last=513', 'first=1', 'last=3', 'first=1&last=2&last=3', 'first=1&last=2&x=1', 'first=a&last=2'])
      assert.equal((await call(port, 'GET', '/spring-live/capture-check?' + q)).status, 400, 'capture-check ' + q);

    for (const headers of [{host: `localhost:${port}`}, {host: `127.0.0.1.evil.example:${port}`}, {host: `10.0.0.1:${port}`}, {origin: 'http://evil.example'}, {origin: 'null'}])
      assert.equal((await call(port, 'GET', '/health', {headers})).status, 403, JSON.stringify(headers));
    assert.equal((await call(port, 'GET', '/health', {headers: {origin: `http://127.0.0.1:${port}`}})).status, 200);

    assert.equal((await call(port, 'GET', '/dataset')).status, 404);
    assert.equal((await call(port, 'GET', '/spring-live/manifest/')).status, 404);
    assert.equal((await call(port, 'GET', '/saved?name=x.json')).status, 404);
    assert.equal((await call(port, 'POST', '/health')).status, 405);
    assert.equal((await call(port, 'POST', '/spring-live/page?index=1')).status, 405);
    assert.equal((await call(port, 'DELETE', '/spring-live/chunk?runId=a&name=b')).status, 405);
    assert.equal(existsSync(root), false, 'read-only routes create nothing');
  } finally {
    await running.close();
  }
});

test('POST/GET chunk: write-once compact JSON, 201 then 409, sha256 check, strict names and keys', async () => {
  const root = join(TMP, 'chunk-root');
  const running = await server.start({port: 0, resultsRoot: root});
  try {
    const port = running.port;
    const payload = {schema: 'x', a: 1, b: [1.5, 'x', 0.1 + 0.2], c: {d: null, e: -0.000123}};
    let r = await postJson(port, {runId: 'run_A-1', name: 'plan', payload});
    assert.equal(r.status, 201);
    const file = join(root, 'run_A-1', 'plan.json');
    const bytes = readFileSync(file);
    assert.equal(bytes.toString('utf8'), JSON.stringify(payload), 'compact JSON of the payload');
    assert.deepEqual(r.json, {ok: true, path: file, sha256: sha(bytes), bytes: bytes.length});

    r = await postJson(port, {runId: 'run_A-1', name: 'plan', payload});
    assert.equal(r.status, 409, 'repeat is refused');
    r = await postJson(port, {runId: 'run_A-1', name: 'plan', payload: {other: true}});
    assert.equal(r.status, 409);
    assert.deepEqual(readFileSync(file), bytes, 'write-once: the file is unchanged');
    assert.equal((await postJson(port, {runId: 'run_B', name: 'plan', payload: {b: 1}})).status, 201, 'same name in another run');

    const parallel = await Promise.all(Array.from({length: 6}, (_, i) => postJson(port, {runId: 'run_A-1', name: 's0001', payload: {i}})));
    assert.deepEqual(parallel.map(x => x.status).sort(), [201, 409, 409, 409, 409, 409]);

    r = await call(port, 'GET', '/spring-live/chunk?runId=run_A-1&name=plan');
    assert.equal(r.status, 200);
    assert.equal(r.text, bytes.toString('utf8'));
    assert.equal(r.headers['x-content-sha256'], sha(bytes));
    assert.equal((await call(port, 'GET', `/spring-live/chunk?runId=run_A-1&name=plan&sha256=${sha(bytes)}`)).status, 200);
    assert.equal((await call(port, 'GET', `/spring-live/chunk?runId=run_A-1&name=plan&sha256=${'0'.repeat(64)}`)).status, 409);
    for (const q of ['runId=run_A-1&name=plan&sha256=ABC', `runId=run_A-1&name=plan&sha256=${sha(bytes).toUpperCase()}`, 'runId=run_A-1', 'name=plan',
      'runId=run_A-1&name=plan&x=1', 'runId=run_A-1&name=plan&name=plan', 'runId=..&name=plan', 'runId=run_A-1&name=..%2Fplan', 'runId=CON&name=plan'])
      assert.equal((await call(port, 'GET', '/spring-live/chunk?' + q)).status, 400, 'GET chunk ' + q);
    assert.equal((await call(port, 'GET', '/spring-live/chunk?runId=run_A-1&name=missing')).status, 404);

    const before = snapshot(root);
    const badNames = ['', 'a/b', '../x', '..', '.', 'a.json', 'a\\b', 'a b', 'é', 'x'.repeat(101), 'CON', 'nul', 'com1', 'LPT9', 123, null, ['a']];
    for (const bad of badNames) {
      assert.equal((await postJson(port, {runId: bad, name: 'ok', payload: {}})).status, 400, 'runId ' + JSON.stringify(bad));
      assert.equal((await postJson(port, {runId: 'ok', name: bad, payload: {}})).status, 400, 'name ' + JSON.stringify(bad));
    }
    assert.equal((await postJson(port, {runId: 'r', name: 'x'.repeat(100), payload: {}})).status, 201, '100-character name is allowed');
    const badBodies = [{runId: 'r', name: 'k1', payload: {}, extra: 1}, {runId: 'r', name: 'k2'}, {runId: 'r', name: 'k3', payload: [1]},
      {runId: 'r', name: 'k4', payload: null}, {runId: 'r', name: 'k5', payload: 'text'}, [{runId: 'r', name: 'k6', payload: {}}], '{"runId":"r","name":"k7","payload":{}', 'null'];
    for (const body of badBodies) assert.equal((await postJson(port, body)).status, 400, 'body ' + JSON.stringify(body));
    assert.equal((await postJson(port, {runId: 'r', name: 'k8', payload: {}}, {'content-type': 'text/plain'})).status, 415);
    assert.equal((await call(port, 'POST', '/spring-live/chunk?x=1', {headers: {'content-type': 'application/json'}, body: JSON.stringify({runId: 'r', name: 'k9', payload: {}})})).status, 400);
    const after = snapshot(root);
    const added = Object.keys(after).filter(k => !(k in before)).sort();
    assert.deepEqual(added, ['r/', 'r/' + 'x'.repeat(100) + '.json'], 'rejected posts wrote nothing');
  } finally {
    await running.close();
  }
});

test('POST chunk body limit is 48 MiB: exact limit accepted, declared or streamed oversize refused with 413', async () => {
  const root = join(TMP, 'limit-root');
  const MAX = 48 * 1024 * 1024;
  assert.equal(server.MAX_BODY_BYTES, MAX);
  const running = await server.start({port: 0, resultsRoot: root});
  try {
    const port = running.port;
    const body = size => { const pre = '{"runId":"big","name":"N","payload":{"s":"', post = '"}}'; return pre + 'x'.repeat(size - pre.length - post.length) + post; };
    const exact = body(MAX);
    assert.equal(Buffer.byteLength(exact), MAX);
    assert.equal((await postJson(port, exact)).status, 201);
    const over = body(MAX + 1).replace('"name":"N"', '"name":"O"').slice(0, MAX + 1);
    assert.equal(Buffer.byteLength(over), MAX + 1);
    assert.equal((await postJson(port, over)).status, 413, 'declared content-length over the limit (body drained)');
    const rawStatus = text => new Promise((resolve, reject) => {
      const socket = net.connect({host: '127.0.0.1', port}, () => socket.write(text));
      let buffer = '';
      socket.setTimeout(10000, () => { socket.destroy(); reject(new Error('no reply to a huge declared length')); });
      socket.on('data', part => { buffer += part; const m = /^HTTP\/1\.1 (\d{3})/.exec(buffer); if (m) { socket.destroy(); resolve(Number(m[1])); } });
      socket.on('error', reject);
    });
    assert.equal(await rawStatus(`POST /spring-live/chunk HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Type: application/json\r\nContent-Length: ${4 * MAX + 1}\r\n\r\n{}`), 413,
      'a declared length far over the limit is refused without waiting for the body');
    const streamed = await new Promise((resolve, reject) => {
      const req = http.request({host: '127.0.0.1', port, method: 'POST', path: '/spring-live/chunk', agent: false, headers: {'content-type': 'application/json', 'transfer-encoding': 'chunked'}}, res => {
        res.resume();
        res.on('end', () => resolve(res.statusCode));
      });
      req.on('error', reject);
      const block = Buffer.alloc(1024 * 1024, 0x20);
      let sent = 0;
      const pump = () => { while (sent <= MAX) { sent += block.length; if (!req.write(block)) { req.once('drain', pump); return; } } req.end(); };
      pump();
    });
    assert.equal(streamed, 413, 'undeclared (chunked) body over the limit');
    assert.equal(existsSync(join(root, 'big', 'O.json')), false);
    assert.deepEqual(readdirSync(join(root, 'big')), ['N.json']);
  } finally {
    await running.close();
  }
});

test('the server binds 127.0.0.1 only', async t => {
  for (const options of [{port: 0, host: '0.0.0.0'}, {port: 0, host: '::'}, {port: -1}, {port: 1.5}]) {
    const attempt = await server.start({...options, resultsRoot: join(TMP, 'never')}).then(started => started, error => error);
    if (typeof attempt?.close === 'function') { await attempt.close(); assert.fail(`start(${JSON.stringify(options)}) must refuse`); }
    assert.ok(attempt instanceof Error, JSON.stringify(options));
  }
  const running = await server.start({port: 0, resultsRoot: join(TMP, 'bind-root')});
  try {
    assert.equal(running.address, '127.0.0.1');
    assert.deepEqual({address: running.server.address().address, family: running.server.address().family}, {address: '127.0.0.1', family: 'IPv4'});
    const others = Object.values(os.networkInterfaces()).flat().filter(a => a && !a.internal && (a.family === 'IPv4' || a.family === 4)).map(a => a.address);
    const tryConnect = address => new Promise(resolve => {
      const socket = net.connect({host: address, port: running.port, timeout: 3000});
      socket.once('connect', () => { socket.destroy(); resolve('connected'); });
      socket.once('timeout', () => { socket.destroy(); resolve('timeout'); });
      socket.once('error', error => resolve(error.code));
    });
    for (const address of [...others, '::1']) assert.notEqual(await tryConnect(address), 'connected', `reachable on ${address}`);
    assert.equal(await tryConnect('127.0.0.1'), 'connected');
    t.diagnostic(`refused on ${others.length} non-loopback IPv4 address(es) and ::1`);
  } finally {
    await running.close();
  }
  assert.equal(existsSync(join(TMP, 'never')), false);
});

test('importing the server does not listen; running it directly listens (port 0); CLI defaults', async () => {
  const run = (args, onLine) => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, {cwd: V3, windowsHide: true});
    let out = '', err = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error('timeout: ' + out + err)); }, 30000);
    child.stdout.on('data', chunk => { out += chunk; if (onLine) onLine(out, child); });
    child.stderr.on('data', chunk => { err += chunk; });
    child.on('exit', code => { clearTimeout(timer); resolve({code, out, err}); });
  });
  const imported = await run(['--input-type=module', '-e', `await import(${JSON.stringify(pathToFileURL(SERVER_FILE).href)}); console.log('imported');`]);
  assert.equal(imported.code, 0, imported.err);
  assert.equal(imported.out.trim(), 'imported', 'import alone must not keep a listening server alive');

  const cliRoot = join(TMP, 'cli-root');
  let health;
  const direct = await run([SERVER_FILE, '--port', '0', '--results-root', cliRoot, '--lazy'], (out, child) => {
    const m = /http:\/\/127\.0\.0\.1:(\d+)/.exec(out);
    if (m && !health) {
      health = call(Number(m[1]), 'GET', '/health').finally(() => child.kill());
    }
  });
  assert.ok(health, 'the server printed its URL: ' + direct.out + direct.err);
  const h = await health;
  assert.equal(h.status, 200);
  assert.equal(h.json.schema, 'roalgo-spring-live-server-1');
  assert.equal(existsSync(cliRoot), false);

  // Contract L9 (amended 2026-10-05 11:59): default port 47627; 47625 belongs to another project's bridge since 11:56.
  // Integration fix: the controller's default base URL (src/SpringLive.luau BASE_URL) must name the same port.
  assert.equal(server.DEFAULT_PORT, 47627);
  const controllerBase = /^local BASE_URL = "http:\/\/127\.0\.0\.1:(\d+)"$/m.exec(readFileSync(join(V3, 'src', 'SpringLive.luau'), 'utf8'));
  assert.ok(controllerBase, 'src/SpringLive.luau declares its default BASE_URL on one line');
  assert.equal(Number(controllerBase[1]), server.DEFAULT_PORT, 'controller default port equals the server default port');
  assert.equal(server.DEFAULT_RESULTS_ROOT, join(V3, 'results', 'spring-live'));
  assert.deepEqual(server.parseArgs([]), {port: 47627, resultsRoot: join(V3, 'results', 'spring-live'), preload: true});
  assert.deepEqual(server.parseArgs(['--port', '0', '--results-root', 'x', '--lazy'], TMP), {port: 0, resultsRoot: join(TMP, 'x'), preload: false});
  for (const argv of [['--port', 'x'], ['--port', '70000'], ['--port'], ['--host', '0.0.0.0'], ['--bogus']]) assert.throws(() => server.parseArgs(argv), argv.join(' '));
});

// Declared last: node:test runs top-level tests in order.
test('no file under results/ (outside the test temp root) or indicator-v2 changed', () => {
  // The snapshot itself must see an added directory, an added file and a same-size content change.
  const probe = join(TMP, 'snapshot-probe');
  mkdirSync(probe);
  const s0 = snapshot(probe);
  mkdirSync(join(probe, 'd'));
  const s1 = snapshot(probe);
  writeFileSync(join(probe, 'd', 'f.json'), 'aaaa');
  const s2 = snapshot(probe);
  writeFileSync(join(probe, 'd', 'f.json'), 'aaab');
  assert.notDeepEqual(s1, s0);
  assert.notDeepEqual(s2, s1);
  assert.notDeepEqual(snapshot(probe), s2);

  assert.deepEqual(snapshot(RESULTS), BEFORE.results, 'indicator-v3/results unchanged (no results/spring-live created)');
  assert.deepEqual(snapshot(V2), BEFORE.v2, 'indicator-v2 unchanged');
  assert.ok(Object.keys(BEFORE.v2).length > 10 && Object.keys(BEFORE.results).length > 5, 'the snapshots saw the trees');
});
