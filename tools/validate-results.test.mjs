// Tests for tools/validate-results.mjs and tools/canonical-json.mjs (node --test tools/validate-results.test.mjs).
// Fixtures are synthetic and Luau-printed (tools/gen-result-fixtures.mjs); no real validation/final data is read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalJson, canonicalSha256, sha256Hex } from "./canonical-json.mjs";
import {
  createPrng,
  prngFromState,
  reassemblePages,
  validateForecastRecords,
  validateOutcomeRecords,
  validateFailureRecords,
  recomputePointMetrics,
  compareMetrics,
  artifactSha256,
  makeAcknowledgement,
  parseAcknowledgement,
  checkAcknowledgement,
  validateExportDirectory,
  pageFileName,
  nonOverlapOrigins,
} from "./validate-results.mjs";
import { readFixture, readFixtureText } from "./gen-result-fixtures.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sample = readFixture("ExportSample");
const timing = { splits: sample.splits, barSeconds: sample.barSeconds, horizonHours: sample.horizonHours };

// ---------------------------------------------------------------------------------------------- canonical JSON
test("canonical JSON sorts keys recursively, keeps array order, no whitespace", () => {
  assert.equal(canonicalJson({ b: 1, a: { d: [3, 1], c: null } }), '{"a":{"c":null,"d":[3,1]},"b":1}');
  assert.equal(canonicalJson([{ y: true, x: "s" }, []]), '[{"x":"s","y":true},[]]');
  assert.equal(canonicalJson({}), "{}");
  // code-point (UTF-8 byte) order, not UTF-16 code-unit order: U+FFFF sorts before U+1F600
  assert.equal(canonicalJson({ "\u{1F600}": 3, "\uFFFF": 4, z: 1, "é": 2 }), '{"z":1,"é":2,"\uFFFF":4,"\u{1F600}":3}');
  assert.equal(canonicalJson("a\"b\\\n\u0001"), JSON.stringify("a\"b\\\n\u0001"));
  assert.equal(canonicalJson(0.1), "0.1");
  assert.equal(canonicalJson(-0), "0");
  assert.equal(canonicalJson(2 ** 53), "9007199254740992");
});

test("canonical JSON rejects values that cannot be hashed unambiguously", () => {
  for (const bad of [NaN, Infinity, -Infinity, undefined, () => 1, 10n, Symbol("s"), new Date(0), new Map()]) {
    assert.throws(() => canonicalJson(bad), /canonical-json/);
    assert.throws(() => canonicalJson({ a: bad }), /canonical-json/);
  }
  assert.throws(() => canonicalJson([1, , 3]), /sparse/); // eslint-disable-line no-sparse-arrays
  assert.throws(() => canonicalJson("\ud800"), /surrogate/);
  const cyclic = {};
  cyclic.self = cyclic;
  assert.throws(() => canonicalJson(cyclic), /cycle/);
});

test("SHA-256 uses UTF-8 bytes of the canonical text", () => {
  assert.equal(sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert.equal(canonicalSha256({ b: 2, a: 1 }), sha256Hex('{"a":1,"b":2}'));
  assert.equal(canonicalSha256({ a: 1, b: 2 }), canonicalSha256({ b: 2, a: 1 }));
  assert.equal(sha256Hex(Buffer.from("é", "utf8")), sha256Hex("é"));
});

test("Luau pages already use canonical key order", () => {
  const checkOrder = (v) => {
    if (Array.isArray(v)) return v.forEach(checkOrder);
    if (v && typeof v === "object") {
      const keys = Object.keys(v);
      const sorted = [...keys].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
      assert.deepEqual(keys, sorted);
      keys.forEach((k) => checkOrder(v[k]));
    }
  };
  for (const entry of Object.values(sample.kinds)) for (const page of entry.pages) checkOrder(JSON.parse(page));
});

// ---------------------------------------------------------------------------------------------- PRNG
const M64 = (1n << 64n) - 1n;
const M32 = 0xffffffffn;
function bigSplitmix(seed) {
  let s = BigInt(seed) & M64;
  return () => {
    s = (s + 0x9e3779b97f4a7c15n) & M64;
    let z = s;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & M64;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & M64;
    return z ^ (z >> 31n);
  };
}
function bigXoshiro(seed) {
  const sm = bigSplitmix(seed);
  const z1 = sm();
  const z2 = sm();
  const s = [z1 & M32, z1 >> 32n, z2 & M32, z2 >> 32n];
  const rotl = (x, k) => ((x << BigInt(k)) | (x >> BigInt(32 - k))) & M32;
  return () => {
    const r = (rotl((s[1] * 5n) & M32, 7) * 9n) & M32;
    const t = (s[1] << 9n) & M32;
    s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3]; s[2] ^= t; s[3] = rotl(s[3], 11);
    return Number(r);
  };
}

