import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { auditDataset, auditRawBars } from './audit-supplement.mjs';

const bar = t => ({ t, o: 100, h: 102, l: 99, c: 101, v: 1234, n: 100, vw: 100.5 });
const bounds = { requestedStart: '2024-01-01T00:00:00Z', requestedEnd: '2025-01-01T00:00:00Z' };
const schema = ['timestamp_unix', 'open', 'high', 'low', 'close', 'volume', 'trade_count', 'vwap'];
const values = b => [Date.parse(b.t) / 1000, b.o, b.h, b.l, b.c, b.v, b.n, b.vw];
const sha = s => createHash('sha256').update(s).digest('hex');

test('raw validation rejects normalized invalid calendar dates', () => {
  assert.throws(() => auditRawBars([bar('2024-02-30T14:00:00Z')], '1Hour', bounds), /calendar/);
});
test('raw validation rejects duplicate/out-of-order, out-of-bounds and unaligned bars', () => {
  const a = bar('2024-03-01T14:00:00Z');
  assert.throws(() => auditRawBars([a, a], '1Hour', bounds), /ascending/);
  assert.throws(() => auditRawBars([bar('2025-01-01T01:00:00Z')], '1Hour', bounds), /range/);
  assert.equal(auditRawBars([bar('2025-01-01T00:00:00Z')], '1Hour', bounds).count, 1);
  assert.throws(() => auditRawBars([bar('2024-03-01T14:01:00Z')], '5Min', bounds), /alignment/);
  assert.throws(() => auditRawBars([bar('2024-03-01T14:30:00Z')], '1Hour', bounds), /alignment/);
});
test('daily timestamp alignment respects New York daylight saving time', () => {
  const result = auditRawBars([bar('2024-03-08T05:00:00Z'), bar('2024-03-11T04:00:00Z')], '1Day', bounds);
  assert.equal(result.count, 2);
  assert.equal(result.datesNewYork, 2);
  assert.throws(() => auditRawBars([bar('2024-03-11T05:00:00Z')], '1Day', bounds), /midnight/);
});
test('raw validation rejects invalid prices, volume and counts but preserves valid gaps', () => {
  const a = bar('2024-03-01T14:00:00Z');
  for (const patch of [{ o: 105 }, { c: NaN }, { v: -1 }, { n: 1.5 }]) {
    assert.throws(() => auditRawBars([{ ...a, ...patch }], '1Hour', bounds));
  }
  const result = auditRawBars([a, bar('2024-03-04T14:00:00Z')], '1Hour', bounds);
  assert.equal(result.gapsLongerThanInterval, 1);
  assert.equal(result.count, 2);
});
test('invalid metadata ranges are rejected', () => {
  assert.throws(() => auditRawBars([bar('2024-03-01T14:00:00Z')], '1Hour', { ...bounds, requestedStart: '2024-02-30T00:00:00Z' }), /calendar/);
  assert.throws(() => auditRawBars([bar('2024-03-01T14:00:00Z')], '1Hour', { requestedStart: bounds.requestedEnd, requestedEnd: bounds.requestedStart }), /bounds/);
});

