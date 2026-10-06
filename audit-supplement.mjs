import { readFile, readdir, writeFile } from 'node:fs/promises';
import { resolve, join, dirname, relative, isAbsolute, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

// Intentionally independent of downloader/exporter validation and serialization.
const SCHEMA = ['timestamp_unix', 'open', 'high', 'low', 'close', 'volume', 'trade_count', 'vwap'];
const GROUPS = [
  ['five-minute', '5Min', ['SPY', 'QQQ']],
  ['hourly-earlier', '1Hour', ['SPY', 'QQQ']],
  ['daily-context', '1Day', ['SPY', 'QQQ']],
  ['hourly-context', '1Hour', ['IWM', 'TLT']],
  ['hourly-combined', '1Hour', ['SPY', 'QQQ']],
];
const NY_DATE = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' });
const NY_TIME = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/New_York', hourCycle: 'h23', hour: '2-digit', minute: '2-digit', second: '2-digit' });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const json = async p => JSON.parse(await readFile(p, 'utf8'));
const ensure = (ok, message) => { if (!ok) throw new Error(message); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const values = b => [Date.parse(b.t) / 1000, b.o, b.h, b.l, b.c, b.v, b.n, b.vw];

function timestamp(value, context) {
  ensure(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value), `${context}: invalid ISO UTC timestamp`);
  const millis = Date.parse(value);
  ensure(Number.isFinite(millis) && new Date(millis).toISOString().slice(0, 19) === value.slice(0, 19), `${context}: invalid calendar timestamp`);
  return millis;
}

/** Validate untouched source bars. Gaps are measured, never interpolated. */
export function auditRawBars(bars, timeframe, metadata) {
  ensure(['5Min', '1Hour', '1Day'].includes(timeframe), 'Unsupported timeframe');
  ensure(Array.isArray(bars) && bars.length > 0, 'Expected nonempty raw bar array');
  const start = timestamp(metadata.requestedStart, 'requestedStart');
  const end = timestamp(metadata.requestedEnd, 'requestedEnd');
  ensure(start < end, 'Invalid requested time bounds');
  const interval = { '5Min': 300000, '1Hour': 3600000, '1Day': 86400000 }[timeframe];
  let previous = -Infinity;
  let gaps = 0;
  let largestGapSeconds = 0;
  const dates = new Set();
  const months = new Set();
  const years = {};
  for (let i = 0; i < bars.length; i++) {
    const b = bars[i];
    const tag = `raw bar ${i + 1}`;
    ensure(b && typeof b === 'object', `${tag}: invalid bar object`);
    const millis = timestamp(b.t, tag);
    ensure(millis >= start && millis <= end, `${tag}: timestamp outside requested range`);
    ensure(millis > previous, `${tag}: timestamps must be strictly ascending and unique`);
    if (timeframe === '1Day') {
      ensure(millis % 1000 === 0 && NY_TIME.format(millis) === '00:00:00', `${tag}: daily timestamp must be New York midnight`);
    } else {
      ensure(millis % interval === 0, `${tag}: timestamp interval alignment mismatch`);
    }
    if (Number.isFinite(previous)) {
      const gap = millis - previous;
      if (gap > interval) gaps++;
      largestGapSeconds = Math.max(largestGapSeconds, gap / 1000);
    }
    previous = millis;
    for (const key of ['o', 'h', 'l', 'c', 'v', 'n', 'vw']) ensure(typeof b[key] === 'number' && Number.isFinite(b[key]), `${tag}: ${key} must be finite numeric`);
    for (const key of ['o', 'h', 'l', 'c', 'vw']) ensure(b[key] > 0, `${tag}: ${key} must be positive`);
    ensure(b.l <= b.h && b.o >= b.l && b.o <= b.h && b.c >= b.l && b.c <= b.h, `${tag}: invalid OHLC bounds`);
    ensure(b.v >= 0, `${tag}: negative volume`);
    ensure(Number.isSafeInteger(b.n) && b.n >= 0, `${tag}: invalid trade count`);
    const date = NY_DATE.format(millis);
    dates.add(date);
    months.add(date.slice(0, 7));
    const year = date.slice(0, 4);
    years[year] = (years[year] || 0) + 1;
  }
  return { count: bars.length, first: new Date(bars[0].t).toISOString(), last: new Date(bars.at(-1).t).toISOString(), datesNewYork: dates.size, monthsNewYork: months.size, barsByYearNewYork: years, gapsLongerThanInterval: gaps, largestGapSeconds };
}

function confinedPath(root, path) {
  ensure(typeof path === 'string' && path.length > 0 && !isAbsolute(path), 'Manifest requires relative file paths');
  const absolute = resolve(root, path);
  const rel = relative(root, absolute);
  ensure(rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel), 'Manifest path escapes dataset directory');
  return absolute;
}

