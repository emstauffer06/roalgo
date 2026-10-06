import fs from 'node:fs/promises';
import path from 'node:path';
import {exportDataset} from './export-data.mjs';

const root=path.resolve(process.argv[2] ?? 'data/alpaca-2021-10-04_2026-10-02');
const metadata=JSON.parse(await fs.readFile(path.join(root,'source-metadata.json'),'utf8'));
const barsBySymbol={};
for(const symbol of ['SPY','QQQ']) {
  const bars=JSON.parse(await fs.readFile(path.join(root,'raw',`${symbol}-1Hour.json`),'utf8'));
  if(bars.some(bar=>Date.parse(bar.t)<Date.parse(metadata.requestedStart) || Date.parse(bar.t)>Date.parse(metadata.requestedEnd))) {
    throw new Error(`${symbol} contains bars outside the requested interval.`);
  }
  barsBySymbol[symbol]=bars;
}
console.log(JSON.stringify(await exportDataset({barsBySymbol,outputDir:root,metadata}),null,2));
