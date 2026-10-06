import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';

const implementation = await import('./export-data.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
const exportDataset = async options => {
  assert.equal(typeof implementation.exportDataset, 'function', 'exportDataset implementation is missing');
  return implementation.exportDataset(options);
};
const candle = { t: '2024-01-02T14:00:00Z', o: 100, h: 103, l: 99, c: 102, v: 1234, n: 12, vw: 101.25 };
const second = { t: '2024-01-02T15:00:00Z', o: 102, h: 104, l: 101, c: 103, v: 800, n: 8, vw: 102.5 };
const createDirectory = () => mkdtemp(join(tmpdir(), 'market-export-test-'));
const exportBars = (outputDir, bars = [candle, second], metadata = {}) => exportDataset({ barsBySymbol: { SPY: bars }, outputDir, metadata });

test('exports hand-checked candles without changing values, with UTC/Unix roundtrip and file hashes', async () => {
  const outputDir = await createDirectory();
  const summary = await exportBars(outputDir, [candle, second], { provider: 'Alpaca', feed: 'iex', adjustment: 'raw' });
  const csv = await readFile(join(outputDir, 'SPY.csv'), 'utf8');
  assert.equal(csv, 'timestamp_utc,timestamp_unix,open,high,low,close,volume,trade_count,vwap\n' +
    '2024-01-02T14:00:00.000Z,1704204000,100,103,99,102,1234,12,101.25\n' +
    '2024-01-02T15:00:00.000Z,1704207600,102,104,101,103,800,8,102.5\n');
  for (const row of csv.trim().split('\n').slice(1)) {
    const [utc, unix] = row.split(',');
    assert.equal(new Date(Number(unix) * 1000).toISOString(), utc);
  }
  const manifest = JSON.parse(await readFile(join(outputDir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.provider, 'Alpaca');
  assert.equal(manifest.feed, 'iex');
  assert.equal(manifest.timeframe, '1Hour');
  assert.equal(manifest.includesExtendedHours, true);
  assert.equal(manifest.regularSessionOnly, false);
  assert.equal(manifest.containsMarketGaps, true);
  assert.match(manifest.timeframeDescription, /provider-native/i);
  assert.equal(manifest.symbols.SPY.count, 2);
  assert.equal(manifest.symbols.SPY.first, '2024-01-02T14:00:00.000Z');
  assert.equal(manifest.symbols.SPY.last, '2024-01-02T15:00:00.000Z');
  assert.equal(summary.totalBars, 2);
  assert.equal(summary.symbols.SPY.count, 2);
  assert.equal(summary.manifestPath, join(outputDir, 'manifest.json'));
  assert.deepEqual(manifest.files.map(file => file.path).sort(), ['SPY.csv', 'roblox/SPY/Chunk001.luau', 'roblox/SPY/init.luau']);
  for (const file of manifest.files) {
    const bytes = await readFile(join(outputDir, file.path));
    assert.equal(file.sha256, createHash('sha256').update(bytes).digest('hex'));
    assert.equal(file.bytes, bytes.length);
  }
});

const invalidCases = [
  ['empty series', [], /nonempty/i],
  ['duplicate timestamps', [candle, candle], /strictly ascending/i],
  ['out-of-order timestamps', [second, candle], /strictly ascending/i],
  ['invalid timestamp', [{ ...candle, t: 'not-a-date' }], /timestamp/i],
  ['invalid calendar date', [{ ...candle, t: '2024-02-30T14:00:00Z' }], /timestamp/i],
  ['non-UTC timestamp', [{ ...candle, t: '2024-01-02T14:00:00-05:00' }], /timestamp/i],
  ['nonfinite price', [{ ...candle, c: Infinity }], /finite/i],
  ['string number', [{ ...candle, o: '100' }], /finite/i],
  ['missing price', [{ ...candle, o: undefined }], /finite/i],
  ['zero price', [{ ...candle, l: 0 }], /positive/i],
  ['negative price', [{ ...candle, o: -1 }], /positive/i],
  ['close outside high', [{ ...candle, c: 104 }], /OHLC/i],
  ['open outside low', [{ ...candle, o: 98 }], /OHLC/i],
  ['high below low', [{ ...candle, h: 98 }], /OHLC/i],
  ['negative volume', [{ ...candle, v: -1 }], /volume/i],
  ['nonfinite volume', [{ ...candle, v: NaN }], /finite/i],
  ['negative trade count', [{ ...candle, n: -1 }], /trade_count/i],
  ['fractional trade count', [{ ...candle, n: 1.5 }], /trade_count/i],
  ['missing trade count', [{ ...candle, n: undefined }], /trade_count/i],
  ['nonfinite VWAP', [{ ...candle, vw: Infinity }], /finite/i],
  ['missing VWAP', [{ ...candle, vw: undefined }], /finite/i],
  ['zero VWAP', [{ ...candle, vw: 0 }], /positive/i],
];
for (const [name, bars, expectedError] of invalidCases) {
  test(`rejects ${name} before writing any output`, async () => {
    const outputDir = await createDirectory();
    await assert.rejects(exportBars(outputDir, bars), expectedError);
    assert.deepEqual(await readdir(outputDir), []);
  });
}

test('validates all symbols before writing the first symbol', async () => {
  const outputDir = await createDirectory();
  await assert.rejects(exportDataset({ barsBySymbol: { SPY: [candle], QQQ: [] }, outputDir }), /nonempty/i);
  assert.deepEqual(await readdir(outputDir), []);
});

test('rejects empty datasets and unexpected symbols', async () => {
  const outputDir = await createDirectory();
  await assert.rejects(exportDataset({ barsBySymbol: {}, outputDir }), /nonempty/i);
  await assert.rejects(exportDataset({ barsBySymbol: { '../bad': [candle] }, outputDir }), /symbol/i);
});

test('exports independent symbols, preserves market gaps, and metadata cannot override computed facts', async () => {
  const outputDir = await createDirectory();
  const summary = await exportDataset({
    barsBySymbol: { SPY: [candle, { ...second, t: '2024-01-08T15:00:00Z' }], QQQ: [{ ...candle, c: 100 }] },
    outputDir,
    metadata: { symbols: { SPY: { count: 999 } }, files: [], timeframe: '1Min', regularSessionOnly: true },
  });
  assert.equal(summary.totalBars, 3);
  const manifest = JSON.parse(await readFile(join(outputDir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.symbols.SPY.count, 2);
  assert.equal(manifest.symbols.QQQ.count, 1);
  assert.equal(manifest.files.length, 6);
  assert.equal(manifest.timeframe, '1Hour');
  assert.equal(manifest.regularSessionOnly, false);
  assert.equal((await readFile(join(outputDir, 'SPY.csv'), 'utf8')).trim().split('\n').length, 3);
  assert.match(await readFile(join(outputDir, 'QQQ.csv'), 'utf8'), /,100,103,99,100,1234,12,101\.25/);
});

// This parser checks the numeric Luau artifact contract; it is not a Luau interpreter.
function readNumericChunk(source) {
  assert.match(source, /^return \{\n/);
  assert.match(source, /\n\}\n$/);
  return source.split('\n').slice(1, -2).map(line => {
    assert.match(line, /^\s*\{[-\d.eE+, nil]+\},$/);
    return line.trim().slice(1, -2).split(',').map(value => value.trim() === 'nil' ? null : Number(value));
  });
}

test('splits 1001 bars into ordered chunks and loader metadata describes the full series', async () => {
  const outputDir = await createDirectory();
  const bars = Array.from({ length: 1001 }, (_, i) => ({ ...candle, t: new Date(1704204000000 + i * 3600000).toISOString() }));
  const summary = await exportBars(outputDir, bars);
  const folder = join(outputDir, 'roblox', 'SPY');
  const firstChunk = readNumericChunk(await readFile(join(folder, 'Chunk001.luau'), 'utf8'));
  const lastChunk = readNumericChunk(await readFile(join(folder, 'Chunk002.luau'), 'utf8'));
  assert.equal(firstChunk.length, 1000);
  assert.equal(lastChunk.length, 1);
  assert.deepEqual(firstChunk[0], [1704204000, 100, 103, 99, 102, 1234, 12, 101.25]);
  assert.deepEqual(lastChunk[0], [1707804000, 100, 103, 99, 102, 1234, 12, 101.25]);
  const assembled = firstChunk.concat(lastChunk);
  assert.equal(assembled.length, summary.totalBars);
  assert.equal(new Set(assembled.map(row => row[0])).size, 1001);
  const loader = await readFile(join(folder, 'init.luau'), 'utf8');
  assert.match(loader, /local chunkNames = \{"Chunk001", "Chunk002"\}/);
  assert.match(loader, /require\(script:WaitForChild\(chunkName\)\)/);
  assert.match(loader, /table\.insert\(bars, row\)/);
  assert.match(loader, /count = 1001/);
  assert.match(loader, /schema = \{"timestamp_unix", "open", "high", "low", "close", "volume", "trade_count", "vwap"\}/);
  assert.match(loader, /bars = bars/);
});

test('rerunning with fewer rows lists only current chunks and ignores stale files', async () => {
  const outputDir = await createDirectory();
  const bars = Array.from({ length: 1001 }, (_, i) => ({ ...candle, t: new Date(1704204000000 + i * 3600000).toISOString() }));
  await exportBars(outputDir, bars);
  await exportBars(outputDir, [candle]);
  const loader = await readFile(join(outputDir, 'roblox', 'SPY', 'init.luau'), 'utf8');
  assert.match(loader, /local chunkNames = \{"Chunk001"\}/);
  assert.doesNotMatch(loader, /Chunk002|GetChildren/);
  const manifest = JSON.parse(await readFile(join(outputDir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.symbols.SPY.count, 1);
  assert.equal(manifest.files.some(file => file.path.includes('Chunk002')), false);
});