function checkMetadata(m, timeframe, symbols, label) {
  ensure(m && typeof m === 'object', `${label}: missing metadata`);
  ensure(m.timeframe === timeframe, `${label}: timeframe mismatch`);
  ensure(m.feed === 'sip' && m.adjustment === 'raw', `${label}: feed or adjustment mismatch`);
  const actualSymbols = Array.isArray(m.symbols) ? m.symbols : Object.keys(m.symbols || {});
  ensure(same([...actualSymbols].sort(), [...symbols].sort()), `${label}: symbol set mismatch`);
  const start = timestamp(m.requestedStart, `${label} requestedStart`);
  const end = timestamp(m.requestedEnd, `${label} requestedEnd`);
  ensure(start < end, `${label}: invalid requested bounds`);
}

function compareCsv(text, bars, label) {
  const lines = text.split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  ensure(lines.shift() === `timestamp_utc,${SCHEMA.join(',')}`, `${label}: CSV schema mismatch`);
  ensure(lines.length === bars.length, `${label}: CSV row count mismatch`);
  for (let i = 0; i < lines.length; i++) {
    const columns = lines[i].split(',');
    ensure(columns.length === 9 && columns[0] === new Date(bars[i].t).toISOString(), `${label}: CSV timestamp mismatch at row ${i + 1}`);
    const raw = values(bars[i]);
    ensure(columns.slice(1).every((cell, j) => cell.trim() !== '' && Number(cell) === raw[j]), `${label}: CSV numeric mismatch at row ${i + 1}`);
  }
}

function parseChunk(text, label) {
  const lines = text.trim().split(/\r?\n/);
  ensure(lines.shift().trim() === 'return {' && lines.pop().trim() === '}', `${label}: unsupported Luau chunk envelope`);
  return lines.map((line, i) => {
    const match = /^\s*\{([^{}]+)\},\s*$/.exec(line);
    ensure(match, `${label}: invalid Luau row ${i + 1}`);
    const cells = match[1].split(',');
    ensure(cells.length === 8 && cells.every(s => /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(s.trim())), `${label}: invalid Luau numeric row ${i + 1}`);
    const row = cells.map(Number);
    ensure(row.every(Number.isFinite), `${label}: nonfinite Luau numeric row`);
    return row;
  });
}

