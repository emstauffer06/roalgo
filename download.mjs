import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export function parseCredentials(text) {
  const tokens = text.match(/\b[A-Za-z0-9]{16,128}\b/g) ?? [];
  const keys = tokens.filter(token=>/^[AP]K[A-Z0-9]{14,62}$/.test(token));
  const secrets = tokens.filter(token=>!keys.includes(token) && token.length>=32);
  if (keys.length !== 1 || secrets.length !== 1) {
    throw new Error('Credential file must contain one Alpaca key ID and one secret.');
  }
  return { key: keys[0], secret: secrets[0] };
}

export async function fetchHourlyBars({symbol, start, end, credentials, fetchImpl=fetch,
  sleep=(ms)=>new Promise(resolve=>setTimeout(resolve,ms)), onPage=()=>{}}) {
  if (!['SPY','QQQ'].includes(symbol) || !Number.isFinite(Date.parse(start)) ||
      !Number.isFinite(Date.parse(end)) || Date.parse(start) >= Date.parse(end)) {
    throw new Error('Invalid historical data request.');
  }
  const bars=[];
  const seen=new Set();
  let pageToken=null;
  let page=0;
  do {
    const url=new URL('https://data.alpaca.markets/v2/stocks/bars');
    for (const [k,v] of Object.entries({symbols:symbol,timeframe:'1Hour',start,end,
      feed:'sip',adjustment:'raw',limit:'10000',sort:'asc'})) url.searchParams.set(k,v);
    if (pageToken) url.searchParams.set('page_token',pageToken);
    let response;
    for (let attempt=0; attempt<3; attempt++) {
      try {
        response=await fetchImpl(url,{method:'GET',redirect:'error',
          headers:{'APCA-API-KEY-ID':credentials.key,'APCA-API-SECRET-KEY':credentials.secret},
          signal:AbortSignal.timeout(30000)});
      } catch {
        if(attempt===2) throw new Error('Alpaca connection failed; no credential values were logged.');
        await sleep(1000*(attempt+1));
        continue;
      }
      if(response.ok) break;
      if ((response.status===429 || response.status>=500) && attempt<2) {
        await response.body?.cancel();
        await sleep(1000*(attempt+1));
      } else {
        throw new Error(`Alpaca historical bars request failed (HTTP ${response.status}).`);
      }
    }
    if(!response?.ok) throw new Error('Alpaca historical bars request did not complete.');
    let data;
    try { data=await response.json(); }
    catch { throw new Error('Alpaca returned invalid JSON.'); }
    if(!data || typeof data.bars!=='object' || data.bars===null) throw new Error('Alpaca response has no bars object.');
    const batch=data.bars[symbol] ?? [];
    if(!Array.isArray(batch)) throw new Error('Alpaca returned an invalid bars array.');
    bars.push(...batch);
    onPage({symbol,page:++page,received:batch.length,total:bars.length});
    pageToken=data.next_page_token;
    if(pageToken) {
      if(typeof pageToken!=='string' || seen.has(pageToken)) throw new Error('Repeated pagination token or invalid token.');
      seen.add(pageToken);
    }
  } while(pageToken);
  return bars;
}

async function main() {
  const [credentialsPath, outputPath] = process.argv.slice(2);
  if(!credentialsPath || !outputPath) throw new Error('Usage: node download.mjs <local-credentials-file> <new-output-directory>');
  let credentialText;
  try { credentialText=await fs.readFile(credentialsPath,'utf8'); }
  catch { throw new Error('Could not read the specified local credential file.'); }
  const credentials=parseCredentials(credentialText);
  credentialText='';
  const start='2021-10-04T04:00:00Z';
  const end='2026-10-03T04:00:00Z';
  const outputDir=path.resolve(outputPath);
  await fs.mkdir(path.join(outputDir,'raw'),{recursive:true});
  const metadata={provider:'Alpaca Market Data API',endpoint:'https://data.alpaca.markets/v2/stocks/bars',
    timeframe:'1Hour',feed:'sip',adjustment:'raw',symbols:['SPY','QQQ'],
    requestedStart:start,requestedEnd:end,requestedDatesNewYork:'2021-10-04 through 2026-10-02',
    timestamps:'UTC bar-start times; chronological and not yet resampled',
    sessionPolicy:'Provider-native hourly bars across available sessions, including extended hours; not regular-session-only.',
    forecastWarning:'Eight rows are not necessarily eight elapsed hours. Gaps and partial market-session boundary bars require an explicit target definition.',
    retrievedAtUTC:new Date().toISOString()};
  console.log('Local credentials parsed. Requesting historical data from Alpaca only.');
  for (const symbol of metadata.symbols) {
    const bars=await fetchHourlyBars({symbol,start,end,credentials,
      onPage:info=>console.log(JSON.stringify(info))});
    if(!bars.length) throw new Error(`Alpaca returned no ${symbol} bars for the requested range.`);
    const file=path.join(outputDir,'raw',`${symbol}-1Hour.json`);
    await fs.writeFile(file,JSON.stringify(bars),{encoding:'utf8',flag:'wx'});
    console.log(JSON.stringify({saved:symbol,rows:bars.length,first:bars[0].t,last:bars.at(-1).t}));
  }
  await fs.writeFile(path.join(outputDir,'source-metadata.json'),JSON.stringify(metadata,null,2)+'\n',{flag:'wx'});
  console.log('Historical download complete. Export and validation are the next step.');
}

if(process.argv[1] && import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error=>{
    // Do not serialize requests, headers, responses, or full exception objects.
    const message=typeof error?.message==='string' ? error.message : 'Download failed.';
    console.error(message);
    process.exitCode=1;
  });
}
