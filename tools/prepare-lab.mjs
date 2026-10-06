// Prepares the lab's generated data-side modules (Node 24, built-in modules only, no network).
//
// Writes into lab/generated/:
//   NyOffsets.luau            America/New_York UTC-offset table derived from Intl.DateTimeFormat (never a fixed offset)
//   CalendarFixture.luau      Intl-computed expected New York facts used by the Luau Calendar tests
//   Sources.luau              CLI-only loader table: requires the existing exported chunk modules by relative path
//   NodeStructureAudit.luau   the Node structural audit as a Luau literal (so lab/cli/audit.luau can cross-check)
//   node-structure-audit.json the same audit as JSON
//
// The structural audit counts timestamps only (pairing, segments, eligibility, split populations). It never
// reads prices, so no target return, error or performance figure is computed for any period.
//
// Usage: node tools/prepare-lab.mjs   (from anywhere; paths are resolved from this file)
import { readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { toLuau } from "./luau-literal.mjs";

export const ZONE = "America/New_York";
export const GENERATED_DIR = "lab/generated";
const ORIGINAL_DIR = "data/alpaca-2021-10-04_2026-10-02";
const SUPPLEMENT_DIR = "data/alpaca-supplement-2016-01-01_2026-10-02";

// Group ids, directories and symbol order. Chunk lists always come from each group's manifest.
export const GROUPS = Object.freeze([
  { id: "hourly-original", dir: ORIGINAL_DIR, symbols: ["SPY", "QQQ"] },
  { id: "hourly-combined", dir: `${SUPPLEMENT_DIR}/hourly-combined`, symbols: ["SPY", "QQQ"] },
  { id: "five-minute", dir: `${SUPPLEMENT_DIR}/five-minute`, symbols: ["SPY", "QQQ"] },
  { id: "daily-context", dir: `${SUPPLEMENT_DIR}/daily-context`, symbols: ["SPY", "QQQ"] },
  { id: "hourly-context", dir: `${SUPPLEMENT_DIR}/hourly-context`, symbols: ["IWM", "TLT"] },
]);

// UTC coverage of the offset table: every New York date 2015-01-01..2027-12-31 plus the midnight after it.
export const COVERAGE_START = Date.UTC(2014, 11, 31) / 1000; // 2014-12-31T00:00:00Z
export const COVERAGE_END = Date.UTC(2028, 0, 2) / 1000; // 2028-01-02T00:00:00Z (exclusive)

// Plan section 2.3 (and section 6 for the O14 non-overlap counts). Order: train, validation, final.
export const EXPECTED = Object.freeze({
  O14: {
    pairedInputBars: [8850, 4022, 7015],
    nyDates: [564, 252, 439],
    eligibleOrigins: [2646, 1249, 2186],
    nonOverlappingOrigins: [564, 252, 439],
    datesWithoutEligibleOrigin: [0, 0, 0], // section 6: one non-overlapping origin per New York date
    total: { pairedInputBars: 19887, nyDates: 1255, eligibleOrigins: 6081 },
    // Section 1: SPY has 75 extra timestamps, QQQ none; section 2.3: one candidate removed by continuity.
    facts: { spyOnly: 75, qqqOnly: 0, endpointOnlyIntermediateGaps: 1 },
  },
  H14: {
    pairedInputBars: [31292, 4022, 7015],
    nyDates: [2012, 252, 439],
    eligibleOrigins: [9103, 1249, 2186],
    nonOverlappingOrigins: [2003, 252, 439],
    datesWithoutEligibleOrigin: [9, 0, 0], // section 2.3: nine H14 training dates without an eligible origin
    total: { pairedInputBars: 42329, nyDates: 2703, eligibleOrigins: 12538, nonOverlappingOrigins: 2694 },
    facts: {},
  },
});

const SPLITS = ["train", "validation", "final"];
const SAMPLES_PER_SERIES = 300;
const MIDNIGHT_STRIDE_DAYS = 15;

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const iso = (t) => new Date(t * 1000).toISOString().replace(".000Z", "Z");

// ---------------------------------------------------------------------------------------------------------
// New York calendar facts from Intl

const nyFormat = new Intl.DateTimeFormat("en-US", {
  timeZone: ZONE,
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});

export function nyParts(t) {
  if (!Number.isInteger(t)) throw new Error(`prepare-lab: timestamp must be an integer, got ${t}`);
  const p = {};
  for (const part of nyFormat.formatToParts(new Date(t * 1000))) {
    if (part.type !== "literal") p[part.type] = Number(part.value);
  }
  if (!(p.hour >= 0 && p.hour <= 23)) throw new Error(`prepare-lab: Intl returned hour ${p.hour}`);
  return {
    year: p.year,
    month: p.month,
    day: p.day,
    hour: p.hour,
    minute: p.minute,
    second: p.second,
    dateKey: p.year * 10000 + p.month * 100 + p.day,
  };
}

// New York wall clock minus UTC, in seconds (e.g. -18000 for EST).
export function nyOffset(t) {
  const p = nyParts(t);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) / 1000 - t;
}