test("JS PRNG reproduces the published xoshiro128** vector", () => {
  const g = prngFromState([1, 2, 3, 4]);
  assert.deepEqual(
    Array.from({ length: 10 }, () => g.nextUint32()),
    [11520, 0, 5927040, 70819200, 2031721883, 1637235492, 1287239034, 3734860849, 3729100597, 4258142804],
  );
});

test("JS PRNG agrees with an independent BigInt reference", () => {
  for (const seed of [0, 1, 1234567, 20261004, 20261005, 2 ** 53 - 1]) {
    const ref = bigXoshiro(seed);
    const g = createPrng(seed);
    for (let i = 0; i < 256; i++) assert.equal(g.nextUint32(), ref(), `seed ${seed} draw ${i}`);
  }
});

test("JS PRNG reproduces the Luau-printed vector fixture exactly", () => {
  const vectors = readFixture("PrngVectors");
  assert.equal(vectors.identity, "xoshiro128**/splitmix64/v1");
  assert.ok(vectors.cases.length >= 4);
  for (const c of vectors.cases) {
    assert.deepEqual(createPrng(c.seed).state(), c.initialState, `state ${c.seed}`);
    const g = createPrng(c.seed);
    const take = (n, fn) => Array.from({ length: n }, fn);
    assert.deepEqual(take(16, () => g.nextUint32()), c.uint32, `uint32 ${c.seed}`);
    assert.deepEqual(take(8, () => g.nextNumber()), c.numbers, `numbers ${c.seed}`);
    assert.deepEqual(take(16, () => g.nextInteger(1, 248)), c.blockStarts, `blockStarts ${c.seed}`);
    assert.deepEqual(take(8, () => g.nextInteger(0, 2 ** 31)), c.rejecting, `rejecting ${c.seed}`);
    assert.deepEqual(take(8, () => g.nextInteger(-3, 3)), c.signed, `signed ${c.seed}`);
    assert.deepEqual(take(4, () => g.nextInteger(0, 2 ** 32 - 1)), c.full, `full ${c.seed}`);
  }
  const fixed = prngFromState(vectors.stateVector.state);
  assert.deepEqual(Array.from({ length: 10 }, () => fixed.nextUint32()), vectors.stateVector.uint32);
});

test("JS PRNG validates seeds and bounds", () => {
  for (const bad of [-1, 1.5, NaN, 2 ** 53, "1"]) assert.throws(() => createPrng(bad), /seed/);
  const g = createPrng(7);
  assert.throws(() => g.nextInteger(3, 2), /prng/);
  assert.throws(() => g.nextInteger(0, 2 ** 32), /prng/);
  assert.throws(() => prngFromState([0, 0, 0, 0]), /zero/);
});

// ---------------------------------------------------------------------------------------------- pages
function kindRecords(kind) {
  const { manifest, pages } = sample.kinds[kind];
  return reassemblePages(manifest, pages);
}

