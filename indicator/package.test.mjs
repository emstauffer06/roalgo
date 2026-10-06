import test from 'node:test';
import assert from 'node:assert/strict';
const pkg=await import('./package.mjs').catch(()=>null);
test('packager exists and escapes source without dropping literal text',()=>{
  assert.ok(pkg,'packager missing');
  const source='return "<node> & ]] >"';
  const xml=pkg.modelXML([{path:'src/Test',source,sha256:'abc'}],false);
  assert.match(xml,/class="ModuleScript"/);
  assert.match(xml,/&lt;node&gt; &amp;/);
  assert.doesNotMatch(xml,/class="Script"/);
});
test('plugin version includes guarded bootstrap; model is inert',()=>{
  assert.ok(pkg);
  const files=[{path:'src/App',source:'return {}',sha256:'abc'}];
  assert.match(pkg.modelXML(files,true),/PlaceId ~= 0 then return/);
  assert.match(pkg.modelXML(files,true),/RoAlgo/);
  assert.doesNotMatch(pkg.modelXML(files,false),/CreateToolbar/);
  assert.throws(()=>pkg.modelXML([{path:'../Private',source:'x'}]),/path/);
});
