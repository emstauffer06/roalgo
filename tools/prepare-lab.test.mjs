// Tests for tools/prepare-lab.mjs: New York calendar generation (Intl, never a fixed offset), the CLI-only
// source loader table, and the independent Node structural audit of the paired hourly streams.
// Run: node --test tools/prepare-lab.test.mjs   (from the project root)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import * as P from "./prepare-lab.mjs";
import { LUAU } from "./luau-run.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const utc = (y, mo, d, h = 0, mi = 0, s = 0) => Date.UTC(y, mo - 1, d, h, mi, s) / 1000;

// Built once: reading every source is the slow part, and determinism is checked by building twice.
let builtOnce;
function built() {
  builtOnce ??= P.buildAll(root);
  return builtOnce;
}

test("nyParts and nyOffset come from Intl America/New_York, never a fixed offset", () => {
  const a = P.nyParts(utc(2024, 3, 8, 14));
  const b = P.nyParts(utc(2024, 3, 11, 13));
  assert.deepEqual([a.dateKey, a.hour, a.minute], [20240308, 9, 0], "2024-03-08T14:00Z is 09:00 EST");
  assert.deepEqual([b.dateKey, b.hour, b.minute], [20240311, 9, 0], "2024-03-11T13:00Z is 09:00 EDT");
  assert.equal(P.nyOffset(utc(2024, 3, 8, 14)), -18000);
  assert.equal(P.nyOffset(utc(2024, 3, 11, 13)), -14400);
  // November transition: 2024-11-03T06:00Z is 01:00 EST; one second earlier is 01:59:59 EDT.
  const before = P.nyParts(utc(2024, 11, 3, 6) - 1);
  const after = P.nyParts(utc(2024, 11, 3, 6));
  assert.deepEqual([before.hour, before.minute, before.second], [1, 59, 59]);
  assert.deepEqual([after.hour, after.minute, after.second], [1, 0, 0]);
  assert.equal(P.nyOffset(utc(2024, 11, 3, 6) - 1), -14400);
  assert.equal(P.nyOffset(utc(2024, 11, 3, 6)), -18000);
});

test("buildNyOffsets: exact-second transitions, two per year 2015-2027, both sides agree with Intl", () => {
  const ny = P.buildNyOffsets();
  assert.equal(ny.zone, "America/New_York");
  assert.ok(ny.coverageStart <= utc(2015, 1, 1), "covers 2015-01-01");
  assert.ok(ny.coverageEnd > utc(2028, 1, 1, 5), "covers next midnight after 2027-12-31");
  const tr = ny.transitions;
  assert.equal(tr[0].utcStartSeconds, ny.coverageStart, "first entry starts the coverage");
  assert.equal(tr.length, 1 + 2 * 13, "initial entry plus a spring and an autumn change for 13 years");
  for (let i = 1; i < tr.length; i++) {
    assert.ok(tr[i].utcStartSeconds > tr[i - 1].utcStartSeconds, "strictly increasing");
    assert.notEqual(tr[i].offsetSeconds, tr[i - 1].offsetSeconds, "each entry is a real change");
    assert.equal(P.nyOffset(tr[i].utcStartSeconds), tr[i].offsetSeconds, "offset at the change");
    assert.equal(P.nyOffset(tr[i].utcStartSeconds - 1), tr[i - 1].offsetSeconds, "offset one second earlier");
  }
  assert.deepEqual([...new Set(tr.map((x) => x.offsetSeconds))].sort((a, b) => a - b), [-18000, -14400]);
  const at = (t) => tr.find((x) => x.utcStartSeconds === t);
  assert.equal(at(utc(2024, 3, 10, 7))?.offsetSeconds, -14400, "2024 spring change at 07:00Z");
  assert.equal(at(utc(2024, 11, 3, 6))?.offsetSeconds, -18000, "2024 autumn change at 06:00Z");
  assert.equal(at(utc(2016, 3, 13, 7))?.offsetSeconds, -14400, "2016 spring change");
  assert.equal(at(utc(2026, 11, 1, 6))?.offsetSeconds, -18000, "2026 autumn change");
});

