// Spring live forward test, W1 server (spring-live-contract.md: L9, L10; module contract W1).
// Loopback-only (127.0.0.1, default port 47627 per contract L9: 47625 has been taken since 2026-10-05 11:56 by another
// project's bridge, which is not ours). Read-only over data, apart from write-once chunk posts under
// <resultsRoot>/<runId>/<name>.json. The running v3 bridge (47624) and v2 bridge are left alone. The controller
// (src/SpringLive.luau BASE_URL) defaults to the same port; tests/spring-live-data.test.mjs checks the two agree.
// It listens only when run directly: node spring-live-server.mjs [--port N] [--results-root DIR] [--lazy]
import http from 'node:http';
import {readFileSync, existsSync, mkdirSync, openSync, writeSync, fsyncSync, closeSync} from 'node:fs';
import {join, resolve, relative, isAbsolute, sep} from 'node:path';
import {pathToFileURL} from 'node:url';
import * as liveData from './spring-live-data.mjs';

export const DEFAULT_PORT = 47627;
export const HOST = '127.0.0.1';
export const APP = 'RoAlgo Spring Live';
export const SERVER_SCHEMA = 'roalgo-spring-live-server-1';
export const DEFAULT_RESULTS_ROOT = join(liveData.ROOT, 'results', 'spring-live');
export const MAX_BODY_BYTES = 48 * 1024 * 1024;
export const NAME_RE = /^[A-Za-z0-9_-]{1,100}$/;
export const RESERVED_RE = /^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$/i;
const SHA_RE = /^[a-f0-9]{64}$/;
const INT_RE = /^[1-9][0-9]{0,8}$/;
const POST_KEYS = ['name', 'payload', 'runId'];

const httpError = (status, message) => Object.assign(new Error(message), {status});

function send(res, status, data, headers = {}) {
  const body = typeof data === 'string' || Buffer.isBuffer(data) ? data : JSON.stringify(data);
  res.writeHead(status, {'content-type': 'application/json', 'cache-control': 'no-store', ...headers});
  res.end(body);
}

// Exactly the allowed keys, each at most once; `required` keys must be present.
function queryKeys(params, allowed, required = allowed) {
  for (const key of params.keys())
    if (!allowed.includes(key) || params.getAll(key).length !== 1) throw httpError(400, `Unknown or duplicate query key: ${key}`);
  for (const key of required) if (!params.has(key)) throw httpError(400, `Missing query key: ${key}`);
}
function queryInt(params, key) {
  const raw = params.get(key);
  if (!INT_RE.test(raw)) throw httpError(400, `${key} must be a positive decimal integer`);
  return Number(raw);
}
export function validName(value) {
  return typeof value === 'string' && NAME_RE.test(value) && !RESERVED_RE.test(value);
}

async function readJsonBody(req) {
  if (!/^application\/json\s*(?:;|$)/i.test(req.headers['content-type'] ?? '')) throw httpError(415, 'Content-Type application/json required');
  // An oversize body up to 4x the limit is drained (never buffered) so the 413 reply reaches the client before the
  // socket closes; a declared length or a stream beyond 4x the limit is refused at once.
  const declared = req.headers['content-length'];
  if (declared !== undefined && !(Number(declared) <= 4 * MAX_BODY_BYTES)) throw httpError(413, `Body exceeds ${MAX_BODY_BYTES} bytes`);
  const parts = [];
  let total = 0;
  for await (const part of req) {
    total += part.length;
    if (total > 4 * MAX_BODY_BYTES) { req.destroy(); throw httpError(413, `Body exceeds ${MAX_BODY_BYTES} bytes`); }
    if (total > MAX_BODY_BYTES) { parts.length = 0; continue; }
    parts.push(part);
  }
  if (total > MAX_BODY_BYTES) throw httpError(413, `Body exceeds ${MAX_BODY_BYTES} bytes`);
  try { return JSON.parse(Buffer.concat(parts).toString('utf8')); }
  catch { throw httpError(400, 'Body is not valid JSON'); }
}

function chunkPath(root, runId, name) {
  if (!validName(runId)) throw httpError(400, 'Invalid runId (^[A-Za-z0-9_-]{1,100}$, no device names)');
  if (!validName(name)) throw httpError(400, 'Invalid chunk name (^[A-Za-z0-9_-]{1,100}$, no device names)');
  const dir = join(root, runId), path = join(dir, name + '.json'), rel = relative(root, path);
  if (!rel || rel.startsWith('..') || isAbsolute(rel) || rel.split(sep).length !== 2) throw httpError(400, 'Chunk path escapes the results root');
  return {dir, path};
}

function writeOnce(path, text) {
  const fd = openSync(path, 'wx');
  try { writeSync(fd, text); fsyncSync(fd); } finally { closeSync(fd); }
}

