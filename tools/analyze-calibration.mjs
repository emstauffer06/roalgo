// Drive-displacement calibration (plan section 4 / Task 3): inputs only, no targets.
// Reads the calibration job's state pages and, per profile, selects the largest grid drive whose saturated
// node-state fraction (|x| >= saturationThreshold studs) is <= maxSaturationFraction for ALL three presets.
// Also reports max |x|, exact-zero velocity fraction (engine small-velocity quantisation), and state variance.
// Usage: node tools/analyze-calibration.mjs <jobId>   -> runs/<EXP>/calibration.json (refuses to overwrite)
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadStatePages } from "./states-to-luau.mjs";
import { canonicalSha256 } from "./canonical-json.mjs";
import { EXP } from "./run-lab.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(join(root, "lab/config/default.json"), "utf8"));
const phys = config.physics;

export function summarise(rows, keys) {
  const out = {};
  for (const key of keys) {
    let saturated = 0, measured = 0, zeroV = 0, maxAbsX = 0;
    const sum = new Float64Array(48), sq = new Float64Array(48);
    for (const r of rows) {
      const s = r.s[key];
      for (let n = 0; n < 24; n++) {
        const x = Math.abs(s[n] * 3);
        measured++;
        if (x >= phys.saturationThreshold) saturated++;
        if (x > maxAbsX) maxAbsX = x;
        if (s[24 + n] === 0) zeroV++;
      }
      for (let k = 0; k < 48; k++) {
        sum[k] += s[k];
        sq[k] += s[k] * s[k];
      }
    }
    let varSum = 0;
    for (let k = 0; k < 48; k++) {
      const m = sum[k] / rows.length;
      varSum += sq[k] / rows.length - m * m;
    }
    out[key] = {
      rows: rows.length,
      saturatedFraction: saturated / measured,
      maxAbsX,
      zeroVelocityFraction: zeroV / measured,
      meanStateVariance: varSum / 48,
    };
  }
  return out;
}

export function choose(summary, profiles, presets, grid) {
  const chosen = {};
  for (const p of profiles) {
    const passing = grid.filter((d) =>
      presets.every((pre) => {
        const s = summary[`${p}:${pre}:d${d}`];
        if (!s) throw new Error(`missing calibration key ${p}:${pre}:d${d}`);
        return s.saturatedFraction <= phys.maxSaturationFraction;
      }),
    );
    chosen[p] = passing.length ? Math.max(...passing) : null;
  }
  return chosen;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const jobId = process.argv[2];
  const job = JSON.parse(readFileSync(join(root, "runs", EXP, `${jobId}-job.json`), "utf8"));
  const summary = {};
  const coverage = {};
  for (const stream of job.streams) {
    const pages = loadStatePages(join(root, "runs", EXP, "state-cache", stream));
    if (pages.rows.length !== job.rows) throw new Error(`${stream}: ${pages.rows.length} of ${job.rows} rows`);
    Object.assign(summary, summarise(pages.rows, pages.keys));
    coverage[stream] = { rows: pages.rows.length, pageHashes: pages.pageHashes };
  }
  const profiles = Object.values(job.streamProfiles);
  const presets = Object.keys(phys.presets);
  const chosen = choose(summary, profiles, presets, phys.driveDisplacementGrid);
  const result = {
    experimentId: EXP,
    jobId,
    window: job.window,
    rows: job.rows,
    segments: job.segments,
    rule: "largest grid drive with saturated node-state fraction <= maxSaturationFraction for all presets",
    maxSaturationFraction: phys.maxSaturationFraction,
    saturationThreshold: phys.saturationThreshold,
    grid: phys.driveDisplacementGrid,
    chosen,
    summary,
    coverage,
  };
  result.sha256 = canonicalSha256(result);
  const file = join(root, "runs", EXP, "calibration.json");
  if (existsSync(file)) throw new Error(`refusing to overwrite ${file}`);
  writeFileSync(file, JSON.stringify(result, null, 2), "utf8");
  console.log(JSON.stringify({ chosen, file }));
  for (const [k, v] of Object.entries(summary)) {
    console.log(k.padEnd(18), `sat ${v.saturatedFraction.toExponential(2)}  max|x| ${v.maxAbsX.toFixed(3)}  zeroV ${(100 * v.zeroVelocityFraction).toFixed(2)}%  var ${v.meanStateVariance.toExponential(3)}`);
  }
}