// Scan day by day and bisect each change to the exact second. New York changes at most once per day.
export function deriveTransitions(start, end) {
  const out = [{ utcStartSeconds: start, offsetSeconds: nyOffset(start) }];
  let a = start;
  let offA = out[0].offsetSeconds;
  while (a < end - 1) {
    const b = Math.min(a + 86400, end - 1);
    const offB = nyOffset(b);
    if (offB !== offA) {
      let lo = a;
      let hi = b;
      while (hi - lo > 1) {
        const mid = Math.floor((lo + hi) / 2);
        if (nyOffset(mid) === offA) lo = mid;
        else hi = mid;
      }
      const offHi = nyOffset(hi);
      if (offHi !== offB) throw new Error(`prepare-lab: more than one offset change between ${a} and ${b}`);
      out.push({ utcStartSeconds: hi, offsetSeconds: offHi });
    }
    a = b;
    offA = offB;
  }
  return out;
}

export function buildNyOffsets() {
  return {
    zone: ZONE,
    method: "Intl.DateTimeFormat(timeZone America/New_York): daily scan, each change bisected to the exact second",
    icu: process.versions.icu,
    tz: process.versions.tz,
    coverageStart: COVERAGE_START,
    coverageStartIso: iso(COVERAGE_START),
    coverageEnd: COVERAGE_END,
    coverageEndIso: iso(COVERAGE_END),
    transitions: deriveTransitions(COVERAGE_START, COVERAGE_END),
  };
}

function dateKeyParts(dateKey) {
  const y = Math.floor(dateKey / 10000);
  const m = Math.floor(dateKey / 100) % 100;
  const d = dateKey % 100;
  const ms = Date.UTC(y, m - 1, d);
  const dt = new Date(ms);
  if (!Number.isInteger(dateKey) || dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) {
    throw new Error(`prepare-lab: invalid date ${dateKey}`);
  }
  return { y, m, d, days: ms / 86400000 };
}

function dateKeyFromDays(days) {
  const dt = new Date(days * 86400000);
  return dt.getUTCFullYear() * 10000 + (dt.getUTCMonth() + 1) * 100 + dt.getUTCDate();
}

// UTC seconds of 00:00 New York on the calendar date after dateKey, verified with Intl on both sides.
export function nextMidnightAfter(dateKey) {
  const { days } = dateKeyParts(dateKey);
  const nextKey = dateKeyFromDays(days + 1);
  const local = (days + 1) * 86400; // next date's 00:00 written as if it were UTC
  let t = local - nyOffset(local);
  t = local - nyOffset(t);
  const at = nyParts(t);
  const before = nyParts(t - 1);
  if (at.dateKey !== nextKey || at.hour !== 0 || at.minute !== 0 || at.second !== 0 || before.dateKey !== dateKey) {
    throw new Error(`prepare-lab: could not resolve New York midnight after ${dateKey}`);
  }
  return t;
}

// ---------------------------------------------------------------------------------------------------------
// Calendar fixture

const NAMED_INSTANTS = [
  ["2024-03-08T14:00:00Z", "09:00 EST, Friday before the 2024 spring change"],
  ["2024-03-11T13:00:00Z", "09:00 EDT, Monday after the 2024 spring change"],
  ["2024-03-10T06:59:59Z", "01:59:59 EST, last second before the spring gap"],
  ["2024-03-10T07:00:00Z", "03:00 EDT, first second after the spring gap"],
  ["2024-11-01T13:00:00Z", "09:00 EDT, Friday before the 2024 autumn change"],
  ["2024-11-04T14:00:00Z", "09:00 EST, Monday after the 2024 autumn change"],
  ["2024-11-03T05:59:59Z", "01:59:59 EDT, last second before the repeated hour"],
  ["2024-11-03T06:00:00Z", "01:00 EST, start of the repeated hour"],
  ["2024-01-01T05:00:00Z", "validation start, 00:00 EST"],
  ["2025-01-01T05:00:00Z", "test start, 00:00 EST"],
  ["2026-10-03T04:00:00Z", "dataset end, 00:00 EDT"],
];

function localFacts(t) {
  const p = nyParts(t);
  return { dateKey: p.dateKey, hour: p.hour, minute: p.minute, offsetSeconds: nyOffset(t) };
}

