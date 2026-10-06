// Writes runs/<EXP>/protocol.json: the experiment rules frozen BEFORE any validation search (plan Tasks 6/9).
// Refuses to overwrite an existing protocol; a revision must be a new versioned file.
import { writeFileSync, existsSync, readFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalSha256 } from "./canonical-json.mjs";
import { EXP } from "./run-lab.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(join(root, "lab/config/default.json"), "utf8"));
const inputs = {};
for (const p of ["O14", "R50", "H14"]) {
  inputs[p] = JSON.parse(readFileSync(join(root, "runs", EXP, `${p}-feature-schema.json`), "utf8")).version;
}
const inputHashes = {};
for (const p of ["O14", "R50", "H14"]) {
  const head = readFileSync(join(root, "runs", EXP, "inputs", `${p}.json`), "utf8").slice(0, 4000);
  const m = head.match(/"inputsSha256":"([0-9a-f]{64})"/);
  inputHashes[p] = m ? m[1] : null;
}

const protocol = {
  protocolVersion: "mrl-protocol-1",
  experimentId: EXP,
  writtenAt: new Date().toISOString(),
  statement: "Frozen before any validation search. Final-period targets have not been read by any code in this project.",
  plan: "docs/superpowers/plans/2026-10-04-roblox-physics-market-forecast.md (revised 2026-10-05)",
  profiles: {
    included: ["O14", "R50", "H14"],
    excluded: { R60: "optional profile not preregistered; disabled (config profiles.R60.enabled=false)" },
    runIds: { O14: "O14-a1", R50: "R50-a1", H14: "H14-a1" },
  },
  comparisons: {
    primary: "R50 RAW+PHYSICS vs R50 RAW-RIDGE (each selected on validation within its 21-setting budget); statistic: paired 5-date moving-block bootstrap of the difference in mean-over-symbols RMSE / R50 training target std, 2000 replicates",
    alsoReported: ["R50 RAW+PHYSICS vs R50 exact eight-lag RAW-RIDGE", "R50 PHYSICS-RIDGE (diagnostic)", "ZERO", "MEAN", "MARKOV"],
    secondary: [
      "O14 RAW+PHYSICS vs O14 RAW-RIDGE (simpler reference)",
      "R50 vs O14 (extra information), common denominator = O14 training target std",
      "H14 vs O14 (training history), common denominator = O14 training target std",
    ],
    secondaryLabel: "exploratory; no multiplicity adjustment",
  },
  target: { horizonHours: 8, warmupObservations: 4, sameNyDate: true, splits: config.splits },
  inputs: { schemaVersions: inputs, inputsSha256: inputHashes, scaler: "training-only (decisionTime < validationStart), observed values only, clip 4" },
  budgets: {
    perProfile: { "RAW-RIDGE": "lags {1,4,8} x 7 lambdas = 21", "RAW+PHYSICS": "presets {P1,P2,P3} x 7 lambdas = 21", "PHYSICS-RIDGE": "7 lambdas at the RAW+PHYSICS-selected preset (diagnostic)" },
    lambdas: config.lambdas,
    totalRidgeCandidates: 147,
    noSearch: ["ZERO", "MEAN", "MARKOV"],
    selection: "mean over SPY/QQQ of validation RMSE / training target std; tie tolerance 1e-12; ties -> larger lambda, then smaller lag / lower preset",
  },
  physics: {
    geometry: "plan section 4 defaults (24 nodes 4x6, prismatic rails +-3, axial + 38 coupling native SpringConstraints, VectorForce per node)",
    projection: "Roblox Random.new(20261004), saved matrices runs/<EXP>/projection-D14.json, -D50.json (O14 and H14 share D14)",
    presets: config.physics.presets,
    driveCalibration: {
      grid: config.physics.driveDisplacementGrid,
      window: "first 1,187 paired observations from 2021-10-04 (76 whole segments, all training), identical timestamps for O14/R50/H14",
      rule: "per profile, the largest grid value whose saturated node-state fraction (|x| >= 2.9 studs) is <= 0.1% for all three presets; targets never used",
    },
    stepping: "verified deferred stepping (docs/stepping-capability.md): StepPhysics(1/60, all moving parts + 2 metronomes) one outstanding request at a time, each confirmed as exactly one dt; dropped requests re-issued; any non-unit step replays the whole call's segments from reset",
    execution: "independent segments processed in parallel lanes inside one verified StepPhysics call (every segment starts from the same reset + 60 settle steps); lane layout changes states by <= ~7e-5 (measured), within the repeatability gate",
    repeatabilityGate: config.physics.repeatability,
    resets: "soft reset (equilibrium CFrame, zero velocities, zero drive) + 60 zero-input steps at every segment start",
  },
  markov: config.markov,
  evaluation: { bootstrap: config.bootstrap, nonOverlap: "accept an origin only if its decision time >= previous selected outcome time" },
  releaseGate: "all included profiles locked and every final prediction ledger exported and hashed before any final outcome is joined",
};

const file = join(root, "runs", EXP, "protocol.json");
if (existsSync(file)) {
  console.error(`refusing to overwrite ${file}`);
  process.exit(1);
}
mkdirSync(dirname(file), { recursive: true });
const { writtenAt: _ignored, ...hashed } = protocol;
protocol.sha256 = canonicalSha256(hashed);
writeFileSync(file, JSON.stringify(protocol, null, 2), "utf8");
console.log("wrote", file, protocol.sha256);
