// Local-only transport between Roblox Studio and this project (plan Task 5 "Concrete export path").
// Binds 127.0.0.1. Studio code reaches it with HttpService; nothing here talks to any other host.
//
//   GET  /health
//   GET  /tree                          lab source tree (allowlisted folders) for the dev mirror in Studio
//   GET  /inputs/<runId>/<stream>?from=i&count=n     rows of a prepared physics input stream
//   GET  /artifact/<runId>/<name>       a small JSON artifact from runs/<runId>/ (allowlisted names)
//   POST /states/<runId>/<stream>       one page {page, fromIndex, rows:[...]} -> runs/<runId>/state-cache/
//   POST /artifact/<runId>/<name>       store a JSON artifact produced in Studio (e.g. projection matrices)
//
// Every stored page is written beside then renamed, hashed (sha256 of exact bytes) and acknowledged with
// {sha256, bytes, rows}. Existing pages are immutable: a re-post must be byte-identical or is rejected.
import { createServer } from "node:http";
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, readdirSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const ID = /^[A-Za-z0-9_-]{1,64}$/;
const TREE_DIRS = ["lab/src", "lab/generated", "lab/tests", "lab/fixtures"];
// CLI-only generated files (data loaders, audits, fixtures) are not mirrored into Studio; Studio also
// rejects any script Source of 200,000 characters or more.
const TREE_EXCLUDE = new Set(["lab/generated/Sources.luau", "lab/generated/NodeStructureAudit.luau"]);
const MAX_STUDIO_SOURCE = 199999;
const ARTIFACT_NAMES = /^[A-Za-z0-9_.-]{1,80}\.json$/;

export function listTree(base = root) {
  const files = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      if (name.startsWith(".")) continue;
      const full = join(dir, name);
      const st = statSync(full);
      if (st.isDirectory()) walk(full);
      else if (name.endsWith(".luau")) {
        const rel = relative(base, full).split(sep).join("/");
        if (!TREE_EXCLUDE.has(rel) && st.size <= MAX_STUDIO_SOURCE) files.push(rel);
      }
    }
  };
  for (const d of TREE_DIRS) if (existsSync(join(base, d))) walk(join(base, d));
  return files.map((rel) => {
    const source = readFileSync(join(base, rel), "utf8");
    const isScript = rel.endsWith(".server.luau");
    const path = rel.replace(/^lab\//, "").replace(/\.server\.luau$|\.luau$/, "");
    return { path, className: isScript ? "Script" : "ModuleScript", source, sha256: sha(source) };
  });
}

