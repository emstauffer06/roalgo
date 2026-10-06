// Host-side validation of ResultStore exports (plan Task 5 "Concrete export path" and Task 7).
// Node 24, built-in modules only. No network.
//
// What it checks:
//   * ResultStore pages (lab/src/Experiment/ResultStore.luau, format "mrl-resultstore-1"): page count, page order
//     (pageIndex, firstRow), per-page and total UTF-8 byte counts, the maxPageBytes cap, row counts, strict UTF-8,
//     and that every number is finite. Each page's SHA-256 is computed over its exact bytes; the artifact hash is
//     SHA-256 of canonical JSON {kind, runId, records} (tools/canonical-json.mjs), independent of paging.
//   * Record schemas: forecasts (deterministic id runId:modelId:symbol:t, causal times, finite prediction, no
//     duplicate ids), outcomes (eligible -> finite actual; excluded -> plan exclusion reason), failures (never a
//     prediction field, never sharing an id with a forecast).
//   * Point metrics (RMSE, MAE, direction counts, always-up rate, correlation, mean prediction/actual, forecast
//     dispersion) recomputed independently from exported forecasts and outcomes, required to agree with the exported
//     Luau metric records within 1e-10, separately for each scoring subset in the metrics artifact ("all" eligible
//     origins and the plan's "nonOverlap" subset, whose selection rule is re-implemented here). Each record's
//     eligible and missing coverage counts are re-derived from the outcome population and must match exactly.
//   * Host acknowledgements {runId, artifactKind, sha256}: strict schema, wrong-run and stale-hash rejection.
//   * The PRNG of lab/src/Util/Prng.luau (xoshiro128** seeded by SplitMix64), re-implemented for cross-checks.
//
// Saved export layout (one directory per artifact kind, files hold the exact page bytes read from the bridge):
//   <exportDir>/<kind>/manifest.json   <exportDir>/<kind>/Page000001.json, Page000002.json, ...
// CLI: node tools/validate-results.mjs <exportDir> [--splits <splits.json>]
//   Splits default to lab/config/default.json. Prints a JSON summary; exits 1 on any failure.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalJson, sha256Hex } from "./canonical-json.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

export const RESULTSTORE_FORMAT = "mrl-resultstore-1";
export const MAX_PAGE_BYTES = 49152;
export const EXCLUSION_REASONS = Object.freeze([
  "invalid_input",
  "insufficient_warmup",
  "missing_intermediate_hour",
  "missing_target",
  "different_local_date",
  "split_boundary",
]);
const NAME = /^[A-Za-z0-9_-]+$/;
const SHA256 = /^[0-9a-f]{64}$/;
const TWO32 = 4294967296;

function fail(msg) {
  throw new Error(`validate-results: ${msg}`);
}

function isName(s) {
  return typeof s === "string" && NAME.test(s);
}

function isFiniteNumber(x) {
  return typeof x === "number" && Number.isFinite(x);
}

function isTimestamp(t) {
  return Number.isSafeInteger(t) && t >= 0;
}

function exactKeys(obj, required, optional, what) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) fail(`${what} must be an object`);
  for (const k of Object.keys(obj)) {
    if (!required.includes(k) && !optional.includes(k)) fail(`unknown field ${k} in ${what}`);
  }
  for (const k of required) if (!(k in obj)) fail(`missing field ${k} in ${what}`);
}

function assertAllFinite(value, path) {
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail(`non-finite number at ${path}`);
  } else if (Array.isArray(value)) {
    value.forEach((v, i) => assertAllFinite(v, `${path}[${i}]`));
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) assertAllFinite(v, `${path}.${k}`);
  }
}

// ------------------------------------------------------------------------------------------------ PRNG
// xoshiro128** 1.1 on 32-bit words; state seeded from SplitMix64(seed) as {lo(z1), hi(z1), lo(z2), hi(z2)}.
const M64 = (1n << 64n) - 1n;

function splitmix64Words(seed, count) {
  let s = BigInt(seed) & M64;
  const words = [];
  for (let i = 0; i < count; i++) {
    s = (s + 0x9e3779b97f4a7c15n) & M64;
    let z = s;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & M64;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & M64;
    z ^= z >> 31n;
    words.push(Number(z & 0xffffffffn), Number(z >> 32n));
  }
  return words;
}

const rotl = (x, k) => ((x << k) | (x >>> (32 - k))) >>> 0;