test("nextMidnightAfter is the Intl-verified New York midnight, not t + 86400", () => {
  // 2024-03-09 -> 2024-03-10 00:00 EST = 05:00Z; 2024-03-10 -> 2024-03-11 00:00 EDT = 04:00Z.
  assert.equal(P.nextMidnightAfter(20240309), utc(2024, 3, 10, 5));
  assert.equal(P.nextMidnightAfter(20240310), utc(2024, 3, 11, 4));
  assert.equal(P.nextMidnightAfter(20241102), utc(2024, 11, 3, 4));
  assert.equal(P.nextMidnightAfter(20241103), utc(2024, 11, 4, 5));
  assert.equal(P.nextMidnightAfter(20231231), utc(2024, 1, 1, 5), "validation start is NY midnight");
  assert.equal(P.nextMidnightAfter(20261002), 1791000000, "dataset end is NY midnight after 2026-10-02");
  assert.equal(P.nextMidnightAfter(20240228), utc(2024, 2, 29, 5), "leap day");
  assert.throws(() => P.nextMidnightAfter(20240230), /invalid date/);
});

test("calendar fixture: named 09:00 cases, DST-adjacent hours 2016-2026, samples and midnights match Intl", () => {
  const { calendarFixture: fx, ny } = built();
  const named = Object.fromEntries(fx.named.map((n) => [n.label, n]));
  assert.equal(named["2024-03-08T14:00:00Z"].hour, 9);
  assert.equal(named["2024-03-11T13:00:00Z"].hour, 9);
  assert.equal(named["2024-03-08T14:00:00Z"].dateKey, 20240308);
  assert.equal(named["2024-03-11T13:00:00Z"].dateKey, 20240311);
  assert.ok(fx.named.some((n) => n.label.startsWith("2024-11")), "a November transition fixture");
  const ts = new Set(fx.instants.map((r) => r[0]));
  const changes = ny.transitions.slice(1).filter((x) => {
    const y = new Date(x.utcStartSeconds * 1000).getUTCFullYear();
    return y >= 2016 && y <= 2026;
  });
  assert.equal(changes.length, 22);
  for (const c of changes) {
    for (let h = -3; h <= 3; h++) assert.ok(ts.has(c.utcStartSeconds + h * 3600), `DST-adjacent hour ${h}`);
    assert.ok(ts.has(c.utcStartSeconds - 1), "one second before the change");
  }
  const sampled = fx.instants.length - fx.dstAdjacentCount;
  assert.ok(sampled >= 2900 && sampled <= 3100, `about 3000 sampled source timestamps, got ${sampled}`);
  for (let i = 1; i < fx.instants.length; i++) assert.ok(fx.instants[i][0] > fx.instants[i - 1][0], "sorted, unique");
  // Independent re-check of every expected value against Intl.
  for (const [t, dateKey, hour, minute] of fx.instants) {
    const p = P.nyParts(t);
    assert.deepEqual([p.dateKey, p.hour, p.minute], [dateKey, hour, minute], `instant ${t}`);
  }
  assert.ok(fx.midnights.length >= 380 && fx.midnights.length <= 420, `about 400 midnights, got ${fx.midnights.length}`);
  const mdates = new Set(fx.midnights.map((m) => m[0]));
  for (const c of ny.transitions.slice(1)) {
    const changeDate = P.nyParts(c.utcStartSeconds).dateKey;
    assert.ok(mdates.has(changeDate), `DST-change date ${changeDate} present`);
  }
  for (const [dateKey, t] of fx.midnights) {
    const at = P.nyParts(t);
    const prev = P.nyParts(t - 1);
    assert.deepEqual([at.hour, at.minute, at.second], [0, 0, 0], `midnight for ${dateKey}`);
    assert.equal(prev.dateKey, dateKey, `one second before is still ${dateKey}`);
    assert.notEqual(at.dateKey, dateKey);
  }
});