test("reassembles every exported kind and verifies counts, bytes and order", () => {
  for (const kind of ["forecasts", "outcomes", "failures", "metrics"]) {
    const { manifest, pages } = sample.kinds[kind];
    const out = reassemblePages(manifest, pages);
    assert.equal(out.records.length, manifest.rowCount, kind);
    assert.equal(out.kind, kind);
    assert.equal(out.runId, sample.runId);
    assert.equal(out.pageSha256.length, manifest.pageCount);
    assert.match(out.artifactSha256, /^[0-9a-f]{64}$/);
    assert.ok(manifest.pageCount >= 1);
    for (const p of pages) assert.ok(Buffer.byteLength(p, "utf8") <= sample.maxPageBytes);
  }
  assert.ok(sample.kinds.forecasts.manifest.pageCount > 5, "the sample spans many pages");
  // byte length differs from UTF-16 length where the failure detail is non-ASCII
  const failurePage = sample.kinds.failures.pages[0];
  assert.ok(Buffer.byteLength(failurePage, "utf8") > failurePage.length);
  assert.equal(sample.kinds.failures.manifest.byteCount, Buffer.byteLength(failurePage, "utf8"));
});

test("record schemas: finite values, deterministic ids, no duplicate forecasts", () => {
  const forecasts = kindRecords("forecasts").records;
  const outcomes = kindRecords("outcomes").records;
  const failures = kindRecords("failures").records;
  const byId = validateForecastRecords(forecasts, { runId: sample.runId, ...timing });
  assert.equal(byId.size, forecasts.length);
  validateOutcomeRecords(outcomes, { runId: sample.runId });
  validateFailureRecords(failures, { runId: sample.runId, forecastIds: byId });
  const dup = [...forecasts, forecasts[3]];
  assert.throws(() => validateForecastRecords(dup, { runId: sample.runId, ...timing }), /duplicate forecast id/);
  const wrongId = [{ ...forecasts[0], id: forecasts[1].id }];
  assert.throws(() => validateForecastRecords(wrongId, { runId: sample.runId, ...timing }), /id/);
  const zeroAsFailure = [{ ...failures[0], prediction: 0 }];
  assert.throws(() => validateFailureRecords(zeroAsFailure, { runId: sample.runId }), /prediction|field/);
  assert.throws(() => validateForecastRecords(forecasts, { runId: "other-run", ...timing }), /run/);
  const early = [{ ...forecasts[0], decisionTime: forecasts[0].t }];
  assert.throws(() => validateForecastRecords(early, { runId: sample.runId, ...timing }), /decisionTime/);
  const badOutcome = [{ forecastId: outcomes[0].forecastId, eligible: false, exclusionReason: "made_up" }];
  assert.throws(() => validateOutcomeRecords(badOutcome, { runId: sample.runId }), /exclusionReason/);
});

function buildPage(kind, runId, pageIndex, firstRow, records) {
  return canonicalJson({ firstRow, kind, pageIndex, records, rowCount: records.length, runId });
}
function buildManifest(kind, runId, pages, maxPageBytes = 4096) {
  const pageBytes = pages.map((p) => Buffer.byteLength(p, "utf8"));
  const rowCount = pages.reduce((n, p) => n + JSON.parse(p).records.length, 0);
  return {
    format: "mrl-resultstore-1", kind, runId, pageCount: pages.length, rowCount,
    byteCount: pageBytes.reduce((a, b) => a + b, 0), maxPageBytes, pageBytes,
  };
}