class Xoshiro128ss {
  constructor(words) {
    this.s = words.slice();
  }
  nextUint32() {
    const s = this.s;
    const result = Math.imul(rotl(Math.imul(s[1], 5) >>> 0, 7), 9) >>> 0;
    const t = (s[1] << 9) >>> 0;
    s[2] = (s[2] ^ s[0]) >>> 0;
    s[3] = (s[3] ^ s[1]) >>> 0;
    s[1] = (s[1] ^ s[2]) >>> 0;
    s[0] = (s[0] ^ s[3]) >>> 0;
    s[2] = (s[2] ^ t) >>> 0;
    s[3] = rotl(s[3], 11);
    return result;
  }
  nextNumber() {
    const a = this.nextUint32() >>> 5;
    const b = this.nextUint32() >>> 6;
    return (a * 67108864 + b) / 9007199254740992;
  }
  nextInteger(lo, hi) {
    if (!Number.isSafeInteger(lo) || !Number.isSafeInteger(hi) || lo > hi) fail("prng: nextInteger needs integers lo <= hi");
    const n = hi - lo + 1;
    if (n > TWO32) fail("prng: nextInteger range exceeds 2^32 values");
    if (n === TWO32) return lo + this.nextUint32();
    const limit = TWO32 - (TWO32 % n);
    let x = this.nextUint32();
    while (x >= limit) x = this.nextUint32();
    return lo + (x % n);
  }
  state() {
    return this.s.slice();
  }
}

export function createPrng(seed) {
  if (!Number.isSafeInteger(seed) || seed < 0) fail(`prng: seed must be an integer in [0, 2^53), got ${seed}`);
  return new Xoshiro128ss(splitmix64Words(seed, 2));
}

export function prngFromState(words) {
  if (!Array.isArray(words) || words.length !== 4 || !words.every((w) => Number.isInteger(w) && w >= 0 && w < TWO32)) {
    fail("prng: state must be four 32-bit words");
  }
  if (words.every((w) => w === 0)) fail("prng: all-zero state is invalid");
  return new Xoshiro128ss(words);
}

// ------------------------------------------------------------------------------------------------ pages
export function pageFileName(index) {
  return `Page${String(index).padStart(6, "0")}.json`;
}

export function artifactSha256(kind, runId, records) {
  return sha256Hex(canonicalJson({ kind, runId, records }));
}

function validateManifest(m) {
  exactKeys(m, ["format", "kind", "runId", "pageCount", "rowCount", "byteCount", "maxPageBytes", "pageBytes"], [], "manifest");
  if (m.format !== RESULTSTORE_FORMAT) fail(`manifest format ${m.format} is not ${RESULTSTORE_FORMAT}`);
  if (!isName(m.kind)) fail(`manifest kind ${m.kind} is invalid`);
  if (!isName(m.runId)) fail(`manifest runId ${m.runId} is invalid`);
  for (const k of ["pageCount", "rowCount", "byteCount"]) {
    if (!Number.isSafeInteger(m[k]) || m[k] < 0) fail(`manifest ${k} must be a non-negative integer`);
  }
  if (!Number.isSafeInteger(m.maxPageBytes) || m.maxPageBytes < 1 || m.maxPageBytes > MAX_PAGE_BYTES) {
    fail(`manifest maxPageBytes must be in [1, ${MAX_PAGE_BYTES}]`);
  }
  if (!Array.isArray(m.pageBytes) || m.pageBytes.length !== m.pageCount) fail("manifest pageBytes must list every page");
}