// Synthetic calendar instants for the public repository: a fixed grid from 2016-01-04 to 2026-10-03 at an
// odd stride (31 h 13 min), so every hour and minute pattern is exercised without using market-data timestamps.
export const SYNTHETIC_STRIDE_SECONDS = 31 * 3600 + 13 * 60;
export function syntheticTimestamps(start = Date.UTC(2016, 0, 4) / 1000, end = Date.UTC(2026, 9, 3) / 1000, stride = SYNTHETIC_STRIDE_SECONDS) {
  const out = [];
  for (let t = start; t < end; t += stride) out.push(t);
  return out;
}

// Evenly spaced, deterministic picks from each real source's timestamp array. When a pick repeats an
// already chosen timestamp (SPY and QQQ share most timestamps) it steps forward to the next unused one.
// (Used during the original study; the public build uses syntheticTimestamps instead.)
export function sampleTimestamps(series, perSeries = SAMPLES_PER_SERIES) {
  const chosen = new Set();
  for (const key of Object.keys(series).sort()) {
    const ts = series[key];
    const n = ts.length;
    const m = Math.min(perSeries, n);
    for (let i = 0; i < m; i++) {
      let idx = m === 1 ? 0 : Math.round((i * (n - 1)) / (m - 1));
      while (idx < n && chosen.has(ts[idx])) idx++;
      if (idx < n) chosen.add(ts[idx]);
    }
  }
  return [...chosen].sort((a, b) => a - b);
}

export function buildCalendarFixture(ny, samples) {
  const named = NAMED_INSTANTS.map(([label, note]) => {
    const t = Date.parse(label) / 1000;
    return { label, note, t, ...localFacts(t) };
  });
  const changes = ny.transitions.slice(1);
  const adjacent = new Set();
  for (const c of changes) {
    const y = new Date(c.utcStartSeconds * 1000).getUTCFullYear();
    if (y < 2016 || y > 2026) continue;
    for (let h = -3; h <= 3; h++) adjacent.add(c.utcStartSeconds + h * 3600);
    adjacent.add(c.utcStartSeconds - 1);
  }
  const all = new Set([...adjacent, ...samples]);
  const instants = [...all].sort((a, b) => a - b).map((t) => {
    const f = localFacts(t);
    return [t, f.dateKey, f.hour, f.minute, f.offsetSeconds];
  });

  const dates = new Set();
  for (const c of changes) {
    const { days } = dateKeyParts(nyParts(c.utcStartSeconds).dateKey);
    for (const d of [-1, 0, 1]) dates.add(dateKeyFromDays(days + d));
  }
  const first = dateKeyParts(20150101).days;
  const last = dateKeyParts(20271231).days;
  for (let d = first; d <= last; d += MIDNIGHT_STRIDE_DAYS) dates.add(dateKeyFromDays(d));
  for (const k of [20150101, 20271231, 20231231, 20241231, 20261002]) dates.add(k);
  const midnights = [...dates].sort((a, b) => a - b).map((k) => [k, nextMidnightAfter(k)]);

  return {
    zone: ZONE,
    note: "Expected values computed with Intl.DateTimeFormat; instants are {t, dateKey, hour, minute, offsetSeconds}; midnights are {dateKey, nextMidnightAfter}.",
    named,
    instants,
    dstAdjacentCount: instants.filter((r) => adjacent.has(r[0])).length,
    midnights,
  };
}

// ---------------------------------------------------------------------------------------------------------
// Source groups (manifest-driven chunk enumeration, hash and row-count verification)

const ROW_RE = /^\s*\{(-?\d+(?:\.\d+)?),[^{}\n]*\},?\s*$/gm;