test("tampered or incomplete transfers are rejected", () => {
  const { manifest, pages } = sample.kinds.forecasts;
  assert.throws(() => reassemblePages(manifest, pages.slice(0, -1)), /pageCount/);
  const swapped = [pages[1], pages[0], ...pages.slice(2)];
  assert.throws(() => reassemblePages(manifest, swapped), /pageIndex|bytes|firstRow/);
  assert.throws(() => reassemblePages({ ...manifest, byteCount: manifest.byteCount + 1 }, pages), /byteCount/);
  assert.throws(() => reassemblePages({ ...manifest, rowCount: manifest.rowCount - 1 }, pages), /rowCount/);
  assert.throws(() => reassemblePages({ ...manifest, runId: "other-run" }, pages), /runId/);
  // a page edited in transit no longer matches its recorded byte length
  const edited = [pages[0].replace('"prediction":', '"prediction": '), ...pages.slice(1)];
  assert.throws(() => reassemblePages(manifest, edited), /bytes/);
  // over-cap page, non-finite value, invalid UTF-8
  const recs = [{ v: 1 }];
  const big = buildPage("rows", "run-1", 1, 1, [{ s: "x".repeat(5000) }]);
  assert.throws(() => reassemblePages(buildManifest("rows", "run-1", [big], 4096), [big]), /maxPageBytes/);
  const inf = '{"firstRow":1,"kind":"rows","pageIndex":1,"records":[{"v":1e400}],"rowCount":1,"runId":"run-1"}';
  assert.throws(() => reassemblePages(buildManifest("rows", "run-1", [inf]), [inf]), /finite/);
  const okPage = buildPage("rows", "run-1", 1, 1, recs);
  const bytes = Buffer.from(okPage, "utf8");
  const broken = Buffer.concat([bytes.subarray(0, bytes.length - 2), Buffer.from([0xc3]), bytes.subarray(bytes.length - 1)]);
  const m = buildManifest("rows", "run-1", [okPage]);
  m.pageBytes = [broken.length];
  m.byteCount = broken.length;
  assert.throws(() => reassemblePages(m, [broken]), /UTF-8/);
  // a JS-built page with the same records passes and gives the same artifact hash at any page size
  assert.doesNotThrow(() => reassemblePages(buildManifest("rows", "run-1", [okPage]), [okPage]));
});

test("artifact hash depends on records, not on how they were paged", () => {
  const { records, artifactSha256: hash } = kindRecords("forecasts");
  const half = Math.ceil(records.length / 2);
  const pages = [
    buildPage("forecasts", sample.runId, 1, 1, records.slice(0, half)),
    buildPage("forecasts", sample.runId, 2, half + 1, records.slice(half)),
  ];
  const repaged = reassemblePages(buildManifest("forecasts", sample.runId, pages, 49152), pages);
  assert.equal(repaged.artifactSha256, hash);
  assert.equal(hash, artifactSha256("forecasts", sample.runId, records));
  assert.notEqual(artifactSha256("forecasts", "other-run", records), hash);
});

// ---------------------------------------------------------------------------------------------- metrics
// The exported metrics artifact carries both scoring populations; each is checked against its own recomputation.
const metricsOf = (subset) => kindRecords("metrics").records.filter((r) => r.subset === subset);

test("independent point metrics agree with the Luau metrics within 1e-10", () => {
  const forecasts = kindRecords("forecasts").records;
  const outcomes = kindRecords("outcomes").records;
  const luau = metricsOf("all");
  const recomputed = recomputePointMetrics(forecasts, outcomes, timing);
  const summary = compareMetrics(luau, recomputed, 1e-10);
  assert.equal(summary.compared, 18);
  assert.ok(summary.maxAbsDiff <= 1e-10, `max diff ${summary.maxAbsDiff}`);
  // the missing physics forecast is visible in the Luau record and absent from the recomputed rows
  const phys = luau.find((r) => r.modelId === "O14-PHYSICS" && r.symbol === "QQQ" && r.split === "validation");
  assert.equal(phys.missing, 1);
  assert.equal(phys.n, 9);
  assert.equal(recomputed.get(`${sample.runId}:O14-PHYSICS|QQQ|validation`).n, 9);
  assert.equal(sample.comparisonStatus, "incomplete");
  // constant predictions: correlation undefined on both sides
  const markov = luau.find((r) => r.modelId === "O14-MARKOV" && r.symbol === "SPY" && r.split === "train");
  assert.equal(markov.correlation, undefined);
  assert.equal(recomputed.get(`${sample.runId}:O14-MARKOV|SPY|train`).correlation, null);
});

