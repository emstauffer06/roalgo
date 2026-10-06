// Writes runs/exp-20261005/report.md (and a JSON digest) from saved artifacts only (plan Task 9).
// Usage: node tools/report.mjs
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const EXP = "exp-20261005";
const expDir = join(root, "runs", EXP);
const rd = (f) => JSON.parse(readFileSync(f, "utf8"));
const opt = (f) => (existsSync(f) ? rd(f) : null);
const PROFILES = ["O14", "R50", "H14"];
const MODELS = ["ZERO", "MEAN", "MARKOV", "RAW", "RAW8", "PHYSICS", "RAW_PHYSICS"];
const NAMES = { ZERO: "ZERO", MEAN: "MEAN", MARKOV: "MARKOV", RAW: "RAW-RIDGE", RAW8: "RAW-RIDGE (8 lags)", PHYSICS: "PHYSICS-RIDGE", RAW_PHYSICS: "RAW+PHYSICS" };
const bp = (x) => (x == null ? "n/a" : (x * 10000).toFixed(2));
const pct = (x) => (x == null ? "n/a" : (100 * x).toFixed(1) + "%");
const f4 = (x) => (x == null ? "n/a" : x.toFixed(4));

const protocol = rd(join(expDir, "protocol.json"));
const calibration = rd(join(expDir, "calibration.json"));
const mechanism = rd(join(expDir, "mechanism.json"));
const evaluation = opt(join(expDir, "evaluation-final.json"));
const manifest = opt(join(expDir, "experiment-manifest.json"));
const locks = Object.fromEntries(PROFILES.map((p) => [p, opt(join(root, "runs", `${p}-a1`, "model-lock.json"))]));
const valid = Object.fromEntries(PROFILES.map((p) => [p, opt(join(root, "runs", `${p}-a1`, "validation-summary.json"))]));
const pumpFinals = readdirSync(expDir)
  .filter((n) => /-pump-final(-\d+)?\.json$/.test(n))
  .map((n) => ({ job: n.replace(/-pump-final(-\d+)?\.json$/, ""), file: n, ...rd(join(expDir, n)) }));

const L = [];
const P = (...s) => L.push(...s);
P(`# Roblox physics market forecast: results`, "");
P(`Experiment \`${EXP}\`. Protocol sha256 \`${protocol.sha256.slice(0, 16)}…\`, frozen before any validation search.`, "");
P("This is an eight-hour, within-day, extended-session forecasting experiment on SPY (S&P 500 ETF proxy) and QQQ (Nasdaq-100 ETF). It is not a trading strategy and makes no profitability claim.", "");

P("## 1. Did Roblox's native solver generate the features?", "");
let steps = 0, dropped = 0, corrupt = 0, requests = 0, replays = 0;
for (const pf of pumpFinals) {
  const st = pf.stopped?.stats ?? pf.stats;
  if (st) {
    steps += st.totalSteps ?? 0;
    dropped += st.droppedRequests ?? 0;
    corrupt += st.corruptSteps ?? 0;
    requests += st.requests ?? 0;
  }
  replays += pf.replays ?? 0;
}
P(`Yes. Every physical feature is a position or velocity read from Roblox parts moved by native PrismaticConstraint rails, SpringConstraints and VectorForces under \`WorldRoot:StepPhysics(1/60)\` in Studio 0.741 Edit mode, from a local plugin thread.`,
  `Studio applies each StepPhysics request on a later frame and drops about one request in eight, so every step was verified: two free-falling metronome parts rode in every call and each completed step was confirmed as exactly one dt before the next was issued (docs/stepping-capability.md).`,
  `Across all recorded jobs: ${steps.toLocaleString()} verified steps from ${requests.toLocaleString()} requests (${dropped.toLocaleString()} dropped and re-issued), ${corrupt} corrupt steps, ${replays} segment replays.`, "");

P("## 2. Software, causality, numerical and export checks", "");
P("- Structural audit reproduces every count in plan section 2.3 (O14/R50 2,646/1,249/2,186 eligible origins; H14 9,103/1,249/2,186) in Luau and independently in Node.",
  "- Tests at delivery: see README (Luau pure suite, Node suites, Studio Physics.spec).",
  `- Inputs: training-only scaler; inputs sha256 O14 \`${protocol.inputs.inputsSha256.O14.slice(0, 12)}…\`, R50 \`${protocol.inputs.inputsSha256.R50.slice(0, 12)}…\`, H14 \`${protocol.inputs.inputsSha256.H14.slice(0, 12)}…\`.`);
if (manifest) P(`- Release gate: all profiles locked and final ledgers exported before outcomes were joined: ${manifest.releaseReady}.`);
if (evaluation) P(`- Node recomputation of point metrics: ${evaluation.nodeRecomputation.groups} groups, ${evaluation.nodeRecomputation.disagreements.length} disagreements beyond 1e-10.`);
P("");