function chunkRows(text, label) {
  if (!/^return \{/.test(text)) throw new Error(`prepare-lab: ${label} is not a returned row table`);
  const ts = [];
  for (const m of text.matchAll(ROW_RE)) ts.push(Number(m[1]));
  return ts;
}

export function describeGroups(root) {
  const groups = [];
  const timestamps = {};
  for (const g of GROUPS) {
    const manifestPath = `${g.dir}/manifest.json`;
    const manifestBytes = readFileSync(join(root, manifestPath));
    const manifest = JSON.parse(manifestBytes.toString("utf8"));
    const fileIndex = new Map(manifest.files.map((f) => [f.path, f]));
    const symbols = [];
    for (const symbol of g.symbols) {
      const info = manifest.symbols?.[symbol];
      if (!info) throw new Error(`prepare-lab: ${g.id} manifest has no ${symbol}`);
      const re = new RegExp(`^roblox/${symbol}/Chunk(\\d+)\\.luau$`);
      const listed = manifest.files
        .filter((f) => re.test(f.path))
        .map((f) => ({ num: Number(re.exec(f.path)[1]), file: f }))
        .sort((a, b) => a.num - b.num);
      if (listed.length !== info.chunkCount) {
        throw new Error(`prepare-lab: ${g.id}/${symbol} lists ${listed.length} chunks, chunkCount ${info.chunkCount}`);
      }
      listed.forEach((c, i) => {
        if (c.num !== i + 1) throw new Error(`prepare-lab: ${g.id}/${symbol} chunk numbering is not contiguous`);
      });
      // Cross-check the loader's own chunk order.
      const modulePath = `${g.dir}/${info.modulePath}`;
      const moduleBytes = readFileSync(join(root, modulePath));
      const names = /local chunkNames = \{([^}]*)\}/.exec(moduleBytes.toString("utf8"))?.[1].match(/Chunk\d+/g) ?? [];
      const chunkNames = listed.map((c) => `Chunk${String(c.num).padStart(3, "0")}`);
      if (names.join(",") !== chunkNames.join(",")) {
        throw new Error(`prepare-lab: ${modulePath} chunk order differs from the manifest`);
      }
      const moduleEntry = fileIndex.get(info.modulePath);
      if (moduleEntry && moduleEntry.sha256 !== sha256(moduleBytes)) throw new Error(`prepare-lab: ${modulePath} hash mismatch`);
      const csvPath = `${g.dir}/${info.csvPath}`;
      const csvBytes = readFileSync(join(root, csvPath));
      const csvEntry = fileIndex.get(info.csvPath);
      if (!csvEntry || csvEntry.sha256 !== sha256(csvBytes)) throw new Error(`prepare-lab: ${csvPath} hash mismatch`);

      const series = [];
      const chunks = listed.map(({ file }, i) => {
        const path = `${g.dir}/${file.path}`;
        const bytes = readFileSync(join(root, path));
        if (bytes.length !== file.bytes || sha256(bytes) !== file.sha256) {
          throw new Error(`prepare-lab: ${path} does not match its manifest bytes/sha256`);
        }
        const rows = chunkRows(bytes.toString("utf8"), path);
        for (const t of rows) series.push(t);
        const name = chunkNames[i];
        return {
          name,
          path,
          requirePath: posix.relative(GENERATED_DIR, `${g.dir}/roblox/${symbol}/${name}`),
          sha256: file.sha256,
          bytes: file.bytes,
          rows: rows.length,
        };
      });
      if (series.length !== info.count) {
        throw new Error(`prepare-lab: ${g.id}/${symbol} chunks hold ${series.length} rows, manifest says ${info.count}`);
      }
      // The CSV export must carry exactly the same timestamps as the Luau chunks.
      const csvTs = csvBytes.toString("utf8").trim().split(/\r?\n/).slice(1).map((l) => Number(l.split(",")[1]));
      if (csvTs.length !== series.length || csvTs.some((t, i) => t !== series[i])) {
        throw new Error(`prepare-lab: ${g.id}/${symbol} CSV timestamps differ from the Luau chunks`);
      }
      if (series[0] !== Date.parse(info.first) / 1000 || series[series.length - 1] !== Date.parse(info.last) / 1000) {
        throw new Error(`prepare-lab: ${g.id}/${symbol} first/last timestamps differ from the manifest`);
      }
      timestamps[`${g.id}/${symbol}`] = series;
      symbols.push({
        symbol,
        count: info.count,
        first: info.first,
        last: info.last,
        chunkCount: info.chunkCount,
        modulePath,
        moduleSha256: sha256(moduleBytes),
        csvPath,
        csvSha256: csvEntry.sha256,
        rowsCounted: series.length,
        chunks,
      });
    }
    groups.push({
      id: g.id,
      dir: g.dir,
      manifestPath,
      manifestSha256: sha256(manifestBytes),
      timeframe: manifest.timeframe,
      symbols,
    });
  }
  return { groups, timestamps };
}