async function compareLuau(groupRoot, symbol, entry, bars, timeframe, hashedPaths) {
  const label = `${symbol} Luau`;
  const loader = await readFile(confinedPath(groupRoot, entry.modulePath), 'utf8');
  const chunksMatch = /local chunkNames = \{([^}]*)\}/.exec(loader);
  ensure(chunksMatch, `${label}: missing explicit chunk list`);
  const chunkNames = JSON.parse(`[${chunksMatch[1]}]`);
  ensure(chunkNames.length === entry.chunkCount && new Set(chunkNames).size === chunkNames.length, `${label}: chunk count mismatch`);
  ensure(chunkNames.every((s, i) => s === `Chunk${String(i + 1).padStart(3, '0')}`), `${label}: nonsequential chunk list`);
  const schemaMatch = /\bschema = \{([^}]*)\}/.exec(loader);
  ensure(schemaMatch && same(JSON.parse(`[${schemaMatch[1]}]`), SCHEMA), `${label}: schema mismatch`);
  for (const [key, value] of Object.entries({ symbol, timeframe, feed: 'sip', adjustment: 'raw' })) {
    ensure(new RegExp(`\\b${key}\\s*=\\s*${JSON.stringify(value)}`).test(loader), `${label}: ${key} metadata mismatch`);
  }
  ensure(new RegExp(`assert\\(#bars == ${bars.length},`).test(loader), `${label}: missing exact row-count assertion`);
  ensure(new RegExp(`\\bcount\\s*=\\s*${bars.length}\\b`).test(loader), `${label}: count metadata mismatch`);
  const folder = `roblox/${symbol}`;
  const actualChunks = (await readdir(join(groupRoot, folder))).filter(n => /^Chunk.*\.luau$/.test(n)).sort();
  ensure(same(actualChunks, chunkNames.map(n => `${n}.luau`)), `${label}: unexpected/missing chunk files`);
  let index = 0;
  for (const name of chunkNames) {
    const path = `${folder}/${name}.luau`;
    ensure(hashedPaths.has(path), `${label}: missing hash coverage for ${path}`);
    const chunkRows = parseChunk(await readFile(confinedPath(groupRoot, path), 'utf8'), `${label}/${name}`);
    ensure(chunkRows.length > 0 && chunkRows.length <= 1000, `${label}: invalid chunk size`);
    for (const row of chunkRows) {
      ensure(index < bars.length && same(row, values(bars[index])), `${label}: numeric mismatch at row ${index + 1}`);
      index++;
    }
  }
  ensure(index === bars.length, `${label}: total row count mismatch`);
}