async function fixture(t) {
  const base = await mkdtemp(join(tmpdir(), 'supplement-audit-'));
  t.after(() => rm(base, { recursive: true, force: true }));
  const root = join(base, 'supplement');
  const originalRoot = join(base, 'original');
  const earlier = [bar('2024-03-01T14:00:00Z')];
  const original = [bar('2024-03-04T14:00:00Z')];
  await mkdir(join(originalRoot, 'raw'), { recursive: true });
  await writeFile(join(originalRoot, 'source-metadata.json'), JSON.stringify({ timeframe: '1Hour', feed: 'sip', adjustment: 'raw', requestedStart: '2024-03-04T00:00:00Z', requestedEnd: bounds.requestedEnd }));
  for (const symbol of ['SPY', 'QQQ']) await writeFile(join(originalRoot, 'raw', `${symbol}-1Hour.json`), JSON.stringify(original));
  for (const [id, timeframe, symbols, bars, dates] of [
    ['five-minute', '5Min', ['SPY', 'QQQ'], [bar('2024-03-01T14:00:00Z'), bar('2024-03-01T14:05:00Z')], bounds],
    ['hourly-earlier', '1Hour', ['SPY', 'QQQ'], earlier, { requestedStart: bounds.requestedStart, requestedEnd: '2024-03-03T23:59:59Z' }],
    ['daily-context', '1Day', ['SPY', 'QQQ'], [bar('2024-03-01T05:00:00Z')], bounds],
    ['hourly-context', '1Hour', ['IWM', 'TLT'], earlier, bounds],
    ['hourly-combined', '1Hour', ['SPY', 'QQQ'], [...earlier, ...original], bounds],
  ]) {
    const group = join(root, id);
    const metadata = { timeframe, feed: 'sip', adjustment: 'raw', symbols, ...dates, series: [] };
    const manifest = { ...metadata, totalBars: bars.length * symbols.length, csvSchema: ['timestamp_utc', ...schema], robloxSchema: schema, symbols: {}, files: [] };
    const save = async (path, data) => {
      await mkdir(join(group, path, '..'), { recursive: true });
      await writeFile(join(group, path), data);
      manifest.files.push({ path, bytes: Buffer.byteLength(data), sha256: sha(data) });
    };
    await mkdir(join(group, 'raw'), { recursive: true });
    for (const symbol of symbols) {
      const raw = JSON.stringify(bars);
      await writeFile(join(group, 'raw', `${symbol}-${timeframe}.json`), raw);
      metadata.series.push({ symbol, file: `raw/${symbol}-${timeframe}.json`, count: bars.length, first: bars[0].t, last: bars.at(-1).t, sha256: sha(raw) });
      await save(`${symbol}.csv`, ['timestamp_utc,' + schema.join(','), ...bars.map(b => new Date(b.t).toISOString() + ',' + values(b).join(',')), ''].join('\n'));
      await save(`roblox/${symbol}/Chunk001.luau`, 'return {\n' + bars.map(b => '    {' + values(b).join(',') + '},\n').join('') + '}\n');
      await save(`roblox/${symbol}/init.luau`, `local chunkNames = {"Chunk001"}\nassert(#bars == ${bars.length}, "Market dataset row count mismatch")\nreturn { metadata = { symbol = "${symbol}", timeframe = "${timeframe}", feed = "sip", adjustment = "raw", count = ${bars.length} }, schema = {${schema.map(s => JSON.stringify(s)).join(',')}} }\n`);
      manifest.symbols[symbol] = { count: bars.length, first: new Date(bars[0].t).toISOString(), last: new Date(bars.at(-1).t).toISOString(), csvPath: `${symbol}.csv`, modulePath: `roblox/${symbol}/init.luau`, chunkCount: 1 };
    }
    await writeFile(join(group, 'source-metadata.json'), JSON.stringify(metadata));
    await writeFile(join(group, 'manifest.json'), JSON.stringify(manifest));
  }
  return { root, originalRoot };
}

async function rehash(root, group, relative) {
  const manifestPath = join(root, group, 'manifest.json');
  const m = JSON.parse(await readFile(manifestPath, 'utf8'));
  const data = await readFile(join(root, group, relative));
  Object.assign(m.files.find(f => f.path === relative), { bytes: data.length, sha256: sha(data) });
  await writeFile(manifestPath, JSON.stringify(m));
}
test('complete independent fixture passes every group and exact combined-source check', async t => {
  const f = await fixture(t);
  const result = await auditDataset(f.root, { originalRoot: f.originalRoot });
  assert.equal(result.ok, true);
  assert.equal(result.groups.length, 5);
  assert.equal(result.groups.at(-1).symbols.SPY.concatenationVerified, true);
});
test('altered export is detected even when its manifest hash is refreshed', async t => {
  const f = await fixture(t);
  const csv = join(f.root, 'five-minute', 'SPY.csv');
  await writeFile(csv, (await readFile(csv, 'utf8')).replace(',1234,', ',1235,'));
  await rehash(f.root, 'five-minute', 'SPY.csv');
  await assert.rejects(auditDataset(f.root, { originalRoot: f.originalRoot }), /CSV.*mismatch/);
});
test('altered Luau values and file hashes are both detected', async t => {
  const f = await fixture(t);
  const path = join(f.root, 'five-minute', 'roblox', 'SPY', 'Chunk001.luau');
  await writeFile(path, (await readFile(path, 'utf8')).replace(',1234,', ',1235,'));
  await assert.rejects(auditDataset(f.root, { originalRoot: f.originalRoot }), /hash|SHA|Luau.*mismatch/);
  await rehash(f.root, 'five-minute', 'roblox/SPY/Chunk001.luau');
  await assert.rejects(auditDataset(f.root, { originalRoot: f.originalRoot }), /Luau.*mismatch/);
});
test('incorrect group timeframe and missing hash coverage are rejected', async t => {
  const f = await fixture(t);
  const p = join(f.root, 'five-minute', 'manifest.json');
  const m = JSON.parse(await readFile(p, 'utf8'));
  m.timeframe = '1Hour';
  await writeFile(p, JSON.stringify(m));
  await assert.rejects(auditDataset(f.root, { originalRoot: f.originalRoot }), /timeframe/);
  m.timeframe = '5Min';
  m.files = m.files.filter(e => e.path !== 'SPY.csv');
  await writeFile(p, JSON.stringify(m));
  await assert.rejects(auditDataset(f.root, { originalRoot: f.originalRoot }), /hash coverage/);
});
test('combined data must exactly retain the original frozen raw values', async t => {
  const f = await fixture(t);
  const p = join(f.originalRoot, 'raw', 'SPY-1Hour.json');
  const bars = JSON.parse(await readFile(p, 'utf8'));
  bars[0].v += 1;
  await writeFile(p, JSON.stringify(bars));
  await assert.rejects(auditDataset(f.root, { originalRoot: f.originalRoot }), /concatenation/);
});