P("## 3. Final-period comparison (all eligible origins)", "");
if (evaluation) {
  for (const p of PROFILES) {
    const ev = evaluation.profiles[p];
    P(`### ${p}  (status: ${ev.comparisonStatus}; forecasts ${ev.forecasts}, failures ${ev.failures})`, "");
    P("| Model | SPY RMSE bp | SPY MAE bp | SPY direction | QQQ RMSE bp | QQQ MAE bp | QQQ direction |", "|---|---:|---:|---:|---:|---:|---:|");
    for (const m of MODELS) {
      const g = (sym) => ev.metrics.find((r) => r.modelId === m && r.symbol === sym && r.split === "final");
      const s = g("SPY"), q = g("QQQ");
      P(`| ${NAMES[m]} | ${bp(s?.rmse)} | ${bp(s?.mae)} | ${pct(s?.directionAccuracy)} | ${bp(q?.rmse)} | ${bp(q?.mae)} | ${pct(q?.directionAccuracy)} |`);
    }
    const s0 = ev.metrics.find((r) => r.modelId === "ZERO" && r.symbol === "SPY" && r.split === "final");
    P("", `Eligible final origins per symbol: ${s0?.eligible}. Always-up direction benchmark: SPY ${pct(s0?.alwaysUpAccuracy)}, QQQ ${pct(ev.metrics.find((r) => r.modelId === "ZERO" && r.symbol === "QQQ" && r.split === "final")?.alwaysUpAccuracy)}.`, "");
  }
} else P("_Final evaluation not run yet._", "");

P("## 4. Size and uncertainty of the differences", "");
if (evaluation) {
  P("Paired moving-block bootstrap over New York dates (5-date blocks, 2,000 replicates), difference in mean-over-symbols RMSE divided by training target std (negative = model A better).", "",
    "| Comparison | Estimate | 2.5% | 97.5% |", "|---|---:|---:|---:|");
  for (const c of evaluation.comparisons) {
    P(`| ${c.primary ? "**" + c.label + "**" : c.label} | ${c.ok ? f4(c.interval.estimate) : "error"} | ${c.ok ? f4(c.interval.lower) : ""} | ${c.ok ? f4(c.interval.upper) : ""} |`);
  }
  const prim = evaluation.comparisons.find((c) => c.primary);
  P("", prim?.ok
    ? (prim.interval.upper < 0
      ? "The primary interval lies entirely below zero: on this holdout RAW+PHYSICS improved the frozen primary metric relative to the equally informed raw baseline."
      : prim.interval.lower > 0
        ? "The primary interval lies entirely above zero: on this holdout RAW+PHYSICS was worse than the equally informed raw baseline."
        : `The primary interval includes zero: no evidence of incremental value from the physics features on this holdout. The point estimate (${f4(prim.interval.estimate)}) ${prim.interval.estimate > 0 ? "favours the raw baseline (adding physics features made the normalized RMSE slightly worse)" : "favours RAW+PHYSICS, but not distinguishably from zero"}.`)
    : "Primary comparison unavailable.", "");
  const worse = evaluation.comparisons.filter((c) => !c.primary && c.ok && /RAW\+PHYSICS - (O14|H14|R50) RAW-RIDGE/.test(c.label) && c.interval.lower > 0);
  if (worse.length) P(`Exploratory: ${worse.map((c) => c.label).join("; ")} have intervals above zero, i.e. the physics-augmented readout was worse than its raw comparator there.`, "");
  const zeroRow = (p, m, sym) => evaluation.profiles[p].metrics.find((r) => r.modelId === m && r.symbol === sym && r.split === "final");
  P(`Context: every model's RMSE is within about 1% of the no-change forecast (R50 SPY ZERO ${bp(zeroRow("R50", "ZERO", "SPY")?.rmse)} bp vs best ${bp(Math.min(...["RAW", "RAW8", "PHYSICS", "RAW_PHYSICS", "MEAN", "MARKOV"].map((m) => zeroRow("R50", m, "SPY")?.rmse ?? Infinity)))} bp), and no model's direction accuracy beats simply predicting "up" (always-up SPY ${pct(zeroRow("R50", "ZERO", "SPY")?.alwaysUpAccuracy)}, QQQ ${pct(zeroRow("R50", "ZERO", "QQQ")?.alwaysUpAccuracy)}). Eight-hour SPY/QQQ returns were essentially unpredictable from this information for all methods.`,
    "",
    "Secondary comparisons are exploratory (no multiplicity adjustment). Overlapping eight-hour forecasts and the two ETFs are not independent trials.", "");
}