// pages: strings (exact text) or Buffers (exact bytes), in Page000001.. order.
export function reassemblePages(manifest, pages) {
  validateManifest(manifest);
  if (!Array.isArray(pages) || pages.length !== manifest.pageCount) {
    fail(`pageCount ${manifest.pageCount} but ${Array.isArray(pages) ? pages.length : "no"} pages supplied for ${manifest.kind}`);
  }
  const records = [];
  const pageSha256 = [];
  let bytesTotal = 0;
  pages.forEach((raw, i) => {
    const index = i + 1;
    let bytes;
    let text;
    if (Buffer.isBuffer(raw)) {
      bytes = raw;
      try {
        text = new TextDecoder("utf-8", { fatal: true }).decode(raw);
      } catch {
        fail(`page ${index} of ${manifest.kind} is not valid UTF-8`);
      }
    } else if (typeof raw === "string") {
      if (!raw.isWellFormed()) fail(`page ${index} of ${manifest.kind} is not valid UTF-8 (lone surrogate)`);
      text = raw;
      bytes = Buffer.from(raw, "utf8");
    } else {
      fail(`page ${index} must be a string or Buffer`);
    }
    if (bytes.length > manifest.maxPageBytes) fail(`page ${index} of ${manifest.kind} has ${bytes.length} bytes > maxPageBytes ${manifest.maxPageBytes}`);
    if (bytes.length !== manifest.pageBytes[i]) fail(`page ${index} of ${manifest.kind} has ${bytes.length} bytes, manifest says ${manifest.pageBytes[i]}`);
    bytesTotal += bytes.length;
    let page;
    try {
      page = JSON.parse(text);
    } catch (e) {
      fail(`page ${index} of ${manifest.kind} is not JSON: ${e.message}`);
    }
    exactKeys(page, ["firstRow", "kind", "pageIndex", "records", "rowCount", "runId"], [], `page ${index}`);
    if (page.kind !== manifest.kind) fail(`page ${index} kind ${page.kind} does not match manifest kind ${manifest.kind}`);
    if (page.runId !== manifest.runId) fail(`page ${index} runId ${page.runId} does not match manifest runId ${manifest.runId}`);
    if (page.pageIndex !== index) fail(`page ${index} carries pageIndex ${page.pageIndex}`);
    if (page.firstRow !== records.length + 1) fail(`page ${index} firstRow ${page.firstRow}, expected ${records.length + 1}`);
    if (!Array.isArray(page.records) || page.records.length === 0) fail(`page ${index} must carry a non-empty records array`);
    if (page.rowCount !== page.records.length) fail(`page ${index} rowCount ${page.rowCount} but ${page.records.length} records`);
    assertAllFinite(page.records, `${manifest.kind}.page${index}.records`);
    records.push(...page.records);
    pageSha256.push(sha256Hex(bytes));
  });
  if (bytesTotal !== manifest.byteCount) fail(`byteCount ${manifest.byteCount} but pages total ${bytesTotal} bytes`);
  if (records.length !== manifest.rowCount) fail(`rowCount ${manifest.rowCount} but pages carry ${records.length} records`);
  return {
    kind: manifest.kind,
    runId: manifest.runId,
    records,
    pageSha256,
    artifactSha256: artifactSha256(manifest.kind, manifest.runId, records),
  };
}

// ------------------------------------------------------------------------------------------------ records
function parseForecastId(id) {
  if (typeof id !== "string") fail("forecast id must be a string");
  const parts = id.split(":");
  if (parts.length !== 4 || !parts.slice(0, 3).every(isName)) fail(`malformed forecast id ${id}`);
  const t = Number(parts[3]);
  if (!isTimestamp(t) || String(t) !== parts[3]) fail(`malformed timestamp in forecast id ${id}`);
  return { runId: parts[0], modelId: parts[1], symbol: parts[2], t };
}

function resolveTiming(opts = {}) {
  const barSeconds = opts.barSeconds ?? 3600;
  const horizonHours = opts.horizonHours ?? 8;
  if (!Number.isSafeInteger(barSeconds) || barSeconds <= 0) fail("barSeconds must be a positive integer");
  if (!Number.isSafeInteger(horizonHours) || horizonHours <= 0) fail("horizonHours must be a positive integer");
  return { barSeconds, horizonHours };
}

const FORECAST_FIELDS = ["id", "runId", "modelId", "symbol", "t", "decisionTime", "outcomeTime", "prediction", "modelHash", "dataHash"];

// Returns Map id -> forecast.
export function validateForecastRecords(records, opts = {}) {
  const { barSeconds, horizonHours } = resolveTiming(opts);
  const byId = new Map();
  records.forEach((r, i) => {
    exactKeys(r, FORECAST_FIELDS, [], `forecast ${i + 1}`);
    if (opts.runId !== undefined && r.runId !== opts.runId) fail(`forecast ${r.id} belongs to run ${r.runId}, expected ${opts.runId}`);
    for (const k of ["runId", "modelId", "symbol"]) if (!isName(r[k])) fail(`forecast ${i + 1} has an invalid ${k}`);
    if (!isTimestamp(r.t)) fail(`forecast ${i + 1} t must be a non-negative integer`);
    const expected = `${r.runId}:${r.modelId}:${r.symbol}:${r.t}`;
    if (r.id !== expected) fail(`forecast id ${r.id} does not match expected id ${expected}`);
    if (r.decisionTime !== r.t + barSeconds) fail(`forecast ${r.id} decisionTime must equal t + ${barSeconds}`);
    if (r.outcomeTime !== r.decisionTime + horizonHours * barSeconds) fail(`forecast ${r.id} outcomeTime must equal decisionTime + ${horizonHours * barSeconds}`);
    if (!isFiniteNumber(r.prediction)) fail(`forecast ${r.id} prediction must be finite`);
    for (const k of ["modelHash", "dataHash"]) if (typeof r[k] !== "string" || r[k] === "") fail(`forecast ${r.id} ${k} must be a non-empty string`);
    if (byId.has(r.id)) fail(`duplicate forecast id ${r.id}`);
    byId.set(r.id, r);
  });
  return byId;
}