test("plan metric fixture computed independently in JS", () => {
  const runId = "run-1";
  const t0 = 1601280000;
  const preds = [0, -0.01, 0.02];
  const acts = [0.01, -0.02, 0.03];
  const forecasts = preds.map((p, i) => {
    const t = t0 + i * 3600;
    return { id: `${runId}:M:SPY:${t}`, runId, modelId: "M", symbol: "SPY", t, decisionTime: t + 3600,
      outcomeTime: t + 32400, prediction: p, modelHash: "m", dataHash: "d" };
  });
  const outcomes = acts.map((a, i) => ({ forecastId: forecasts[i].id, eligible: true, actual: a }));
  const g = recomputePointMetrics(forecasts, outcomes, { splits: sample.splits }).get(`${runId}:M|SPY|train`);
  assert.ok(Math.abs(g.mae - 0.01) < 1e-15);
  assert.ok(Math.abs(g.rmse - 0.01) < 1e-15);
  assert.equal(g.directionCorrect, 2);
  assert.equal(g.directionTotal, 3);
  assert.equal(g.zeroPredictions, 1);
});

test("metric disagreement beyond tolerance is reported", () => {
  const forecasts = kindRecords("forecasts").records;
  const outcomes = kindRecords("outcomes").records;
  const luau = metricsOf("all");
  const recomputed = recomputePointMetrics(forecasts, outcomes, timing);
  // perturb a scored group whose correlation is defined (the constant Markov groups have none)
  const target = luau.findIndex((r) => r.n > 0 && typeof r.correlation === "number");
  assert.ok(target >= 0);
  const bump = (field, delta) => luau.map((r, i) => (i === target ? { ...r, [field]: r[field] + delta } : r));
  assert.throws(() => compareMetrics(bump("rmse", 1e-9), recomputed), /rmse/);
  assert.throws(() => compareMetrics(bump("mae", -2e-10), recomputed), /mae/);
  assert.throws(() => compareMetrics(bump("directionCorrect", 1), recomputed), /directionCorrect/);
  assert.throws(() => compareMetrics(bump("n", 1), recomputed), /n /);
  assert.throws(() => compareMetrics(luau.slice(1), recomputed), /no Luau metric/);
  const noCorr = luau.map((r, i) => (i === target ? { ...r, correlation: undefined } : r));
  assert.throws(() => compareMetrics(noCorr, recomputed), /correlation/);
  assert.doesNotThrow(() => compareMetrics(bump("rmse", 5e-11), recomputed));
  assert.throws(() => compareMetrics(bump("meanPrediction", 1e-9), recomputed), /meanPrediction/);
  assert.throws(() => compareMetrics(bump("forecastDispersion", 1e-9), recomputed), /forecastDispersion/);
});

test("non-overlap rule: accept when decision >= previous selected outcome (JS, independent)", () => {
  const t0 = 1601251200 + 7 * 3600;
  const hourly = Array.from({ length: 11 }, (_, h) => t0 + h * 3600);
  const timingOnly = { barSeconds: 3600, horizonHours: 8 };
  assert.deepEqual(nonOverlapOrigins(hourly, timingOnly), [t0, t0 + 8 * 3600], "boundary is inclusive");
  assert.deepEqual(nonOverlapOrigins([t0, t0 + 7 * 3600], timingOnly), [t0]);
  assert.deepEqual(nonOverlapOrigins([t0 + 8 * 3600, t0, t0, t0 + 3600], timingOnly), [t0, t0 + 8 * 3600]);
});