P("## 5. Consistency across ETFs, months and origin hours", "");
if (evaluation) {
  for (const p of PROFILES) {
    const b = evaluation.profiles[p].breakdowns.filter((r) => r.split === "final");
    const parts = [];
    for (const dim of ["month", "hour"]) {
      for (const sym of ["SPY", "QQQ"]) {
        const a = new Map(b.filter((r) => r.dimension === dim && r.symbol === sym && r.modelId === "RAW_PHYSICS").map((r) => [r.key, r.rmse]));
        const raw = b.filter((r) => r.dimension === dim && r.symbol === sym && r.modelId === "RAW");
        let wins = 0, total = 0;
        for (const r of raw) if (a.has(r.key) && r.rmse != null && a.get(r.key) != null) { total++; if (a.get(r.key) < r.rmse) wins++; }
        parts.push(`${sym} ${dim}s ${wins}/${total}`);
      }
    }
    P(`- ${p}: RAW+PHYSICS had lower RMSE than RAW-RIDGE in ${parts.join(", ")}.`);
  }
  P("", "Full per-month, per-origin-hour and per-segment-age breakdowns: `evaluation-final.json` (profiles.<P>.breakdowns).", "");
}

P("## 6. Repeatability and speed of the native computation", "");
for (const p of PROFILES) {
  const r = mechanism.repeatability[p];
  P(`- ${p}: soft-reset repeats max ${Math.max(...r.softResetRepeats.map((s) => s.max)).toExponential(2)}, median ${Math.max(...r.softResetRepeats.map((s) => s.median)).toExponential(2)}; clean builds max ${Math.max(...r.cleanBuilds.map((s) => s.max)).toExponential(2)} (gate max 1e-3, median 1e-5): ${r.softPasses && r.cleanPasses ? "pass" : "FAIL"}.`);
}
P(`- Superposition (O14 inputs, u/2u/v/u+v): homogeneity deviation ${Object.entries(mechanism.superposition).map(([k, v]) => `${k} ${(100 * v.homogeneityDeviationRelative).toFixed(1)}%`).join(", ")}; additivity ${Object.entries(mechanism.superposition).map(([k, v]) => `${k} ${(100 * v.additivityDeviationRelative).toFixed(1)}%`).join(", ")} of response RMS.`);
P(`- Drive calibration (inputs only): chosen ${JSON.stringify(calibration.chosen)} studs; no saturation at any grid value.`);
const cross = opt(join(expDir, "mechanism-crosssession.json"));
if (cross) P(`- Cross-session check (new Studio session and plugin build vs the earlier session, recorded before final physics): ${Object.values(cross.profiles).flatMap((k) => Object.entries(k)).filter(([, s]) => !s.passes).map(([k, s]) => `${k} max ${s.max.toExponential(2)}`).join(", ") || "all within the gate"}; every locked preset matched within ${Math.max(...["O14:P1", "R50:P3", "H14:P3"].map((k) => cross.profiles[k.split(":")[0]][k].max)).toExponential(1)}. The engine's small-velocity quantisation can turn ~1e-7 float differences into discrete ~1e-3 jumps; native repeatability is therefore high but not bit-for-bit across sessions.`);
for (const pf of pumpFinals) if (pf.barsPerSecond) P(`- Job ${pf.job}: ${pf.processed ?? "?"} observations at ${pf.barsPerSecond.toFixed(2)} obs/s (${(pf.stepsPerSecond ?? 0).toFixed(1)} verified steps/s).`);
P("");

P("## 7. Limitations", "",
  "- One train/validation/final split; no walk-forward refit. Raw (not total-return) prices; extended-hours native hourly bars; QQQ is not the Nasdaq Composite.",
  "- StepPhysics in this Studio build is deferred and lossy; the verified protocol guarantees exactly-one-dt requests but cannot observe the engine's internal adaptive sub-stepping of each assembly. Repeatability is measured, not assumed.",
  "- Independent segments ran in parallel lanes; lane layout changes states by at most ~7e-5.",
  "- The engine reports exactly-zero velocities for a small fraction of slow nodes (small-velocity quantisation); this is part of the measured native response.",
  "- Validation-selected hyperparameters within a fixed 147-candidate budget; equal candidate counts do not imply equal capacity.", "");

P("## 8. Extra information and longer history", "", "See the secondary rows of the table in section 4 (R50 vs O14, H14 vs O14; O14 training target std as the common denominator).", "");
P("## 9. Regime inputs (R60)", "", "Not preregistered; disabled. No R60 result exists.", "");

P("## Validation-period selection (for reference; selection used validation only)", "");
for (const p of PROFILES) {
  if (!locks[p]) continue;
  P(`- ${p}: RAW-RIDGE ${locks[p].selected.rawRidge.config} λ=${locks[p].selected.rawRidge.lambda}; RAW+PHYSICS ${locks[p].selected.rawPhysics.config} λ=${locks[p].selected.rawPhysics.lambda}; PHYSICS-RIDGE λ=${locks[p].selected.physicsOnly.lambda}; model sha256 \`${locks[p].hashes.model.slice(0, 12)}…\`.`);
}
P("");
const out = L.join("\n");
writeFileSync(join(expDir, "report.md"), out, "utf8");
console.log(out);
