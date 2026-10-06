import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';

const SCHEMA = ['timestamp_unix', 'open', 'high', 'low', 'close', 'volume', 'trade_count', 'vwap'];
const MARKET_METADATA = {
  timeframe: '1Hour',
  timeframeDescription: 'Provider-native 1Hour bars; all native sessions including extended hours. Overnight, weekend, holiday, and other market gaps remain unfilled.',
  includesExtendedHours: true,
  regularSessionOnly: false,
  containsMarketGaps: true,
  timestampMeaning: 'UTC start of the provider-native bar; Unix timestamp in seconds.',
};

function validateBars(symbol, bars) {
  if (!Array.isArray(bars) || bars.length === 0) throw new Error(`${symbol}: expected a nonempty bar array`);
  let previous = -Infinity;
  return bars.map((bar, index) => {
    const fail = message => { throw new Error(`${symbol} bar ${index + 1}: ${message}`); };
    if (!bar || typeof bar !== 'object') fail('expected a bar object');
    if (typeof bar.t !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(bar.t)) fail('timestamp must be an ISO UTC timestamp ending in Z');
    const millis = Date.parse(bar.t);
    if (!Number.isFinite(millis)) fail('invalid timestamp');
    const utc = new Date(millis).toISOString();
    if (utc.slice(0, 19) !== bar.t.slice(0, 19)) fail('invalid calendar timestamp');
    if (millis <= previous) fail('timestamps must be strictly ascending and unique');
    previous = millis;
    for (const field of ['o', 'h', 'l', 'c', 'v', 'vw']) {
      if (typeof bar[field] !== 'number' || !Number.isFinite(bar[field])) fail(`${field} must be a finite number`);
    }
    for (const field of ['o', 'h', 'l', 'c', 'vw']) {
      if (bar[field] <= 0) fail(`${field} must be positive`);
    }
    if (bar.l > bar.h || bar.o < bar.l || bar.o > bar.h || bar.c < bar.l || bar.c > bar.h) fail('invalid OHLC bounds');
    if (bar.v < 0) fail('volume must be nonnegative');
    if (!Number.isSafeInteger(bar.n) || bar.n < 0) fail('trade_count must be a finite nonnegative safe integer');
    return { utc, values: [millis / 1000, bar.o, bar.h, bar.l, bar.c, bar.v, bar.n, bar.vw] };
  });
}

function loaderSource(symbol, rows, chunkNames, metadata, marketMetadata) {
  const quote = value => JSON.stringify(String(value)).replace(/\\u([\da-f]{4})/gi, '\\u{$1}');
  const strings = { symbol, first: rows[0].utc, last: rows.at(-1).utc, ...marketMetadata };
  for (const name of ['provider', 'feed', 'adjustment']) {
    if (metadata[name] !== undefined) strings[name] = String(metadata[name]);
  }
  const entries = Object.entries(strings).map(([name, value]) => `        ${name} = ${typeof value === 'boolean' ? value : quote(value)},`);
  return `-- Place ChunkNNN ModuleScripts underneath this ModuleScript.\n` +
    `local chunkNames = {${chunkNames.map(quote).join(', ')}}\n` +
    `local bars = {}\n` +
    `for _, chunkName in ipairs(chunkNames) do\n` +
    `    for _, row in ipairs(require(script:WaitForChild(chunkName))) do\n` +
    `        table.insert(bars, row)\n` +
    `    end\n` +
    `end\n` +
    `assert(#bars == ${rows.length}, "Market dataset row count mismatch")\n` +
    `return {\n` +
    `    metadata = {\n${entries.join('\n')}\n        count = ${rows.length},\n    },\n` +
    `    schema = {${SCHEMA.map(quote).join(', ')}},\n` +
    `    bars = bars,\n}\n`;
}

/** Export validated Alpaca stock bars without sorting, filling gaps, or changing prices. */
export async function exportDataset({ barsBySymbol, outputDir, metadata = {}, timeframe = '1Hour' }) {
  if (!['5Min', '1Hour', '1Day'].includes(timeframe)) throw new Error('Unsupported export timeframe');
  const marketMetadata = { ...MARKET_METADATA, timeframe };
  if (timeframe === '5Min') marketMetadata.timeframeDescription = 'Provider-native 5Min bars across available sessions, including extended hours. Missing intervals remain unfilled.';
  if (timeframe === '1Day') {
    delete marketMetadata.includesExtendedHours;
    marketMetadata.timeframeDescription = 'Provider-native daily aggregation with New York day-start timestamps; not resampled from the hourly dataset.';
    marketMetadata.availabilityWarning = 'Use only fully completed previous-day bars for intraday features. Daily boundaries follow America/New_York, not a fixed 86400-second UTC offset.';
  }
  if (!barsBySymbol || typeof barsBySymbol !== 'object' || Array.isArray(barsBySymbol) || Object.keys(barsBySymbol).length === 0) throw new Error('Expected a nonempty barsBySymbol object');
  if (typeof outputDir !== 'string' || !outputDir.trim()) throw new Error('outputDir must be a nonempty path');
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) throw new Error('metadata must be an object');
  // Validate every symbol and serialize metadata before creating any output files.
  const sourceMetadata = JSON.parse(JSON.stringify(metadata));
  const validated = Object.entries(barsBySymbol).map(([symbol, bars]) => {
    if (!['SPY', 'QQQ', 'IWM', 'TLT'].includes(symbol)) throw new Error(`Unsupported symbol: ${symbol}`);
    return [symbol, validateBars(symbol, bars)];
  });
  const root = resolve(outputDir);
  const files = [];
  const symbols = {};
  let totalBars = 0;
  const save = async (relativePath, content) => {
    const path = join(root, relativePath);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content, 'utf8');
    files.push({ path: relativePath, bytes: Buffer.byteLength(content, 'utf8'), sha256: createHash('sha256').update(content, 'utf8').digest('hex') });
  };
  for (const [symbol, rows] of validated) {
    const csvPath = `${symbol}.csv`;
    await save(csvPath, `timestamp_utc,${SCHEMA.join(',')}\n` + rows.map(row => `${row.utc},${row.values.join(',')}\n`).join(''));
    const chunkNames = [];
    for (let start = 0; start < rows.length; start += 1000) {
      const name = `Chunk${String(chunkNames.length + 1).padStart(3, '0')}`;
      chunkNames.push(name);
      await save(`roblox/${symbol}/${name}.luau`, 'return {\n' + rows.slice(start, start + 1000).map(row => `    {${row.values.join(',')}},\n`).join('') + '}\n');
    }
    // Explicit names make old surplus chunks inert when reusing an output directory.
    const modulePath = `roblox/${symbol}/init.luau`;
    await save(modulePath, loaderSource(symbol, rows, chunkNames, sourceMetadata, marketMetadata));
    symbols[symbol] = { count: rows.length, first: rows[0].utc, last: rows.at(-1).utc, csvPath, modulePath, chunkCount: chunkNames.length };
    totalBars += rows.length;
  }
  const manifest = { ...sourceMetadata, schemaVersion: 1, ...marketMetadata, csvSchema: ['timestamp_utc', ...SCHEMA], robloxSchema: SCHEMA, totalBars, symbols, files };
  const manifestPath = join(root, 'manifest.json');
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
  return { outputDir: root, manifestPath, totalBars, symbols };
}
