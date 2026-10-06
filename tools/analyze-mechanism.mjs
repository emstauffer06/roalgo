// Mechanism checks from the R1/R2/R3 and SP jobs (plan Task 3; section 6 items 3 and superposition).
//   Repeatability gate: max |difference| <= 1e-3 and median <= 1e-5 of normalized physical features
//     soft  : first vs second pass of the same window inside one job (soft resets between segments)
//     clean : R1 vs R2 vs R3 first passes (three clean builds)
//   Superposition: responses to u, 2u, v, u+v from identical resets; deviation relative to response RMS.
// Usage: node tools/analyze-mechanism.mjs   -> runs/<EXP>/mechanism.json (refuses to overwrite)
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadStatePages } from "./states-to-luau.mjs";
import { canonicalSha256 } from "./canonical-json.mjs";
import { EXP } from "./run-lab.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const expDir = join(root, "runs", EXP);
const config = JSON.parse(readFileSync(join(root, "lab/config/default.json"), "utf8"));
const gate = config.physics.repeatability;
const pages = (stream) => loadStatePages(join(expDir, "state-cache", stream));

function diffStats(a, b, keys) {
  const d = [];
  for (let k = 0; k < a.length; k++) for (const key of keys) for (let j = 0; j < 48; j++) d.push(Math.abs(a[k].s[key][j] - b[k].s[key][j]));
  d.sort((x, y) => x - y);
  return { n: d.length, max: d.at(-1), median: d[Math.floor((d.length - 1) / 2)], p99: d[Math.floor(0.99 * (d.length - 1))], exactZeroFraction: d.filter((x) => x === 0).length / d.length };
}
const passes = (s) => s.max <= gate.maxAbs && s.median <= gate.median;

const repeatability = {};
for (const p of ["O14", "R50", "H14"]) {
  const runs = ["R1", "R2", "R3"].map((j) => pages(`${j}-${p}`));
  const keys = runs[0].keys;
  const half = runs[0].rows.length / 2;
  if (!Number.isInteger(half)) throw new Error("repeat window not doubled");
  const first = runs.map((r) => r.rows.slice(0, half));
  const second = runs.map((r) => r.rows.slice(half));
  first.forEach((f, k) => f.forEach((row, i) => { if (row.t !== second[k][i].t) throw new Error("repeat misaligned"); }));
  const soft = runs.map((_, k) => diffStats(first[k], second[k], keys));
  const clean = [diffStats(first[0], first[1], keys), diffStats(first[0], first[2], keys), diffStats(first[1], first[2], keys)];
  repeatability[p] = {
    observations: half,
    keys,
    softResetRepeats: soft,
    cleanBuilds: clean,
    softPasses: soft.every(passes),
    cleanPasses: clean.every(passes),
  };
}

// Superposition (O14 inputs): homogeneity 2u vs 2*R(u); additivity R(u+v) vs R(u)+R(v).
const sp = { u: pages("SP-u"), u2: pages("SP-2u"), v: pages("SP-v"), uv: pages("SP-uv") };
const superposition = {};
for (const pre of ["P1", "P2", "P3"]) {
  let sumSq = 0, hom = 0, add = 0, n = 0;
  const kU = `U:${pre}`, kU2 = `U2:${pre}`, kV = `V:${pre}`, kUV = `UV:${pre}`;
  for (let i = 0; i < sp.u.rows.length; i++) {
    const ru = sp.u.rows[i].s[kU], r2 = sp.u2.rows[i].s[kU2], rv = sp.v.rows[i].s[kV], ruv = sp.uv.rows[i].s[kUV];
    for (let j = 0; j < 48; j++) {
      sumSq += ru[j] ** 2 + rv[j] ** 2;
      hom += (r2[j] - 2 * ru[j]) ** 2;
      add += (ruv[j] - ru[j] - rv[j]) ** 2;
      n++;
    }
  }
  const rms = Math.sqrt(sumSq / (2 * n));
  superposition[pre] = {
    responseRms: rms,
    homogeneityDeviationRelative: Math.sqrt(hom / n) / rms,
    additivityDeviationRelative: Math.sqrt(add / n) / rms,
  };
}
const maxRel = Math.max(...Object.values(superposition).flatMap((s) => [s.homogeneityDeviationRelative, s.additivityDeviationRelative]));
const result = {
  experimentId: EXP,
  gate,
  repeatability,
  repeatabilityPasses: Object.values(repeatability).every((r) => r.softPasses && r.cleanPasses),
  superposition,
  superpositionReading: maxRel < 0.01
    ? "deviation from superposition below 1% of response RMS: the calibrated operating range is nearly linear; do not advertise measured nonlinearity"
    : "superposition deviation of at least 1% of response RMS: measurable nonlinearity in the calibrated range (attribute only after ruling out engine quantisation)",
  resetEveryObservationAblation: "omitted (declared before final evaluation): runtime budget; soft-reset vs clean-build repeatability is reported instead",
};
result.sha256 = canonicalSha256(result);
const file = join(expDir, "mechanism.json");
if (existsSync(file)) throw new Error(`refusing to overwrite ${file}`);
writeFileSync(file, JSON.stringify(result, null, 2), "utf8");
console.log(JSON.stringify({ repeatabilityPasses: result.repeatabilityPasses, superposition, reading: result.superpositionReading }, null, 1));
for (const [p, r] of Object.entries(repeatability)) {
  console.log(p, "soft max", Math.max(...r.softResetRepeats.map((s) => s.max)).toExponential(2), "median", Math.max(...r.softResetRepeats.map((s) => s.median)).toExponential(2),
    "| clean max", Math.max(...r.cleanBuilds.map((s) => s.max)).toExponential(2), "median", Math.max(...r.cleanBuilds.map((s) => s.median)).toExponential(2));
}