export function renderSources(groups) {
  const L = [];
  L.push("-- GENERATED by tools/prepare-lab.mjs from the group manifests. Do not edit by hand.");
  L.push("-- CLI-only source loaders; never packaged into the Studio plugin. Each load() requires the existing");
  L.push("-- exported chunk modules by relative literal path from lab/generated/, in manifest order, concatenates");
  L.push("-- their rows (frozen, shared with the require cache) and asserts the manifest row count. No data is");
  L.push("-- copied into this file. Usage: Sources.get(\"hourly-original\", \"SPY\").load()");
  L.push("");
  L.push("local function append(rows: { any }, chunk: any, label: string, name: string, expected: number)");
  L.push("\tif type(chunk) ~= \"table\" then");
  L.push("\t\terror(\"Sources: \" .. label .. \"/\" .. name .. \" did not return a row table\", 2)");
  L.push("\tend");
  L.push("\tif #chunk ~= expected then");
  L.push("\t\terror(string.format(\"Sources: %s/%s has %d rows, manifest scan found %d\", label, name, #chunk, expected), 2)");
  L.push("\tend");
  L.push("\tlocal n = #rows");
  L.push("\tfor i, row in ipairs(chunk) do");
  L.push("\t\tif type(row) ~= \"table\" then");
  L.push("\t\t\terror(\"Sources: \" .. label .. \"/\" .. name .. \" row \" .. i .. \" is not a table\", 2)");
  L.push("\t\tend");
  L.push("\t\tif not table.isfrozen(row) then");
  L.push("\t\t\ttable.freeze(row)");
  L.push("\t\tend");
  L.push("\t\trows[n + i] = row");
  L.push("\tend");
  L.push("end");
  L.push("");
  L.push("local function finish(rows: { any }, expected: number, label: string): { any }");
  L.push("\tif #rows ~= expected then");
  L.push("\t\terror(string.format(\"Sources: %s row count %d does not match manifest %d\", label, #rows, expected), 2)");
  L.push("\tend");
  L.push("\treturn rows");
  L.push("end");
  L.push("");
  L.push("local groups = {}");
  for (const g of groups) {
    L.push("");
    L.push(`groups[${JSON.stringify(g.id)}] = {`);
    L.push(`\tid = ${JSON.stringify(g.id)},`);
    L.push(`\tdir = ${JSON.stringify(g.dir)},`);
    L.push(`\tmanifestPath = ${JSON.stringify(g.manifestPath)},`);
    L.push(`\tmanifestSha256 = ${JSON.stringify(g.manifestSha256)},`);
    L.push(`\ttimeframe = ${JSON.stringify(g.timeframe)},`);
    L.push(`\tsymbolOrder = { ${g.symbols.map((s) => JSON.stringify(s.symbol)).join(", ")} },`);
    L.push("\tsymbols = {");
    for (const s of g.symbols) {
      const label = `${g.id}/${s.symbol}`;
      L.push(`\t\t${s.symbol} = {`);
      L.push(`\t\t\tsymbol = ${JSON.stringify(s.symbol)},`);
      L.push(`\t\t\tcount = ${s.count},`);
      L.push(`\t\t\tfirst = ${JSON.stringify(s.first)},`);
      L.push(`\t\t\tlast = ${JSON.stringify(s.last)},`);
      L.push(`\t\t\tchunkCount = ${s.chunkCount},`);
      L.push(`\t\t\tmodulePath = ${JSON.stringify(s.modulePath)},`);
      L.push(`\t\t\tmoduleSha256 = ${JSON.stringify(s.moduleSha256)},`);
      L.push("\t\t\tchunks = {");
      for (const c of s.chunks) {
        L.push(`\t\t\t\t{ name = ${JSON.stringify(c.name)}, path = ${JSON.stringify(c.path)}, sha256 = ${JSON.stringify(c.sha256)}, bytes = ${c.bytes}, rows = ${c.rows} },`);
      }
      L.push("\t\t\t},");
      L.push("\t\t\tload = function(): { any }");
      L.push(`\t\t\t\tlocal rows = table.create(${s.count})`);
      for (const c of s.chunks) {
        L.push(`\t\t\t\tappend(rows, require(${JSON.stringify(c.requirePath)}), ${JSON.stringify(label)}, ${JSON.stringify(c.name)}, ${c.rows})`);
      }
      L.push(`\t\t\t\treturn finish(rows, ${s.count}, ${JSON.stringify(label)})`);
      L.push("\t\t\tend,");
      L.push("\t\t},");
    }
    L.push("\t},");
    L.push("}");
  }
  L.push("");
  L.push("local Sources = {");
  L.push(`\tgroupOrder = { ${groups.map((g) => JSON.stringify(g.id)).join(", ")} },`);
  L.push("\tgroups = groups,");
  L.push("}");
  L.push("");
  L.push("function Sources.get(groupId: string, symbol: string)");
  L.push("\tlocal g = groups[groupId]");
  L.push("\tif not g then");
  L.push("\t\terror(\"Sources: unknown group \" .. tostring(groupId), 2)");
  L.push("\tend");
  L.push("\tlocal s = g.symbols[symbol]");
  L.push("\tif not s then");
  L.push("\t\terror(\"Sources: group \" .. groupId .. \" has no symbol \" .. tostring(symbol), 2)");
  L.push("\tend");
  L.push("\treturn s");
  L.push("end");
  L.push("");
  L.push("return Sources");
  return L.join("\n") + "\n";
}

// ---------------------------------------------------------------------------------------------------------
// Independent structural audit (timestamps only)

export function loadConfig(root) {
  const bytes = readFileSync(join(root, "lab/config/default.json"));
  const c = JSON.parse(bytes.toString("utf8"));
  return { ...c, sourceSha256: sha256(bytes) };
}

function assertIncreasing(ts, label) {
  for (let i = 1; i < ts.length; i++) {
    if (!(ts[i] > ts[i - 1])) throw new Error(`prepare-lab: ${label} timestamps not strictly increasing at ${i}`);
  }
}

