// Packages the market reservoir lab as a Roblox Studio local plugin (RBXMX) from an explicit allowlist.
//
// Usage: node tools/build-plugin.mjs [--out build/MarketReservoirLab.rbxmx] [--stamp <text>] [--install] [--strict]
//                                    [--root <project root>] [--allowlist <file>]
//   Writes the rbxmx and, beside it, package-manifest.json. Relative --out/--allowlist paths resolve against
//   the project root. --install also copies the rbxmx to %LOCALAPPDATA%/Roblox/Plugins/MarketReservoirLab.rbxmx.
//   Static require("./x") / require("../x") strings in packaged scripts are resolved against the instance tree; those
//   that would fail in Studio are listed as warnings and in the manifest (unresolvedRequires). --strict fails instead.
//
// Instance tree (mirrors lab/ so require-by-string paths resolve exactly as they do in the Luau CLI):
//   Folder MarketReservoirLab
//     StringValue BuildInfo            JSON {buildId, sourceHash, fileCount, createdFrom[, stamp]}
//     Folder src | generated | tests   one Folder per directory under lab/, X.luau -> ModuleScript X,
//                                      X.server.luau -> Script X (names keep inner dots, e.g. Data.spec)
//     Folder DataAssets > Folder <group> > ModuleScript <SYMBOL> (loader) > ModuleScript ChunkNNN
//
// Safety: only files named by the allowlist (glob-free directory roots and files) are read. Hidden entries are
// skipped, secret-looking names are refused, and nothing outside the allowlist is ever opened.
// Output is deterministic: sorted children, referents derived from instance paths, LF newlines, no clock.