/** Offline, read-only audit. Only the CLI writes verification.json after success. */
export async function auditDataset(root, { originalRoot = join(dirname(resolve(root)), 'alpaca-2021-10-04_2026-10-02') } = {}) {
  root = resolve(root);
  const result = { ok: true, auditedAtUTC: new Date().toISOString(), datasetRoot: root, groups: [], totalStoredBars: 0, totalExportFilesVerified: 0, note: 'Export rows exactly equal raw input rows; no additional filled rows exist in CSV or Luau. Source completeness is not independently proven. Market gaps and daily DST intervals are diagnostics.' };
  for (const [id, timeframe, symbols] of GROUPS) {
    const groupRoot = join(root, id);
    const source = await json(join(groupRoot, 'source-metadata.json'));
    const manifest = await json(join(groupRoot, 'manifest.json'));
    checkMetadata(source, timeframe, symbols, `${id} source`);
    checkMetadata(manifest, timeframe, symbols, `${id} manifest`);
    ensure(Date.parse(source.requestedStart) === Date.parse(manifest.requestedStart) && Date.parse(source.requestedEnd) === Date.parse(manifest.requestedEnd), `${id}: source/manifest range mismatch`);
    ensure(same(manifest.csvSchema, ['timestamp_utc', ...SCHEMA]) && same(manifest.robloxSchema, SCHEMA), `${id}: manifest schema mismatch`);
    ensure(Array.isArray(manifest.files) && manifest.files.length > 0, `${id}: missing file manifest`);
    const hashedPaths = new Set();
    for (const f of manifest.files) {
      ensure(!hashedPaths.has(f.path), `${id}: duplicate file manifest entry`);
      hashedPaths.add(f.path);
      const data = await readFile(confinedPath(groupRoot, f.path));
      ensure(data.length === f.bytes && hash(data) === f.sha256, `${id}/${f.path}: file bytes/SHA256 hash mismatch`);
    }
    const group = { id, timeframe, requestedStart: source.requestedStart, requestedEnd: source.requestedEnd, exportFilesVerified: manifest.files.length, totalBars: 0, symbols: {} };
    for (const symbol of symbols) {
      const rawPath = `raw/${symbol}-${timeframe}.json`;
      const rawBytes = await readFile(join(groupRoot, rawPath));
      const bars = JSON.parse(rawBytes.toString('utf8'));
      const summary = auditRawBars(bars, timeframe, source);
      const entry = manifest.symbols[symbol];
      ensure(entry.count === summary.count && entry.first === summary.first && entry.last === summary.last, `${id}/${symbol}: manifest bar summary mismatch`);
      ensure(entry.csvPath === `${symbol}.csv` && entry.modulePath === `roblox/${symbol}/init.luau`, `${id}/${symbol}: unexpected export paths`);
      for (const path of [entry.csvPath, entry.modulePath]) ensure(hashedPaths.has(path), `${id}/${symbol}: missing hash coverage for ${path}`);
      if (source.series !== undefined) {
        ensure(Array.isArray(source.series), `${id}: invalid source series metadata`);
        const series = source.series.filter(s => s.symbol === symbol);
        ensure(series.length === 1, `${id}/${symbol}: missing/duplicate source series metadata`);
        const s = series[0];
        ensure(s.file === rawPath && s.count === bars.length && Date.parse(s.first) === Date.parse(summary.first) && Date.parse(s.last) === Date.parse(summary.last), `${id}/${symbol}: source summary mismatch`);
        ensure(s.sha256 === hash(rawBytes), `${id}/${symbol}: raw SHA256 mismatch`);
      }
      compareCsv(await readFile(join(groupRoot, entry.csvPath), 'utf8'), bars, `${id}/${symbol}`);
      await compareLuau(groupRoot, symbol, entry, bars, timeframe, hashedPaths);
      if (id === 'hourly-combined') {
        const earlierSource = await json(join(root, 'hourly-earlier', 'source-metadata.json'));
        const originalSource = await json(join(originalRoot, 'source-metadata.json'));
        ensure(originalSource.timeframe === '1Hour' && originalSource.feed === 'sip' && originalSource.adjustment === 'raw', 'Original source metadata mismatch');
        ensure(Date.parse(earlierSource.requestedEnd) + 1000 === Date.parse(originalSource.requestedStart), 'Combined source boundary mismatch');
        ensure(Date.parse(source.requestedStart) === Date.parse(earlierSource.requestedStart) && Date.parse(source.requestedEnd) === Date.parse(originalSource.requestedEnd), 'Combined requested bounds mismatch');
        const earlier = await json(join(root, 'hourly-earlier', 'raw', `${symbol}-1Hour.json`));
        const original = await json(join(originalRoot, 'raw', `${symbol}-1Hour.json`));
        ensure(bars.length === earlier.length + original.length, `${symbol}: concatenation row count mismatch`);
        for (let i = 0; i < bars.length; i++) {
          const expected = i < earlier.length ? earlier[i] : original[i - earlier.length];
          ensure(same(values(bars[i]), values(expected)), `${symbol}: concatenation mismatch at row ${i + 1}`);
        }
        summary.concatenationVerified = true;
        summary.earlierBars = earlier.length;
        summary.frozenOriginalBars = original.length;
      }
      summary.rawSha256 = hash(rawBytes);
      group.symbols[symbol] = summary;
      group.totalBars += bars.length;
    }
    ensure(group.totalBars === manifest.totalBars, `${id}: manifest total count mismatch`);
    result.groups.push(group);
    result.totalStoredBars += group.totalBars;
    result.totalExportFilesVerified += manifest.files.length;
  }
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.argv[2];
  if (!root) {
    console.error('Usage: node audit-supplement.mjs <dataset-root>');
    process.exitCode = 1;
  } else {
    try {
      const result = await auditDataset(root);
      const output = join(resolve(root), 'verification.json');
      await writeFile(output, JSON.stringify(result, null, 2) + '\n');
      console.log(JSON.stringify({ ok: result.ok, verificationPath: output, totalStoredBars: result.totalStoredBars, exportFilesVerified: result.totalExportFilesVerified, groups: result.groups.map(g => ({ id: g.id, timeframe: g.timeframe, totalBars: g.totalBars, symbols: g.symbols })) }));
    } catch (error) {
      console.error(`Audit failed: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
