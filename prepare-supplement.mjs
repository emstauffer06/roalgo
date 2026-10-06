import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { exportDataset } from './export-data.mjs';

const PROJECT = path.dirname(fileURLToPath(import.meta.url));
const ORIGINAL = path.join(PROJECT, 'data/alpaca-2021-10-04_2026-10-02');
const DEFAULT_ROOT = path.join(PROJECT, 'data/alpaca-supplement-2016-01-01_2026-10-02');
const GROUPS = [
  {id:'five-minute',timeframe:'5Min',symbols:['SPY','QQQ']},
  {id:'hourly-earlier',timeframe:'1Hour',symbols:['SPY','QQQ']},
  {id:'daily-context',timeframe:'1Day',symbols:['SPY','QQQ']},
  {id:'hourly-context',timeframe:'1Hour',symbols:['IWM','TLT']},
];
const sha = value => createHash('sha256').update(value).digest('hex');
const json = value => JSON.stringify(value, null, 2) + '\n';

export function mergeHourlyBars(earlier, later) {
  if (!Array.isArray(earlier) || !earlier.length || !Array.isArray(later) || !later.length) throw new Error('Both hourly sources must be nonempty');
  let previous = -Infinity;
  const merged = earlier.concat(later);
  for (const bar of merged) {
    const time = Date.parse(bar?.t);
    if (!Number.isFinite(time) || time <= previous) throw new Error('Hourly source overlap or invalid timestamp order');
    previous = time;
  }
  return merged;
}

async function immutableWrite(file, content) {
  try {
    const existing = await fs.readFile(file, 'utf8');
    if (existing !== content) throw new Error('Existing derived raw data differs; choose a new dataset directory');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    await fs.mkdir(path.dirname(file), {recursive:true});
    await fs.writeFile(file, content, {encoding:'utf8',flag:'wx'});
  }
}

function checkBounds(bars, metadata) {
  const start = Date.parse(metadata.requestedStart);
  const end = Date.parse(metadata.requestedEnd);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end) throw new Error('Missing or invalid source date range');
  if (!Array.isArray(bars) || !bars.length) throw new Error('Empty source series');
  for (const bar of bars) {
    const t = Date.parse(bar.t);
    if (!Number.isFinite(t) || t < start || t > end) throw new Error('Source row outside requested range');
  }
}

export async function prepareSupplement(root = DEFAULT_ROOT, originalRoot = ORIGINAL) {
  root = path.resolve(root);
  originalRoot = path.resolve(originalRoot);
  if (root === originalRoot) throw new Error('Supplement output must differ from original dataset');
  const groups = [];
  const metadataByGroup = new Map();
  let downloadedBars = 0;
  for (const spec of GROUPS) {
    const groupDir = path.join(root, spec.id);
    const metadata = JSON.parse(await fs.readFile(path.join(groupDir,'source-metadata.json'),'utf8'));
    if (metadata.timeframe !== spec.timeframe || metadata.feed !== 'sip' || metadata.adjustment !== 'raw') throw new Error('Source feed/timeframe/adjustment mismatch');
    metadataByGroup.set(spec.id, metadata);
    const barsBySymbol = {};
    const rawFiles = [];
    for (const symbol of spec.symbols) {
      const relative = 'raw/' + symbol + '-' + spec.timeframe + '.json';
      const bytes = await fs.readFile(path.join(groupDir,relative));
      const bars = JSON.parse(bytes);
      checkBounds(bars, metadata);
      barsBySymbol[symbol] = bars;
      rawFiles.push({path:relative,bytes:bytes.length,sha256:sha(bytes)});
    }
    const result = await exportDataset({barsBySymbol,outputDir:groupDir,metadata:{...metadata,rawFiles},timeframe:spec.timeframe});
    downloadedBars += result.totalBars;
    groups.push({id:spec.id,timeframe:spec.timeframe,totalBars:result.totalBars,symbols:result.symbols,manifestPath:spec.id+'/manifest.json'});
    console.log(JSON.stringify({exported:spec.id,bars:result.totalBars}));
  }

  const earlierMetadata = metadataByGroup.get('hourly-earlier');
  const originalMetadata = JSON.parse(await fs.readFile(path.join(originalRoot,'source-metadata.json'),'utf8'));
  if (Date.parse(earlierMetadata.requestedEnd) + 1000 !== Date.parse(originalMetadata.requestedStart)) throw new Error('Earlier download must end exactly one second before frozen original range');
  const combinedDir = path.join(root,'hourly-combined');
  const combined = {};
  const sources = [];
  const rawFiles = [];
  for (const symbol of ['SPY','QQQ']) {
    const filename = symbol + '-1Hour.json';
    const earlierPath = path.join(root,'hourly-earlier/raw',filename);
    const originalPath = path.join(originalRoot,'raw',filename);
    const earlierBytes = await fs.readFile(earlierPath);
    const originalBytes = await fs.readFile(originalPath);
    combined[symbol] = mergeHourlyBars(JSON.parse(earlierBytes), JSON.parse(originalBytes));
    const content = JSON.stringify(combined[symbol]);
    await immutableWrite(path.join(combinedDir,'raw',filename),content);
    rawFiles.push({path:'raw/'+filename,bytes:Buffer.byteLength(content),sha256:sha(content)});
    sources.push({symbol,earlierPath:path.relative(root,earlierPath).replaceAll('\\','/'),earlierSha256:sha(earlierBytes),originalPath,originalSha256:sha(originalBytes)});
  }
  const combinedMetadata = {
    provider:'Alpaca Market Data API',feed:'sip',adjustment:'raw',timeframe:'1Hour',
    symbols:['SPY','QQQ'],requestedStart:earlierMetadata.requestedStart,
    requestedEnd:originalMetadata.requestedEnd,
    derivation:'Exact chronological concatenation of earlier download and frozen original hourly source. No resampling, filling, repricing, or replacement.',
    timestampMeaning:'UTC bar-start timestamps.',
    sessionPolicy:'Provider-native hourly aggregates across available sessions, including extended hours; gaps remain unfilled.',
    sources,rawFiles,
  };
  await immutableWrite(path.join(combinedDir,'source-metadata.json'),json(combinedMetadata));
  const result = await exportDataset({barsBySymbol:combined,outputDir:combinedDir,metadata:combinedMetadata,timeframe:'1Hour'});
  groups.push({id:'hourly-combined',timeframe:'1Hour',totalBars:result.totalBars,symbols:result.symbols,manifestPath:'hourly-combined/manifest.json'});
  const summary = {
    schemaVersion:1,originalDataset:originalRoot,
    originalManifestSha256:sha(await fs.readFile(path.join(originalRoot,'manifest.json'))),
    downloadedBars,derivedCombinedBars:result.totalBars,
    totalExportedBars:groups.reduce((sum,g)=>sum+g.totalBars,0),groups,
    warning:'totalExportedBars includes the derived combined view and duplicates earlier hourly records. downloadedBars counts only newly fetched rows.',
    featureEngineeringPerformed:false,modelTrainingPerformed:false,robloxStudioImportPerformed:false,
  };
  await fs.writeFile(path.join(root,'supplement-manifest.json'),json(summary),'utf8');
  console.log(JSON.stringify({prepared:true,downloadedBars,derivedCombinedBars:result.totalBars,totalExportedBars:summary.totalExportedBars}));
  return summary;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  prepareSupplement(process.argv[2]).catch(error => {
    console.error(error instanceof Error ? error.message : 'Supplement export failed');
    process.exitCode=1;
  });
}
