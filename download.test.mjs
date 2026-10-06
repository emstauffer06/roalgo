import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCredentials, fetchHourlyBars } from './download.mjs';

const credentials = { key: `PK${'A'.repeat(18)}`, secret: 'b'.repeat(40) };
const candle = (t) => ({t, o:100, h:102, l:99, c:101, v:200, n:4, vw:100.5});

test('accepts longer current key pairs instead of assuming legacy lengths',()=>{
  const current={key:`PK${'C'.repeat(24)}`,secret:'d'.repeat(44)};
  assert.deepEqual(parseCredentials(`Key: ${current.key}\nSecret ${current.secret}`),current);
});

test('reads labeled or plain credentials without echoing malformed secret text', () => {
  assert.deepEqual(parseCredentials(`API KEY: ${credentials.key}\nSECRET KEY: ${credentials.secret}`), credentials);
  assert.deepEqual(parseCredentials(`\uFEFF${credentials.key}\r\n${credentials.secret}\r\n`), credentials);
  assert.throws(() => parseCredentials('private value which must never appear in diagnostics'), {message:'Credential file must contain one Alpaca key ID and one secret.'});
  assert.throws(() => parseCredentials(`${credentials.key}\n${credentials.key}\n${credentials.secret}`));
});

test('follows every page using a read-only fixed Alpaca destination and retains request settings', async () => {
  const urls=[];
  const pages=[{bars:{SPY:[candle('2021-10-04T14:00:00Z')]},next_page_token:'page-2'},
    {bars:{SPY:[candle('2021-10-04T15:00:00Z')]},next_page_token:null}];
  const result=await fetchHourlyBars({symbol:'SPY',start:'2021-10-04T04:00:00Z',end:'2026-10-03T04:00:00Z',credentials,
    fetchImpl:async (url, options) => {
      urls.push(new URL(url));
      assert.equal(options.method,'GET');
      assert.equal(options.redirect,'error');
      assert.equal(options.headers['APCA-API-KEY-ID'], credentials.key);
      assert.equal(options.headers['APCA-API-SECRET-KEY'], credentials.secret);
      return new Response(JSON.stringify(pages.shift()),{status:200});
    }});
  assert.equal(result.length,2);
  assert.deepEqual(result.map(b=>b.t),['2021-10-04T14:00:00Z','2021-10-04T15:00:00Z']);
  assert.equal(urls.length,2);
  for(const u of urls){
    assert.equal(u.origin,'https://data.alpaca.markets');
    assert.equal(u.pathname,'/v2/stocks/bars');
    assert.equal(u.searchParams.get('feed'),'sip');
    assert.equal(u.searchParams.get('adjustment'),'raw');
    assert.equal(u.searchParams.get('timeframe'),'1Hour');
    assert.equal(u.searchParams.get('start'),'2021-10-04T04:00:00Z');
    assert.equal(u.searchParams.get('end'),'2026-10-03T04:00:00Z');
    assert.equal(u.searchParams.get('limit'),'10000');
  }
  assert.equal(urls[0].searchParams.get('page_token'),null);
  assert.equal(urls[1].searchParams.get('page_token'),'page-2');
});

test('fails on denial without exposing response body or authentication values', async () => {
  await assert.rejects(fetchHourlyBars({symbol:'QQQ',start:'2021-10-04T04:00:00Z',end:'2026-10-03T04:00:00Z',credentials,
    fetchImpl:async()=>new Response(credentials.secret,{status:403})}), {message:'Alpaca historical bars request failed (HTTP 403).'});
});

test('fails if provider repeats a pagination token rather than silently duplicating bars', async () => {
  await assert.rejects(fetchHourlyBars({symbol:'SPY',start:'2021-10-04T04:00:00Z',end:'2026-10-03T04:00:00Z',credentials,
    fetchImpl:async()=>new Response(JSON.stringify({bars:{SPY:[]},next_page_token:'repeat'}),{status:200})}), /Repeated pagination token/);
});

test('retries a transient rate limit and accepts only the successful response',async()=>{
  let attempts=0;
  const bars=await fetchHourlyBars({symbol:'SPY',start:'2021-10-04T04:00:00Z',end:'2026-10-03T04:00:00Z',credentials,sleep:async()=>{},
    fetchImpl:async()=> ++attempts===1 ? new Response('',{status:429}) : new Response(JSON.stringify({bars:{SPY:[candle('2021-10-04T14:00:00Z')]},next_page_token:null}),{status:200})});
  assert.equal(attempts,2);
  assert.equal(bars.length,1);
});
