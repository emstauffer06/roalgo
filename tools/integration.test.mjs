// Tests for the integration tools: bridge transport, state-page validation, run-lab guards.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { makeServer, listTree } from "./bridge-server.mjs";
import { loadStatePages, writeStateChunks } from "./states-to-luau.mjs";
import { summarise, choose } from "./analyze-calibration.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const state = (v) => Array.from({ length: 48 }, (_, k) => v + k / 1000);
const page = (n, from, rows, keys = ["O14:P1"]) => ({ page: n, fromIndex: from, keys, rows });
const row = (i, t, off) => ({ i, t, seg: 1, off, s: { "O14:P1": state(i) } });

test("loadStatePages accepts contiguous pages and rejects gaps, key changes and bad widths", () => {
  const dir = mkdtempSync(join(tmpdir(), "mrl-pages-"));
  try {
    writeFileSync(join(dir, "page-000001.json"), JSON.stringify(page(1, 1, [row(1, 100, 1), row(2, 3700, 2)])));
    writeFileSync(join(dir, "page-000002.json"), JSON.stringify(page(2, 3, [row(3, 7300, 3)])));
    const ok = loadStatePages(dir);
    assert.equal(ok.rows.length, 3);
    assert.equal(ok.pageHashes.length, 2);
    writeFileSync(join(dir, "page-000002.json"), JSON.stringify(page(2, 3, [row(4, 7300, 3)])));
    assert.throws(() => loadStatePages(dir), /row index 4, expected 3/);
    writeFileSync(join(dir, "page-000002.json"), JSON.stringify(page(2, 3, [row(3, 7300, 3)], ["O14:P2"])));
    assert.throws(() => loadStatePages(dir), /keys changed/);
    const bad = row(3, 7300, 3);
    bad.s["O14:P1"] = state(3).slice(0, 47);
    writeFileSync(join(dir, "page-000002.json"), JSON.stringify(page(2, 3, [bad])));
    assert.throws(() => loadStatePages(dir), /bad state/);
    const nonFinite = row(3, 7300, 3);
    nonFinite.s["O14:P1"][5] = null;
    writeFileSync(join(dir, "page-000002.json"), JSON.stringify(page(2, 3, [nonFinite])));
    assert.throws(() => loadStatePages(dir), /bad state/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("writeStateChunks emits Luau that the CLI reads back exactly", () => {
  const dir = mkdtempSync(join(tmpdir(), "mrl-chunks-"));
  try {
    const rows = [row(1, 100, 1), row(2, 3700, 2)];
    rows[0].s["O14:P1"][0] = 0.1 + 0.2;
    rows[1].s["O14:P1"][1] = -0;
    writeStateChunks(dir, { rows, keys: ["O14:P1"], pageHashes: ["a".repeat(64)] });
    const probe = join(dir, "probe.luau");
    writeFileSync(probe, 'local c = require("./Chunk001"); local i = require("./index"); print(string.format("%.17g|%s|%d|%d", c[1][5][1], tostring(1/c[2][5][2]), #c, i.count))');
    const r = spawnSync((process.env.LUAU_EXE || "luau"), [probe], { encoding: "utf8" });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), "0.30000000000000004|-inf|2|2");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("bridge: atomic immutable batches, declared streams only, Studio cannot write locks", async () => {
  const base = mkdtempSync(join(tmpdir(), "mrl-bridge-"));
  const exp = "exp-t";
  const expDir = join(base, "runs", exp);
  mkdirSync(join(expDir, "inputs"), { recursive: true });
  const { createHash } = await import("node:crypto");
  const shaOf = (t) => createHash("sha256").update(t).digest("hex");
  const streamText = (name, rows) => JSON.stringify({ header: { jobId: "J1" }, rows });
  const rowsA = [{ i: 1, t: 1704100000, seg: 1, off: 1, x: [0.1] }, { i: 2, t: 1704103600, seg: 1, off: 2, x: [0.2] }];
  const textA = streamText("J1-O14", rowsA), textB = streamText("J1-R50", rowsA);
  writeFileSync(join(expDir, "inputs", "J1-O14.json"), textA);
  writeFileSync(join(expDir, "inputs", "J1-R50.json"), textB);
  writeFileSync(join(expDir, "J1-job.json"), JSON.stringify({ jobId: "J1", streams: ["J1-O14", "J1-R50"], streamHashes: { "J1-O14": shaOf(textA), "J1-R50": shaOf(textB) }, final: false }));
  writeFileSync(join(expDir, "protocol.json"), JSON.stringify({ profiles: { included: ["O14", "R50"] } }));
  const server = makeServer({ base, experiment: exp });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${server.address().port}`;
  const postBatch = (pages) => fetch(`${url}/states-batch/${exp}`, { method: "POST", body: JSON.stringify({ pages }) }).then(async (r) => ({ status: r.status, body: await r.json() }));
  const pg = (stream, n, rows) => ({ stream, page: n, fromIndex: 1, keys: ["O14:P1"], rows, diag: { seconds: Math.random() } });
  try {
    const inp = await fetch(`${url}/inputs/${exp}/J1-O14?from=1&count=10`).then((r) => r.json());
    assert.equal(inp.rows.length, 2);
    assert.equal((await fetch(`${url}/inputs/${exp}/O14?from=1`)).status, 500, "whole profile files are never served");
    const a = await postBatch([pg("J1-O14", 1, [row(1, 100, 1)]), pg("J1-R50", 1, [row(1, 100, 1)])]);
    assert.equal(a.status, 200);
    assert.ok(a.body.pages.every((p) => p.created && /^[0-9a-f]{64}$/.test(p.sha256)));
    const retry = await postBatch([pg("J1-O14", 1, [row(1, 100, 1)]), pg("J1-R50", 1, [row(1, 100, 1)])]);
    assert.equal(retry.status, 200, "a retried batch with identical rows (different timings) is accepted");
    assert.ok(retry.body.pages.every((p) => !p.created));
    const changed = await postBatch([pg("J1-O14", 1, [row(1, 101, 1)]), pg("J1-R50", 1, [row(1, 100, 1)])]);
    assert.equal(changed.status, 500, "a different page with the same number is rejected");
    const half = await postBatch([pg("J1-O14", 2, [row(2, 3700, 2)]), pg("NOPE-O14", 2, [row(2, 3700, 2)])]);
    assert.notEqual(half.status, 200);
    assert.ok(!existsSync(join(expDir, "state-cache", "J1-O14", "page-000002.json")), "a rejected batch writes no stream");
    const prog = await fetch(`${url}/progress/${exp}/J1-O14`).then((r) => r.json());
    assert.deepEqual(prog, { pages: 1, rows: 1 });
    const forged = await fetch(`${url}/artifact/${exp}/model-lock.json`, { method: "POST", body: "{}" });
    assert.equal(forged.status, 403);
    const ok = await fetch(`${url}/artifact/${exp}/J1-pump-final-1.json`, { method: "POST", body: "{}" });
    assert.equal(ok.status, 200);
  } finally {
    server.close();
    rmSync(base, { recursive: true, force: true });
  }
});

test("bridge tree excludes CLI-only generated files and anything too large for a Studio Source", () => {
  const files = listTree();
  const paths = files.map((f) => f.path);
  assert.ok(paths.includes("src/Main.server") === false && paths.includes("src/Main"), "Main mirrored as Script named Main");
  assert.ok(!paths.some((p) => p.startsWith("generated/Sources")));
  assert.ok(files.every((f) => Buffer.byteLength(f.source) < 200000));
});

test("calibration chooses the largest drive that passes for all presets", () => {
  const s = (sat) => ({ saturatedFraction: sat });
  const summary = {
    "O14:P1:d0.15": s(0), "O14:P2:d0.15": s(0), "O14:P3:d0.15": s(0),
    "O14:P1:d0.3": s(0), "O14:P2:d0.3": s(0.0005), "O14:P3:d0.3": s(0),
    "O14:P1:d0.6": s(0), "O14:P2:d0.6": s(0.002), "O14:P3:d0.6": s(0),
  };
  assert.deepEqual(choose(summary, ["O14"], ["P1", "P2", "P3"], [0.15, 0.3, 0.6]), { O14: 0.3 });
  summary["O14:P1:d0.15"] = s(0.5);
  summary["O14:P1:d0.3"] = s(0.5);
  assert.deepEqual(choose(summary, ["O14"], ["P1", "P2", "P3"], [0.15, 0.3, 0.6]), { O14: null });
  const rows = [{ s: { k: [1, ...Array(23).fill(0), 0, ...Array(23).fill(0.1)] } }];
  const sum = summarise(rows, ["k"]);
  assert.equal(sum.k.saturatedFraction, 1 / 24, "x/3 = 1 means x = 3 studs >= 2.9");
  assert.equal(sum.k.zeroVelocityFraction, 1 / 24);
});

test("run-lab refuses a development window that reaches the final period and a final window without locks", () => {
  const node = process.execPath;
  const dev = spawnSync(node, ["tools/run-lab.mjs", "streams", "Xbad", "--profiles", "O14", "--from", "2024-12-01T00:00:00Z", "--to", "2025-02-01T00:00:00Z", "--presets", "P1", "--drives", "O14=0.6"], { cwd: root, encoding: "utf8" });
  assert.notEqual(dev.status, 0);
  assert.match(dev.stderr, /may not reach the final period/);
  const fin = spawnSync(node, ["tools/run-lab.mjs", "streams", "Xbad", "--profiles", "O14", "--from", "2025-01-01T05:00:00Z", "--to", "2026-10-03T04:00:00Z", "--presets", "P1", "--drives", "O14=0.6", "--final"], { cwd: root, encoding: "utf8" });
  if (!existsSync(join(root, "runs", "O14-a1", "model-lock.json"))) {
    assert.notEqual(fin.status, 0);
    assert.match(fin.stderr, /sealed/);
  }
  const noFlag = spawnSync(node, ["tools/run-lab.mjs", "streams", "Xbad", "--profiles", "O14", "--from", "2025-01-01T05:00:00Z", "--to", "2026-10-03T04:00:00Z", "--presets", "P1", "--drives", "O14=0.6"], { cwd: root, encoding: "utf8" });
  assert.notEqual(noFlag.status, 0);
  assert.match(noFlag.stderr, /requires --final/);
  assert.ok(!existsSync(join(root, "runs", "exp-20261005", "Xbad-job.json")));
});

// ---------------------------------------------------------------------------------------------------------------
// Review 2026-10-05: defects confirmed in a sandbox copy of the tools (they resolve root from their own location,
// so nothing here reads or writes the real runs/). Marked todo until the tools are fixed; each passes once fixed.
// ---------------------------------------------------------------------------------------------------------------
const SANDBOX_TOOLS = ["run-lab", "luau-literal", "luau-run", "canonical-json", "states-to-luau", "bridge-server"];
const DAY_SPLITS = [["2023-06-01", "train"], ["2023-06-02", "train"], ["2024-03-01", "validation"], ["2024-03-04", "validation"], ["2025-02-03", "final"], ["2025-02-04", "final"]];

async function makeSandbox() {
  const sb = mkdtempSync(join(tmpdir(), "mrl-sandbox-"));
  mkdirSync(join(sb, "tools"));
  mkdirSync(join(sb, "lab", "config"), { recursive: true });
  for (const t of SANDBOX_TOOLS) writeFileSync(join(sb, "tools", `${t}.mjs`), readFileSync(join(root, "tools", `${t}.mjs`)));
  writeFileSync(join(sb, "lab", "config", "default.json"), readFileSync(join(root, "lab", "config", "default.json")));
  const { canonicalSha256 } = await import(pathToFileURL(join(sb, "tools", "canonical-json.mjs")).href);
  const writeProfile = (p, scale = 1) => {
    const rows = [];
    DAY_SPLITS.forEach(([d, split], k) => {
      for (let h = 0; h < 8; h++) {
        rows.push({ i: rows.length + 1, t: Date.parse(`${d}T13:00:00Z`) / 1000 + h * 3600, seg: k + 1, off: h + 1, split, x: [scale * 0.1 * h, -0.2] });
      }
    });
    const header = { profileId: p, dimension: 2, count: rows.length, inputsSha256: canonicalSha256(rows) };
    mkdirSync(join(sb, "runs", "exp-20261005", "inputs"), { recursive: true });
    writeFileSync(join(sb, "runs", "exp-20261005", "inputs", `${p}.json`), JSON.stringify({ header, rows }));
  };
  for (const p of ["O14", "R50", "H14"]) writeProfile(p);
  writeFileSync(join(sb, "runs", "exp-20261005", "protocol.json"), JSON.stringify({ sha256: "p", profiles: { included: ["O14", "R50", "H14"] } }));
  const lab = (...args) => spawnSync(process.execPath, [join(sb, "tools", "run-lab.mjs"), ...args], { cwd: sb, encoding: "utf8" });
  const calibrate = () => writeFileSync(join(sb, "runs", "exp-20261005", "calibration.json"), JSON.stringify({ sha256: "c", chosen: { O14: 0.6, R50: 0.6, H14: 0.6 } }));
  const lockProfile = (p) => {
    mkdirSync(join(sb, "runs", `${p}-a1`), { recursive: true });
    writeFileSync(join(sb, "runs", `${p}-a1`, "model-lock.json"), JSON.stringify({ profileId: p, preset: "P2", drive: 0.6, hashes: { model: "m" } }));
  };
  // Fake Studio state pages for one job stream, in the bridge page format.
  const fakePages = (jobId, p, fill) => {
    const job = JSON.parse(readFileSync(join(sb, "runs", "exp-20261005", `${jobId}-job.json`), "utf8"));
    const inp = JSON.parse(readFileSync(join(sb, "runs", "exp-20261005", "inputs", `${jobId}-${p}.json`), "utf8"));
    const keys = job.reservoirs.filter((r) => r.profileId === p).map((r) => r.key);
    const rows = inp.rows.map((r) => ({ i: r.i, t: r.t, seg: r.seg, off: r.off, s: Object.fromEntries(keys.map((k) => [k, Array(48).fill(fill)])) }));
    const dir = join(sb, "runs", "exp-20261005", "state-cache", `${jobId}-${p}`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "page-000001.json"), JSON.stringify({ page: 1, fromIndex: 1, keys, rows }));
  };
  return { sb, lab, lockProfile, fakePages, writeProfile, calibrate, cleanup: () => rmSync(sb, { recursive: true, force: true }) };
}

test("a final-period job needs every included lock and is pinned to the locked preset and drive", async () => {
  const s = await makeSandbox();
  try {
    s.lockProfile("O14"); // R50 and H14 are still unlocked
    const partial = s.lab("streams", "F1", "--profiles", "O14", "--from", "2025-01-01T05:00:00Z", "--to", "2026-10-03T04:00:00Z", "--final");
    assert.notEqual(partial.status, 0, "final physics must stay sealed until every included profile is locked");
    assert.match(partial.stderr, /no model lock for R50/);
    s.lockProfile("R50");
    s.lockProfile("H14");
    const wrong = s.lab("streams", "F2", "--profiles", "O14", "--from", "2025-01-01T05:00:00Z", "--to", "2026-10-03T04:00:00Z", "--drives", "O14=0.15", "--final");
    assert.notEqual(wrong.status, 0, "a final job may not take a drive from the command line");
    const right = s.lab("streams", "F3", "--profiles", "O14,R50", "--from", "2025-01-01T05:00:00Z", "--to", "2026-10-03T04:00:00Z", "--final");
    assert.equal(right.status, 0, right.stderr);
    const job = JSON.parse(readFileSync(join(s.sb, "runs", "exp-20261005", "F3-job.json"), "utf8"));
    assert.deepEqual(job.reservoirs.map((r) => [r.key, r.drive]), [["O14:P2", 0.6], ["R50:P2", 0.6]], "only the locked preset at the locked drive");
  } finally {
    s.cleanup();
  }
});

test("assemble refuses jobs run at different drives or built from stale inputs", async () => {
  const s = await makeSandbox();
  try {
    assert.equal(s.lab("streams", "A", "--profiles", "O14", "--from", "2023-01-01T00:00:00Z", "--to", "2024-01-01T05:00:00Z", "--drives", "O14=0.6").status, 0);
    assert.equal(s.lab("streams", "B", "--profiles", "O14", "--from", "2024-01-01T05:00:00Z", "--to", "2025-01-01T05:00:00Z", "--drives", "O14=0.15").status, 0);
    s.calibrate(); // calibration chose 0.6 for every profile
    assert.notEqual(s.lab("streams", "B2", "--profiles", "O14", "--from", "2024-01-01T05:00:00Z", "--to", "2025-01-01T05:00:00Z", "--drives", "O14=0.15").status, 0, "dev jobs must use the calibrated drive");
    s.fakePages("A", "O14", 0.6);
    s.fakePages("B", "O14", 0.15);
    const mixed = s.lab("assemble", "O14", "dev", "A,B");
    assert.notEqual(mixed.status, 0, "training states at drive 0.6 and validation states at 0.15 must not form one dev cache");
    assert.match(mixed.stderr, /expected presets/);
    assert.equal(s.lab("streams", "C", "--profiles", "O14", "--from", "2023-01-01T00:00:00Z", "--to", "2025-01-01T05:00:00Z", "--drives", "O14=0.6").status, 0);
    s.fakePages("C", "O14", 0.6);
    assert.equal(s.lab("assemble", "O14", "dev", "C").status, 0, "a consistent job assembles");
    s.writeProfile("O14", 7); // profile inputs re-prepared after the job's states were computed
    const stale = s.lab("assemble", "O14", "dev", "C");
    assert.notEqual(stale.status, 0, "states computed from superseded inputs must not be assembled");
    assert.match(stale.stderr, /driven by inputs/);
  } finally {
    s.cleanup();
  }
});

test("the bridge does not serve final-period inputs or accept lock files", async () => {
  const s = await makeSandbox();
  const { makeServer: makeSandboxServer } = await import(pathToFileURL(join(s.sb, "tools", "bridge-server.mjs")).href);
  const server = makeSandboxServer();
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const testStart = JSON.parse(readFileSync(join(root, "lab", "config", "default.json"), "utf8")).splits.testStart;
    const res = await fetch(`${base}/inputs/exp-20261005/O14?from=1&count=5000`);
    const body = await res.json();
    const finalRows = res.ok ? body.rows.filter((r) => r.t + 3600 >= testStart).length : 0;
    assert.equal(finalRows, 0, "final-period inputs reached Studio without any model lock");
    const forged = await fetch(`${base}/artifact/R50-a1/model-lock.json`, { method: "POST", body: "{}" });
    assert.notEqual(forged.status, 200, "Studio must not be able to create the lock file that opens the final gate");
    assert.ok(!existsSync(join(s.sb, "runs", "R50-a1", "model-lock.json")));
  } finally {
    server.close();
    s.cleanup();
  }
});