// Returns Map forecastId -> outcome.
export function validateOutcomeRecords(records, opts = {}) {
  const byId = new Map();
  records.forEach((r, i) => {
    exactKeys(r, ["forecastId", "eligible"], ["actual", "exclusionReason"], `outcome ${i + 1}`);
    const parsed = parseForecastId(r.forecastId);
    if (opts.runId !== undefined && parsed.runId !== opts.runId) fail(`outcome ${r.forecastId} belongs to run ${parsed.runId}, expected ${opts.runId}`);
    if (typeof r.eligible !== "boolean") fail(`outcome ${r.forecastId} eligible must be boolean`);
    if (r.eligible) {
      if (!isFiniteNumber(r.actual)) fail(`eligible outcome ${r.forecastId} needs a finite actual`);
      if (r.exclusionReason !== undefined) fail(`eligible outcome ${r.forecastId} must not carry an exclusionReason`);
    } else {
      if (r.actual !== undefined) fail(`excluded outcome ${r.forecastId} must not carry an actual`);
      if (!EXCLUSION_REASONS.includes(r.exclusionReason)) fail(`outcome ${r.forecastId} has unknown exclusionReason ${r.exclusionReason}`);
    }
    if (byId.has(r.forecastId)) fail(`duplicate outcome for ${r.forecastId}`);
    byId.set(r.forecastId, r);
  });
  return byId;
}

// Failures are never numeric forecasts. opts.forecastIds (Map/Set) rejects failures sharing a forecast id.
export function validateFailureRecords(records, opts = {}) {
  const { barSeconds } = resolveTiming(opts);
  const byId = new Map();
  records.forEach((r, i) => {
    if (r && typeof r === "object" && "prediction" in r) fail(`failure ${i + 1} must not carry a prediction`);
    exactKeys(r, ["id", "runId", "modelId", "symbol", "t", "decisionTime", "reason"], ["detail", "phase"], `failure ${i + 1}`);
    if (opts.runId !== undefined && r.runId !== opts.runId) fail(`failure ${r.id} belongs to run ${r.runId}, expected ${opts.runId}`);
    const parsed = parseForecastId(r.id);
    if (parsed.runId !== r.runId || parsed.modelId !== r.modelId || parsed.symbol !== r.symbol || parsed.t !== r.t) fail(`failure ${r.id} fields disagree with its id`);
    if (r.decisionTime !== r.t + barSeconds) fail(`failure ${r.id} decisionTime must equal t + ${barSeconds}`);
    if (typeof r.reason !== "string" || r.reason === "") fail(`failure ${r.id} needs a reason`);
    if (opts.forecastIds && opts.forecastIds.has(r.id)) fail(`id ${r.id} is both a forecast and a failure`);
    if (byId.has(r.id)) fail(`duplicate failure id ${r.id}`);
    byId.set(r.id, r);
  });
  return byId;
}

// ------------------------------------------------------------------------------------------------ metrics
function checkSplits(s) {
  if (!s || !isFiniteNumber(s.validationStart) || !isFiniteNumber(s.testStart) || !isFiniteNumber(s.datasetEnd) ||
    !(s.validationStart < s.testStart && s.testStart < s.datasetEnd)) {
    fail("splits must be finite and ordered validationStart < testStart < datasetEnd");
  }
  return s;
}

// Plan Section 2.4 split rule with exclusive upper bounds.
export function labelSplit(decisionTime, outcomeTime, splits) {
  const s = checkSplits(splits);
  if (decisionTime < s.validationStart && outcomeTime < s.validationStart) return "train";
  if (decisionTime >= s.validationStart && decisionTime < s.testStart && outcomeTime < s.testStart) return "validation";
  if (decisionTime >= s.testStart && outcomeTime < s.datasetEnd) return "final";
  return "none";
}