test("generation is deterministic: building twice gives byte-identical files", () => {
  const a = built();
  const b = P.buildAll(root);
  assert.deepEqual(Object.keys(a.files).sort(), Object.keys(b.files).sort());
  for (const name of Object.keys(a.files)) assert.equal(a.files[name], b.files[name], name);
  assert.deepEqual(Object.keys(a.files).sort(), [
    "CalendarFixture.luau",
    "NodeStructureAudit.luau",
    "NyOffsets.luau",
    "Sources.luau",
    "node-structure-audit.json",
  ]);
});

test("generated files on disk are current (run node tools/prepare-lab.mjs after changes)", () => {
  const { files } = built();
  for (const [name, content] of Object.entries(files)) {
    const p = join(root, P.GENERATED_DIR, name);
    assert.ok(existsSync(p), `${name} written`);
    assert.equal(readFileSync(p, "utf8"), content, `${name} is stale`);
  }
});

test("source groups: chunks enumerated from manifests, hashes and row counts match", () => {
  const { groups } = built();
  const expected = {
    "hourly-original": { SPY: 19962, QQQ: 19887 },
    "hourly-combined": { SPY: 42543, QQQ: 42334 },
    "five-minute": { SPY: 236059, QQQ: 237287 },
    "daily-context": { SPY: 2703, QQQ: 2703 },
    "hourly-context": { IWM: 41857, TLT: 38263 },
  };
  assert.deepEqual(groups.map((g) => g.id), Object.keys(expected));
  for (const g of groups) {
    assert.match(g.manifestSha256, /^[0-9a-f]{64}$/);
    assert.deepEqual(g.symbols.map((s) => s.symbol), Object.keys(expected[g.id]));
    for (const s of g.symbols) {
      assert.equal(s.count, expected[g.id][s.symbol], `${g.id}/${s.symbol} count`);
      assert.equal(s.chunks.length, s.chunkCount, "chunk list length equals manifest chunkCount");
      assert.equal(s.rowsCounted, s.count, "rows counted in chunk files equal the manifest count");
      s.chunks.forEach((c, i) => {
        assert.equal(c.name, `Chunk${String(i + 1).padStart(3, "0")}`, "chunks in order");
        assert.ok(c.requirePath.startsWith("../../data/"), "relative literal path from lab/generated");
        const onDisk = resolve(root, P.GENERATED_DIR, c.requirePath + ".luau");
        assert.equal(onDisk, resolve(root, c.path), "require path resolves to the manifest file");
        assert.ok(existsSync(onDisk));
        assert.match(c.sha256, /^[0-9a-f]{64}$/);
      });
    }
  }
});