function counter() {
  return Object.fromEntries(SPLITS.map((s) => [s, 0]));
}

export function structureAudit(spyTs, qqqTs, { splits, warmup, horizonHours, barSeconds }) {
  assertIncreasing(spyTs, "SPY");
  assertIncreasing(qqqTs, "QQQ");
  const { validationStart: vs, testStart: ts, datasetEnd: de } = splits;
  const qset = new Set(qqqTs);
  const paired = spyTs.filter((t) => qset.has(t));
  const pset = new Set(paired);
  const dateOf = new Map(paired.map((t) => [t, nyParts(t).dateKey]));

  // Segments: first pair, New York date change, or delta other than one bar.
  const offset = [];
  let segments = 0;
  for (let i = 0; i < paired.length; i++) {
    const fresh = i === 0 || dateOf.get(paired[i]) !== dateOf.get(paired[i - 1]) || paired[i] - paired[i - 1] !== barSeconds;
    if (fresh) segments++;
    offset.push(fresh ? 1 : offset[i - 1] + 1);
  }

  // Input-bar split conventions. Boundaries must be New York midnights for the date convention.
  const boundaryDate = (t) => {
    const p = nyParts(t);
    return p.hour === 0 && p.minute === 0 && p.second === 0 ? p.dateKey : null;
  };
  const vsDate = boundaryDate(vs);
  const tsDate = boundaryDate(ts);
  const deDate = boundaryDate(de);
  const byValue = (x, a, b, c) => (x < a ? "train" : x < b ? "validation" : x < c ? "final" : "none");
  const inputSplit = (t) => byValue(t + barSeconds, vs, ts, de);
  const conventions = { decisionTime: {}, barStart: {}, nyDate: {} };
  for (const k of Object.keys(conventions)) conventions[k] = { ...counter(), none: 0 };
  const inputTimestamps = { train: [], validation: [], final: [], none: [] };
  for (const t of paired) {
    conventions.decisionTime[inputSplit(t)]++;
    inputTimestamps[inputSplit(t)].push(t);
    conventions.barStart[byValue(t, vs, ts, de)]++;
    conventions.nyDate[vsDate === null || tsDate === null || deDate === null ? "none" : byValue(dateOf.get(t), vsDate, tsDate, deDate)]++;
  }

  // Section 2.4 split of a labelled origin (exclusive upper bounds, outcome purge).
  const labelSplit = (decision, outcome) => {
    if (decision < vs && outcome < vs) return "train";
    if (decision >= vs && decision < ts && outcome < ts) return "validation";
    if (decision >= ts && outcome < de) return "final";
    return "none";
  };

  const H = horizonHours;
  const eligibleTimestamps = { train: [], validation: [], final: [] };
  const reasonsByInputSplit = { train: {}, validation: {}, final: {}, none: {} };
  const datesBySplit = { train: new Set(), validation: new Set(), final: new Set() };
  const eligibleDates = { train: new Set(), validation: new Set(), final: new Set() };
  let maxEligibleSegmentOffset = 0;
  let endpointOnlyIntermediateGaps = 0;
  paired.forEach((t, i) => {
    const s = inputSplit(t);
    if (datesBySplit[s]) datesBySplit[s].add(dateOf.get(t));
    let missingIntermediate = false;
    for (let k = 1; k < H; k++) if (!pset.has(t + k * barSeconds)) missingIntermediate = true;
    const targetT = t + H * barSeconds;
    const hasTarget = pset.has(targetT);
    const sameDate = hasTarget && dateOf.get(targetT) === dateOf.get(t);
    const split = labelSplit(t + barSeconds, targetT + barSeconds);
    let reason = null;
    if (offset[i] < warmup) reason = "insufficient_warmup";
    else if (missingIntermediate) reason = "missing_intermediate_hour";
    else if (!hasTarget) reason = "missing_target";
    else if (!sameDate) reason = "different_local_date";
    else if (split === "none") reason = "split_boundary";
    if (offset[i] >= warmup && missingIntermediate && hasTarget && sameDate && split !== "none") endpointOnlyIntermediateGaps++;
    if (reason) {
      reasonsByInputSplit[s][reason] = (reasonsByInputSplit[s][reason] ?? 0) + 1;
    } else {
      eligibleTimestamps[split].push(t);
      eligibleDates[split].add(dateOf.get(t));
      maxEligibleSegmentOffset = Math.max(maxEligibleSegmentOffset, offset[i]);
    }
  });

  const nonOverlap = (arr) => {
    let n = 0;
    let lastOutcome = -Infinity;
    for (const t of arr) {
      if (t + barSeconds >= lastOutcome) {
        n++;
        lastOutcome = t + (H + 1) * barSeconds;
      }
    }
    return n;
  };
  const splitsOut = {};
  for (const s of SPLITS) {
    splitsOut[s] = {
      pairedInputBars: conventions.decisionTime[s],
      nyDates: datesBySplit[s].size,
      eligibleOrigins: eligibleTimestamps[s].length,
      nonOverlappingOrigins: nonOverlap(eligibleTimestamps[s]),
      datesWithoutEligibleOrigin: [...datesBySplit[s]].filter((d) => !eligibleDates[s].has(d)).length,
    };
  }
  const sum = (key) => SPLITS.reduce((acc, s) => acc + splitsOut[s][key], 0);
  return {
    symbolCounts: { SPY: spyTs.length, QQQ: qqqTs.length },
    pairedTotal: paired.length,
    spyOnly: spyTs.length - paired.length,
    qqqOnly: qqqTs.length - paired.length,
    segments,
    conventions,
    splits: splitsOut,
    total: {
      pairedInputBars: sum("pairedInputBars"),
      nyDates: sum("nyDates"),
      eligibleOrigins: sum("eligibleOrigins"),
      nonOverlappingOrigins: sum("nonOverlappingOrigins"),
    },
    reasonsByInputSplit,
    maxEligibleSegmentOffset,
    endpointOnlyIntermediateGaps,
    eligibleTimestamps,
    inputTimestamps, // paired input timestamps by decision-time split (compared, not written out)
  };
}