function groupMetrics(rows) {
  const n = rows.length;
  let sse = 0;
  let sae = 0;
  let correct = 0;
  let total = 0;
  let up = 0;
  let zeroPredictions = 0;
  let sumP = 0;
  let sumA = 0;
  for (const { p, a } of rows) {
    const e = p - a;
    sse += e * e;
    sae += Math.abs(e);
    sumP += p;
    sumA += a;
    if (a !== 0) {
      total += 1;
      if (a > 0) up += 1;
      if (p === 0) zeroPredictions += 1;
      else if ((p > 0) === (a > 0)) correct += 1;
    }
  }
  const meanP = sumP / n;
  const meanA = sumA / n;
  const constant = (key) => rows.every((r) => r[key] === rows[0][key]);
  const constP = constant("p");
  let forecastDispersion = 0;
  if (!constP) {
    let vp = 0;
    for (const { p } of rows) vp += (p - meanP) * (p - meanP);
    forecastDispersion = Math.sqrt(vp / n);
  }
  let correlation = null;
  if (n >= 2 && !constP && !constant("a")) {
    // Scale-invariant form: deviations divided by their largest magnitude, so the sums stay in [1, n] and
    // extreme magnitudes cannot underflow/overflow into NaN or Infinity.
    let sp = 0;
    let sa = 0;
    for (const { p, a } of rows) {
      sp = Math.max(sp, Math.abs(p - meanP));
      sa = Math.max(sa, Math.abs(a - meanA));
    }
    if (sp > 0 && sa > 0) {
      let cov = 0;
      let vp = 0;
      let va = 0;
      for (const { p, a } of rows) {
        const dp = (p - meanP) / sp;
        const da = (a - meanA) / sa;
        cov += dp * da;
        vp += dp * dp;
        va += da * da;
      }
      correlation = cov / (Math.sqrt(vp) * Math.sqrt(va));
    }
  }
  return {
    n,
    rmse: Math.sqrt(sse / n),
    mae: sae / n,
    directionCorrect: correct,
    directionTotal: total,
    directionAccuracy: total > 0 ? correct / total : null,
    alwaysUpAccuracy: total > 0 ? up / total : null,
    zeroPredictions,
    correlation,
    meanPrediction: meanP,
    meanActual: meanA,
    forecastDispersion,
  };
}

export const SUBSETS = Object.freeze(["all", "nonOverlap"]);

// Plan Section 6 non-overlapping subset, implemented independently of lab/src/Experiment/Evaluator.luau: sort the
// distinct origin timestamps and accept one only when its decision time is at or after the previous selected
// origin's outcome time.
export function nonOverlapOrigins(origins, opts = {}) {
  const { barSeconds, horizonHours } = resolveTiming(opts);
  const sorted = [...new Set(origins)].sort((a, b) => a - b);
  const selected = [];
  let lastOutcome = -Infinity;
  for (const t of sorted) {
    if (!isFiniteNumber(t)) fail(`non-finite origin timestamp ${t}`);
    const decision = t + barSeconds;
    if (decision >= lastOutcome) {
      selected.push(t);
      lastOutcome = decision + horizonHours * barSeconds;
    }
  }
  return selected;
}