export function createLiveServer({resultsRoot = DEFAULT_RESULTS_ROOT, data = liveData} = {}) {
  const root = resolve(resultsRoot);
  const routes = {
    'GET /health': params => { queryKeys(params, []); return {ok: true, app: APP, schema: SERVER_SCHEMA}; },
    'GET /spring-live/manifest': params => { queryKeys(params, []); return data.liveManifest(); },
    'GET /spring-live/page': params => { queryKeys(params, ['index']); return data.livePage(queryInt(params, 'index')); },
    'GET /spring-live/capture-check': params => {
      queryKeys(params, ['first', 'last']);
      return data.captureCheck(queryInt(params, 'first'), queryInt(params, 'last'));
    },
    'GET /spring-live/chunk': (params, res) => {
      queryKeys(params, ['runId', 'name', 'sha256'], ['runId', 'name']);
      const expected = params.get('sha256');
      if (expected !== null && !SHA_RE.test(expected)) throw httpError(400, 'sha256 must be 64 lowercase hex characters');
      const {path} = chunkPath(root, params.get('runId'), params.get('name'));
      if (!existsSync(path)) throw httpError(404, 'Chunk not found');
      const bytes = readFileSync(path), found = liveData.sha256(bytes);
      if (expected !== null && found !== expected) throw httpError(409, 'Saved chunk hash mismatch');
      send(res, 200, bytes, {'x-content-sha256': found});
    },
    'POST /spring-live/chunk': async (params, res, req) => {
      queryKeys(params, []);
      const body = await readJsonBody(req);
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw httpError(400, 'Body must be {runId, name, payload}');
      const keys = Object.keys(body).sort();
      if (keys.length !== POST_KEYS.length || keys.some((key, i) => key !== POST_KEYS[i])) throw httpError(400, 'Body must have exactly the keys runId, name, payload');
      const {payload} = body;
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw httpError(400, 'payload must be a JSON object');
      const {dir, path} = chunkPath(root, body.runId, body.name);
      const text = JSON.stringify(payload);
      mkdirSync(dir, {recursive: true});
      writeOnce(path, text);
      send(res, 201, {ok: true, path, sha256: liveData.sha256(text), bytes: Buffer.byteLength(text)});
    },
  };
  const knownPaths = new Set(Object.keys(routes).map(key => key.split(' ')[1]));

  return http.createServer(async (req, res) => {
    try {
      const host = req.headers.host ?? '', origin = req.headers.origin;
      if (!/^127\.0\.0\.1(?::\d+)?$/.test(host) || (origin !== undefined && origin !== `http://${host}`))
        return send(res, 403, {error: 'Loopback host/origin required'});
      const target = req.url ?? '';
      if (!target.startsWith('/') || target.startsWith('//')) return send(res, 404, {error: 'Unknown route'});
      const url = new URL(target, 'http://127.0.0.1');
      const handler = routes[`${req.method} ${url.pathname}`];
      if (!handler) {
        if (knownPaths.has(url.pathname)) return send(res, 405, {error: 'Method not allowed'});
        return send(res, 404, {error: 'Unknown route'});
      }
      const out = await handler(url.searchParams, res, req);
      if (out !== undefined) send(res, 200, out);
    } catch (error) {
      const status = error.status ?? (error.code === 'EEXIST' ? 409 : 500);
      const headers = status === 413 ? {connection: 'close'} : {};
      if (!req.readableEnded && !req.destroyed) req.resume();
      if (!res.headersSent) send(res, status, {error: error.code === 'EEXIST' ? 'Chunk already exists (write-once)' : error.message}, headers);
    }
  });
}

// Binds 127.0.0.1 only; the host is not configurable. Resolves once listening.
export async function start({port = DEFAULT_PORT, resultsRoot = DEFAULT_RESULTS_ROOT, preload = false, host = HOST, data = liveData} = {}) {
  if (host !== HOST) throw new Error(`The spring live server binds ${HOST} only`);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error(`Invalid port ${port}`);
  if (preload) { data.liveManifest(); }
  const server = createLiveServer({resultsRoot, data});
  await new Promise((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(port, HOST, () => { server.off('error', rejectListen); resolveListen(); });
  });
  const address = server.address();
  return {
    server, port: address.port, address: address.address, url: `http://${HOST}:${address.port}`, resultsRoot: resolve(resultsRoot),
    close: () => new Promise(done => { server.close(() => done()); server.closeAllConnections(); }),
  };
}

export function parseArgs(argv, cwd = process.cwd()) {
  const options = {port: DEFAULT_PORT, resultsRoot: DEFAULT_RESULTS_ROOT, preload: true};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--lazy') options.preload = false;
    else if (arg === '--port' && i + 1 < argv.length) {
      const value = argv[++i];
      if (!/^(0|[1-9][0-9]{0,4})$/.test(value) || Number(value) > 65535) throw new Error(`Invalid --port ${value}`);
      options.port = Number(value);
    } else if (arg === '--results-root' && i + 1 < argv.length) options.resultsRoot = resolve(cwd, argv[++i]);
    else throw new Error(`Unknown argument ${arg}. Usage: node spring-live-server.mjs [--port N] [--results-root DIR] [--lazy]`);
  }
  return options;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const running = await start(options);
    console.log(`${APP} server ${running.url} results ${running.resultsRoot}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