test("non-overlap subset metrics are recomputed independently and agree within 1e-10", () => {
  const forecasts = kindRecords("forecasts").records;
  const outcomes = kindRecords("outcomes").records;
  const luau = metricsOf("nonOverlap");
  assert.ok(luau.length > 0, "the sample exports non-overlap metrics");
  const recomputed = recomputePointMetrics(forecasts, outcomes, { ...timing, subset: "nonOverlap" });
  const summary = compareMetrics(luau, recomputed, 1e-10);
  assert.equal(summary.compared, 18);
  // one origin per synthetic date: 3 training dates, 2 validation dates, 2 final dates
  assert.equal(recomputed.get(`${sample.runId}:O14-RAW_RIDGE|SPY|train`).n, 3);
  assert.equal(recomputed.get(`${sample.runId}:O14-RAW_RIDGE|QQQ|validation`).n, 2);
  assert.equal(recomputed.get(`${sample.runId}:O14-PHYSICS|QQQ|final`).n, 2);
  // a subset record compared against the wrong population is reported, not silently matched
  assert.throws(() => compareMetrics(luau, recomputePointMetrics(forecasts, outcomes, timing)), /subset/);
  assert.throws(() => recomputePointMetrics(forecasts, outcomes, { ...timing, subset: "best" }), /subset/);
});

test("eligible and missing coverage counts are verified independently", () => {
  const forecasts = kindRecords("forecasts").records;
  const outcomes = kindRecords("outcomes").records;
  const luau = metricsOf("all");
  const recomputed = recomputePointMetrics(forecasts, outcomes, timing);
  const phys = luau.findIndex((r) => r.modelId === "O14-PHYSICS" && r.symbol === "QQQ" && r.split === "validation");
  assert.equal(luau[phys].missing, 1);
  const hide = luau.map((r, i) => (i === phys ? { ...r, missing: 0 } : r));
  assert.throws(() => compareMetrics(hide, recomputed), /missing/);
  const shrink = luau.map((r, i) => (i === phys ? { ...r, eligible: r.eligible - 1, missing: 0 } : r));
  assert.throws(() => compareMetrics(shrink, recomputed), /eligible/);
});

test("JS correlation stays finite and scale-invariant at extreme magnitudes", () => {
  const runId = "run-1";
  const t0 = 1601280000;
  const make = (scale) => {
    const preds = [1, 2, 4].map((v) => v * scale);
    const acts = [2, 3, 7].map((v) => v * scale);
    const forecasts = preds.map((pv, i) => {
      const t = t0 + i * 3600;
      return { id: `${runId}:M:SPY:${t}`, runId, modelId: "M", symbol: "SPY", t, decisionTime: t + 3600,
        outcomeTime: t + 32400, prediction: pv, modelHash: "m", dataHash: "d" };
    });
    const outs = acts.map((a, i) => ({ forecastId: forecasts[i].id, eligible: true, actual: a }));
    return recomputePointMetrics(forecasts, outs, { splits: sample.splits }).get(`${runId}:M|SPY|train`).correlation;
  };
  const reference = 8 / Math.sqrt((42 / 9) * 14);
  for (const scale of [1, 1e-170, 1e-100, 1e100, 1e150]) {
    const c = make(scale);
    assert.ok(Number.isFinite(c), `finite at scale ${scale}`);
    assert.ok(Math.abs(c - reference) < 1e-12, `scale ${scale}: ${c}`);
  }
});