test("Sources.luau requires every chunk by its relative literal path, in order, once", () => {
  const { files, groups } = built();
  const text = files["Sources.luau"];
  const requires = [...text.matchAll(/require\("([^"]+)"\)/g)].map((m) => m[1]);
  const expected = groups.flatMap((g) => g.symbols.flatMap((s) => s.chunks.map((c) => c.requirePath)));
  assert.deepEqual(requires, expected);
  assert.ok(!/[A-Za-z]:[\\/]/.test(text), "no absolute Windows paths");
  assert.ok(!text.includes("\\"), "no backslashes");
  for (const g of groups) for (const s of g.symbols) assert.ok(text.includes(`count = ${s.count},`));
});

test("Luau smoke: Sources loaders return the manifest row counts in the real Luau CLI", { timeout: 300000 }, () => {
  assert.ok(existsSync(LUAU), "luau.exe present");
  const r = spawnSync(LUAU, ["tools/prepare-lab-smoke.luau"], { cwd: root, encoding: "utf8", maxBuffer: 1 << 24 });
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const lines = r.stdout.trim().split(/\r?\n/).filter((l) => l.startsWith("SMOKE "));
  const got = Object.fromEntries(lines.map((l) => {
    const [, key, count, first, last] = l.split(" ");
    return [key, { count: Number(count), first: Number(first), last: Number(last) }];
  }));
  const { groups } = built();
  for (const g of groups) {
    for (const s of g.symbols) {
      const k = `${g.id}/${s.symbol}`;
      assert.equal(got[k]?.count, s.count, k);
      assert.equal(got[k].first, Date.parse(s.first) / 1000, `${k} first timestamp`);
      assert.equal(got[k].last, Date.parse(s.last) / 1000, `${k} last timestamp`);
    }
  }
});

test("structureAudit on a synthetic day: timestamp pairing, segments, warmup, gaps and splits", () => {
  const t0 = 1704186000; // 2024-01-02T09:00Z = 04:00 New York
  const day = Array.from({ length: 13 }, (_, i) => t0 + i * 3600);
  const opts = { splits: P.loadConfig(root).splits, warmup: 4, horizonHours: 8, barSeconds: 3600 };
  const full = P.structureAudit(day, day, opts);
  assert.equal(full.pairedTotal, 13);
  assert.equal(full.segments, 1);
  assert.deepEqual(full.eligibleTimestamps.validation, [t0 + 3 * 3600, t0 + 4 * 3600], "origins 4 and 5 only");
  assert.equal(full.splits.validation.nonOverlappingOrigins, 1);
  // SPY has an extra bar that QQQ lacks: pairing uses the timestamp intersection, never the row index.
  const qqq = day.filter((_, i) => i !== 6);
  const gap = P.structureAudit(day, qqq, opts);
  assert.equal(gap.pairedTotal, 12);
  assert.equal(gap.spyOnly, 1);
  assert.equal(gap.segments, 2, "the gap starts a new segment");
  assert.equal(gap.total.eligibleOrigins, 0, "no origin may bridge the missing hour");
  // Warmed origins: t0+3h,4h,5h (first segment) and t0+10h,11h,12h (second); all lack an intermediate hour.
  assert.equal(gap.reasonsByInputSplit.validation.missing_intermediate_hour, 6);
  assert.equal(gap.reasonsByInputSplit.validation.insufficient_warmup, 6);
  // t0+3h and t0+4h would be eligible except for the missing hour: their endpoints exist on the same date.
  assert.equal(gap.endpointOnlyIntermediateGaps, 2);
  assert.equal(full.reasonsByInputSplit.validation.missing_target, 1, "t0+5h has hours 1-7 but no endpoint");
  assert.equal(full.reasonsByInputSplit.validation.missing_intermediate_hour, 7);
  // A day straddling New York midnight: 20:00 origin whose target is on the next date.
  const evening = Array.from({ length: 13 }, (_, i) => 1704229200 + i * 3600); // 2024-01-02T21:00Z = 16:00 NY
  const ev = P.structureAudit(evening, evening, opts);
  assert.equal(ev.segments, 2, "date change starts a new segment");
  assert.equal(ev.total.eligibleOrigins, 0);
  // Exclusive upper bound: origin 4 (outcome t0+12h) stays in training; origin 5's outcome t0+13h reaches
  // validationStart exactly and is purged.
  const custom = { ...opts, splits: { validationStart: t0 + 13 * 3600, testStart: t0 + 20 * 3600, datasetEnd: t0 + 40 * 3600 } };
  const purged = P.structureAudit(day, day, custom);
  assert.deepEqual(purged.eligibleTimestamps.train, [t0 + 3 * 3600]);
  assert.equal(purged.total.eligibleOrigins, 1);
  assert.equal(purged.reasonsByInputSplit.train.split_boundary, 1);
});

test("buildAudit compares H14 validation/final paired-input arrays with O14 element by element, and plan facts", () => {
  // Review finding: only the counts of H14's validation/final paired inputs were compared with O14, while
  // plan 2.3 says the timestamp arrays themselves are identical. Same count, one input moved by an hour:
  const t0 = 1704186000; // 2024-01-02T09:00Z, validation period
  const day = Array.from({ length: 13 }, (_, i) => t0 + i * 3600);
  const moved = [...day.slice(0, 12), t0 + 14 * 3600];
  const groups = [{ id: "hourly-original", manifestSha256: "x" }, { id: "hourly-combined", manifestSha256: "y" }];
  const timestamps = {
    "hourly-original/SPY": day, "hourly-original/QQQ": day,
    "hourly-combined/SPY": moved, "hourly-combined/QQQ": moved,
  };
  const audit = P.buildAudit(groups, timestamps, P.loadConfig(root));
  assert.equal(audit.profiles.H14.splits.validation.pairedInputBars, audit.profiles.O14.splits.validation.pairedInputBars, "counts agree");
  assert.equal(audit.crossChecks.h14ValidationInputsEqualO14, false);
  assert.equal(audit.crossChecks.h14FinalInputsEqualO14, true, "both final arrays are empty");
  assert.ok(audit.mismatches.includes("H14 validation paired input timestamps differ from O14"), audit.mismatches.join("; "));
  // Plan facts beyond the table are part of the plan comparison too.
  assert.ok(audit.mismatches.includes("O14 spyOnly: expected 75, got 0"), "section 1: 75 SPY-only timestamps");
  assert.ok(audit.mismatches.includes("O14 endpointOnlyIntermediateGaps: expected 1, got 0"), "section 2.3: one continuity removal");
  assert.ok(audit.mismatches.includes("H14 train datesWithoutEligibleOrigin: expected 9, got 0"), "section 2.3: nine H14 dates");
});

test("structure audit on the real hourly sources reproduces plan section 2.3", { timeout: 300000 }, () => {
  const { audit } = built();
  const o = audit.profiles.O14;
  const h = audit.profiles.H14;
  const cols = (p, key) => ["train", "validation", "final"].map((s) => p.splits[s][key]);
  assert.deepEqual(cols(o, "pairedInputBars"), [8850, 4022, 7015]);
  assert.deepEqual(cols(o, "nyDates"), [564, 252, 439]);
  assert.deepEqual(cols(o, "eligibleOrigins"), [2646, 1249, 2186]);
  assert.deepEqual([o.total.pairedInputBars, o.total.nyDates, o.total.eligibleOrigins], [19887, 1255, 6081]);
  assert.deepEqual(cols(o, "nonOverlappingOrigins"), [564, 252, 439]);
  assert.equal(o.spyOnly, 75);
  assert.equal(o.qqqOnly, 0);
  assert.equal(o.endpointOnlyIntermediateGaps, 1, "one candidate removed by strict continuity");
  assert.deepEqual(cols(h, "pairedInputBars"), [31292, 4022, 7015]);
  assert.deepEqual(cols(h, "nyDates"), [2012, 252, 439]);
  assert.deepEqual(cols(h, "eligibleOrigins"), [9103, 1249, 2186]);
  assert.deepEqual(cols(h, "nonOverlappingOrigins"), [2003, 252, 439]);
  assert.deepEqual([h.total.pairedInputBars, h.total.nyDates, h.total.eligibleOrigins, h.total.nonOverlappingOrigins], [42329, 2703, 12538, 2694]);
  assert.deepEqual(h.eligibleTimestamps.validation, o.eligibleTimestamps.validation);
  assert.deepEqual(h.eligibleTimestamps.final, o.eligibleTimestamps.final);
  assert.equal(audit.crossChecks.h14ValidationInputsEqualO14, true, "validation paired-input arrays identical");
  assert.equal(audit.crossChecks.h14FinalInputsEqualO14, true, "final paired-input arrays identical");
  assert.deepEqual(cols(o, "datesWithoutEligibleOrigin"), [0, 0, 0]);
  assert.deepEqual(cols(h, "datesWithoutEligibleOrigin"), [9, 0, 0], "nine H14 training dates without an eligible origin");
  assert.ok(o.maxEligibleSegmentOffset <= 8 && h.maxEligibleSegmentOffset <= 8, "at most eight observations since reset");
  assert.equal(audit.matchesPlan, true);
  assert.deepEqual(audit.mismatches, []);
  for (const p of [o, h]) {
    const c = p.conventions;
    assert.deepEqual(c.decisionTime, c.barStart, "decision-time and bar-start conventions agree");
    assert.deepEqual(c.decisionTime, c.nyDate, "decision-time and NY-date conventions agree");
  }
});

test("layering: no Data module other than Targets requires Targets", () => {
  const dir = join(root, "lab/src/Data");
  if (!existsSync(dir)) return;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".luau") || f === "Targets.luau") continue;
    const text = readFileSync(join(dir, f), "utf8");
    assert.ok(!/require\(\s*["'][^"']*Targets["']\s*\)/.test(text), `${f} must not require Targets`);
  }
});