function compareToPlan(profileId, p) {
  const e = EXPECTED[profileId];
  const out = [];
  for (const key of ["pairedInputBars", "nyDates", "eligibleOrigins", "nonOverlappingOrigins", "datesWithoutEligibleOrigin"]) {
    SPLITS.forEach((s, i) => {
      if (p.splits[s][key] !== e[key][i]) out.push(`${profileId} ${s} ${key}: expected ${e[key][i]}, got ${p.splits[s][key]}`);
    });
  }
  for (const [key, v] of Object.entries(e.total)) {
    if (p.total[key] !== v) out.push(`${profileId} total ${key}: expected ${v}, got ${p.total[key]}`);
  }
  for (const [key, v] of Object.entries(e.facts)) {
    if (p[key] !== v) out.push(`${profileId} ${key}: expected ${v}, got ${p[key]}`);
  }
  return out;
}

export function buildAudit(groups, timestamps, config) {
  const opts = {
    splits: config.splits,
    warmup: config.warmupObservations,
    horizonHours: config.horizonHours,
    barSeconds: config.barSeconds,
  };
  const groupInfo = Object.fromEntries(groups.map((g) => [g.id, g]));
  const profiles = {};
  const inputs = {};
  for (const [profileId, groupId, covers] of [["O14", "hourly-original", ["O14", "R50"]], ["H14", "hourly-combined", ["H14"]]]) {
    const { inputTimestamps, ...a } = structureAudit(timestamps[`${groupId}/SPY`], timestamps[`${groupId}/QQQ`], opts);
    inputs[profileId] = inputTimestamps;
    profiles[profileId] = { profiles: covers, source: groupId, manifestSha256: groupInfo[groupId].manifestSha256, ...a };
  }
  const mismatches = [...compareToPlan("O14", profiles.O14), ...compareToPlan("H14", profiles.H14)];
  const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
  // Plan 2.3: H14's validation/final paired-input arrays are identical to O14's (non-overlap arrays follow
  // from the eligible arrays, which are compared below).
  const crossChecks = {
    h14ValidationInputsEqualO14: same(inputs.H14.validation, inputs.O14.validation),
    h14FinalInputsEqualO14: same(inputs.H14.final, inputs.O14.final),
    h14ValidationEqualsO14: same(profiles.H14.eligibleTimestamps.validation, profiles.O14.eligibleTimestamps.validation),
    h14FinalEqualsO14: same(profiles.H14.eligibleTimestamps.final, profiles.O14.eligibleTimestamps.final),
    splitConventionsAgree: ["O14", "H14"].every((k) => {
      const c = profiles[k].conventions;
      return JSON.stringify(c.decisionTime) === JSON.stringify(c.barStart) && JSON.stringify(c.decisionTime) === JSON.stringify(c.nyDate);
    }),
    maxEligibleSegmentOffsetAtMostEight: profiles.O14.maxEligibleSegmentOffset <= 8 && profiles.H14.maxEligibleSegmentOffset <= 8,
  };
  if (!crossChecks.h14ValidationInputsEqualO14) mismatches.push("H14 validation paired input timestamps differ from O14");
  if (!crossChecks.h14FinalInputsEqualO14) mismatches.push("H14 final paired input timestamps differ from O14");
  if (!crossChecks.h14ValidationEqualsO14) mismatches.push("H14 validation eligible timestamps differ from O14");
  if (!crossChecks.h14FinalEqualsO14) mismatches.push("H14 final eligible timestamps differ from O14");
  return {
    auditVersion: "mrl-node-structure-audit-1",
    generator: "tools/prepare-lab.mjs",
    method:
      "Independent Node implementation. Timestamps parsed from the exported Luau chunk files (identical to the CSV exports); " +
      "New York dates from Intl.DateTimeFormat per timestamp, not from the generated offset table. Timestamps only: no prices read.",
    config: { sourceSha256: config.sourceSha256, ...opts },
    splitConvention:
      "Paired input bars and New York dates are assigned to a split by decision time t+3600 with the decision half of the " +
      "section 2.4 inequalities (decision < validationStart: train; < testStart: validation; < datasetEnd: final). " +
      "Bar-start time and New York date of the bar start give identical counts here because every boundary is a New York " +
      "midnight and no paired bar starts in the last hour before one. Eligible origins use the full 2.4 rule with outcome purge.",
    profiles,
    expected: EXPECTED,
    crossChecks,
    mismatches,
    matchesPlan: mismatches.length === 0,
  };
}