// ---------------------------------------------------------------------------------------------- acknowledgements
test("acknowledgement records: schema, wrong run and stale hashes rejected", () => {
  const sha = "0123456789abcdef".repeat(4);
  const text = makeAcknowledgement({ runId: "run-1", artifactKind: "model", sha256: sha });
  // byte-identical to the literal the Luau ResultStore.parseAcknowledgement test accepts
  assert.equal(text, `{"artifactKind":"model","runId":"run-1","sha256":"${sha}"}`);
  const ack = parseAcknowledgement(text);
  assert.deepEqual(ack, { artifactKind: "model", runId: "run-1", sha256: sha });
  assert.equal(checkAcknowledgement(ack, { runId: "run-1", artifactKind: "model", sha256: sha }), true);
  assert.throws(() => checkAcknowledgement(ack, { runId: "run-2", artifactKind: "model", sha256: sha }), /wrong run/);
  assert.throws(() => checkAcknowledgement(ack, { runId: "run-1", artifactKind: "forecasts", sha256: sha }), /artifact kind/);
  assert.throws(() => checkAcknowledgement(text, { runId: "run-1", artifactKind: "model", sha256: "f".repeat(64) }), /stale/);
  assert.throws(() => parseAcknowledgement(`{"artifactKind":"model","extra":1,"runId":"run-1","sha256":"${sha}"}`), /field/);
  assert.throws(() => parseAcknowledgement(`{"artifactKind":"model","runId":"run-1","sha256":"${sha.toUpperCase()}"}`), /sha256/);
  assert.throws(() => parseAcknowledgement(`{"artifactKind":"model","runId":"run 1","sha256":"${sha}"}`), /runId/);
  assert.throws(() => parseAcknowledgement("[]"), /object/);
  assert.throws(() => makeAcknowledgement({ runId: "run-1", artifactKind: "model", sha256: "abc" }), /sha256/);
});

// ---------------------------------------------------------------------------------------------- directory + CLI
function writeExport(dir, mutate) {
  for (const [kind, entry] of Object.entries(sample.kinds)) {
    const kdir = join(dir, kind);
    mkdirSync(kdir, { recursive: true });
    writeFileSync(join(kdir, "manifest.json"), JSON.stringify(entry.manifest));
    entry.pages.forEach((p, i) => writeFileSync(join(kdir, pageFileName(i + 1)), mutate ? mutate(kind, i, p) : p, "utf8"));
  }
}

test("validates a saved export directory end to end, then the CLI", () => {
  const dir = mkdtempSync(join(tmpdir(), "mrl-validate-"));
  try {
    writeExport(dir);
    const summary = validateExportDirectory(dir, timing);
    assert.deepEqual(Object.keys(summary.kinds).sort(), ["failures", "forecasts", "metrics", "outcomes"]);
    assert.equal(summary.kinds.forecasts.rowCount, sample.kinds.forecasts.manifest.rowCount);
    assert.equal(summary.metrics.compared, 36, "18 all-origin groups + 18 non-overlap groups");
    assert.deepEqual(Object.keys(summary.metrics.subsets).sort(), ["all", "nonOverlap"]);
    assert.equal(pageFileName(1), "Page000001.json");
    const splitsFile = join(dir, "splits.json");
    writeFileSync(splitsFile, JSON.stringify(sample.splits));
    const ok = spawnSync(process.execPath, [join(root, "tools", "validate-results.mjs"), dir, "--splits", splitsFile], { encoding: "utf8" });
    assert.equal(ok.status, 0, ok.stderr);
    const printed = JSON.parse(ok.stdout);
    assert.equal(printed.kinds.forecasts.artifactSha256, summary.kinds.forecasts.artifactSha256);

    const bad = mkdtempSync(join(tmpdir(), "mrl-validate-bad-"));
    try {
      writeExport(bad, (kind, i, p) => (kind === "outcomes" && i === 0 ? p.replace('"eligible":true', '"eligible":false') : p));
      const res = spawnSync(process.execPath, [join(root, "tools", "validate-results.mjs"), bad, "--splits", splitsFile], { encoding: "utf8" });
      assert.equal(res.status, 1);
      assert.match(res.stderr, /validate-results/);
    } finally {
      rmSync(bad, { recursive: true, force: true });
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("fixture text is what Luau requires (single-line JSON, no long-bracket terminator)", () => {
  for (const name of ["PrngVectors", "ExportSample"]) {
    const text = readFixtureText(name);
    assert.ok(!/[\r\n]/.test(text));
    assert.ok(!text.includes("]==]"));
    assert.doesNotThrow(() => JSON.parse(text));
  }
});