export function sha(text) {
  return createHash("sha256").update(text).digest("hex");
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req, limit = 64 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) reject(new Error("body too large"));
      else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function writeImmutable(file, bytes) {
  if (existsSync(file)) {
    const prev = readFileSync(file);
    if (Buffer.compare(prev, bytes) !== 0) throw new Error(`immutable page differs: ${relative(root, file)}`);
    return false;
  }
  mkdirSync(dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  writeFileSync(tmp, bytes);
  renameSync(tmp, file);
  return true;
}

export const EXPERIMENT = "exp-20261005";
const TEST_START = 1735707600; // 2025-01-01T05:00:00Z (lab/config/default.json splits.testStart)

// Studio may read only streams that a job definition declares, byte-identical to the hashed definition, and
// final-period rows only for a final job after every included profile is locked (plan release order).
const inputCache = new Map();
function loadJobStream(runId, stream, base = root, experiment = EXPERIMENT) {
  if (runId !== experiment) throw new Error("unknown experiment");
  const m = /^([A-Za-z0-9_]+)-([A-Za-z0-9_]+)$/.exec(stream);
  if (!m) throw new Error("not a job stream");
  const jobFile = join(base, "runs", runId, `${m[1]}-job.json`);
  if (!existsSync(jobFile)) throw new Error(`no job definition for ${stream}`);
  const job = JSON.parse(readFileSync(jobFile, "utf8"));
  if (!job.streams.includes(stream)) throw new Error(`job ${job.jobId} does not declare ${stream}`);
  const file = join(base, "runs", runId, "inputs", `${stream}.json`);
  const bytes = readFileSync(file);
  const key = `${stream}:${sha(bytes)}`;
  if (sha(bytes) !== job.streamHashes[stream]) throw new Error(`${stream} differs from its job definition`);
  if (!inputCache.has(key)) {
    const data = JSON.parse(bytes.toString("utf8"));
    const hasFinal = data.rows.some((r) => r.t + 3600 >= TEST_START);
    if (hasFinal) {
      if (job.final !== true) throw new Error(`${stream}: final-period rows in a non-final job`);
      const protocol = JSON.parse(readFileSync(join(base, "runs", runId, "protocol.json"), "utf8"));
      for (const p of protocol.profiles.included) {
        if (!existsSync(join(base, "runs", `${p}-a1`, "model-lock.json"))) throw new Error(`final rows are sealed: ${p} is not locked`);
      }
    }
    inputCache.set(key, data);
  }
  return inputCache.get(key);
}

// Studio may store only pump status artifacts and projection matrices in the experiment directory.
const STUDIO_ARTIFACTS = /^(projection-D\d+|[A-Za-z0-9_]+-(reservoirs|resume-\d+|pump-final-\d+))\.json$/;

export function makeServer({ base = root, experiment = EXPERIMENT } = {}) {
  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://127.0.0.1");
      const parts = url.pathname.split("/").filter(Boolean);
      if (req.method === "GET" && url.pathname === "/health") return send(res, 200, { ok: true, root });
      if (req.method === "GET" && url.pathname === "/tree") return send(res, 200, { files: listTree() });
      if (req.method === "GET" && url.pathname === "/devtools") {
        return send(res, 200, { source: readFileSync(join(root, "lab/snippets/DevTools.luau"), "utf8") });
      }
      if (parts[0] === "inputs" && req.method === "GET") {
        const [, runId, stream] = parts;
        if (!ID.test(runId) || !ID.test(stream)) return send(res, 400, { error: "bad id" });
        const data = loadJobStream(runId, stream, base, experiment);
        const from = Math.max(1, Number(url.searchParams.get("from") ?? 1));
        const count = Math.min(5000, Math.max(1, Number(url.searchParams.get("count") ?? 500)));
        const rows = data.rows.slice(from - 1, from - 1 + count);
        return send(res, 200, { runId, stream, total: data.rows.length, from, header: data.header, rows });
      }
      if (req.method === "GET" && url.pathname === "/replay") {
        const { buildReplay } = await import("./replay-data.mjs");
        const profile = url.searchParams.get("profile") ?? "R50";
        if (!["O14", "R50", "H14"].includes(profile)) return send(res, 400, { error: "bad profile" });
        return send(res, 200, buildReplay({ profile, segment: url.searchParams.get("segment"), date: url.searchParams.get("date"), label: url.searchParams.get("label") ?? undefined }));
      }
      if (parts[0] === "progress" && req.method === "GET") {
        const [, runId, stream] = parts;
        if (!ID.test(runId) || !ID.test(stream)) return send(res, 400, { error: "bad id" });
        const dir = join(base, "runs", runId, "state-cache", stream);
        if (!existsSync(dir)) return send(res, 200, { pages: 0, rows: 0 });
        const names = readdirSync(dir).filter((n) => /^page-\d{6}\.json$/.test(n)).sort();
        let rows = 0;
        names.forEach((n, k) => {
          const p = JSON.parse(readFileSync(join(dir, n), "utf8"));
          if (p.page !== k + 1 || p.fromIndex !== rows + 1) throw new Error(`state pages of ${stream} are not contiguous at ${n}`);
          rows += p.rows.length;
        });
        return send(res, 200, { pages: names.length, rows });
      }
      if (parts[0] === "states-batch" && req.method === "POST") {
        // One batch = the same page number for every stream of one job; all pages are validated, written
        // beside, then renamed together, so streams can never end up with different saved progress.
        const [, runId] = parts;
        if (runId !== experiment) return send(res, 400, { error: "bad id" });
        const bytes = await readBody(req);
        const batch = JSON.parse(bytes.toString("utf8"));
        if (!Array.isArray(batch.pages) || batch.pages.length === 0) return send(res, 400, { error: "pages missing" });
        const plans = [];
        for (const page of batch.pages) {
          if (!ID.test(page.stream ?? "") || !Number.isInteger(page.page) || page.page < 1 || !Array.isArray(page.rows)) {
            return send(res, 400, { error: "bad page" });
          }
          loadJobStream(runId, page.stream, base, experiment); // the stream must belong to a declared, unchanged job
          if (page.page !== batch.pages[0].page) return send(res, 400, { error: "pages of one batch must share a page number" });
          const pageBytes = Buffer.from(JSON.stringify(page), "utf8");
          const file = join(base, "runs", runId, "state-cache", page.stream, `page-${String(page.page).padStart(6, "0")}.json`);
          if (existsSync(file)) {
            // A retried batch is accepted only if its rows are identical to what is stored.
            const prev = JSON.parse(readFileSync(file, "utf8"));
            if (JSON.stringify(prev.rows) !== JSON.stringify(page.rows)) throw new Error(`immutable page differs: ${relative(root, file)}`);
            plans.push({ file, bytes: null, rows: page.rows.length, sha256: sha(readFileSync(file)) });
          } else {
            plans.push({ file, bytes: pageBytes, rows: page.rows.length, sha256: sha(pageBytes) });
          }
        }
        for (const p of plans) {
          if (p.bytes) {
            mkdirSync(dirname(p.file), { recursive: true });
            writeFileSync(p.file + ".tmp", p.bytes);
          }
        }
        for (const p of plans) if (p.bytes) renameSync(p.file + ".tmp", p.file);
        return send(res, 200, { ok: true, pages: plans.map((p) => ({ file: relative(base, p.file), rows: p.rows, sha256: p.sha256, created: !!p.bytes })) });
      }
      if (parts[0] === "states" && req.method === "POST") {
        const [, runId, stream] = parts;
        if (!ID.test(runId) || !ID.test(stream)) return send(res, 400, { error: "bad id" });
        const bytes = await readBody(req);
        const page = JSON.parse(bytes.toString("utf8"));
        if (!Number.isInteger(page.page) || page.page < 1) return send(res, 400, { error: "bad page number" });
        if (!Array.isArray(page.rows)) return send(res, 400, { error: "rows missing" });
        loadJobStream(runId, stream, base, experiment); // legacy single-stream post: declared job streams only
        const file = join(base, "runs", runId, "state-cache", stream, `page-${String(page.page).padStart(6, "0")}.json`);
        const created = writeImmutable(file, bytes);
        return send(res, 200, { ok: true, created, sha256: sha(bytes), bytes: bytes.length, rows: page.rows.length });
      }
      if (parts[0] === "artifact") {
        const [, runId, name] = parts;
        if (!ID.test(runId) || !ARTIFACT_NAMES.test(name)) return send(res, 400, { error: "bad artifact id" });
        const file = join(base, "runs", runId, name);
        if (req.method === "GET") {
          if (!existsSync(file)) return send(res, 404, { error: "missing" });
          return send(res, 200, JSON.parse(readFileSync(file, "utf8")));
        }
        if (req.method === "POST") {
          if (runId !== experiment || !STUDIO_ARTIFACTS.test(name)) return send(res, 403, { error: "Studio may not write this artifact" });
          const bytes = await readBody(req);
          JSON.parse(bytes.toString("utf8"));
          const created = writeImmutable(file, bytes);
          return send(res, 200, { ok: true, created, sha256: sha(bytes), bytes: bytes.length });
        }
      }
      return send(res, 404, { error: "not found" });
    } catch (err) {
      return send(res, 500, { error: String(err && err.message ? err.message : err) });
    }
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const port = Number(process.env.MRL_BRIDGE_PORT ?? 47621);
  makeServer().listen(port, "127.0.0.1", () => console.log(`bridge listening on 127.0.0.1:${port}`));
}
