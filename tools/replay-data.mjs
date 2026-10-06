// Builds the data for a recorded experiment replay (plan Task 8) from saved artifacts only:
// final-period inputs and physics states, frozen forecasts, and outcomes (only after evaluation exported them).
// Served by the bridge at GET /replay?profile=R50&segment=<n> (or &date=YYYY-MM-DD).
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadStatePages } from "./states-to-luau.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const EXP = "exp-20261005";
const nyFmt = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" });

function ny(t) {
  const parts = Object.fromEntries(nyFmt.formatToParts(new Date(t * 1000)).map((p) => [p.type, p.value]));
  return { date: `${parts.year}-${parts.month}-${parts.day}`, hour: Number(parts.hour) };
}

const readJson = (f) => JSON.parse(readFileSync(f, "utf8"));
const readJsonl = (f) => (existsSync(f) ? readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);

export function buildReplay({ profile = "R50", segment, date, label }) {
  const inputs = readJson(join(root, "runs", EXP, "inputs", `${profile}.json`)).rows;
  let rows = inputs.filter((r) => r.split === "final");
  if (segment != null) rows = rows.filter((r) => r.seg === Number(segment));
  else if (date) rows = rows.filter((r) => ny(r.t).date === date);
  else throw new Error("segment or date required");
  if (!rows.length) throw new Error("no final-period rows for that selection");
  const lock = readJson(join(root, "runs", `${profile}-a1`, "model-lock.json"));
  const preset = lock.preset;
  const key = `${profile}:${preset}`;
  const states = new Map();
  const jobFile = readJson(join(root, "runs", EXP, "final-job-id.json"));
  const pages = loadStatePages(join(root, "runs", EXP, "state-cache", `${jobFile.jobId}-${profile}`));
  for (const r of pages.rows) states.set(r.t, r.s[key]);
  const forecasts = new Map();
  for (const f of readJsonl(join(root, "runs", `${profile}-a1`, "predictions-final.jsonl"))) {
    const k = `${f.t}`;
    if (!forecasts.has(k)) forecasts.set(k, {});
    const m = forecasts.get(k);
    m[f.modelId] = m[f.modelId] ?? [null, null];
    m[f.modelId][f.symbol === "SPY" ? 0 : 1] = f.prediction;
  }
  const outcomes = new Map();
  const exclusion = new Map();
  for (const o of readJsonl(join(root, "runs", EXP, "outcomes-final.jsonl"))) {
    const [run, model, symbol, t] = o.forecastId.split(":");
    if (run !== `${profile}-a1` || model !== "ZERO") continue;
    if (!o.eligible) {
      exclusion.set(t, o.exclusionReason);
      continue;
    }
    if (!outcomes.has(t)) outcomes.set(t, [null, null]);
    outcomes.get(t)[symbol === "SPY" ? 0 : 1] = o.actual;
  }
  const projection = readJson(join(root, "runs", EXP, `projection-D${profile === "R50" ? 50 : 14}.json`)).matrix;
  return {
    profileId: profile,
    preset,
    drive: lock.drive,
    dateNY: ny(rows[0].t).date,
    label: label ?? "preregistered demonstration day",
    projection,
    rows: rows.map((r) => {
      const st = states.get(r.t);
      if (!st) throw new Error(`no final state for t=${r.t}`);
      const out = outcomes.get(`${r.t}`);
      return {
        t: r.t,
        decisionTime: r.t + 3600,
        outcomeTime: r.t + 3600 + 8 * 3600,
        hourNY: ny(r.t).hour,
        x: r.x,
        state: st,
        forecasts: forecasts.get(`${r.t}`) ?? null,
        actual: out && out[0] != null && out[1] != null ? out : null,
        scored: !!(out && out[0] != null && out[1] != null),
        exclusionReason: exclusion.get(`${r.t}`) ?? null,
      };
    }),
  };
}