// ---------------------------------------------------------------------------------------------------------
// Rendering

const HEADER = "-- GENERATED by tools/prepare-lab.mjs. Do not edit by hand.\n";

export function renderNyOffsets(ny) {
  return (
    HEADER +
    "-- America/New_York UTC offsets from Node Intl.DateTimeFormat (never a fixed offset). Each entry gives the\n" +
    "-- offset (New York minus UTC, seconds) in force from utcStartSeconds until the next entry.\n" +
    `return ${toLuau(ny)}\n`
  );
}

export function renderCalendarFixture(fx) {
  return HEADER + "-- Intl-computed New York facts for lab/tests/Data.spec.luau.\n" + `return ${toLuau(fx)}\n`;
}

export function renderAuditLuau(audit) {
  return HEADER + "-- Node structural audit (same content as node-structure-audit.json) for lab/cli/audit.luau.\n" + `return ${toLuau(audit)}\n`;
}

// Stable pretty JSON: sorted keys, numeric arrays on one line.
export function renderJson(value) {
  const walk = (v, indent) => {
    const next = indent + "  ";
    if (Array.isArray(v)) {
      if (v.length === 0) return "[]";
      if (v.every((x) => typeof x === "number")) return `[${v.map((x) => JSON.stringify(x)).join(", ")}]`;
      return `[\n${v.map((x) => next + walk(x, next)).join(",\n")}\n${indent}]`;
    }
    if (v !== null && typeof v === "object") {
      const keys = Object.keys(v).sort();
      if (keys.length === 0) return "{}";
      return `{\n${keys.map((k) => `${next}${JSON.stringify(k)}: ${walk(v[k], next)}`).join(",\n")}\n${indent}}`;
    }
    if (typeof v === "number" && !Number.isFinite(v)) throw new Error("prepare-lab: non-finite number in JSON");
    return JSON.stringify(v);
  };
  return walk(value, "") + "\n";
}

export function buildAll(root) {
  const config = loadConfig(root);
  const ny = buildNyOffsets();
  const { groups, timestamps } = describeGroups(root);
  const calendarFixture = buildCalendarFixture(ny, syntheticTimestamps());
  const audit = buildAudit(groups, timestamps, config);
  const files = {
    "NyOffsets.luau": renderNyOffsets(ny),
    "CalendarFixture.luau": renderCalendarFixture(calendarFixture),
    "Sources.luau": renderSources(groups),
    "NodeStructureAudit.luau": renderAuditLuau(audit),
    "node-structure-audit.json": renderJson(audit),
  };
  return { files, ny, calendarFixture, groups, audit };
}

export function writeAll(root, files) {
  const dir = join(root, GENERATED_DIR);
  mkdirSync(dir, { recursive: true });
  for (const [name, content] of Object.entries(files)) {
    const target = join(dir, name);
    const tmp = `${target}.tmp`;
    writeFileSync(tmp, content, "utf8");
    renameSync(tmp, target);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  const { files, audit, ny } = buildAll(root);
  writeAll(root, files);
  const brief = (p) => ({
    splits: Object.fromEntries(SPLITS.map((s) => [s, p.splits[s]])),
    total: p.total,
    maxEligibleSegmentOffset: p.maxEligibleSegmentOffset,
    endpointOnlyIntermediateGaps: p.endpointOnlyIntermediateGaps,
  });
  console.log(JSON.stringify({
    wrote: Object.keys(files).map((f) => `${GENERATED_DIR}/${f}`),
    nyTransitions: ny.transitions.length,
    O14: brief(audit.profiles.O14),
    H14: brief(audit.profiles.H14),
    crossChecks: audit.crossChecks,
    matchesPlan: audit.matchesPlan,
    mismatches: audit.mismatches,
  }, null, 2));
  if (!audit.matchesPlan) process.exitCode = 1;
}