// Independent recomputation from exported forecasts and outcomes.
// opts.subset: "all" (default, every eligible origin) or "nonOverlap" (the plan's non-overlapping subset, chosen per
// split from the structural population of eligible outcomes, not from where a model happened to forecast).
// Returns Map "runId:modelId|symbol|split" -> {n, rmse, mae, direction counts/accuracy, alwaysUpAccuracy,
// zeroPredictions, correlation, meanPrediction, meanActual, forecastDispersion}; only eligible origins with an issued
// forecast are scored. The Map also carries .subset and .population (Map "symbol|split" -> eligible origin count),
// the union over every outcome record, from which each model's missing count is eligible - n.
export function recomputePointMetrics(forecasts, outcomes, opts = {}) {
  const splits = checkSplits(opts.splits);
  const { barSeconds, horizonHours } = resolveTiming(opts);
  const subset = opts.subset ?? "all";
  if (!SUBSETS.includes(subset)) fail(`subset must be one of ${SUBSETS.join(", ")}, got ${subset}`);
  const splitOf = (t) => {
    const decision = t + barSeconds;
    return labelSplit(decision, decision + horizonHours * barSeconds, splits);
  };
  const outcomeById = new Map();
  const originState = new Map(); // "symbol|t" -> {eligible, actual}
  const eligibleOrigins = new Map(); // "symbol|t" -> {symbol, t, split}
  for (const o of outcomes) {
    if (outcomeById.has(o.forecastId)) fail(`duplicate outcome for ${o.forecastId}`);
    outcomeById.set(o.forecastId, o);
    const { symbol, t } = parseForecastId(o.forecastId);
    const ok = `${symbol}|${t}`;
    const prior = originState.get(ok);
    if (prior) {
      if (prior.eligible !== o.eligible || prior.actual !== o.actual) fail(`inconsistent outcomes for ${ok} across models`);
      continue;
    }
    originState.set(ok, { eligible: o.eligible, actual: o.actual });
    if (o.eligible) {
      const split = splitOf(t);
      if (split === "none") fail(`eligible outcome ${o.forecastId} violates the split boundaries`);
      eligibleOrigins.set(ok, { symbol, t, split });
    }
  }
  let kept = null;
  if (subset === "nonOverlap") {
    const bySplit = new Map();
    for (const { t, split } of eligibleOrigins.values()) {
      if (!bySplit.has(split)) bySplit.set(split, []);
      bySplit.get(split).push(t);
    }
    kept = new Set();
    for (const [split, ts] of bySplit) {
      for (const t of nonOverlapOrigins(ts, { barSeconds, horizonHours })) kept.add(`${split}|${t}`);
    }
  }
  const inSubset = (t, split) => kept === null || kept.has(`${split}|${t}`);
  const population = new Map();
  for (const { symbol, t, split } of eligibleOrigins.values()) {
    if (!inSubset(t, split)) continue;
    const pk = `${symbol}|${split}`;
    population.set(pk, (population.get(pk) ?? 0) + 1);
  }
  const groups = new Map();
  const seen = new Set();
  for (const f of forecasts) {
    if (seen.has(f.id)) fail(`duplicate forecast id ${f.id}`);
    seen.add(f.id);
    const o = outcomeById.get(f.id);
    if (!o) fail(`forecast ${f.id} has no outcome record`);
    if (!o.eligible) continue;
    const split = splitOf(f.t);
    if (split === "none") fail(`eligible outcome ${f.id} violates the split boundaries`);
    if (!inSubset(f.t, split)) continue;
    if (!isFiniteNumber(f.prediction) || !isFiniteNumber(o.actual)) fail(`non-finite value for ${f.id}`);
    const key = `${f.runId}:${f.modelId}|${f.symbol}|${split}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ t: f.t, p: f.prediction, a: o.actual });
  }
  const out = new Map();
  for (const [key, rows] of groups) {
    rows.sort((x, y) => x.t - y.t);
    out.set(key, groupMetrics(rows));
  }
  out.subset = subset;
  out.population = population;
  return out;
}

// Compares exported Luau metric records (Evaluator.metricRecords) of ONE scoring subset with the
// recomputePointMetrics output for that subset. Real-valued fields must agree within tol (log-return units);
// counts, including each record's eligible and missing coverage, must match exactly.
export function compareMetrics(luauRecords, recomputed, tol = 1e-10) {
  const problems = [];
  let maxAbsDiff = 0;
  let compared = 0;
  const seen = new Set();
  const subset = recomputed.subset ?? "all";
  const near = (field, key, a, b) => {
    if (!isFiniteNumber(a) || !isFiniteNumber(b)) {
      problems.push(`${key}: ${field} not finite on both sides (${a} vs ${b})`);
      return;
    }
    const d = Math.abs(a - b);
    maxAbsDiff = Math.max(maxAbsDiff, d);
    if (d > tol) problems.push(`${key}: ${field} differs by ${d} (> ${tol})`);
  };
  const optionalNear = (field, key, a, b) => {
    if (b === null) {
      if (a !== undefined && a !== null) problems.push(`${key}: ${field} should be undefined`);
    } else if (a === undefined || a === null) {
      problems.push(`${key}: ${field} missing in Luau record`);
    } else {
      near(field, key, a, b);
    }
  };
  for (const r of luauRecords) {
    const key = `${r.runId}:${r.modelId}|${r.symbol}|${r.split}`;
    if ((r.subset ?? "all") !== subset) {
      problems.push(`${key}: record subset ${r.subset} compared against a ${subset} recomputation`);
      continue;
    }
    if (seen.has(key)) problems.push(`${key}: duplicate Luau metric record`);
    seen.add(key);
    const g = recomputed.get(key);
    if (!Number.isSafeInteger(r.n) || r.n < 0) {
      problems.push(`${key}: n must be a non-negative integer`);
      continue;
    }
    if (recomputed.population instanceof Map) {
      const eligible = recomputed.population.get(`${r.symbol}|${r.split}`) ?? 0;
      if (r.eligible !== eligible) problems.push(`${key}: eligible differs (Luau ${r.eligible}, host ${eligible})`);
      const missing = eligible - (g ? g.n : 0);
      if (r.missing !== missing) problems.push(`${key}: missing differs (Luau ${r.missing}, host ${missing})`);
    }
    if (r.n === 0) {
      if (g) problems.push(`${key}: n differs (Luau 0, host ${g.n})`);
      continue;
    }
    if (!g) {
      problems.push(`${key}: n differs (Luau ${r.n}, host 0)`);
      continue;
    }
    compared += 1;
    if (r.n !== g.n) problems.push(`${key}: n differs (Luau ${r.n}, host ${g.n})`);
    near("rmse", key, r.rmse, g.rmse);
    near("mae", key, r.mae, g.mae);
    for (const f of ["directionCorrect", "directionTotal", "zeroPredictions"]) {
      if (r[f] !== g[f]) problems.push(`${key}: ${f} differs (Luau ${r[f]}, host ${g[f]})`);
    }
    optionalNear("directionAccuracy", key, r.directionAccuracy, g.directionAccuracy);
    optionalNear("alwaysUpAccuracy", key, r.alwaysUpAccuracy, g.alwaysUpAccuracy);
    // correlation is undefined when either series has zero variance
    optionalNear("correlation", key, r.correlation, g.correlation);
    near("meanPrediction", key, r.meanPrediction, g.meanPrediction);
    near("meanActual", key, r.meanActual, g.meanActual);
    near("forecastDispersion", key, r.forecastDispersion, g.forecastDispersion);
  }
  for (const key of recomputed.keys()) {
    if (!seen.has(key)) problems.push(`${key}: no Luau metric record for a scored group`);
  }
  if (problems.length > 0) fail(`metric mismatch (${subset}):\n  ${problems.join("\n  ")}`);
  return { subset, compared, maxAbsDiff, tolerance: tol };
}

// ------------------------------------------------------------------------------------------------ acknowledgements
// Schema: {runId, artifactKind, sha256}, canonical JSON text, nothing else. The plugin stores it in the bridge's
// acknowledgement StringValue; lab/src/Experiment/ResultStore.luau parseAcknowledgement reads the same text.
function validateAckObject(obj) {
  exactKeys(obj, ["artifactKind", "runId", "sha256"], [], "acknowledgement");
  if (!isName(obj.runId)) fail(`acknowledgement runId ${obj.runId} is invalid`);
  if (!isName(obj.artifactKind)) fail(`acknowledgement artifactKind ${obj.artifactKind} is invalid`);
  if (typeof obj.sha256 !== "string" || !SHA256.test(obj.sha256)) fail("acknowledgement sha256 must be 64 lowercase hex digits");
  return Object.freeze({ artifactKind: obj.artifactKind, runId: obj.runId, sha256: obj.sha256 });
}

export function makeAcknowledgement({ runId, artifactKind, sha256 }) {
  return canonicalJson(validateAckObject({ runId, artifactKind, sha256 }));
}

export function parseAcknowledgement(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (e) {
    fail(`acknowledgement is not JSON: ${e.message}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("acknowledgement must be a JSON object");
  return validateAckObject(value);
}

// expected: the current artifact {runId, artifactKind, sha256}. Rejects a wrong run, a different artifact kind, or a
// stale hash (the artifact changed after it was acknowledged).
export function checkAcknowledgement(ack, expected) {
  const a = typeof ack === "string" ? parseAcknowledgement(ack) : validateAckObject(ack);
  if (a.runId !== expected.runId) fail(`wrong run: acknowledgement is for ${a.runId}, current run is ${expected.runId}`);
  if (a.artifactKind !== expected.artifactKind) fail(`wrong artifact kind: acknowledgement is for ${a.artifactKind}, expected ${expected.artifactKind}`);
  if (a.sha256 !== expected.sha256) fail(`stale acknowledgement: sha256 ${a.sha256} does not match current artifact ${expected.sha256}`);
  return true;
}

// ------------------------------------------------------------------------------------------------ directory
export function readKindDirectory(kindDir) {
  const manifest = JSON.parse(readFileSync(join(kindDir, "manifest.json"), "utf8"));
  const pageFiles = readdirSync(kindDir).filter((f) => /^Page\d{6}\.json$/.test(f)).sort();
  pageFiles.forEach((f, i) => {
    if (f !== pageFileName(i + 1)) fail(`${kindDir}: page files are not contiguous (found ${f}, expected ${pageFileName(i + 1)})`);
  });
  const pages = pageFiles.map((f) => readFileSync(join(kindDir, f)));
  return { manifest, pages };
}

// Validates every <kind>/ directory under exportDir; cross-checks forecasts/outcomes/failures and recomputes
// metrics when those kinds are present. opts: {splits, barSeconds, horizonHours, tolerance}.
export function validateExportDirectory(exportDir, opts = {}) {
  const kinds = {};
  const records = {};
  let runId;
  for (const name of readdirSync(exportDir).sort()) {
    const kindDir = join(exportDir, name);
    if (!statSync(kindDir).isDirectory()) continue;
    const { manifest, pages } = readKindDirectory(kindDir);
    if (manifest.kind !== name) fail(`directory ${name} holds kind ${manifest.kind}`);
    const out = reassemblePages(manifest, pages);
    if (runId === undefined) runId = out.runId;
    else if (out.runId !== runId) fail(`kind ${name} belongs to run ${out.runId}, others to ${runId}`);
    kinds[name] = {
      rowCount: manifest.rowCount,
      pageCount: manifest.pageCount,
      byteCount: manifest.byteCount,
      artifactSha256: out.artifactSha256,
      pageSha256: out.pageSha256,
    };
    records[name] = out.records;
  }
  if (Object.keys(kinds).length === 0) fail(`no exported kinds under ${exportDir}`);
  let forecastIds;
  if (records.forecasts) forecastIds = validateForecastRecords(records.forecasts, { runId, ...opts });
  if (records.outcomes) {
    const outcomeById = validateOutcomeRecords(records.outcomes, { runId });
    if (forecastIds) for (const id of forecastIds.keys()) if (!outcomeById.has(id)) fail(`forecast ${id} has no outcome record`);
  }
  if (records.failures) validateFailureRecords(records.failures, { runId, forecastIds, ...opts });
  let metrics;
  if (records.metrics && records.forecasts && records.outcomes) {
    // Each scoring subset in the metrics artifact is checked against its own independent recomputation.
    const bySubset = new Map();
    for (const r of records.metrics) {
      const subset = r && r.subset !== undefined ? r.subset : "all";
      if (!SUBSETS.includes(subset)) fail(`metric record has unknown subset ${subset}`);
      if (!bySubset.has(subset)) bySubset.set(subset, []);
      bySubset.get(subset).push(r);
    }
    const tolerance = opts.tolerance ?? 1e-10;
    metrics = { compared: 0, maxAbsDiff: 0, tolerance, subsets: {} };
    for (const subset of SUBSETS) {
      if (!bySubset.has(subset)) continue;
      const recomputed = recomputePointMetrics(records.forecasts, records.outcomes, { ...opts, subset });
      const summary = compareMetrics(bySubset.get(subset), recomputed, tolerance);
      metrics.subsets[subset] = summary;
      metrics.compared += summary.compared;
      metrics.maxAbsDiff = Math.max(metrics.maxAbsDiff, summary.maxAbsDiff);
    }
  }
  return { runId, kinds, metrics };
}

function main(argv) {
  const args = argv.slice(2);
  const dir = args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--splits");
  if (!dir) {
    console.error("usage: node tools/validate-results.mjs <exportDir> [--splits <splits.json>]");
    return 2;
  }
  const si = args.indexOf("--splits");
  let splits;
  let barSeconds;
  let horizonHours;
  if (si >= 0) {
    splits = JSON.parse(readFileSync(args[si + 1], "utf8"));
  } else {
    const config = JSON.parse(readFileSync(join(root, "lab", "config", "default.json"), "utf8"));
    splits = config.splits;
    barSeconds = config.barSeconds;
    horizonHours = config.horizonHours;
  }
  try {
    const summary = validateExportDirectory(dir, { splits, barSeconds, horizonHours });
    console.log(JSON.stringify(summary, null, 2));
    return 0;
  } catch (e) {
    console.error(e.message);
    return 1;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main(process.argv);
}
