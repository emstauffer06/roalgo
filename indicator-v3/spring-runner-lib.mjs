// Spring indicator runner pipeline (contract spring-indicator-contract.md: D15, D18, D19, section 2, Runner contract).
// 1. verifySpringInputs: refit-saved verifySavedCapture plus the D15 / section 2 checks it lacks.
// 2. minimiseRecords + prepareHarness: Luau data modules holding only the allowlisted fields, in an OS temp run dir,
//    beside copies of the src modules the run needs (hashed) and a generated runner.
// 3. runLuauHarness: luau.exe without --codegen (D19), stdout decoded with a StringDecoder, ASCII-only @@JSON (D18).
// 4. planOutput / writeSpringOutputs: write-once result (sha256-referenced parts above 16 MB) and spring-runs/<id>/.
// It never starts Studio, never steps physics and never computes signals in JavaScript (JS only re-checks invariants).
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync, rmSync} from 'node:fs';
import {join, dirname, basename, resolve, delimiter} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {StringDecoder} from 'node:string_decoder';
import {verifySavedCapture, verifyUnchanged} from './refit-saved.mjs';

const deepFreeze = value => {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
};
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const isPlainObject = v => v !== null && typeof v === 'object' && !Array.isArray(v) &&
  (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);
// Sorted-key JSON that tolerates null; used only to compare/hash verified input structures.
const canonicalJson = x => JSON.stringify(x, (_k, v) => isPlainObject(v)
  ? Object.fromEntries(Object.keys(v).sort().map(k => [k, v[k]])) : v);

export const ROOT = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_MANIFEST = join(ROOT, '../indicator-v2/results/RoAlgoV2_SPY_1791205420530.json');
export const DEFAULT_OUT_DIR = join(ROOT, 'results');
export const DEFAULT_REPORTS_DIR = join(ROOT, 'spring-runs');
export const DEFAULT_SRC_DIR = join(ROOT, 'src');
export const RUNNER_DIR = join(ROOT, 'spring-runner');
export const VERIFICATION_DOC = join(ROOT, '../indicator-v2/VERIFICATION.md');
// The Luau CLI: LUAU_EXE when set, otherwise the first `luau` (luau.exe on Windows) found on PATH.
function resolveLuauPath(name = process.env.LUAU_EXE || 'luau') {
  if (existsSync(name)) return name;
  const exts = process.platform === 'win32' ? ['.exe', ''] : [''];
  for (const dir of (process.env.PATH || '').split(delimiter)) for (const ext of exts) {
    const candidate = join(dir, name + ext);
    if (dir && existsSync(candidate)) return candidate;
  }
  return name;
}
export const LUAU_PATH = resolveLuauPath();
export const RESULT_NAME_RE = /^[A-Za-z0-9_-]{1,100}\.json$/;
export const RESULT_STEM_PREFIX = 'RoAlgoV3_spring_v1_';
export const CHUNK_THRESHOLD_BYTES = 16 * 1024 * 1024;
export const RESULT_SCHEMA = 'roalgo-spring-indicator-v1';
export const PART_SCHEMA = 'roalgo-spring-indicator-v1-part';
export const CHUNK_FORMAT = 'spring-chunks-v1';
export const RECORDS_PER_MODULE = 64;
export const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;
export const VARIANTS = deepFreeze(['coupled', 'independent', 'numeric']);
export const DRIVE_NAMES = deepFreeze(['trend', 'immediateReturn', 'rangeActivity', 'volume', 'peerRelative', 'hourlyContext', 'dailyTrend', 'regimeStress']);
// Contract section 3: no spring module may require these; App/Dashboard are UI and never part of a CLI run.
export const FORBIDDEN_MODULES = deepFreeze(['Engine', 'VerifiedStepper', 'Mechanics', 'PhysicsView', 'Learning', 'Features', 'App', 'Dashboard']);
export const ENTRY_MODULES = deepFreeze(['SpringPolicy', 'SpringState', 'SpringStudy']);
export const KEPT_FIELDS = deepFreeze({
  bar: ['t', 'o', 'h', 'l', 'c', 'availableT', 'day', 'label'],
  feature: ['reset', 'ready', 'volatility'],
  state: ['vector', 'names'],
});
// D15: verified-unchanged inputs. Manifest from handover 3.4; checkpoints from manifest.cacheChunks;
// _source.json from indicator-v2/VERIFICATION.md line 15.
export const DEFAULT_PINS = deepFreeze({
  manifestSha256: 'bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828',
  checkpointSha256s: [
    'd75e3a65a34750e2e54bf394a6d3ac5c1eae63810a1724e911bac2b80640b74a',
    '7ef24f376cdc10d6784ade62d2a61e104d7f063d85a631aa61d9f8a34f4a69f5',
    '55c352c0a752ce6c58713030463c3543a557e7a4d62f4d8ee4e472a5d932cab0',
    'b79751d37ba5c6cc193983437e4e63c2b155cfcf4f910386042a50a7235b7ca3',
    '109aab90b951a60623db3c683dff06dba0e1a293dd2954d420fe1db243bdfa76',
  ],
  sourceJsonSha256: 'ecbee1e2e639acd7e9b51d0b81a0d9541e24cc1ec23fdc4e033a2860a16dee58',
  sourceJsonPinnedFrom: 'indicator-v2/VERIFICATION.md:15',
});

// Protocol ids the runner accepts. The protocol VALUES are owned by the Luau code: the generated runner passes
// SpringPolicy.protocol(id) (the canonical frozen table that every Spring module validates against) and the
// table actually used is echoed back, hashed and recorded in provenance. JavaScript never keeps a second copy.
export const PROTOCOLS = deepFreeze({
  'spring-consensus-v1': {id: 'spring-consensus-v1', resultSchema: RESULT_SCHEMA, authority: 'src/SpringPolicy.luau SpringPolicy.protocol(id)'},
});

export function getProtocol(id) {
  if (typeof id !== 'string' || !Object.hasOwn(PROTOCOLS, id))
    throw new Error(`Unknown protocol '${id}'; supported: ${Object.keys(PROTOCOLS).join(', ')}`);
  return PROTOCOLS[id];
}

// ---------------------------------------------------------------------------------------------
// Deterministic serialisers
// ---------------------------------------------------------------------------------------------

