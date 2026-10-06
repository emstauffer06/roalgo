import test from 'node:test';
import assert from 'node:assert/strict';

const implementation = await import('./bridge.mjs').catch(() => null);
test('transport implementation exists', () => assert.ok(implementation, 'indicator bridge is not implemented'));
test('CSV parser rejects invalid OHLC, duplicates and unsorted data', () => {
  assert.ok(implementation);
  const head='timestamp_utc,timestamp_unix,open,high,low,close,volume,trade_count,vwap\n';
  const row='2024-01-02T14:30:00.000Z,1704205800,100,102,99,101,1000,5,100.5\n';
  assert.equal(implementation.parseCSV(head+row).length,1);
  assert.throws(()=>implementation.parseCSV(head+row+row),/order|duplicate/);
  assert.throws(()=>implementation.parseCSV(head+row.replace(',102,99,',',98,99,')),/OHLC/);
  assert.throws(()=>implementation.parseCSV(head+row.replace(',1000,',',-1,')),/volume/);
});
test('New York regular-hours conversion handles DST',()=>{
  assert.ok(implementation);
  assert.equal(implementation.nyTime(1704205800).minute,570);
  assert.equal(implementation.nyTime(Date.parse('2024-07-02T13:30:00Z')/1000).minute,570);
  assert.equal(implementation.nyTime(Date.parse('2024-07-02T13:25:00Z')/1000).minute,565);
});
test('query validation constrains symbols, sessions and cutoff',()=>{
  assert.ok(implementation);
  assert.deepEqual(implementation.validateQuery(new URLSearchParams('symbol=QQQ&days=5&end=2024-12-31')),{symbol:'QQQ',days:5,end:'2024-12-31'});
  for (const q of ['symbol=../secret','days=10000','end=2026-99-99','end=2026-10-02','days=NaN']) assert.throws(()=>implementation.validateQuery(new URLSearchParams(q)));
});
test('session selection is chronological and excludes pre/post market',()=>{
  assert.ok(implementation);
  const rows=[{t:1704205500,o:100,h:102,l:99,c:101,v:500},{t:1704205800,o:100,h:102,l:99,c:101,v:500},{t:1704229200,o:100,h:102,l:99,c:101,v:500}];
  const out=implementation.selectBars(rows,{symbol:'SPY',days:5,end:'2024-12-31'});
  assert.equal(out.bars.length,1);
  assert.equal(out.bars[0].day,'2024-01-02');
  assert.match(out.bars[0].label,/09:30/);
});
test('exchange early-close schedule excludes afternoon extended trading',()=>{
  const make=t=>({t:Date.parse(t)/1000,o:100,h:102,l:99,c:101,v:500});
  const rows=[make('2024-12-24T17:55:00Z'),make('2024-12-24T18:00:00Z'),make('2024-12-24T19:00:00Z')];
  assert.equal(implementation.selectBars(rows,{symbol:'SPY',days:5,end:'2024-12-31'}).bars.length,1);
});
test('HTTP server binds loopback and rejects unlisted routes and bad results',async()=>{
  assert.ok(implementation);
  const server=implementation.createServer({load:()=>({bars:[],metadata:{}})});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  try {
    const base='http://127.0.0.1:'+server.address().port;
    assert.equal(server.address().address,'127.0.0.1');
    assert.equal((await fetch(base+'/health')).status,200);
    assert.equal((await fetch(base+'/bars?symbol=../secret')).status,400);
    assert.equal((await fetch(base+'/private-file')).status,404);
    assert.equal((await fetch(base+'/result',{method:'POST',body:JSON.stringify({name:'../../secret',result:{}})})).status,400);
  } finally {await new Promise(r=>server.close(r));}
});