import { createHash } from "node:crypto";
import { copyFileSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export const ROOT_NAME = "MarketReservoirLab";
export const PLUGIN_FILE_NAME = "MarketReservoirLab.rbxmx";
export const MANIFEST_FILE_NAME = "package-manifest.json";
export const CREATED_FROM = "tools/build-plugin.mjs";
export const ALLOWLIST_SCHEMA = "mrl-package-allowlist-1";
export const MANIFEST_SCHEMA = "mrl-package-manifest-1";
export const SOURCE_HASH_SCHEME = "sha256 over UTF-8 lines 'path<TAB>sha256<TAB>bytes<LF>' for every packaged file, sorted by path (code-unit order); sha256 and bytes are those of the file on disk";

const SECRET_NAME = /key|secret|token|credential|\.env/i;
const XML_ILLEGAL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/;
const SHA256_HEX = /^[0-9a-f]{64}$/;
const SYMBOL_NAME = /^[A-Za-z][A-Za-z0-9_]*$/;
const GROUP_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const MAX_STAMP_LENGTH = 200;

const defaultProjectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const defaultAllowlistPath = join(dirname(fileURLToPath(import.meta.url)), "build-plugin.allowlist.json");
const utf8 = new TextDecoder("utf-8", { fatal: true });

export class PackageError extends Error {
  constructor(message, missing) {
    super(message);
    this.name = "PackageError";
    if (missing) this.missing = missing;
  }
}

const fail = (message, missing) => {
  throw new PackageError(`build-plugin: ${message}`, missing);
};

const byCodeUnit = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const sha256Hex = (data) => createHash("sha256").update(data).digest("hex");
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// ---------------------------------------------------------------------------------------------
// XML
// ---------------------------------------------------------------------------------------------

// Ampersand first, so the ampersands of the entities added afterwards are not escaped a second time.
export function escapeXml(s) {
  if (typeof s !== "string") throw new TypeError("escapeXml: expected a string");
  return s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

// ---------------------------------------------------------------------------------------------
// Path rules
// ---------------------------------------------------------------------------------------------

export function isSecretLookingName(name) {
  return SECRET_NAME.test(name);
}

// Validates a project-relative, glob-free, forward-slash path and returns its segments. Throws for anything
// unsafe, hidden or secret-looking. `what` names the field in the message.
export function assertAllowedPath(relPath, what = "path") {
  if (typeof relPath !== "string" || relPath === "") fail(`unsafe ${what}: expected a non-empty string`);
  if (relPath.includes("\\") || relPath.includes("\0")) fail(`unsafe ${what} ${JSON.stringify(relPath)}: use forward slashes only`);
  if (relPath.startsWith("/") || /^[A-Za-z]:/.test(relPath)) fail(`unsafe ${what} ${JSON.stringify(relPath)}: must be relative to the project root`);
  if (/[*?[\]{}]/.test(relPath)) fail(`unsafe ${what} ${JSON.stringify(relPath)}: globs are not allowed`);
  const segments = relPath.split("/");
  for (const seg of segments) {
    if (seg === "" || seg === "." || seg === "..") fail(`unsafe ${what} ${JSON.stringify(relPath)}: empty, "." or ".." segment`);
    if (seg.startsWith(".")) fail(`${what} ${JSON.stringify(relPath)} is hidden (segment ${JSON.stringify(seg)}); hidden files are never packaged`);
    if (SECRET_NAME.test(seg)) fail(`${what} ${JSON.stringify(relPath)} has a secret-looking name (segment ${JSON.stringify(seg)}: key, secret, token, credential or .env); refusing`);
  }
  return segments;
}

// Case-insensitive on purpose: Windows file systems are, so an allowlist entry "lab/generated/sources.luau" names the
// very file that a neverPackage entry "lab/generated/Sources.luau" denies.
const underOrEqual = (path, root) => {
  const p = path.toLowerCase();
  const r = root.toLowerCase();
  return p === r || p.startsWith(`${r}/`);
};

// ---------------------------------------------------------------------------------------------
// Allowlist
// ---------------------------------------------------------------------------------------------

function checkKeys(obj, allowed, what) {
  for (const key of Object.keys(obj)) {
    if (!allowed.includes(key)) fail(`unknown key ${JSON.stringify(key)} in ${what}`);
  }
}

function checkStringList(value, what) {
  if (!Array.isArray(value) || !value.every((v) => typeof v === "string")) fail(`${what} must be an array of strings`);
}

export function validateAllowlist(a) {
  if (!isObject(a)) fail("the allowlist must be a JSON object");
  checkKeys(a, ["schema", "luauRoot", "directories", "files", "required", "neverPackage", "dataAssets"], "the allowlist");
  if (a.schema !== ALLOWLIST_SCHEMA) fail(`allowlist schema must be ${JSON.stringify(ALLOWLIST_SCHEMA)}`);
  if (typeof a.luauRoot !== "string") fail("allowlist luauRoot must be a string");
  assertAllowedPath(a.luauRoot, "allowlist luauRoot");
  const inLuauRoot = (p, what) => {
    assertAllowedPath(p, what);
    if (!p.startsWith(`${a.luauRoot}/`)) fail(`${what} ${JSON.stringify(p)} is outside luauRoot ${JSON.stringify(a.luauRoot)}`);
  };

  checkStringList(a.neverPackage ?? [], "allowlist neverPackage");
  const deny = a.neverPackage ?? [];
  for (const p of deny) assertAllowedPath(p, "allowlist neverPackage entry");
  const denied = (p) => deny.find((d) => underOrEqual(p, d));

  if (!Array.isArray(a.directories)) fail("allowlist directories must be an array");
  a.directories.forEach((d, i) => {
    const what = `allowlist directories[${i}]`;
    if (!isObject(d)) fail(`${what} must be an object`);
    checkKeys(d, ["path", "recursive", "optional"], what);
    if (typeof d.path !== "string") fail(`${what}.path must be a string`);
    inLuauRoot(d.path, `${what}.path`);
    if (typeof d.recursive !== "boolean") fail(`${what}.recursive must be true or false`);
    if (d.optional !== undefined && typeof d.optional !== "boolean") fail(`${what}.optional must be true or false`);
    if (denied(d.path)) fail(`${what}.path ${JSON.stringify(d.path)} is listed in neverPackage and must never be packaged`);
  });

  checkStringList(a.files, "allowlist files");
  for (const p of a.files) {
    inLuauRoot(p, "allowlist file");
    if (!p.endsWith(".luau")) fail(`allowlist file ${JSON.stringify(p)} must end in .luau`);
    if (denied(p)) fail(`allowlist file ${JSON.stringify(p)} is listed in neverPackage and must never be packaged`);
  }

  checkStringList(a.required ?? [], "allowlist required");
  for (const p of a.required ?? []) inLuauRoot(p, "allowlist required entry");

  if (!Array.isArray(a.dataAssets)) fail("allowlist dataAssets must be an array");
  const groupNames = new Set();
  a.dataAssets.forEach((g, i) => {
    const what = `allowlist dataAssets[${i}]`;
    if (!isObject(g)) fail(`${what} must be an object`);
    checkKeys(g, ["group", "root", "manifest", "symbols", "expectedLoaders", "expectedChunks"], what);
    if (typeof g.group !== "string" || !GROUP_NAME.test(g.group)) fail(`${what}.group must be a simple name`);
    if (groupNames.has(g.group)) fail(`duplicate data group name ${JSON.stringify(g.group)}`);
    groupNames.add(g.group);
    if (typeof g.root !== "string") fail(`${what}.root must be a string`);
    assertAllowedPath(g.root, `${what}.root`);
    if (typeof g.manifest !== "string") fail(`${what}.manifest must be a string`);
    assertAllowedPath(g.manifest, `${what}.manifest`);
    if (!Array.isArray(g.symbols) || g.symbols.length === 0 || !g.symbols.every((s) => typeof s === "string" && SYMBOL_NAME.test(s))) {
      fail(`${what}.symbols must be a non-empty array of symbol names`);
    }
    if (new Set(g.symbols).size !== g.symbols.length) fail(`duplicate symbol in ${what}.symbols`);
    for (const key of ["expectedLoaders", "expectedChunks"]) {
      if (!Number.isInteger(g[key]) || g[key] < 0) fail(`${what}.${key} must be a non-negative integer`);
    }
  });
  return a;
}

export function loadAllowlist(path = defaultAllowlistPath) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    fail(`cannot read allowlist ${path}: ${err.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    fail(`allowlist ${path} is not valid JSON: ${err.message}`);
  }
  return { allowlist: validateAllowlist(parsed), sha256: sha256Hex(text) };
}

// ---------------------------------------------------------------------------------------------
// Reading files
// ---------------------------------------------------------------------------------------------

function absolute(projectRoot, relPath) {
  return join(projectRoot, ...relPath.split("/"));
}

// Throws when any component of relPath below projectRoot is a symbolic link or junction (lstat on the last component
// alone would silently follow a linked parent directory out of the tree). Stops quietly at the first missing component.
function assertNoLinkInPath(projectRoot, relPath) {
  let current = projectRoot;
  for (const segment of relPath.split("/")) {
    current = join(current, segment);
    let st;
    try {
      st = lstatSync(current);
    } catch (err) {
      if (err.code === "ENOENT" || err.code === "ENOTDIR") return;
      throw err;
    }
    if (st.isSymbolicLink()) fail(`refusing symbolic link or junction at ${relPath} (a component of the path is a link)`);
  }
}

// Reads one regular file; returns null when it does not exist. Symbolic links are refused.
function readRegularFile(projectRoot, relPath) {
  const abs = absolute(projectRoot, relPath);
  let st;
  try {
    st = lstatSync(abs);
  } catch (err) {
    if (err.code === "ENOENT" || err.code === "ENOTDIR") return null;
    throw err;
  }
  if (st.isSymbolicLink()) fail(`refusing symbolic link ${relPath}`);
  if (!st.isFile()) fail(`${relPath} is not a regular file`);
  return readFileSync(abs);
}

// Script text as embedded: valid UTF-8, BOM removed, CRLF and lone CR turned into LF, XML-legal characters only.
function decodeSource(raw, relPath) {
  let text;
  try {
    text = utf8.decode(raw);
  } catch {
    fail(`${relPath} is not valid UTF-8`);
  }
  text = text.replace(/\r\n?/g, "\n");
  const bad = XML_ILLEGAL.exec(text);
  if (bad) fail(`${relPath} contains an illegal XML character U+${bad[0].charCodeAt(0).toString(16).toUpperCase().padStart(4, "0")}`);
  return text;
}

function makeRecord(raw, relPath) {
  const text = decodeSource(raw, relPath);
  return {
    relPath,
    sha256: sha256Hex(raw),
    bytes: raw.length,
    text,
    embeddedSha256: sha256Hex(text),
  };
}

// lab/<dirs>/<name>.luau -> { folders, name, className }
function describeLabFile(relPath, luauRoot) {
  const segments = relPath.slice(luauRoot.length + 1).split("/");
  const file = segments.pop();
  let name = file.slice(0, -".luau".length);
  let className = "ModuleScript";
  if (name.endsWith(".server")) {
    name = name.slice(0, -".server".length);
    className = "Script";
  } else if (name.endsWith(".client")) {
    fail(`${relPath}: .client.luau (LocalScript) is not supported by this package`);
  }
  if (name === "" || name === "init") fail(`${relPath}: the name "init" is reserved for dataset loaders and cannot be mirrored into the tree`);
  return { folders: segments, name, className };
}

function scanDirectory(projectRoot, dirRel, recursive, found) {
  const entries = readdirSync(absolute(projectRoot, dirRel), { withFileTypes: true });
  entries.sort((a, b) => byCodeUnit(a.name, b.name));
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue; // hidden: skipped, never packaged
    const rel = `${dirRel}/${entry.name}`;
    if (entry.isSymbolicLink()) fail(`refusing symbolic link ${rel}`);
    if (entry.isDirectory()) {
      if (!recursive) continue;
      if (SECRET_NAME.test(entry.name)) fail(`directory ${JSON.stringify(rel)} has a secret-looking name; refusing`);
      scanDirectory(projectRoot, rel, true, found);
    } else if (entry.isFile() && entry.name.endsWith(".luau")) {
      if (SECRET_NAME.test(entry.name)) fail(`file ${JSON.stringify(rel)} has a secret-looking name (key, secret, token, credential or .env); refusing`);
      found.add(rel);
    }
  }
}

function directoryExists(projectRoot, relPath) {
  try {
    return lstatSync(absolute(projectRoot, relPath)).isDirectory();
  } catch (err) {
    if (err.code === "ENOENT" || err.code === "ENOTDIR") return false;
    throw err;
  }
}

// Reads every file the allowlist selects. Absent allowlisted files/directories and unmet `required` entries are
// returned as `missing` (path -> reason) so the caller can report them all at once.
function collectLabFiles(projectRoot, allowlist) {
  const paths = new Set();
  const missing = new Map();
  for (const dir of allowlist.directories) {
    assertNoLinkInPath(projectRoot, dir.path); // before the existence test: a linked directory is neither "absent" nor optional
    if (!directoryExists(projectRoot, dir.path)) {
      if (!dir.optional) missing.set(dir.path, "allowlisted directory does not exist");
      continue;
    }
    scanDirectory(projectRoot, dir.path, dir.recursive, paths);
  }
  for (const file of allowlist.files) paths.add(file);

  const deny = allowlist.neverPackage ?? [];
  const records = [];
  for (const rel of [...paths].sort(byCodeUnit)) {
    const hit = deny.find((d) => underOrEqual(rel, d));
    if (hit) fail(`${rel} is under neverPackage entry ${hit} and must never be packaged`);
    assertNoLinkInPath(projectRoot, rel);
    const raw = readRegularFile(projectRoot, rel);
    if (raw === null) {
      missing.set(rel, allowlist.files.includes(rel) ? "named in the allowlist but absent on disk" : "absent on disk");
      continue;
    }
    const record = makeRecord(raw, rel);
    Object.assign(record, describeLabFile(rel, allowlist.luauRoot));
    records.push(record);
  }
  const have = new Set(records.map((r) => r.relPath));
  for (const rel of allowlist.required ?? []) {
    if (!have.has(rel) && !missing.has(rel)) missing.set(rel, "required but not covered by the allowlist");
  }
  return { records, missing };
}

// ---------------------------------------------------------------------------------------------
// Data assets (original-style dataset export: roblox/<SYM>/init.luau + ChunkNNN.luau, enumerated from manifest.json)
// ---------------------------------------------------------------------------------------------

function readDataFile(projectRoot, relPath, entry) {
  assertAllowedPath(relPath, "data file");
  const raw = readRegularFile(projectRoot, relPath);
  if (raw === null) fail(`data file ${relPath} listed in the data manifest does not exist`);
  const sha = sha256Hex(raw);
  if (sha !== entry.sha256) fail(`sha256 mismatch for ${relPath}: data manifest says ${entry.sha256}, file is ${sha}`);
  if (raw.length !== entry.bytes) fail(`byte count mismatch for ${relPath}: data manifest says ${entry.bytes}, file is ${raw.length}`);
  return makeRecord(raw, relPath);
}

function loaderChunkNames(text, relPath) {
  const m = /local\s+chunkNames\s*=\s*\{([^}]*)\}/.exec(text);
  if (!m) fail(`loader ${relPath} has no chunkNames list`);
  return [...m[1].matchAll(/"([^"]*)"/g)].map((x) => x[1]);
}

export function collectDataAssets(projectRoot, groups) {
  const out = [];
  for (const group of groups) {
    const manifestRel = `${group.root}/${group.manifest}`;
    assertAllowedPath(manifestRel, "data manifest");
    const manifestRaw = readRegularFile(projectRoot, manifestRel);
    if (manifestRaw === null) fail(`data manifest ${manifestRel} does not exist`);
    let manifest;
    try {
      manifest = JSON.parse(utf8.decode(manifestRaw));
    } catch (err) {
      fail(`data manifest ${manifestRel} is not valid JSON: ${err.message}`);
    }
    if (!isObject(manifest) || !isObject(manifest.symbols) || !Array.isArray(manifest.files)) {
      fail(`data manifest ${manifestRel} must have "symbols" and "files"`);
    }
    const seenPaths = new Set();
    for (const f of manifest.files) {
      if (!isObject(f) || typeof f.path !== "string" || !SHA256_HEX.test(f.sha256) || !Number.isInteger(f.bytes)) {
        fail(`data manifest ${manifestRel} has a malformed file entry ${JSON.stringify(f)}`);
      }
      if (seenPaths.has(f.path)) fail(`data manifest ${manifestRel} lists ${f.path} twice`);
      seenPaths.add(f.path);
    }

    const symbols = [];
    for (const symbol of group.symbols) {
      const meta = manifest.symbols[symbol];
      if (!isObject(meta)) fail(`data manifest ${manifestRel} has no symbol ${symbol}`);
      const loaderPath = `roblox/${symbol}/init.luau`;
      if (meta.modulePath !== loaderPath) fail(`data manifest ${manifestRel}: ${symbol} modulePath is ${JSON.stringify(meta.modulePath)}, expected ${loaderPath}`);
      const prefix = `roblox/${symbol}/`;
      const chunkPattern = new RegExp(`^roblox/${symbol}/Chunk(\\d{3})\\.luau$`);
      let loaderEntry;
      const chunkEntries = [];
      for (const f of manifest.files) {
        if (!f.path.startsWith(prefix)) continue;
        if (f.path === loaderPath) {
          loaderEntry = f;
          continue;
        }
        if (!chunkPattern.test(f.path)) fail(`data manifest ${manifestRel} lists ${f.path}, which is neither the ${symbol} loader nor a ChunkNNN module`);
        chunkEntries.push(f);
      }
      if (!loaderEntry) fail(`data manifest ${manifestRel} does not list the ${symbol} loader ${loaderPath}`);
      chunkEntries.sort((a, b) => byCodeUnit(a.path, b.path));
      chunkEntries.forEach((e, i) => {
        const want = `Chunk${String(i + 1).padStart(3, "0")}`;
        if (e.path !== `${prefix}${want}.luau`) fail(`data manifest ${manifestRel}: ${symbol} chunks are not contiguous (expected ${want}, found ${basename(e.path)})`);
      });
      if (meta.chunkCount !== chunkEntries.length) {
        fail(`data manifest ${manifestRel}: ${symbol} chunkCount is ${meta.chunkCount} but ${chunkEntries.length} chunk files are listed`);
      }

      const loader = readDataFile(projectRoot, `${group.root}/${loaderEntry.path}`, loaderEntry);
      loader.name = symbol;
      loader.className = "ModuleScript";
      const chunks = chunkEntries.map((e) => {
        const record = readDataFile(projectRoot, `${group.root}/${e.path}`, e);
        record.name = basename(e.path, ".luau");
        record.className = "ModuleScript";
        return record;
      });
      const named = loaderChunkNames(loader.text, loader.relPath);
      const actual = chunks.map((c) => c.name);
      if (named.length !== actual.length || named.some((n, i) => n !== actual[i])) {
        fail(`loader ${loader.relPath} chunkNames [${named.join(", ")}] do not match the chunks listed in the data manifest [${actual.join(", ")}]`);
      }
      symbols.push({ symbol, loader, chunks });
    }

    const loaderCount = symbols.length;
    const chunkCount = symbols.reduce((n, s) => n + s.chunks.length, 0);
    if (loaderCount !== group.expectedLoaders) fail(`data group ${JSON.stringify(group.group)}: expected ${group.expectedLoaders} loaders, found ${loaderCount}`);
    if (chunkCount !== group.expectedChunks) fail(`data group ${JSON.stringify(group.group)}: expected ${group.expectedChunks} chunks, found ${chunkCount}`);
    out.push({ name: group.group, root: group.root, manifestPath: manifestRel, manifestSha256: sha256Hex(manifestRaw), symbols });
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Instance tree
// ---------------------------------------------------------------------------------------------

function newNode(name, className, parent, origin) {
  return { name, className, origin, path: parent ? `${parent.path}/${name}` : name, children: new Map() };
}

function addChild(parent, node) {
  const existing = parent.children.get(node.name);
  if (existing) fail(`instance name collision at ${node.path}: ${existing.origin} and ${node.origin} both map to ${existing.className} ${node.name}`);
  parent.children.set(node.name, node);
  return node;
}

function ensureFolder(parent, name, origin) {
  const existing = parent.children.get(name);
  if (!existing) return addChild(parent, newNode(name, "Folder", parent, origin));
  if (existing.className !== "Folder") fail(`instance name collision at ${existing.path}: ${existing.origin} and ${origin} both map to ${name}`);
  return existing;
}

function scriptNode(parent, record, name, className) {
  const node = newNode(name, className, parent, record.relPath);
  node.source = record.text;
  return node;
}

function buildTree(labRecords, dataGroups) {
  const root = newNode(ROOT_NAME, "Folder", null, "<root>");
  for (const record of labRecords) {
    let parent = root;
    for (const folder of record.folders) parent = ensureFolder(parent, folder, record.relPath);
    record.node = addChild(parent, scriptNode(parent, record, record.name, record.className));
  }
  if (dataGroups.length > 0) {
    // addChild, not ensureFolder: a lab directory called DataAssets must collide, not merge into the data folder.
    const dataRoot = addChild(root, newNode("DataAssets", "Folder", root, "<data assets>"));
    for (const group of dataGroups) {
      const groupFolder = addChild(dataRoot, newNode(group.name, "Folder", dataRoot, group.manifestPath));
      for (const { loader, chunks } of group.symbols) {
        loader.node = addChild(groupFolder, scriptNode(groupFolder, loader, loader.name, "ModuleScript"));
        for (const chunk of chunks) chunk.node = addChild(loader.node, scriptNode(loader.node, chunk, chunk.name, "ModuleScript"));
      }
    }
  }
  return root;
}

function sortedChildren(node) {
  return [...node.children.values()].sort((a, b) => byCodeUnit(a.name, b.name));
}

// ---------------------------------------------------------------------------------------------
// Dangling require-by-string detection
//
// The package only contains what the allowlist names, so a spec can require a file that exists on disk (and works in
// the Luau CLI) yet is missing from the Studio tree. This reads the static relative requires of every packaged lab
// script and resolves them against the instance tree, the way Studio does: "./" and "../" start at the requiring
// script's parent, and the target must be a ModuleScript.
// ---------------------------------------------------------------------------------------------

// Opening long bracket at text[i] ("[[", "[=[", ...) -> its length and closing delimiter, else null.
function longBracket(text, i) {
  const m = /^\[(=*)\[/.exec(text.slice(i, i + 64));
  return m ? { open: m[0].length, close: `]${m[1]}]` } : null;
}

// Luau source with every comment blanked to spaces (newlines kept). Strings and long strings stay verbatim, so a
// commented-out require is not seen and a "--" inside a string literal does not hide the code after it.
export function blankLuauComments(text) {
  const out = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === "-" && text[i + 1] === "-") {
      const bracket = text[i + 2] === "[" ? longBracket(text, i + 2) : null;
      let stop;
      if (bracket) {
        const end = text.indexOf(bracket.close, i + 2 + bracket.open);
        stop = end < 0 ? n : end + bracket.close.length;
      } else {
        const end = text.indexOf("\n", i);
        stop = end < 0 ? n : end;
      }
      out.push(text.slice(i, stop).replace(/[^\n]/g, " "));
      i = stop;
    } else if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < n && text[j] !== c && text[j] !== "\n") j += text[j] === "\\" ? 2 : 1;
      out.push(text.slice(i, j + 1));
      i = j + 1;
    } else if (c === "[") {
      const bracket = longBracket(text, i);
      if (bracket) {
        const end = text.indexOf(bracket.close, i + bracket.open);
        const stop = end < 0 ? n : end + bracket.close.length;
        out.push(text.slice(i, stop));
        i = stop;
      } else {
        out.push(c);
        i += 1;
      }
    } else {
      out.push(c);
      i += 1;
    }
  }
  return out.join("");
}

const REQUIRE_CALL = /\brequire\s*\(\s*(?:"(\.{1,2}\/[^"\n]*)"|'(\.{1,2}\/[^'\n]*)')\s*\)/g;

// Instance-path segments a require string points at, starting from the requiring script's container; null when it
// climbs above the plugin root.
function resolveRequirePath(containerPath, spec) {
  const parts = containerPath.split("/");
  for (const seg of spec.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (parts.length <= 1) return null;
      parts.pop();
    } else {
      parts.push(seg);
    }
  }
  return parts;
}

// records: packaged lab scripts with .relPath, .text and .node. Returns [{ from, require, target }] sorted by
// (from, require), one entry per distinct pair; target is the lab-relative path without extension, or null when the
// require climbs above the plugin root. Requires that are not static "./" or "../" strings are out of scope.
export function findUnresolvedRequires(records, root, luauRoot) {
  const byPath = new Map();
  const index = (node) => {
    byPath.set(node.path, node);
    for (const child of node.children.values()) index(child);
  };
  index(root);

  const found = new Map();
  for (const record of records) {
    const containerPath = record.node.path.split("/").slice(0, -1).join("/");
    for (const match of blankLuauComments(record.text).matchAll(REQUIRE_CALL)) {
      const spec = match[1] ?? match[2];
      const parts = resolveRequirePath(containerPath, spec);
      const node = parts ? byPath.get(parts.join("/")) : undefined;
      if (node && node.className === "ModuleScript") continue;
      const key = `${record.relPath}\0${spec}`;
      if (!found.has(key)) found.set(key, { from: record.relPath, require: spec, target: parts ? `${luauRoot}/${parts.slice(1).join("/")}` : null });
    }
  }
  return [...found.values()].sort((a, b) => byCodeUnit(a.from, b.from) || byCodeUnit(a.require, b.require));
}

const describeUnresolved = (u) => `${u.from} requires "${u.require}" -> ${u.target ? `${u.target} is not a packaged ModuleScript` : "climbs above the plugin root"}`;

function assignReferents(root) {
  const seen = new Map();
  const visit = (node) => {
    node.referent = `RBX${sha256Hex(node.path).slice(0, 32).toUpperCase()}`;
    if (seen.has(node.referent)) fail(`referent collision between ${seen.get(node.referent)} and ${node.path}`);
    seen.set(node.referent, node.path);
    for (const child of node.children.values()) visit(child);
  };
  visit(root);
}

const RBXMX_OPEN = [
  '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
  '\t<Meta name="ExplicitAutoJoints">true</Meta>',
  "\t<External>null</External>",
  "\t<External>nil</External>",
];

function renderNode(node, depth, lines) {
  const pad = "\t".repeat(depth);
  lines.push(`${pad}<Item class="${node.className}" referent="${node.referent}">`);
  lines.push(`${pad}\t<Properties>`);
  lines.push(`${pad}\t\t<string name="Name">${escapeXml(node.name)}</string>`);
  // Script source is escaped XML text, never CDATA (a CDATA section cannot contain its own terminator).
  if (node.source !== undefined) lines.push(`${pad}\t\t<ProtectedString name="Source">${escapeXml(node.source)}</ProtectedString>`);
  if (node.value !== undefined) lines.push(`${pad}\t\t<string name="Value">${escapeXml(node.value)}</string>`);
  lines.push(`${pad}\t</Properties>`);
  for (const child of sortedChildren(node)) renderNode(child, depth + 1, lines);
  lines.push(`${pad}</Item>`);
}

function renderRbxmx(root) {
  const lines = [...RBXMX_OPEN];
  renderNode(root, 1, lines);
  lines.push("</roblox>");
  return `${lines.join("\n")}\n`;
}

// ---------------------------------------------------------------------------------------------
// Hashes, manifest, build
// ---------------------------------------------------------------------------------------------

// files: { [relPath]: { sha256, bytes } } (a manifest "files" object works).
export function computeSourceHash(files) {
  const hash = createHash("sha256");
  for (const rel of Object.keys(files).sort(byCodeUnit)) {
    hash.update(`${rel}\t${files[rel].sha256}\t${files[rel].bytes}\n`, "utf8");
  }
  return hash.digest("hex");
}

function checkStamp(stamp) {
  if (stamp === undefined) return;
  if (typeof stamp !== "string" || stamp.length === 0 || stamp.length > MAX_STAMP_LENGTH || /[\u0000-\u001F\u007F]/.test(stamp) || XML_ILLEGAL.test(stamp)) {
    fail(`stamp must be a non-empty single-line string of at most ${MAX_STAMP_LENGTH} characters without control or XML-illegal characters`);
  }
}

// Builds the package in memory. allowlist is a parsed allowlist object; projectRoot is the directory its paths are
// relative to. Returns { xml, manifest, manifestJson }.
export function buildPackage({ projectRoot, allowlist, stamp, strictRequires = false }) {
  validateAllowlist(allowlist);
  checkStamp(stamp);

  const lab = collectLabFiles(projectRoot, allowlist);
  if (lab.missing.size > 0) {
    const paths = [...lab.missing.keys()].sort(byCodeUnit);
    fail(`cannot build, missing: ${paths.map((p) => `${p} (${lab.missing.get(p)})`).join("; ")}`, paths);
  }
  const dataGroups = collectDataAssets(projectRoot, allowlist.dataAssets);

  const root = buildTree(lab.records, dataGroups);
  const unresolvedRequires = findUnresolvedRequires(lab.records, root, allowlist.luauRoot);
  if (strictRequires && unresolvedRequires.length > 0) {
    fail(`${unresolvedRequires.length} unresolved require(s) in packaged scripts: ${unresolvedRequires.map(describeUnresolved).join("; ")}`);
  }
  const records = [...lab.records, ...dataGroups.flatMap((g) => g.symbols.flatMap((s) => [s.loader, ...s.chunks]))];
  const files = {};
  for (const record of records.sort((a, b) => byCodeUnit(a.relPath, b.relPath))) {
    if (files[record.relPath]) fail(`${record.relPath} is packaged twice`);
    files[record.relPath] = {
      sha256: record.sha256,
      bytes: record.bytes,
      instancePath: record.node.path,
      className: record.node.className,
      embeddedSha256: record.embeddedSha256,
    };
  }

  const sourceHash = computeSourceHash(files);
  const buildId = `mrl-${sourceHash.slice(0, 12)}`;
  const fileCount = records.length;
  const info = { buildId, sourceHash, fileCount, createdFrom: CREATED_FROM };
  if (stamp !== undefined) info.stamp = stamp;
  const buildInfo = addChild(root, newNode("BuildInfo", "StringValue", root, "<build info>"));
  buildInfo.value = JSON.stringify(info);

  assignReferents(root);
  const xml = renderRbxmx(root);

  const manifest = {
    schema: MANIFEST_SCHEMA,
    createdFrom: CREATED_FROM,
    buildId,
    sourceHash,
    sourceHashScheme: SOURCE_HASH_SCHEME,
    fileCount,
    ...(stamp !== undefined ? { stamp } : {}),
    allowlistSha256: sha256Hex(JSON.stringify(allowlist)),
    package: { sha256: sha256Hex(Buffer.from(xml, "utf8")), bytes: Buffer.byteLength(xml, "utf8") },
    dataAssets: dataGroups.map((g) => ({
      group: g.name,
      manifestPath: g.manifestPath,
      manifestSha256: g.manifestSha256,
      loaders: g.symbols.length,
      chunks: g.symbols.reduce((n, s) => n + s.chunks.length, 0),
    })),
    unresolvedRequires,
    files,
  };
  return { xml, manifest, manifestJson: `${JSON.stringify(manifest, null, 2)}\n` };
}

export function writePackage(result, outPath) {
  const manifestPath = join(dirname(outPath), MANIFEST_FILE_NAME);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, Buffer.from(result.xml, "utf8"));
  writeFileSync(manifestPath, Buffer.from(result.manifestJson, "utf8"));
  return { outPath, manifestPath };
}

// ---------------------------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------------------------

export function defaultPluginsDir(env = process.env) {
  if (!env.LOCALAPPDATA) fail("LOCALAPPDATA is not set; cannot locate the Roblox Plugins folder");
  return join(env.LOCALAPPDATA, "Roblox", "Plugins");
}

// Copies the rbxmx into pluginsDir (created if needed) via a temporary name, so a reader never sees a partial file.
export function installPlugin(rbxmxPath, pluginsDir) {
  mkdirSync(pluginsDir, { recursive: true });
  const dest = join(pluginsDir, PLUGIN_FILE_NAME);
  const temp = `${dest}.tmp`;
  try {
    copyFileSync(rbxmxPath, temp);
    renameSync(temp, dest);
  } catch (err) {
    rmSync(temp, { force: true }); // never leave a half-installed copy in the Plugins folder
    throw err;
  }
  return dest;
}

// ---------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------

export function main(argv, { env = process.env, log = console.log } = {}) {
  const { values } = parseArgs({
    args: argv,
    options: {
      out: { type: "string" },
      stamp: { type: "string" },
      install: { type: "boolean" },
      root: { type: "string" },
      allowlist: { type: "string" },
      strict: { type: "boolean" },
    },
    strict: true,
    allowPositionals: false,
  });
  const projectRoot = values.root ? resolve(values.root) : defaultProjectRoot;
  const outPath = resolve(projectRoot, values.out ?? join("build", PLUGIN_FILE_NAME));
  const allowlistPath = values.allowlist ? resolve(projectRoot, values.allowlist) : defaultAllowlistPath;

  const { allowlist } = loadAllowlist(allowlistPath);
  const result = buildPackage({ projectRoot, allowlist, stamp: values.stamp, strictRequires: values.strict === true });
  const written = writePackage(result, outPath);
  log(`built ${written.outPath} (${result.manifest.fileCount} files, ${result.manifest.package.bytes} bytes, buildId ${result.manifest.buildId})`);
  log(`manifest ${written.manifestPath}`);
  const unresolved = result.manifest.unresolvedRequires;
  if (unresolved.length > 0) {
    log(`warning: ${unresolved.length} unresolved require(s) in packaged scripts; they will fail in Studio (--strict makes this an error):`);
    for (const u of unresolved) log(`  ${describeUnresolved(u)}`);
  }
  const response = { ...written, buildId: result.manifest.buildId, sourceHash: result.manifest.sourceHash };
  if (values.install) {
    response.installedPath = installPlugin(outPath, defaultPluginsDir(env));
    log(`installed ${response.installedPath}`);
  }
  return response;
}

function isEntryPoint() {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(err instanceof PackageError ? err.message : `build-plugin: ${err.message}`);
    process.exitCode = 1;
  }
}
