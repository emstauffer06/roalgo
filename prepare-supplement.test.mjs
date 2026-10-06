import test from 'node:test';
import assert from 'node:assert/strict';
const implementation = await import('./prepare-supplement.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
const merge = (...args) => {
  assert.equal(typeof implementation.mergeHourlyBars, 'function', 'mergeHourlyBars is missing');
  return implementation.mergeHourlyBars(...args);
};
const earlier = {t:'2021-10-01T23:00:00Z',o:100,h:102,l:99,c:101,v:10,n:2,vw:100.5};
const later = {t:'2021-10-04T08:00:00Z',o:101,h:103,l:100,c:102,v:12,n:3,vw:101.5};

test('combines disjoint hourly history without filling the intervening market closure', () => {
  const result = merge([earlier], [later]);
  assert.deepEqual(result, [earlier, later]);
  assert.equal(result.length, 2);
});
test('rejects overlap instead of silently dropping or replacing the frozen original candle', () => {
  assert.throws(() => merge([earlier,later],[later]), /overlap|order/i);
});
test('rejects bad input order within the earlier source', () => {
  assert.throws(() => merge([later,earlier],[{...later,t:'2021-10-05T08:00:00Z'}]), /order/i);
});
test('requires both sources for a combined history', () => {
  assert.throws(() => merge([], [later]), /nonempty/i);
});