const asciiString = s => {
  if (!s.isWellFormed()) throw new Error('stableStringify: string contains a lone surrogate');
  return JSON.stringify(s).replace(/[\u007f-\uffff]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
};
const jsonNumber = (n, path) => {
  if (!Number.isFinite(n)) throw new Error(`stableStringify: non-finite number at ${path}`);
  return Object.is(n, -0) ? '-0' : JSON.stringify(n);
};
// Sorted keys, shortest round-trip numbers, ASCII only (non-ASCII as \uXXXX), no null/undefined/NaN/Infinity.
export function stableStringify(value, path = '$') {
  switch (typeof value) {
    case 'number': return jsonNumber(value, path);
    case 'string': return asciiString(value);
    case 'boolean': return value ? 'true' : 'false';
    case 'object':
      if (Array.isArray(value)) {
        const items = new Array(value.length);
        for (let i = 0; i < value.length; i++) {
          if (!(i in value)) throw new Error(`stableStringify: sparse array at ${path}[${i}]`);
          items[i] = stableStringify(value[i], `${path}[${i}]`);
        }
        return '[' + items.join(',') + ']';
      }
      if (isPlainObject(value)) {
        const keys = Object.keys(value).sort();
        return '{' + keys.map(k => asciiString(k) + ':' + stableStringify(value[k], `${path}.${k}`)).join(',') + '}';
      }
      throw new Error(`stableStringify: unsupported value (null or non-plain object) at ${path}`);
    default:
      throw new Error(`stableStringify: unsupported ${typeof value} at ${path}`);
  }
}

const LUAU_KEYWORDS = new Set(['and', 'break', 'continue', 'do', 'else', 'elseif', 'end', 'export', 'false', 'for', 'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'type', 'typeof', 'until', 'while']);
const luauString = s => {
  if (!s.isWellFormed()) throw new Error('luauLiteral: string contains a lone surrogate');
  // Printable ASCII passes; everything else is written as decimal byte escapes of its UTF-8 encoding.
  // The u flag matters: astral characters must be encoded whole, never as two lone surrogates.
  return '"' + s.replace(/[^\x20-\x7e]|["\\]/gu, ch => [...Buffer.from(ch, 'utf8')].map(b => '\\' + String(b).padStart(3, '0')).join('')) + '"';
};
// Deterministic Luau table-constructor source for plain JSON-like data (sorted keys, round-trip numbers).
export function luauLiteral(value, path = '$') {
  switch (typeof value) {
    case 'number':
      if (!Number.isFinite(value)) throw new Error(`luauLiteral: non-finite number at ${path}`);
      return Object.is(value, -0) ? '-0' : String(value);
    case 'string': return luauString(value);
    case 'boolean': return value ? 'true' : 'false';
    case 'object':
      if (Array.isArray(value)) {
        const items = new Array(value.length);
        for (let i = 0; i < value.length; i++) {
          if (!(i in value)) throw new Error(`luauLiteral: sparse array at ${path}[${i}]`);
          items[i] = luauLiteral(value[i], `${path}[${i}]`);
        }
        return '{' + items.join(',') + '}';
      }
      if (isPlainObject(value)) {
        return '{' + Object.keys(value).sort().map(k => {
          const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && !LUAU_KEYWORDS.has(k) ? k : '[' + luauString(k) + ']';
          return key + '=' + luauLiteral(value[k], `${path}.${k}`);
        }).join(',') + '}';
      }
      throw new Error(`luauLiteral: unsupported value (null or non-plain object) at ${path}`);
    default:
      throw new Error(`luauLiteral: unsupported ${typeof value} at ${path}`);
  }
}

// ---------------------------------------------------------------------------------------------
// (1) Input verification: verifySavedCapture + D15 / section 2 checks
// ---------------------------------------------------------------------------------------------

export function pinFromVerificationDoc(docPath = VERIFICATION_DOC) {
  const lines = readFileSync(docPath, 'utf8').split('\n');
  const index = lines.findIndex(line => /_source\.json/.test(line) && /SHA256\s*`[a-f0-9]{64}`/.test(line));
  if (index < 0) throw new Error(`No _source.json SHA256 found in ${docPath}`);
  return {sha256: lines[index].match(/_source\.json`?,?\s*SHA256\s*`([a-f0-9]{64})`/)[1], line: index + 1};
}

export function sourceJsonPathFor(manifestPath) {
  return join(dirname(manifestPath), basename(manifestPath, '.json') + '_source.json');
}

export function expectedStateNames(config) {
  return [...config.nodes.map(n => n.name + '.x'), ...config.nodes.map(n => n.name + '.v'), ...config.bankNames.map(b => b + '.energy')];
}

export function verifySpringInputs(manifestPath = DEFAULT_MANIFEST, {pins = DEFAULT_PINS, expectedRecords, expectedChunks, driveNames = DRIVE_NAMES} = {}) {
  manifestPath = resolve(manifestPath);
  const fail = reason => { throw new Error('Spring input verification failed: ' + reason); };
  if (!pins || !/^[a-f0-9]{64}$/.test(pins.manifestSha256 ?? '') || !/^[a-f0-9]{64}$/.test(pins.sourceJsonSha256 ?? '') || !Array.isArray(pins.checkpointSha256s))
    fail('pins {manifestSha256, checkpointSha256s[], sourceJsonSha256} are required');
  // Cheap pin pre-check before the full parse; the authoritative comparison uses verifySavedCapture's own bytes below.
  const preSha = sha256(readFileSync(manifestPath));
  if (preSha !== pins.manifestSha256) fail(`manifest sha256 pin mismatch for ${basename(manifestPath)}: pinned ${pins.manifestSha256}, found ${preSha}`);

  const capture = verifySavedCapture(manifestPath, {expectedRecords, expectedChunks});
  const {manifest, records} = capture;
  const inputHashes = capture.inputHashes.map(entry => ({...entry}));
  if (inputHashes[0].sha256 !== pins.manifestSha256) fail(`manifest sha256 pin mismatch (changed during verification): ${inputHashes[0].sha256}`);

  // Checkpoint SHAs: the explicit pins must equal manifest.cacheChunks and the verified file bytes.
  const checkpoints = inputHashes.slice(1);
  if (pins.checkpointSha256s.length !== checkpoints.length)
    fail(`checkpoint pin count ${pins.checkpointSha256s.length} != manifest.cacheChunks ${checkpoints.length}`);
  checkpoints.forEach((entry, i) => {
    if (entry.sha256 !== pins.checkpointSha256s[i])
      fail(`checkpoint sha256 pin mismatch for ${basename(entry.path)}: pinned ${pins.checkpointSha256s[i]}, found ${entry.sha256}`);
    if (manifest.cacheChunks[i].sha256 !== entry.sha256) fail(`manifest.cacheChunks[${i}] sha256 differs from the verified checkpoint`);
  });

  // _source.json: pinned bytes, and its modules must be exactly manifest.sourceHashes (the recorded capture source).
  const sourcePath = sourceJsonPathFor(manifestPath);
  if (!existsSync(sourcePath)) fail(`capture _source.json missing: ${sourcePath}`);
  const sourceBytes = readFileSync(sourcePath), sourceSha = sha256(sourceBytes);
  if (sourceSha !== pins.sourceJsonSha256)
    fail(`_source.json sha256 pin mismatch (pinned from ${pins.sourceJsonPinnedFrom}): pinned ${pins.sourceJsonSha256}, found ${sourceSha}`);
  const sourceDoc = JSON.parse(sourceBytes);
  const sourceFiles = Array.isArray(sourceDoc?.files) ? sourceDoc.files : fail('_source.json has no files[]');
  const recorded = manifest.sourceHashes ?? fail('manifest.sourceHashes missing');
  if (sourceFiles.length !== Object.keys(recorded).length) fail(`_source.json lists ${sourceFiles.length} modules, manifest.sourceHashes ${Object.keys(recorded).length}`);
  for (const file of sourceFiles) {
    if (typeof file.source !== 'string' || sha256(file.source) !== file.sha256) fail(`_source.json module ${file.path} does not hash to its recorded sha256`);
    if (recorded[file.path] !== file.sha256) fail(`_source.json module ${file.path} differs from manifest.sourceHashes`);
  }
  inputHashes.push({path: sourcePath, sha256: sourceSha, bytes: sourceBytes.length});

  // native.config: present, shaped, and identical in every checkpoint (re-read bytes must be the verified bytes).
  const config = manifest.native?.config;
  if (!isPlainObject(config)) fail('manifest.native.config missing');
  if (!Array.isArray(config.nodes) || config.nodes.length !== 24) fail(`native.config must have 24 nodes, found ${config.nodes?.length}`);
  config.nodes.forEach((node, i) => {
    if (node?.index !== i + 1 || typeof node.name !== 'string' || !node.name) fail(`native.config.nodes[${i + 1}] index/name invalid`);
  });
  if (!Array.isArray(config.bankNames) || config.bankNames.length !== 3 || !config.bankNames.every(b => typeof b === 'string'))
    fail('native.config.bankNames must be three names');
  const configCanonical = canonicalJson(config);
  for (const entry of checkpoints) {
    const bytes = readFileSync(entry.path);
    if (sha256(bytes) !== entry.sha256) fail(`checkpoint ${basename(entry.path)} changed during verification`);
    if (canonicalJson(JSON.parse(bytes).native?.config) !== configCanonical)
      fail(`native.config in ${basename(entry.path)} differs from manifest.native.config`);
  }

  // Drive names (descriptor input; D23 order).
  if (canonicalJson(manifest.featureInfo?.driveNames) !== canonicalJson([...driveNames]))
    fail(`featureInfo.driveNames ${JSON.stringify(manifest.featureInfo?.driveNames)} != ${JSON.stringify(driveNames)}`);

  // Per record: 51 names rebuilt from config for all 3 variants, vector[1..48] == nodes[].x/v,
  // availableT == t + 300, finite volatility, and the types the minimised data module needs.
  const names = expectedStateNames(config);
  let minVol = Infinity, maxVol = -Infinity;
  const finite = Number.isFinite;
  records.forEach((record, k) => {
    const i = k + 1, {bar, feature, states} = record;
    if (!Number.isInteger(bar.availableT) || bar.availableT !== bar.t + 300)
      fail(`bar.availableT != bar.t + 300 at record ${i} (t=${bar.t}, availableT=${bar.availableT})`);
    if (!finite(feature.volatility)) fail(`feature.volatility not finite at record ${i} (${feature.volatility})`);
    for (const key of ['o', 'h', 'l', 'c']) if (!finite(bar[key])) fail(`bar.${key} not finite at record ${i}`);
    if (typeof bar.day !== 'string' || typeof bar.label !== 'string') fail(`bar.day/bar.label must be strings at record ${i}`);
    if (typeof feature.ready !== 'boolean' || typeof feature.reset !== 'boolean') fail(`feature.ready/reset must be booleans at record ${i}`);
    minVol = Math.min(minVol, feature.volatility); maxVol = Math.max(maxVol, feature.volatility);
    for (const variant of VARIANTS) {
      const s = states[variant];
      if (!s) fail(`states.${variant} missing at record ${i}`);
      for (let j = 0; j < 51; j++)
        if (s.names[j] !== names[j]) fail(`state names for ${variant} at record ${i} differ from names rebuilt from native.config at index ${j + 1} (found ${s.names[j]}, expected ${names[j]})`);
      for (let j = 0; j < 24; j++) {
        if (s.nodes[j]?.x !== s.vector[j]) fail(`${variant} record ${i}: nodes[${j + 1}].x != vector[${j + 1}]`);
        if (s.nodes[j]?.v !== s.vector[24 + j]) fail(`${variant} record ${i}: nodes[${j + 1}].v != vector[${24 + j + 1}]`);
      }
    }
  });

  const split = manifest.split;
  if (!(finite(split?.trainEndT) && finite(split.validationEndT) && finite(split.testStartT) && split.trainEndT < split.validationEndT && split.validationEndT <= split.testStartT))
    fail('manifest.split must be finite and ordered');
  const partitions = {training: 0, validation: 0, evaluation: 0};
  for (const r of records) partitions[r.bar.t < split.trainEndT ? 'training' : r.bar.t < split.validationEndT ? 'validation' : 'evaluation'] += 1;

  const checks = {
    manifest: {name: basename(manifestPath), sha256: inputHashes[0].sha256, pinned: true},
    checkpoints: checkpoints.map(e => ({name: basename(e.path), sha256: e.sha256, pinned: true})),
    sourceJson: {name: basename(sourcePath), sha256: sourceSha, pinnedFrom: pins.sourceJsonPinnedFrom, modules: sourceFiles.length, modulesEqualManifestSourceHashes: true},
    nativeConfig: {sha256: sha256(configCanonical), checkpointsEqualManifest: checkpoints.length, nodes: config.nodes.length},
    stateNames: {rebuiltFromConfig: 51, variants: VARIANTS.length, recordsChecked: records.length, mismatches: 0},
    nodeXV: {comparisons: records.length * VARIANTS.length * 48, mismatches: 0},
    availableT: {recordsChecked: records.length, equalTPlus300: records.length},
    volatility: {finite: records.length, min: minVol, max: maxVol},
    driveNames: [...driveNames],
    partitions,
  };
  return {
    manifestPath, records, inputHashes, audit: capture.audit, checks,
    nativeConfig: config, nativeConfigSha256: checks.nativeConfig.sha256, stateNames: names, driveNames: [...driveNames],
    split: {trainEndT: split.trainEndT, validationEndT: split.validationEndT, testStartT: split.testStartT},
    captureSource: {...recorded},
  };
}

// ---------------------------------------------------------------------------------------------
// (2) Data minimisation
// ---------------------------------------------------------------------------------------------

export function minimiseRecords(records) {
  const omitted = {record: new Set(), bar: new Set(), feature: new Set(), states: new Set(), state: new Set()};
  const note = (set, object, kept) => { for (const key of Object.keys(object)) if (!kept.includes(key)) set.add(key); };
  const minimal = records.map(record => {
    note(omitted.record, record, ['bar', 'feature', 'states']);
    note(omitted.bar, record.bar, KEPT_FIELDS.bar);
    note(omitted.feature, record.feature, KEPT_FIELDS.feature);
    note(omitted.states, record.states, VARIANTS);
    const states = {};
    for (const variant of VARIANTS) {
      const s = record.states[variant];
      note(omitted.state, s, KEPT_FIELDS.state);
      states[variant] = {vector: [...s.vector], names: [...s.names]};
    }
    const bar = {};
    for (const key of KEPT_FIELDS.bar) bar[key] = record.bar[key];
    const feature = {};
    for (const key of KEPT_FIELDS.feature) feature[key] = record.feature[key];
    return {bar, feature, states};
  });
  const sorted = set => [...set].sort();
  return {
    records: minimal,
    minimisation: {
      recordCount: records.length,
      kept: {bar: [...KEPT_FIELDS.bar], feature: [...KEPT_FIELDS.feature], states: [...VARIANTS], state: [...KEPT_FIELDS.state]},
      omitted: {record: sorted(omitted.record), bar: sorted(omitted.bar), feature: sorted(omitted.feature), states: sorted(omitted.states), state: sorted(omitted.state)},
      note: 'Only the kept fields reach Luau. The omitted fields (raw features, feature drives, regime, contexts, volume/VWAP/trade count, per-node x/v/drive/force tables, bank summaries and the separate energy field) never enter the harness. Bank energies remain inside vector[49..51] as recorded.',
    },
  };
}

// ---------------------------------------------------------------------------------------------
// (3) Luau harness
// ---------------------------------------------------------------------------------------------

// Positions of `require` tokens in code (comments and string literals skipped).
function requireTokenPositions(source) {
  const positions = [];
  let i = 0;
  const longBracket = at => { const m = /^\[(=*)\[/.exec(source.slice(at, at + 64)); return m ? m[1].length : -1; };
  const skipLong = (at, level) => { const close = ']' + '='.repeat(level) + ']'; const end = source.indexOf(close, at); return end < 0 ? source.length : end + close.length; };
  while (i < source.length) {
    const ch = source[i];
    if (ch === '-' && source[i + 1] === '-') {
      const level = longBracket(i + 2);
      if (level >= 0) i = skipLong(i + 2, level);
      else { const eol = source.indexOf('\n', i); i = eol < 0 ? source.length : eol + 1; }
    } else if (ch === '"' || ch === "'" || ch === '`') {
      i++;
      while (i < source.length && source[i] !== ch) { if (source[i] === '\\') i++; i++; }
      i++;
    } else if (ch === '[' && longBracket(i) >= 0) {
      i = skipLong(i, longBracket(i));
    } else if (/[A-Za-z_]/.test(ch)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(source.slice(i, i + 256));
      const prev = i > 0 ? source[i - 1] : '';
      if (m[0] === 'require' && prev !== '.' && prev !== ':') positions.push(i);
      i += m[0].length;
    } else i++;
  }
  return positions;
}
const REQUIRE_FORMS = [
  /^require\s*\(\s*script\.Parent\.(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\)/,
  /^require\s*\(\s*script\.Parent\s*:\s*(?:WaitForChild|FindFirstChild)\s*\(\s*["'](?<name>[A-Za-z_][A-Za-z0-9_]*)["']\s*\)\s*\)/,
  /^require\s*\(\s*["']\.\/(?<name>[A-Za-z_][A-Za-z0-9_]*)["']\s*\)/,
  /^require\s*,\s*["']\.\/(?<name>[A-Za-z_][A-Za-z0-9_]*)["']/,
];
export function luauRequires(source, moduleName = 'module') {
  const deps = new Set();
  for (const at of requireTokenPositions(source)) {
    const rest = source.slice(at, at + 200);
    const match = REQUIRE_FORMS.map(re => re.exec(rest)).find(Boolean);
    if (!match) throw new Error(`Unsupported require form in ${moduleName}.luau: ${JSON.stringify(rest.split('\n')[0].slice(0, 80))}; only sibling modules (script.Parent.X / "./X") can run in the harness`);
    deps.add(match.groups.name);
  }
  return [...deps];
}

export function resolveModuleClosure(srcDir = DEFAULT_SRC_DIR, entries = ENTRY_MODULES, forbidden = FORBIDDEN_MODULES) {
  const found = new Map(), queue = entries.map(name => ({name, by: 'runner'}));
  while (queue.length) {
    const {name, by} = queue.shift();
    if (found.has(name)) continue;
    if (forbidden.includes(name))
      throw new Error(`Forbidden module ${name} required by ${by}: spring runs must not reach ${forbidden.join(', ')} (contract sections 3-4; no native stepping)`);
    const path = join(srcDir, name + '.luau');
    if (!existsSync(path)) throw new Error(`Required Luau module ${name}.luau not found in ${srcDir} (required by ${by})`);
    const bytes = readFileSync(path);
    found.set(name, {name, path, bytes, sha256: sha256(bytes), requiredBy: by});
    for (const dep of luauRequires(bytes.toString('utf8'), name)) queue.push({name: dep, by: name});
  }
  return [...found.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

export function assertSourcesUnchanged(modules) {
  for (const m of modules) if (sha256(readFileSync(m.path)) !== m.sha256) throw new Error(`Luau source changed during the spring run: ${m.path}`);
  return true;
}

const DATA_MARKER = '--[[@@DATA_REQUIRES@@]]';
export function prepareHarness({verified, protocol, srcDir = DEFAULT_SRC_DIR, runRoot = tmpdir(), recordsPerModule = RECORDS_PER_MODULE, runnerDir = RUNNER_DIR}) {
  if (!verified?.records?.length) throw new Error('prepareHarness: verified records required');
  const modules = resolveModuleClosure(srcDir);
  const {records, minimisation} = minimiseRecords(verified.records);
  mkdirSync(runRoot, {recursive: true});
  const runDir = mkdtempSync(join(runRoot, 'spring-run-'));
  mkdirSync(join(runDir, 'src'));
  mkdirSync(join(runDir, 'data'));
  const files = [];
  const write = (rel, bytes) => {
    writeFileSync(join(runDir, rel), bytes, {flag: 'wx'});
    const entry = {path: rel, sha256: sha256(bytes), bytes: Buffer.byteLength(bytes)};
    files.push(entry);
    return entry;
  };
  const srcHashes = {};
  for (const m of modules) { write('src/' + m.name + '.luau', m.bytes); srcHashes['src/' + m.name + '.luau'] = m.sha256; }
  const jsonSource = readFileSync(join(runnerDir, 'SpringJson.luau')), template = readFileSync(join(runnerDir, 'Runner.template.luau'), 'utf8');
  write('SpringJson.luau', jsonSource);
  const dataModules = [];
  for (let start = 0; start < records.length; start += recordsPerModule) {
    const name = 'Records' + String(dataModules.length + 1).padStart(4, '0');
    const source = `-- Generated spring data module: minimised records ${start + 1}-${Math.min(start + recordsPerModule, records.length)}. Do not edit.\nreturn ${luauLiteral(records.slice(start, start + recordsPerModule))}\n`;
    if (Buffer.byteLength(source) >= 4 * 1024 * 1024) throw new Error(`Data module ${name} exceeds 4 MiB`);
    dataModules.push({name, ...write('data/' + name + '.luau', source)});
  }
  const input = {
    protocolId: protocol.id, split: verified.split, nativeConfig: verified.nativeConfig, driveNames: verified.driveNames,
    stateNames: verified.stateNames, variants: [...VARIANTS], recordCount: records.length, dataModuleCount: dataModules.length,
  };
  const inputEntry = write('Input.luau', `-- Generated spring harness input (protocol, split, descriptor inputs). Do not edit.\nreturn ${luauLiteral(input)}\n`);
  if (template.split(DATA_MARKER).length !== 2) throw new Error('Runner template must contain the data marker exactly once');
  const runner = template.replace(DATA_MARKER, () => dataModules.map(d => `append(require("./data/${d.name}"))`).join('\n'));
  const runnerEntry = write('Runner.luau', runner);
  return {
    runDir, runnerPath: join(runDir, 'Runner.luau'),
    modules: modules.map(({name, path, sha256: hash, bytes, requiredBy}) => ({name, path, sha256: hash, bytes: bytes.length, requiredBy})),
    srcHashes, files,
    harnessHashes: {
      'spring-runner/SpringJson.luau': sha256(jsonSource),
      'spring-runner/Runner.template.luau': sha256(template),
      'Runner.luau (generated)': runnerEntry.sha256,
      'Input.luau (generated)': inputEntry.sha256,
    },
    dataModules: {
      count: dataModules.length, recordsPerModule, totalBytes: dataModules.reduce((a, d) => a + d.bytes, 0),
      digest: sha256(dataModules.map(d => `${d.name}:${d.sha256}`).join('\n')),
      modules: dataModules.map(({name, sha256: hash, bytes}) => ({name, sha256: hash, bytes})),
    },
    minimisedRecordsSha256: sha256(stableStringify(records)),
    minimisation,
  };
}

export function luauIdentity(luauPath = LUAU_PATH) {
  if (!existsSync(luauPath)) throw new Error(`Luau CLI missing at ${luauPath}`);
  return {path: luauPath, sha256: sha256(readFileSync(luauPath)), version: process.env.LUAU_VERSION || /luau-(\d+\.\d+)/.exec(luauPath)?.[1] || 'unknown',
    mode: 'interpreted; no --codegen flags (D19), default optimisation as in the spec runs'};
}

// Runs the generated runner. Exactly one @@HARNESS and one @@JSON line, both printable ASCII; other lines are logs.
export function runLuauHarness(runnerPath, {cwd = dirname(runnerPath), timeoutMs = DEFAULT_TIMEOUT_MS, luauPath = LUAU_PATH, maxStdoutBytes = 2 ** 30} = {}) {
  return new Promise((resolvePromise, reject) => {
    const argv = [runnerPath];
    const started = process.hrtime.bigint();
    let child;
    try { child = spawn(luauPath, argv, {cwd, windowsHide: true}); } catch (error) { reject(new Error(`Failed to start Luau (${luauPath}): ${error.message}`)); return; }
    const out = new StringDecoder('utf8'), errOut = new StringDecoder('utf8');
    const markers = {'@@JSON ': null, '@@HARNESS ': null}, logs = [];
    let pending = [], stderr = '', stdoutBytes = 0, settled = false, closed = false, failure = null, fallback = null;
    // Failures reject only after the child has exited (or 5 s after the kill), so callers can delete the run dir.
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (!error) return resolvePromise(value);
      failure = error;
      if (closed) return reject(error);
      try { child.kill(); } catch {}
      fallback = setTimeout(() => reject(error), 5000);
    };
    const handleLine = raw => {
      const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
      for (const marker of Object.keys(markers)) {
        if (!line.startsWith(marker)) continue;
        if (markers[marker] !== null) throw new Error(`Luau printed more than one ${marker.trim()} line`);
        const payload = line.slice(marker.length), bad = payload.search(/[^\x20-\x7e]/);
        if (bad >= 0) throw new Error(`Luau ${marker.trim()} output is not printable ASCII (D18): code unit U+${payload.charCodeAt(bad).toString(16).padStart(4, '0')} at offset ${bad}`);
        markers[marker] = payload;
        return;
      }
      if (line.length) logs.push(line);
    };
    // Linear in output size: chunks of an unfinished line are only joined once its newline arrives.
    const consume = text => {
      let start = 0, index;
      while ((index = text.indexOf('\n', start)) !== -1) {
        pending.push(text.slice(start, index));
        const line = pending.join('');
        pending = [];
        handleLine(line);
        start = index + 1;
      }
      if (start < text.length) pending.push(text.slice(start));
    };
    const timer = setTimeout(() => finish(new Error(`Luau harness timed out after ${timeoutMs} ms; process killed (${runnerPath})`)), timeoutMs);
    child.stdout.on('data', bytes => {
      if (settled) return;
      stdoutBytes += bytes.length;
      if (stdoutBytes > maxStdoutBytes) return finish(new Error(`Luau stdout exceeded ${maxStdoutBytes} bytes`));
      try { consume(out.write(bytes)); } catch (error) { finish(error); }
    });
    child.stderr.on('data', bytes => { stderr += errOut.write(bytes); });
    child.on('error', error => finish(new Error(`Failed to run Luau (${luauPath}): ${error.message}`)));
    child.on('close', (code, signal) => {
      closed = true;
      if (failure) { clearTimeout(fallback); return reject(failure); }
      if (settled) return;
      try {
        consume(out.end());
        if (pending.length) { const line = pending.join(''); pending = []; handleLine(line); }
        stderr += errOut.end();
      } catch (error) { return finish(error); }
      const wallMs = Number(process.hrtime.bigint() - started) / 1e6;
      if (code !== 0)
        return finish(new Error(`Luau harness failed (exit ${code}${signal ? ', signal ' + signal : ''}).\n--- luau stderr (verbatim) ---\n${stderr}--- last stdout lines ---\n${logs.slice(-20).join('\n')}`));
      if (markers['@@JSON '] === null) return finish(new Error(`Luau harness printed no @@JSON result\n${logs.slice(-20).join('\n')}`));
      if (markers['@@HARNESS '] === null) return finish(new Error('Luau harness printed no @@HARNESS line'));
      let result, harness;
      try { result = JSON.parse(markers['@@JSON ']); harness = JSON.parse(markers['@@HARNESS ']); } catch (error) { return finish(new Error('Luau output is not valid JSON: ' + error.message)); }
      finish(null, {result, harness, logs, stderr, wallMs, exitCode: code, argv: argv.map(a => basename(a)), stdoutBytes, resultChars: markers['@@JSON '].length});
    });
  });
}

// ---------------------------------------------------------------------------------------------
// (4) Outputs: write-once result, sha256-referenced chunk parts, spring-runs/<id>/
// ---------------------------------------------------------------------------------------------

const pointerToken = key => String(key).replace(/~/g, '~0').replace(/\//g, '~1');
const RESERVED = /^\$springChunk/;
function assertNoReservedKeys(value, path = '$') {
  if (Array.isArray(value)) value.forEach((v, i) => assertNoReservedKeys(v, `${path}[${i}]`));
  else if (isPlainObject(value)) for (const [k, v] of Object.entries(value)) {
    if (RESERVED.test(k)) throw new Error(`Result key ${path}.${k} uses the reserved chunk-marker prefix`);
    assertNoReservedKeys(v, `${path}.${k}`);
  }
}

// Plans the bytes to write. Unchunked: one file = stableStringify(result) + "\n" (<= threshold).
// Chunked: subtrees move into part files of <= threshold bytes each; the main file keeps the structure with
// {"$springChunkedArray":{length,parts:[{name,sha256,bytes,start,count}]}} or {"$springChunk":{name,sha256,bytes}}
// markers and a top-level "$springChunks" header holding the logical sha256. readSpringResult reverses it.
export function planOutput(result, {stem, threshold = CHUNK_THRESHOLD_BYTES}) {
  const mainName = stem + '.json';
  if (!RESULT_NAME_RE.test(mainName)) throw new Error(`Result name ${mainName} does not match ${RESULT_NAME_RE}`);
  if (!isPlainObject(result)) throw new Error('Result must be a JSON object');
  assertNoReservedKeys(result);
  const logicalText = stableStringify(result), logicalSha256 = sha256(logicalText);
  if (logicalText.length + 1 <= threshold)
    return {mainName, chunked: false, threshold, logicalSha256, logicalBytes: logicalText.length, main: {name: mainName, text: logicalText + '\n'}, parts: []};

  const parts = [], q = s => stableStringify(s);
  const partName = () => {
    const name = `${stem}_part${String(parts.length + 1).padStart(4, '0')}.json`;
    if (!RESULT_NAME_RE.test(name)) throw new Error(`Part name ${name} does not match ${RESULT_NAME_RE}`);
    return name;
  };
  const addPart = text => {
    const name = partName();
    if (text.length > threshold) throw new Error(`Chunk part ${name} would be ${text.length} bytes, above the ${threshold}-byte threshold`);
    const ref = {name, sha256: sha256(text), bytes: text.length};
    parts.push({...ref, text});
    return ref;
  };
  const arrayPart = (pointer, start, items) => `{"count":${items.length},"index":${parts.length + 1},"items":[${items.join(',')}],"parent":${q(mainName)},"pointer":${q(pointer)},"schema":${q(PART_SCHEMA)},"start":${start}}\n`;
  const valuePart = (pointer, valueText) => `{"index":${parts.length + 1},"parent":${q(mainName)},"pointer":${q(pointer)},"schema":${q(PART_SCHEMA)},"value":${valueText}}\n`;
  const externalise = (pointer, text) => '{"$springChunk":' + q(addPart(valuePart(pointer, text))) + '}';
  const markChunked = e => ({...e, marker: e.text.startsWith('{"$springChunk')});
  const objectText = entries => '{' + entries.map(e => e.keyText + ':' + e.text).join(',') + '}';
  const shrinkObject = (entries, pointer, limit) => {
    let size = objectText(entries).length;
    while (size > limit) {
      const candidates = entries.filter(e => !e.marker).sort((a, b) => b.text.length - a.text.length || (a.key < b.key ? -1 : 1));
      if (!candidates.length) throw new Error(`Cannot chunk object at ${pointer || '/'} below ${threshold} bytes`);
      const e = candidates[0], before = e.text.length;
      e.text = externalise(pointer + '/' + pointerToken(e.key), e.text);
      e.marker = true;
      size += e.text.length - before;
    }
  };
  const proc = (value, pointer) => {
    if (Array.isArray(value)) {
      const items = value.map((v, i) => proc(v, `${pointer}/${i}`));
      const total = 2 + items.reduce((a, t) => a + t.length, 0) + Math.max(0, items.length - 1);
      if (total <= threshold) return '[' + items.join(',') + ']';
      const refs = [], overhead = arrayPart(pointer, Number.MAX_SAFE_INTEGER, []).length + 32;
      let start = 0;
      while (start < items.length) {
        let end = start, size = overhead;
        while (end < items.length && size + items[end].length + 1 <= threshold) { size += items[end].length + 1; end++; }
        if (end === start) throw new Error(`Array element ${pointer}/${start} is too large to chunk below ${threshold} bytes`);
        refs.push({...addPart(arrayPart(pointer, start, items.slice(start, end))), start, count: end - start});
        start = end;
      }
      return '{"$springChunkedArray":' + q({length: items.length, parts: refs}) + '}';
    }
    if (isPlainObject(value)) {
      const entries = Object.keys(value).sort().map(key => ({key, keyText: q(key), text: proc(value[key], pointer + '/' + pointerToken(key))})).map(markChunked);
      shrinkObject(entries, pointer, threshold);
      return objectText(entries);
    }
    const text = q(value);
    if (text.length > threshold) throw new Error(`Scalar at ${pointer} is larger than ${threshold} bytes`);
    return text;
  };
  const rootEntries = Object.keys(result).sort().map(key => ({key, keyText: q(key), text: proc(result[key], '/' + pointerToken(key))})).map(markChunked);
  let mainText;
  for (;;) {
    const header = {format: CHUNK_FORMAT, logicalSha256, logicalBytes: logicalText.length, partCount: parts.length, threshold};
    const entries = [...rootEntries, {key: '$springChunks', keyText: q('$springChunks'), text: q(header), marker: true}].sort((a, b) => (a.key < b.key ? -1 : 1));
    mainText = objectText(entries) + '\n';
    if (mainText.length <= threshold) break;
    shrinkObject(rootEntries, '', threshold - (mainText.length - objectText(rootEntries).length) - 64);
  }
  return {mainName, chunked: true, threshold, logicalSha256, logicalBytes: logicalText.length, main: {name: mainName, text: mainText}, parts};
}

// Reads a written result (single or chunked), checking every part's bytes, sha256, parent and pointer,
// and the logical sha256 of the reassembled value.
export function readSpringResult(mainPath) {
  const dir = dirname(mainPath), mainName = basename(mainPath);
  const main = JSON.parse(readFileSync(mainPath, 'utf8'));
  if (!isPlainObject(main) || !Object.hasOwn(main, '$springChunks')) return main;
  const header = main.$springChunks;
  if (header?.format !== CHUNK_FORMAT) throw new Error(`Unknown chunk format ${header?.format}`);
  delete main.$springChunks;
  const used = new Set();
  const load = (ref, pointer) => {
    if (!RESULT_NAME_RE.test(ref?.name ?? '')) throw new Error(`Invalid chunk part name ${ref?.name}`);
    const bytes = readFileSync(join(dir, ref.name));
    if (bytes.length !== ref.bytes || sha256(bytes) !== ref.sha256) throw new Error(`Chunk part ${ref.name} sha256/bytes mismatch`);
    const part = JSON.parse(bytes.toString('utf8'));
    if (part.schema !== PART_SCHEMA || part.parent !== mainName || part.pointer !== pointer) throw new Error(`Chunk part ${ref.name} does not belong at ${pointer} of ${mainName}`);
    if (used.has(ref.name)) throw new Error(`Chunk part ${ref.name} referenced twice`);
    used.add(ref.name);
    return part;
  };
  const resolveNode = (value, pointer) => {
    if (Array.isArray(value)) return value.map((v, i) => resolveNode(v, `${pointer}/${i}`));
    if (!isPlainObject(value)) return value;
    const keys = Object.keys(value);
    if (keys.length === 1 && keys[0] === '$springChunk') return resolveNode(load(value.$springChunk, pointer).value, pointer);
    if (keys.length === 1 && keys[0] === '$springChunkedArray') {
      const {length, parts} = value.$springChunkedArray, items = [];
      for (const ref of parts) {
        const part = load(ref, pointer);
        if (part.start !== items.length || ref.start !== part.start || part.count !== part.items.length || ref.count !== part.count) throw new Error(`Chunk part ${ref.name} has a gap or overlap at ${pointer}`);
        for (const item of part.items) items.push(item);
      }
      if (items.length !== length) throw new Error(`Chunked array ${pointer} has ${items.length} items, expected ${length}`);
      return items.map((v, i) => resolveNode(v, `${pointer}/${i}`));
    }
    return Object.fromEntries(keys.map(k => [k, resolveNode(value[k], pointer + '/' + pointerToken(k))]));
  };
  const logical = resolveNode(main, '');
  if (used.size !== header.partCount) throw new Error(`Chunked result used ${used.size} parts, header declares ${header.partCount}`);
  if (sha256(stableStringify(logical)) !== header.logicalSha256) throw new Error('Reassembled result sha256 differs from the logical sha256 in the header');
  return logical;
}

export function markdownReport(report) {
  const r = report.result, p = report.provenance;
  const files = [`| ${r.name} | ${r.bytes} | \`${r.sha256}\` |`, ...r.parts.map(x => `| ${x.name} | ${x.bytes} | \`${x.sha256}\` |`)].join('\n');
  const inputs = p.inputHashes.map(i => `| ${i.name} | ${i.bytes} | \`${i.sha256}\` |`).join('\n');
  const src = Object.entries(p.srcHashes).map(([k, v]) => `| ${k} | \`${v}\` |`).join('\n');
  return `# Spring indicator run ${report.runId}

Protocol \`${report.protocolId}\`. Status: **${report.status}**. Created ${report.createdAtUTC}.
This run executed **zero new native steps** (newNativeSteps = ${p.newNativeSteps}); it read previously captured v2 states only.

> Placeholder report written by the runner. Phase 2 (SpringStudy) extends it with paired comparisons,
> setup/action counts, risk/cost breakdowns and the evidence verdict. Market evidence: development only, no fresh holdout.

## Result files (write-once)

${r.chunked ? `Chunked into ${r.parts.length} sha256-referenced parts (threshold ${r.threshold} bytes); logical sha256 \`${r.logicalSha256}\`.` : `Single file; logical sha256 \`${r.logicalSha256}\`.`}

| File | Bytes | SHA-256 |
|---|---:|---|
${files}

## Verified inputs (unchanged before and after writing)

| Input | Bytes | SHA-256 |
|---|---:|---|
${inputs}

Capture source recorded from manifest.sourceHashes (D15); on-disk indicator-v2 src is not hashed as capture source.

## Luau modules executed

| Module | SHA-256 |
|---|---|
${src}

Luau ${p.luau.version} (\`${p.luau.sha256}\`), ${p.luau.mode}.
Data modules: ${p.data.modules.count} (${p.data.modules.totalBytes} bytes); minimised records sha256 \`${p.data.minimisedRecordsSha256}\`.
Omitted fields: bar ${p.data.minimisation.omitted.bar.join(', ') || 'none'}; feature ${p.data.minimisation.omitted.feature.join(', ') || 'none'}; state ${p.data.minimisation.omitted.state.join(', ') || 'none'}.
`;
}

const toolHashes = () => Object.fromEntries(['run-spring-indicator.mjs', 'spring-runner-lib.mjs', 'refit-saved.mjs'].map(name => {
  const path = join(ROOT, name);
  return [name, existsSync(path) ? sha256(readFileSync(path)) : 'missing'];
}));

// The whole pipeline. Options let tests point it at a stub src dir, temp output dirs and small thresholds.
export async function runSpringIndicator(options = {}) {
  const {
    manifestPath = DEFAULT_MANIFEST, protocolId, outDir = DEFAULT_OUT_DIR, reportsDir = DEFAULT_REPORTS_DIR, srcDir = DEFAULT_SRC_DIR,
    runRoot = tmpdir(), pins = DEFAULT_PINS, threshold = CHUNK_THRESHOLD_BYTES, timeoutMs = DEFAULT_TIMEOUT_MS, nowMs = Date.now(),
    keepRunDir = false, luauPath = LUAU_PATH, expectSchema = RESULT_SCHEMA, onProgress = () => {},
  } = options;
  const isDefaultManifest = resolve(manifestPath) === resolve(DEFAULT_MANIFEST);
  const {expectedRecords = isDefaultManifest ? 2268 : undefined, expectedChunks = isDefaultManifest ? 5 : undefined} = options;
  const protocol = getProtocol(protocolId);
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) throw new Error('nowMs must be a non-negative integer');
  const stem = RESULT_STEM_PREFIX + nowMs, resultPath = join(outDir, stem + '.json'), reportDir = join(reportsDir, stem);
  if (!RESULT_NAME_RE.test(stem + '.json')) throw new Error(`Result name ${stem}.json is not bridge-loadable`);
  if (existsSync(resultPath)) throw new Error(`Refusing to overwrite existing result ${resultPath} (write-once)`);
  if (existsSync(reportDir)) throw new Error(`Refusing to overwrite existing run directory ${reportDir} (write-once)`);
  const timing = {}, t0 = Date.now();
  if (pins === DEFAULT_PINS) {
    const doc = pinFromVerificationDoc();
    if (doc.sha256 !== DEFAULT_PINS.sourceJsonSha256) throw new Error(`VERIFICATION.md _source.json pin ${doc.sha256} differs from the runner pin`);
  }

  onProgress('verifying inputs');
  const verified = verifySpringInputs(manifestPath, {pins, expectedRecords, expectedChunks});
  timing.verifyMs = Date.now() - t0;
  onProgress('preparing harness');
  const harness = prepareHarness({verified, protocol, srcDir, runRoot});
  timing.prepareMs = Date.now() - t0 - timing.verifyMs;
  let run;
  try {
    verifyUnchanged(verified.inputHashes);
    assertSourcesUnchanged(harness.modules);
    onProgress('running luau');
    run = await runLuauHarness(harness.runnerPath, {timeoutMs, luauPath});
    assertSourcesUnchanged(harness.modules);
  } catch (error) {
    error.message += `\n(harness kept for inspection at ${harness.runDir})`;
    throw error;
  }
  const result = run.result;
  // JavaScript re-checks invariants only; the signal logic ran in Luau.
  if (!isPlainObject(result)) throw new Error('SpringStudy result must be a JSON object');
  if (result.schema !== expectSchema) throw new Error(`SpringStudy result schema ${JSON.stringify(result.schema)} != ${JSON.stringify(expectSchema)}`);
  if (Object.hasOwn(result, 'provenance')) throw new Error('SpringStudy result already has a provenance key; the runner owns provenance');
  if (Object.hasOwn(result, 'newNativeSteps') && result.newNativeSteps !== 0) throw new Error('SpringStudy result reports native steps; this phase allows none');
  if (run.harness.recordCount !== verified.records.length) throw new Error(`Luau loaded ${run.harness.recordCount} records, verified ${verified.records.length}`);
  if (run.harness.inputRecordsFrozen !== true) throw new Error('Luau harness did not freeze the input records');
  if (!isPlainObject(run.harness.protocol) || run.harness.protocol.id !== protocol.id)
    throw new Error(`Luau SpringPolicy.protocol returned id ${JSON.stringify(run.harness.protocol?.id)}, requested ${protocol.id}`);

  const luau = {...luauIdentity(luauPath), argv: run.argv};
  const provenance = {
    schema: 'roalgo-spring-runner-provenance-1',
    newNativeSteps: 0,
    historicalNativeSteps: verified.audit.historicalNativeSteps,
    protocol: {id: protocol.id, authority: protocol.authority, sha256: sha256(stableStringify(run.harness.protocol)), table: run.harness.protocol},
    inputHashes: verified.inputHashes.map(({path, sha256: hash, bytes}) => ({name: basename(path), path, sha256: hash, bytes})),
    pins: {manifestSha256: pins.manifestSha256, checkpointSha256s: [...pins.checkpointSha256s], sourceJsonSha256: pins.sourceJsonSha256, sourceJsonPinnedFrom: pins.sourceJsonPinnedFrom},
    captureSource: {sourceHashes: verified.captureSource, note: 'manifest.sourceHashes (D15); on-disk indicator-v2 src is not hashed as capture source'},
    frozenRecordHash: verified.audit.frozenRecordHash,
    nativeConfigSha256: verified.nativeConfigSha256,
    srcHashes: harness.srcHashes,
    modules: harness.modules.map(({name, sha256: hash, bytes, requiredBy}) => ({name, sha256: hash, bytes, requiredBy})),
    harness: harness.harnessHashes,
    tools: toolHashes(),
    luau,
    node: process.version,
    data: {minimisedRecordsSha256: harness.minimisedRecordsSha256, modules: {count: harness.dataModules.count, recordsPerModule: harness.dataModules.recordsPerModule, totalBytes: harness.dataModules.totalBytes, digest: harness.dataModules.digest}, minimisation: harness.minimisation},
    verification: verified.checks,
    split: verified.split,
  };
  const plan = planOutput({...result, provenance}, {stem, threshold});

  verifyUnchanged(verified.inputHashes);
  const tw = Date.now();
  mkdirSync(outDir, {recursive: true});
  for (const file of [...plan.parts, plan.main])
    if (existsSync(join(outDir, file.name))) throw new Error(`Refusing to overwrite existing result ${join(outDir, file.name)} (write-once)`);
  const written = [];
  for (const file of [...plan.parts, plan.main]) {
    const path = join(outDir, file.name);
    writeFileSync(path, file.text, {flag: 'wx'});
    written.push({name: file.name, path, sha256: sha256(file.text), bytes: Buffer.byteLength(file.text)});
  }
  const mainReceipt = written.at(-1);
  mkdirSync(reportsDir, {recursive: true});
  mkdirSync(reportDir);
  timing.writeMs = Date.now() - tw;
  timing.totalMs = Date.now() - t0;
  const report = {
    schema: 'roalgo-spring-runner-report-1', status: 'complete', runId: stem, protocolId: protocol.id, createdAtUTC: new Date().toISOString(),
    result: {...mainReceipt, chunked: plan.chunked, threshold: plan.threshold, logicalSha256: plan.logicalSha256, logicalBytes: plan.logicalBytes, parts: written.slice(0, -1)},
    provenance, timing, luauHarness: run.harness, luauWallMs: run.wallMs, luauLogs: run.logs.slice(-200), luauStderr: run.stderr,
    inputsUnchangedBeforeWrite: true, runDir: harness.runDir, runDirKept: keepRunDir,
  };
  writeFileSync(join(reportDir, 'report.json'), JSON.stringify(report, null, 2) + '\n', {flag: 'wx'});
  writeFileSync(join(reportDir, 'report.md'), markdownReport(report), {flag: 'wx'});
  let post;
  try {
    verifyUnchanged(verified.inputHashes);
    assertSourcesUnchanged(harness.modules);
    post = {status: 'unchanged', checkedAtUTC: new Date().toISOString(), inputs: provenance.inputHashes.map(({name, sha256: hash}) => ({name, sha256: hash})), srcHashes: harness.srcHashes};
  } catch (error) {
    post = {status: 'changed', checkedAtUTC: new Date().toISOString(), error: error.message};
  }
  writeFileSync(join(reportDir, 'post-write-verification.json'), JSON.stringify(post, null, 2) + '\n', {flag: 'wx'});
  if (post.status !== 'unchanged') throw new Error('Inputs or sources changed after writing outputs: ' + post.error);
  if (!keepRunDir) rmSync(harness.runDir, {recursive: true, force: true});
  return {...report, reportDir, resultPath: mainReceipt.path, postWriteVerification: post};
}

export function parseCliArgs(argv, cwd = process.cwd()) {
  const valueFlags = {'--manifest': 'manifestPath', '--protocol': 'protocolId', '--out-dir': 'outDir', '--reports-dir': 'reportsDir', '--timeout-ms': 'timeoutMs'};
  const options = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--keep-run-dir') { options.keepRunDir = true; continue; }
    const eq = arg.indexOf('=');
    const flag = eq > 0 ? arg.slice(0, eq) : arg;
    if (!Object.hasOwn(valueFlags, flag)) throw new Error(`Unknown argument '${arg}'. Usage: --manifest <path> --protocol spring-consensus-v1 [--out-dir <dir>] [--reports-dir <dir>] [--timeout-ms <n>] [--keep-run-dir]`);
    let value = eq > 0 ? arg.slice(eq + 1) : argv[++i];
    if (value === undefined || value === '' || (eq < 0 && value.startsWith('--'))) throw new Error(`${flag} requires a value`);
    if (options[valueFlags[flag]] !== undefined) throw new Error(`${flag} given more than once`);
    options[valueFlags[flag]] = value;
  }
  if (options.protocolId === undefined) throw new Error(`--protocol is required (supported: ${Object.keys(PROTOCOLS).join(', ')})`);
  getProtocol(options.protocolId);
  for (const key of ['manifestPath', 'outDir', 'reportsDir']) if (options[key] !== undefined) options[key] = resolve(cwd, options[key]);
  if (options.timeoutMs !== undefined) {
    const n = Number(options.timeoutMs);
    if (!Number.isSafeInteger(n) || n <= 0) throw new Error('--timeout-ms must be a positive integer');
    options.timeoutMs = n;
  }
  return options;
}
