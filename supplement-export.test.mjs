import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { exportDataset } from './export-data.mjs';

const bar = {t:'2024-01-02T14:00:00Z',o:100,h:103,l:99,c:102,v:1200,n:10,vw:101};
const temporary = () => mkdtemp(join(tmpdir(), 'supplement-export-'));

test('explicit five-minute export keeps five-minute timestamps and labels both formats correctly', async () => {
  const outputDir = await temporary();
  await exportDataset({barsBySymbol:{SPY:[bar,{...bar,t:'2024-01-02T14:05:00Z'}]},outputDir,timeframe:'5Min',metadata:{timeframe:'1Hour'}});
  const manifest = JSON.parse(await readFile(join(outputDir,'manifest.json'),'utf8'));
  assert.equal(manifest.timeframe,'5Min');
  assert.equal(manifest.symbols.SPY.count,2);
  const csv = await readFile(join(outputDir,'SPY.csv'),'utf8');
  assert.match(csv,/2024-01-02T14:05:00.000Z,1704204300/);
  const loader = await readFile(join(outputDir,'roblox/SPY/init.luau'),'utf8');
  assert.match(loader,/timeframe = "5Min"/);
});

test('daily export identifies day-start dates and warns against using unfinished daily bars', async () => {
  const outputDir = await temporary();
  await exportDataset({barsBySymbol:{QQQ:[{...bar,t:'2024-01-02T05:00:00Z'}]},outputDir,timeframe:'1Day'});
  const manifest = JSON.parse(await readFile(join(outputDir,'manifest.json'),'utf8'));
  assert.equal(manifest.timeframe,'1Day');
  assert.match(manifest.availabilityWarning,/completed.*day/i);
  assert.match(await readFile(join(outputDir,'roblox/QQQ/init.luau'),'utf8'),/timeframe = "1Day"/);
});

test('exports approved context ETFs without relabeling their source values', async () => {
  const outputDir = await temporary();
  await exportDataset({barsBySymbol:{IWM:[bar],TLT:[{...bar,c:100}]},outputDir,timeframe:'1Hour'});
  const manifest = JSON.parse(await readFile(join(outputDir,'manifest.json'),'utf8'));
  assert.deepEqual(Object.keys(manifest.symbols),['IWM','TLT']);
  assert.match(await readFile(join(outputDir,'TLT.csv'),'utf8'),/,100,103,99,100,1200,10,101/);
});

test('rejects unsupported timeframe before producing an export', async () => {
  const outputDir = await temporary();
  await assert.rejects(exportDataset({barsBySymbol:{SPY:[bar]},outputDir,timeframe:'Tick'}),/timeframe/i);
  assert.deepEqual(await readdir(outputDir),[]);
});
