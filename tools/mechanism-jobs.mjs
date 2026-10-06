// Builds the plan's mechanism-check jobs (Task 3, section 6 "Freeze mechanism checks"), inputs only:
//   R1, R2, R3  : the same fixed 200-observation training window, each processed twice in one job (soft resets),
//                 three separate jobs (three clean builds); O14/R50/H14 x P1-P3 at the calibrated drive.
//   SP          : superposition on O14 inputs: u, 2u, v, u+v through identical resets (pseudo-profiles sharing the
//                 D14 projection), P1-P3 at the calibrated drive.
// Usage: node tools/mechanism-jobs.mjs
import { readFileSync, writeFileSync, mkdirSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { sha256Hex } from "./canonical-json.mjs";
import { EXP } from "./run-lab.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const expDir = join(root, "runs", EXP);
const readJson = (f) => JSON.parse(readFileSync(f, "utf8"));
const calibration = readJson(join(expDir, "calibration.json"));

function writeJson(file, value) {
  mkdirSync(dirname(file), { recursive: true });
  const text = JSON.stringify(value);
  writeFileSync(file + ".tmp", text, "utf8");
  renameSync(file + ".tmp", file);
  return sha256Hex(Buffer.from(text, "utf8"));
}

// Whole segments of a profile's rows starting at the first segment start with decision >= fromIso, ~n rows.
function window(rows, fromIso, n) {
  const from = Date.parse(fromIso) / 1000;
  let start = rows.findIndex((r) => r.t + 3600 >= from && r.off === 1);
  let end = start + n;
  while (end < rows.length && rows[end].off !== 1) end++;
  const w = rows.slice(start, end);
  if (w.some((r) => r.split !== "train")) throw new Error("mechanism window must be training-only");
  return w;
}

function renumber(rows, repeat) {
  const out = [];
  let seg = 0;
  for (let k = 0; k < repeat; k++) {
    for (const r of rows) {
      if (r.off === 1) seg++;
      out.push({ i: out.length + 1, t: r.t, seg, off: r.off, gi: r.i, x: r.x });
    }
  }
  return out;
}

function writeJob(jobId, streams, reservoirs, projectionArtifacts, lanes, meta) {
  const streamProfiles = {};
  const hashes = {};
  for (const [name, { profile, rows }] of Object.entries(streams)) {
    streamProfiles[name] = profile;
    hashes[name] = writeJson(join(expDir, "inputs", `${name}.json`), { header: { jobId, profileId: profile, count: rows.length, ...meta }, rows });
  }
  const first = Object.values(streams)[0].rows;
  const job = {
    experimentId: EXP, runId: EXP, jobId, streams: Object.keys(streamProfiles), streamProfiles, reservoirs, projectionArtifacts,
    pageRows: 400, lanes, rows: first.length, segments: first.at(-1).seg, mechanism: meta, final: false, streamHashes: hashes,
  };
  writeJson(join(expDir, `${jobId}-job.json`), job);
  console.log(JSON.stringify({ jobId, rows: job.rows, segments: job.segments, reservoirs: reservoirs.length }));
}

const presets = ["P1", "P2", "P3"];
const data = {};
for (const p of ["O14", "R50", "H14"]) data[p] = readJson(join(expDir, "inputs", `${p}.json`)).rows;

// Repeatability: window of ~200 training observations from 2022-06-01, identical timestamps for all profiles.
const winO = window(data.O14, "2022-06-01T00:00:00Z", 200);
const tset = new Set(winO.map((r) => r.t));
const winFor = (p) => {
  const w = data[p].filter((r) => tset.has(r.t));
  if (w.length !== winO.length || w.some((r, k) => r.t !== winO[k].t || r.off !== winO[k].off)) throw new Error(`window not aligned for ${p}`);
  return w;
};
const repReservoirs = [];
for (const p of ["O14", "R50", "H14"]) for (const pre of presets) repReservoirs.push({ key: `${p}:${pre}`, profileId: p, presetId: pre, drive: calibration.chosen[p] });
for (const jobId of ["R1", "R2", "R3"]) {
  const streams = {};
  for (const p of ["O14", "R50", "H14"]) streams[`${jobId}-${p}`] = { profile: p, rows: renumber(winFor(p), 2) };
  writeJob(jobId, streams, repReservoirs, { O14: "projection-D14.json", R50: "projection-D50.json", H14: "projection-D14.json" }, 1,
    { purpose: "repeatability", windowFrom: "2022-06-01", observations: winO.length, repeatsInJob: 2 });
}

// Superposition on O14: u from 2022-06-01, v from 2023-03-01 mapped onto u's segment structure.
const u = window(data.O14, "2022-06-01T00:00:00Z", 150);
const vSrc = window(data.O14, "2023-03-01T00:00:00Z", u.length + 40).slice(0, u.length);
if (vSrc.length !== u.length) throw new Error("v window too short");
const mk = (fn) => renumber(u.map((r, k) => ({ ...r, x: fn(r.x, vSrc[k].x) })), 1);
const spStreams = {
  "SP-u": { profile: "U", rows: mk((a) => a) },
  "SP-2u": { profile: "U2", rows: mk((a) => a.map((x) => 2 * x)) },
  "SP-v": { profile: "V", rows: mk((_, b) => b) },
  "SP-uv": { profile: "UV", rows: mk((a, b) => a.map((x, j) => x + b[j])) },
};
const spReservoirs = [];
for (const pp of ["U", "U2", "V", "UV"]) for (const pre of presets) spReservoirs.push({ key: `${pp}:${pre}`, profileId: pp, presetId: pre, drive: calibration.chosen.O14 });
writeJob("SP", spStreams, spReservoirs, { U: "projection-D14.json", U2: "projection-D14.json", V: "projection-D14.json", UV: "projection-D14.json" }, 1,
  { purpose: "superposition", uFrom: "2022-06-01", vFrom: "2023-03-01", observations: u.length });
