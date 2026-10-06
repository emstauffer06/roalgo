// Tests for tools/build-plugin.mjs. Run: node --test tools/build-plugin.test.mjs
// Most tests build from a temporary fixture tree so they do not depend on the lab sources other agents are writing.
// The data-asset tests read the real, immutable original hourly export (read-only).
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  PackageError,
  assertAllowedPath,
  buildPackage,
  collectDataAssets,
  computeSourceHash,
  defaultPluginsDir,
  escapeXml,
  installPlugin,
  isSecretLookingName,
  loadAllowlist,
  main,
  validateAllowlist,
  writePackage,
} from "./build-plugin.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const realRoot = resolve(here, "..");
const scriptPath = join(here, "build-plugin.mjs");

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

// Decodes the five predefined entities; ampersand LAST so escaped, entity-looking source stays literal.
function decodeXmlForTest(s) {
  return s.replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&quot;", '"').replaceAll("&apos;", "'").replaceAll("&amp;", "&");
}

const sha256 = (data) => createHash("sha256").update(data).digest("hex");
const clone = (v) => JSON.parse(JSON.stringify(v));
const tempDirs = [];

function tempDir(prefix = "mrl-build-test-") {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function writeFiles(root, files) {
  for (const [rel, content] of Object.entries(files)) {
    const abs = join(root, ...rel.split("/"));
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
}

// A strict reader for the restricted XML that the builder emits: elements, attributes, text, the five
// predefined entities. It rejects CDATA, comments inside content and any stray ampersand, so a pass proves more
// than "a parser accepted it".
function parseXml(text) {
  const token = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|(<!\[CDATA\[)|<\/([A-Za-z_][\w:.-]*)\s*>|<([A-Za-z_][\w:.-]*)((?:\s+[\w:.-]+="[^"<]*")*)\s*(\/?)>|([^<]+)/y;
  const root = { name: "#document", attrs: {}, children: [], text: "" };
  const stack = [root];
  let pos = 0;
  while (pos < text.length) {
    token.lastIndex = pos;
    const m = token.exec(text);
    if (!m) throw new Error(`XML parse error at offset ${pos}: ${JSON.stringify(text.slice(pos, pos + 40))}`);
    pos = token.lastIndex;
    const [whole, cdata, closeName, openName, attrText, selfClose, chars] = m;
    if (cdata) throw new Error("CDATA section found");
    if (whole.startsWith("<!--")) throw new Error("comment found");
    if (whole.startsWith("<?")) continue;
    if (closeName !== undefined) {
      const top = stack.pop();
      assert.equal(top.name, closeName, "mismatched closing tag");
    } else if (openName !== undefined) {
      const attrs = {};
      for (const a of attrText.matchAll(/([\w:.-]+)="([^"]*)"/g)) {
        assert.ok(!/&(?!(amp|lt|gt|quot|apos);)/.test(a[2]), "stray ampersand in attribute");
        attrs[a[1]] = decodeXmlForTest(a[2]);
      }
      const el = { name: openName, attrs, children: [], text: "" };
      stack[stack.length - 1].children.push(el);
      if (!selfClose) stack.push(el);
    } else if (chars !== undefined) {
      assert.ok(!/&(?!(amp|lt|gt|quot|apos);)/.test(chars), "stray ampersand in text");
      stack[stack.length - 1].text += decodeXmlForTest(chars);
    }
  }
  assert.equal(stack.length, 1, "unclosed element");
  return root;
}

function toItem(el) {
  const props = {};
  const propsEl = el.children.find((c) => c.name === "Properties");
  for (const p of propsEl.children) props[p.attrs.name] = { type: p.name, value: p.text };
  return {
    class: el.attrs.class,
    referent: el.attrs.referent,
    name: props.Name.value,
    props,
    items: el.children.filter((c) => c.name === "Item").map(toItem),
  };
}

function parseRbxmx(xml) {
  const doc = parseXml(xml);
  const robloxEl = doc.children.find((c) => c.name === "roblox");
  assert.ok(robloxEl, "root <roblox> element");
  assert.equal(robloxEl.attrs.version, "4");
  const roots = robloxEl.children.filter((c) => c.name === "Item").map(toItem);
  return { roots, robloxEl };
}

function walk(item, prefix, visit) {
  const path = prefix ? `${prefix}/${item.name}` : item.name;
  visit(item, path);
  for (const child of item.items) walk(child, path, visit);
}

function allItems(roots) {
  const out = new Map();
  for (const r of roots) walk(r, "", (item, path) => out.set(path, item));
  return out;
}

const loaderText = (names) =>
  `-- loader\nlocal chunkNames = {${names.map((n) => `"${n}"`).join(", ")}}\nlocal bars = {}\nreturn { bars = bars }\n`;

// Writes a miniature original-style export (loaders + chunks + manifest.json) under <root>/<dir>.
function makeDataFixture(root, { dir = "data/fixture-hourly", symbols = { SPY: 3, QQQ: 3 } } = {}) {
  const files = [];
  const meta = {};
  for (const [symbol, chunkCount] of Object.entries(symbols)) {
    const names = Array.from({ length: chunkCount }, (_, i) => `Chunk${String(i + 1).padStart(3, "0")}`);
    const entries = {
      [`roblox/${symbol}/init.luau`]: loaderText(names),
      ...Object.fromEntries(names.map((n, i) => [`roblox/${symbol}/${n}.luau`, `return {\n    {${1000 + i}, 1, 2, 3, 4, 5, 6, 7},\n}\n`])),
      [`${symbol}.csv`]: "timestamp_utc,timestamp_unix\n",
    };
    for (const [rel, content] of Object.entries(entries)) {
      writeFiles(join(root, dir), { [rel]: content });
      files.push({ path: rel, bytes: Buffer.byteLength(content), sha256: sha256(content) });
    }
    meta[symbol] = { count: chunkCount, csvPath: `${symbol}.csv`, modulePath: `roblox/${symbol}/init.luau`, chunkCount };
  }
  writeFiles(join(root, dir), { "manifest.json": JSON.stringify({ symbols: meta, files }, null, 2) });
  return { dir, manifestPath: join(root, dir, "manifest.json") };
}

const SPECIAL_SOURCE = `-- specials: & < > " ' and a literal CDATA terminator ]]>\nlocal s = "<&> ]]> \\"quoted\\" 'single' &amp; &lt; &#38; \u00e9 \u{1F600}"\nreturn s\n`;

const BASE_FILES = {
  "lab/src/Types.luau": "--!strict\nreturn {}\n",
  "lab/src/Config.luau": 'local data = require("../generated/ConfigData")\nreturn data\n',
  "lab/src/Main.server.luau": 'local Config = require("./Config")\nprint("plugin start", Config)\n',
  "lab/src/Data/Features.luau": 'local Types = require("../Types")\nreturn { Types = Types }\n',
  "lab/src/Model/Ridge.luau": "return {}\n",
  "lab/src/Util/Special.luau": SPECIAL_SOURCE,
  "lab/src/notes.md": "not a luau file, must never be packaged\n",
  "lab/generated/ConfigData.luau": "return { v = 1 }\n",
  "lab/generated/NyOffsets.luau": "return { ny = true }\n",
  "lab/generated/Sources.luau": "-- CLI only: must never be packaged\nreturn {}\n",
  "lab/cli/Run.luau": "-- CLI only: must never be packaged\n",
  "lab/tests/Test.luau": "return {}\n",
  "lab/tests/Specs.luau": "return {}\n",
  "lab/tests/RunAll.luau": "return {}\n",
  "lab/tests/Data.spec.luau": 'local Test = require("./Test")\nreturn Test\n',
};

function fixtureAllowlist(dataDir = "data/fixture-hourly") {
  return {
    schema: "mrl-package-allowlist-1",
    luauRoot: "lab",
    directories: [
      { path: "lab/src", recursive: true },
      { path: "lab/tests", recursive: false },
      { path: "lab/fixtures", recursive: false, optional: true },
    ],
    files: ["lab/generated/ConfigData.luau", "lab/generated/NyOffsets.luau"],
    required: ["lab/src/Main.server.luau", "lab/src/Types.luau", "lab/tests/RunAll.luau"],
    neverPackage: ["lab/generated/Sources.luau", "lab/cli"],
    dataAssets: [
      {
        group: "hourly-original",
        root: dataDir,
        manifest: "manifest.json",
        symbols: ["SPY", "QQQ"],
        expectedLoaders: 2,
        expectedChunks: 6,
      },
    ],
  };
}

function makeFixture(extraFiles = {}, { symbols } = {}) {
  const root = tempDir();
  writeFiles(root, { ...BASE_FILES, ...extraFiles });
  makeDataFixture(root, symbols ? { symbols } : {});
  return root;
}

// ---------------------------------------------------------------------------------------------
// escapeXml and the round trip
// ---------------------------------------------------------------------------------------------

describe("escapeXml", () => {
  test("replaces ampersand first, then < > double quote apostrophe", () => {
    assert.equal(escapeXml("&<>\"'"), "&amp;&lt;&gt;&quot;&apos;");
    assert.equal(escapeXml("<"), "&lt;", "the ampersand of &lt; must not be escaped again");
    assert.equal(escapeXml("&lt;"), "&amp;lt;");
    assert.equal(escapeXml("plain text 123"), "plain text 123");
  });

  test("plan contract: script text with ampersands, angle brackets, quotes and a CDATA terminator round-trips exactly", () => {
    const source = 'return "<&> ]]> \\"quoted\\""';
    assert.equal(decodeXmlForTest(escapeXml(source)), source);
  });

  test("round trip is exact for apostrophes and for entity-looking source text", () => {
    const sources = [
      SPECIAL_SOURCE,
      "&amp; &lt; &gt; &quot; &apos; &#38; &#x26; &amp;amp;",
      "if a < b and b > c then print('x' .. \"y\") end ]]> <![CDATA[ x ]]>",
      "",
      "\t\n\n  trailing spaces   \n",
    ];
    for (const source of sources) {
      assert.equal(decodeXmlForTest(escapeXml(source)), source, JSON.stringify(source));
    }
  });

  test("a decoder that unescapes ampersand first would corrupt entity-looking source (the order matters)", () => {
    const wrongDecode = (s) => s.replaceAll("&amp;", "&").replaceAll("&lt;", "<");
    assert.notEqual(wrongDecode(escapeXml("&lt;")), "&lt;");
    assert.equal(decodeXmlForTest(escapeXml("&lt;")), "&lt;");
  });

  test("rejects non-strings", () => {
    assert.throws(() => escapeXml(42), TypeError);
    assert.throws(() => escapeXml(undefined), TypeError);
  });
});

// ---------------------------------------------------------------------------------------------
// Fixture build: tree shape, classes, escaping in the file, manifest, build info
// ---------------------------------------------------------------------------------------------

describe("fixture package", () => {
  let root;
  let result;
  let tree;
  let items;

  before(() => {
    root = makeFixture();
    result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    tree = parseRbxmx(result.xml);
    items = allItems(tree.roots);
  });

  test("root is one Folder named MarketReservoirLab mirroring lab/", () => {
    assert.equal(tree.roots.length, 1);
    const rootItem = tree.roots[0];
    assert.equal(rootItem.class, "Folder");
    assert.equal(rootItem.name, "MarketReservoirLab");
    assert.deepEqual(
      rootItem.items.map((i) => `${i.class}:${i.name}`),
      ["StringValue:BuildInfo", "Folder:DataAssets", "Folder:generated", "Folder:src", "Folder:tests"],
    );
    assert.deepEqual(items.get("MarketReservoirLab/src").items.map((i) => i.name), ["Config", "Data", "Main", "Model", "Types", "Util"]);
    assert.equal(items.get("MarketReservoirLab/src/Data").class, "Folder");
    assert.equal(items.get("MarketReservoirLab/src/Data/Features").class, "ModuleScript");
    assert.deepEqual(items.get("MarketReservoirLab/generated").items.map((i) => i.name), ["ConfigData", "NyOffsets"]);
  });

  test("class selection: X.luau is a ModuleScript, X.server.luau is a Script, inner dots stay in the name", () => {
    assert.equal(items.get("MarketReservoirLab/src/Main").class, "Script");
    assert.equal(items.get("MarketReservoirLab/src/Types").class, "ModuleScript");
    assert.equal(items.get("MarketReservoirLab/tests/Data.spec").class, "ModuleScript");
    assert.equal(items.get("MarketReservoirLab/tests/Data.spec").name, "Data.spec");
    for (const [path, item] of items) {
      if (item.props.Source) assert.ok(["Script", "ModuleScript"].includes(item.class), path);
    }
    assert.equal(result.manifest.files["lab/src/Main.server.luau"].className, "Script");
    assert.equal(result.manifest.files["lab/src/Main.server.luau"].instancePath, "MarketReservoirLab/src/Main");
    assert.equal(result.manifest.files["lab/tests/Data.spec.luau"].className, "ModuleScript");
    assert.equal(result.manifest.files["lab/tests/Data.spec.luau"].instancePath, "MarketReservoirLab/tests/Data.spec");
  });

  test("only allowlisted Luau files are packaged (CLI-only and non-Luau files are left out)", () => {
    const paths = Object.keys(result.manifest.files);
    assert.ok(!paths.includes("lab/generated/Sources.luau"));
    assert.ok(!paths.some((p) => p.startsWith("lab/cli/")));
    assert.ok(!paths.includes("lab/src/notes.md"));
    assert.ok(!result.xml.includes("must never be packaged"));
  });

  test("script source is escaped XML text, never CDATA, and decodes back to the file text exactly", () => {
    assert.ok(!result.xml.includes("<![CDATA["), "no CDATA opener");
    assert.ok(!result.xml.includes("]]>"), "a literal CDATA terminator must appear only escaped");
    assert.ok(result.xml.includes("]]&gt;"), "the terminator from the fixture is present, escaped");
    assert.ok(!/\r/.test(result.xml), "LF newlines only");
    for (const [rel, entry] of Object.entries(result.manifest.files)) {
      const item = items.get(entry.instancePath);
      assert.ok(item, `${rel} -> ${entry.instancePath}`);
      assert.equal(item.class, entry.className);
      assert.equal(item.props.Source.type, "ProtectedString");
      const onDisk = readFileSync(join(root, ...rel.split("/")), "utf8");
      assert.equal(item.props.Source.value, onDisk, `${rel} round trip`);
    }
    assert.equal(items.get("MarketReservoirLab/src/Util/Special").props.Source.value, SPECIAL_SOURCE);
  });

  test("children are sorted by name at every level and referents are unique, stable-looking ids", () => {
    const seen = new Set();
    for (const [path, item] of items) {
      const names = item.items.map((i) => i.name);
      assert.deepEqual(names, [...names].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)), `children of ${path}`);
      assert.match(item.referent, /^RBX[0-9A-F]{32}$/, path);
      assert.ok(!seen.has(item.referent), `duplicate referent at ${path}`);
      seen.add(item.referent);
    }
    assert.ok(seen.size > 10);
  });

  test("instance paths in the manifest are unique and every one resolves in the parsed tree", () => {
    const instancePaths = Object.values(result.manifest.files).map((e) => e.instancePath);
    assert.equal(new Set(instancePaths).size, instancePaths.length);
    for (const p of instancePaths) assert.ok(items.has(p), p);
  });

  test("manifest entries carry sha256, bytes, instancePath, className; hashes are those of the file bytes", () => {
    for (const [rel, entry] of Object.entries(result.manifest.files)) {
      assert.ok(["sha256", "bytes", "instancePath", "className"].every((k) => k in entry), rel);
      const raw = readFileSync(join(root, ...rel.split("/")));
      assert.equal(entry.sha256, sha256(raw), rel);
      assert.equal(entry.bytes, raw.length, rel);
      assert.match(entry.sha256, /^[0-9a-f]{64}$/);
    }
    assert.deepEqual(Object.keys(result.manifest.files), Object.keys(result.manifest.files).slice().sort());
  });

  test("BuildInfo is a StringValue with {buildId, sourceHash, fileCount, createdFrom} and no timestamp", () => {
    const info = items.get("MarketReservoirLab/BuildInfo");
    assert.equal(info.class, "StringValue");
    assert.equal(info.props.Value.type, "string");
    const parsed = JSON.parse(info.props.Value.value);
    assert.deepEqual(Object.keys(parsed), ["buildId", "sourceHash", "fileCount", "createdFrom"]);
    assert.equal(parsed.createdFrom, "tools/build-plugin.mjs");
    assert.equal(parsed.sourceHash, result.manifest.sourceHash);
    assert.equal(parsed.buildId, result.manifest.buildId);
    assert.equal(parsed.fileCount, Object.keys(result.manifest.files).length);
    assert.equal(parsed.fileCount, result.manifest.fileCount);
    assert.match(parsed.sourceHash, /^[0-9a-f]{64}$/);
    assert.ok(!("stamp" in parsed));
  });

  test("sourceHash is recomputable from the manifest alone and changes when one byte of one file changes", () => {
    assert.equal(computeSourceHash(result.manifest.files), result.manifest.sourceHash);
    const root2 = makeFixture({ "lab/src/Model/Ridge.luau": "return { changed = true }\n" });
    const other = buildPackage({ projectRoot: root2, allowlist: fixtureAllowlist() });
    assert.notEqual(other.manifest.sourceHash, result.manifest.sourceHash);
    assert.notEqual(other.manifest.buildId, result.manifest.buildId);
    assert.notEqual(other.xml, result.xml);
  });

  test("package block records the rbxmx hash so an installed copy can be compared with the manifest", () => {
    assert.equal(result.manifest.package.sha256, sha256(Buffer.from(result.xml, "utf8")));
    assert.equal(result.manifest.package.bytes, Buffer.byteLength(result.xml, "utf8"));
    assert.equal(result.manifest.schema, "mrl-package-manifest-1");
  });

  test("data assets: hourly-original/<SYM> loader ModuleScript with its Chunk children, no collisions", () => {
    for (const sym of ["SPY", "QQQ"]) {
      const loader = items.get(`MarketReservoirLab/DataAssets/hourly-original/${sym}`);
      assert.equal(loader.class, "ModuleScript");
      assert.deepEqual(loader.items.map((i) => `${i.class}:${i.name}`), ["ModuleScript:Chunk001", "ModuleScript:Chunk002", "ModuleScript:Chunk003"]);
      assert.match(loader.props.Source.value, /local chunkNames = \{"Chunk001", "Chunk002", "Chunk003"\}/);
    }
    assert.equal(result.manifest.dataAssets.length, 1);
    assert.deepEqual(
      { group: result.manifest.dataAssets[0].group, loaders: result.manifest.dataAssets[0].loaders, chunks: result.manifest.dataAssets[0].chunks },
      { group: "hourly-original", loaders: 2, chunks: 6 },
    );
  });
});

// ---------------------------------------------------------------------------------------------
// Determinism, stamp, newline handling
// ---------------------------------------------------------------------------------------------

describe("determinism", () => {
  test("two builds of the same tree are byte-identical (xml and manifest)", () => {
    const root = makeFixture();
    const a = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const b = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    assert.equal(a.xml, b.xml);
    assert.equal(a.manifestJson, b.manifestJson);
    assert.ok(Buffer.from(a.xml).equals(Buffer.from(b.xml)));
  });

  test("the output does not depend on where the tree lives or on file creation order", () => {
    const rootA = makeFixture();
    const reversed = Object.fromEntries(Object.entries(BASE_FILES).reverse());
    const rootB = tempDir();
    writeFiles(rootB, reversed);
    makeDataFixture(rootB);
    const a = buildPackage({ projectRoot: rootA, allowlist: fixtureAllowlist() });
    const b = buildPackage({ projectRoot: rootB, allowlist: fixtureAllowlist() });
    assert.equal(a.xml, b.xml);
    assert.equal(a.manifestJson, b.manifestJson);
  });

  test("no timestamp unless --stamp is passed; the stamp lands in BuildInfo and the manifest only", () => {
    const root = makeFixture();
    const plain = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const stamped = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist(), stamp: "2026-10-05T12:00:00Z" });
    assert.ok(!("stamp" in plain.manifest));
    const info = JSON.parse(allItems(parseRbxmx(stamped.xml).roots).get("MarketReservoirLab/BuildInfo").props.Value.value);
    assert.deepEqual(Object.keys(info), ["buildId", "sourceHash", "fileCount", "createdFrom", "stamp"]);
    assert.equal(info.stamp, "2026-10-05T12:00:00Z");
    assert.equal(stamped.manifest.stamp, "2026-10-05T12:00:00Z");
    assert.equal(stamped.manifest.sourceHash, plain.manifest.sourceHash);
    assert.equal(stamped.manifest.buildId, plain.manifest.buildId);
    assert.notEqual(stamped.xml, plain.xml);
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist(), stamp: "" }), /stamp/);
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist(), stamp: "a\nb" }), /stamp/);
  });

  test("CRLF, lone CR and a UTF-8 BOM are normalised to LF text; the manifest still hashes the raw file bytes", () => {
    const raw = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("line1\r\nline2\rline3\n", "utf8")]);
    const root = makeFixture({ "lab/src/Util/Crlf.luau": raw });
    const result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const entry = result.manifest.files["lab/src/Util/Crlf.luau"];
    assert.equal(entry.sha256, sha256(raw));
    assert.equal(entry.bytes, raw.length);
    assert.equal(entry.embeddedSha256, sha256("line1\nline2\nline3\n"));
    const item = allItems(parseRbxmx(result.xml).roots).get("MarketReservoirLab/src/Util/Crlf");
    assert.equal(item.props.Source.value, "line1\nline2\nline3\n");
    assert.ok(!result.xml.includes("\r"));
    assert.ok(!result.xml.includes("\uFEFF"));
  });

  test("XML-illegal control characters and invalid UTF-8 are rejected, not silently dropped", () => {
    const bad = makeFixture({ "lab/src/Util/Ctl.luau": "return 'a\u0001b'\n" });
    assert.throws(() => buildPackage({ projectRoot: bad, allowlist: fixtureAllowlist() }), /illegal XML character/);
    const badUtf8 = makeFixture({ "lab/src/Util/Bin.luau": Buffer.from([0x72, 0xff, 0xfe, 0x0a]) });
    assert.throws(() => buildPackage({ projectRoot: badUtf8, allowlist: fixtureAllowlist() }), /UTF-8/);
  });
});

// ---------------------------------------------------------------------------------------------
// Name mapping and collisions
// ---------------------------------------------------------------------------------------------

describe("instance mapping", () => {
  test("X.luau and X.server.luau in one folder collide", () => {
    const root = makeFixture({ "lab/src/Main.luau": "return {}\n" });
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /collision/);
  });

  test("a file and a directory with the same name collide (directories become Folders)", () => {
    const root = makeFixture({ "lab/src/Util.luau": "return {}\n" });
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /collision/);
  });

  test("X.client.luau and init.luau are refused in lab/ rather than mapped to a misleading name", () => {
    const client = makeFixture({ "lab/src/Gui.client.luau": "return {}\n" });
    assert.throws(() => buildPackage({ projectRoot: client, allowlist: fixtureAllowlist() }), /client/);
    const init = makeFixture({ "lab/src/Util/init.luau": "return {}\n" });
    assert.throws(() => buildPackage({ projectRoot: init, allowlist: fixtureAllowlist() }), /init/);
  });

  test("two data groups or symbols cannot map onto the same instance", () => {
    const root = makeFixture();
    const list = fixtureAllowlist();
    list.dataAssets.push({ ...list.dataAssets[0] });
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /duplicate/i);
    const list2 = fixtureAllowlist();
    list2.dataAssets[0].symbols = ["SPY", "SPY"];
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list2 }), /duplicate/i);
  });
});

// ---------------------------------------------------------------------------------------------
// Allowlist enforcement
// ---------------------------------------------------------------------------------------------

describe("allowlist enforcement", () => {
  test("a hidden file or directory inside an allowlisted directory is skipped, never packaged", () => {
    const root = makeFixture({
      "lab/src/.hidden.luau": "return 'hidden'\n",
      "lab/src/.git/Inner.luau": "return 'hidden dir'\n",
      "lab/tests/.DS_Store": "x",
    });
    const result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    assert.ok(!Object.keys(result.manifest.files).some((p) => p.includes("/.")));
    assert.ok(!result.xml.includes("hidden"));
  });

  test("naming a hidden file explicitly in the allowlist is an error", () => {
    const root = makeFixture({ "lab/src/.hidden.luau": "return 1\n" });
    const list = fixtureAllowlist();
    list.files.push("lab/src/.hidden.luau");
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /hidden/);
    assert.throws(() => validateAllowlist(list), /hidden/);
  });

  test("secret-looking file names (key, secret, token, credential, .env; any case) are refused with an error", () => {
    const names = ["api_key.luau", "MySecret.luau", "TOKEN.luau", "Credentials.luau", "prod.env.luau", "Hotkey.luau"];
    for (const name of names) {
      const root = makeFixture({ [`lab/src/${name}`]: "return 1\n" });
      assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /secret-looking/, name);
    }
    const dirRoot = makeFixture({ "lab/src/keys/Inner.luau": "return 1\n" });
    assert.throws(() => buildPackage({ projectRoot: dirRoot, allowlist: fixtureAllowlist() }), /secret-looking/);
  });

  test("an allowlist entry with a secret-looking name is refused even before the file is looked up", () => {
    const root = makeFixture();
    const list = fixtureAllowlist();
    list.files.push("lab/generated/secret.luau");
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /secret-looking/);
    for (const name of ["key", "secret", "token", "credential", ".env", "Key", "SECRET", "myToken", "credentials.json", "x.ENV"]) {
      assert.equal(isSecretLookingName(name), true, name);
    }
    for (const name of ["Chunk001.luau", "Features.luau", "ConfigData.luau", "NyOffsets.luau"]) {
      assert.equal(isSecretLookingName(name), false, name);
    }
  });

  test("allowlist paths must be project-relative, glob-free, and free of traversal", () => {
    const bad = ["../x.luau", "/abs.luau", "C:/x.luau", "lab\\src\\x.luau", "lab/src/*.luau", "lab/src/./x.luau", "lab//x.luau", "lab/src/{a,b}.luau", "lab/src/x?.luau", ""];
    for (const p of bad) {
      assert.throws(() => assertAllowedPath(p, "test"), /unsafe/, JSON.stringify(p));
    }
    assert.deepEqual(assertAllowedPath("lab/src/Types.luau", "test"), ["lab", "src", "Types.luau"]);
  });

  test("a file outside luauRoot, or a non-.luau explicit entry, is rejected", () => {
    const list = fixtureAllowlist();
    list.files.push("tools/build-plugin.mjs");
    assert.throws(() => validateAllowlist(list), /luauRoot|outside/);
    const list2 = fixtureAllowlist();
    list2.files.push("lab/src/notes.md");
    assert.throws(() => validateAllowlist(list2), /\.luau/);
  });

  test("neverPackage wins: naming Sources.luau or something under lab/cli in the allowlist is an error", () => {
    const root = makeFixture();
    const list = fixtureAllowlist();
    list.files.push("lab/generated/Sources.luau");
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /neverPackage|never be packaged/);
    const list2 = fixtureAllowlist();
    list2.directories.push({ path: "lab/cli", recursive: true });
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list2 }), /neverPackage|never be packaged/);
  });

  test("neverPackage also stops a denied file that a recursive directory scan would otherwise pick up", () => {
    const root = makeFixture();
    const list = fixtureAllowlist();
    list.neverPackage.push("lab/src/Model");
    // lab/src is scanned recursively and contains lab/src/Model/Ridge.luau, which is denied.
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /lab\/src\/Model\/Ridge\.luau is under neverPackage/);
  });

  test("unknown allowlist keys, wrong schema and malformed entries are errors, not ignored", () => {
    assert.throws(() => validateAllowlist({ ...fixtureAllowlist(), directorys: [] }), /unknown/);
    assert.throws(() => validateAllowlist({ ...fixtureAllowlist(), schema: "other" }), /schema/);
    const noRoot = fixtureAllowlist();
    delete noRoot.luauRoot;
    assert.throws(() => validateAllowlist(noRoot), /luauRoot/);
    const badDir = fixtureAllowlist();
    badDir.directories[0].recursive = "yes";
    assert.throws(() => validateAllowlist(badDir), /recursive/);
    const badData = fixtureAllowlist();
    badData.dataAssets[0].expectedChunks = -1;
    assert.throws(() => validateAllowlist(badData), /expectedChunks/);
  });

  test("a missing required file fails with a message naming it, and the error lists every missing path", () => {
    const root = makeFixture();
    rmSync(join(root, "lab/src/Main.server.luau"));
    rmSync(join(root, "lab/generated/NyOffsets.luau"));
    let caught;
    try {
      buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    } catch (err) {
      caught = err;
    }
    assert.ok(caught instanceof PackageError);
    assert.match(caught.message, /^build-plugin: cannot build/);
    assert.match(caught.message, /lab\/src\/Main\.server\.luau/);
    assert.match(caught.message, /lab\/generated\/NyOffsets\.luau/);
    assert.deepEqual([...caught.missing].sort(), ["lab/generated/NyOffsets.luau", "lab/src/Main.server.luau"]);
  });

  test("an optional directory may be absent; a non-optional one may not", () => {
    const root = makeFixture();
    assert.ok(!existsSync(join(root, "lab/fixtures")));
    buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const list = fixtureAllowlist();
    list.directories.push({ path: "lab/missing", recursive: true });
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /lab\/missing/);
  });

  test("non-recursive directories contribute only their own files", () => {
    const root = makeFixture({ "lab/tests/sub/Deep.spec.luau": "return {}\n" });
    const result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    assert.ok(!("lab/tests/sub/Deep.spec.luau" in result.manifest.files));
    assert.ok("lab/tests/Data.spec.luau" in result.manifest.files);
  });
});

// ---------------------------------------------------------------------------------------------
// Data assets
// ---------------------------------------------------------------------------------------------

describe("data assets (fixture)", () => {
  test("hash mismatch against the data manifest is an error", () => {
    const root = makeFixture();
    writeFileSync(join(root, "data/fixture-hourly/roblox/SPY/Chunk002.luau"), "return { tampered = true }\n");
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /sha256/);
  });

  test("a missing chunk file, or a count different from the expectation, is an error", () => {
    const root = makeFixture();
    rmSync(join(root, "data/fixture-hourly/roblox/QQQ/Chunk003.luau"));
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /Chunk003/);
    const root2 = makeFixture();
    const list = fixtureAllowlist();
    list.dataAssets[0].expectedChunks = 40;
    assert.throws(() => buildPackage({ projectRoot: root2, allowlist: list }), /expected 40 chunk/);
    const list2 = fixtureAllowlist();
    list2.dataAssets[0].expectedLoaders = 3;
    assert.throws(() => buildPackage({ projectRoot: root2, allowlist: list2 }), /expected 3 loader/);
  });

  test("a loader that names different chunks than the manifest lists is an error", () => {
    const root = makeFixture();
    const dir = join(root, "data/fixture-hourly");
    const text = loaderText(["Chunk001", "Chunk002", "Chunk009"]);
    writeFileSync(join(dir, "roblox/SPY/init.luau"), text);
    const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    const entry = manifest.files.find((f) => f.path === "roblox/SPY/init.luau");
    entry.sha256 = sha256(text);
    entry.bytes = Buffer.byteLength(text);
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /loader.*chunk|chunkNames/i);
  });

  test("an unexpected file under roblox/<SYM>/ in the data manifest is refused", () => {
    const root = makeFixture();
    const dir = join(root, "data/fixture-hourly");
    const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    manifest.files.push({ path: "roblox/SPY/extra.luau", bytes: 1, sha256: sha256("x") });
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /extra\.luau/);
  });

  test("chunkCount in the data manifest must match the chunks it lists", () => {
    const root = makeFixture();
    const dir = join(root, "data/fixture-hourly");
    const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
    manifest.symbols.SPY.chunkCount = 4;
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /chunkCount/);
  });
});

describe("data assets (real original hourly export, read-only)", () => {
  const dataRel = "data/alpaca-2021-10-04_2026-10-02";
  let list;
  let groups;

  before(() => {
    list = loadAllowlist(join(here, "build-plugin.allowlist.json")).allowlist;
    groups = collectDataAssets(realRoot, list.dataAssets);
  });

  test("the real allowlist requires exactly 2 loaders and 40 chunks and names the original group", () => {
    assert.equal(list.dataAssets.length, 1);
    assert.equal(list.dataAssets[0].group, "hourly-original");
    assert.equal(list.dataAssets[0].root, dataRel);
    assert.deepEqual(list.dataAssets[0].symbols, ["SPY", "QQQ"]);
    assert.equal(list.dataAssets[0].expectedLoaders, 2);
    assert.equal(list.dataAssets[0].expectedChunks, 40);
  });

  test("2 loaders + 40 chunks, with sha256 and bytes equal to the dataset manifest and to the files on disk", () => {
    assert.equal(groups.length, 1);
    const [group] = groups;
    assert.deepEqual(group.symbols.map((s) => s.symbol), ["SPY", "QQQ"]);
    const loaders = group.symbols.map((s) => s.loader);
    const chunks = group.symbols.flatMap((s) => s.chunks);
    assert.equal(loaders.length, 2);
    assert.equal(chunks.length, 40);
    const manifest = JSON.parse(readFileSync(join(realRoot, dataRel, "manifest.json"), "utf8"));
    const expected = new Map(manifest.files.map((f) => [`${dataRel}/${f.path}`, f]));
    for (const rec of [...loaders, ...chunks]) {
      const want = expected.get(rec.relPath);
      assert.ok(want, `${rec.relPath} is listed in the dataset manifest`);
      assert.equal(rec.sha256, want.sha256, rec.relPath);
      assert.equal(rec.bytes, want.bytes, rec.relPath);
      const onDisk = readFileSync(join(realRoot, ...rec.relPath.split("/")));
      assert.equal(sha256(onDisk), want.sha256, `${rec.relPath} on disk`);
    }
    for (const s of group.symbols) {
      assert.equal(s.chunks.length, 20);
      assert.deepEqual(s.chunks.map((c) => c.name), Array.from({ length: 20 }, (_, i) => `Chunk${String(i + 1).padStart(3, "0")}`));
      assert.equal(s.loader.name, s.symbol);
    }
  });

  test("full pipeline on the real data: group/symbol -> DataAssets/hourly-original/<SYM>/ChunkNNN, no collisions", () => {
    const dataOnly = { ...clone(list), directories: [], files: [], required: [] };
    const result = buildPackage({ projectRoot: realRoot, allowlist: dataOnly });
    const items = allItems(parseRbxmx(result.xml).roots);
    for (const sym of ["SPY", "QQQ"]) {
      const loader = items.get(`MarketReservoirLab/DataAssets/hourly-original/${sym}`);
      assert.equal(loader.class, "ModuleScript");
      assert.equal(loader.items.length, 20);
      assert.ok(loader.items.every((c) => c.class === "ModuleScript" && /^Chunk\d{3}$/.test(c.name)));
      assert.match(loader.props.Source.value, /local chunkNames = \{"Chunk001"/);
      assert.match(loader.props.Source.value, /require\(script:WaitForChild\(chunkName\)\)/);
    }
    assert.equal(Object.keys(result.manifest.files).length, 42);
    const instancePaths = Object.values(result.manifest.files).map((e) => e.instancePath);
    assert.equal(new Set(instancePaths).size, 42);
    assert.deepEqual(result.manifest.dataAssets.map((g) => [g.group, g.loaders, g.chunks]), [["hourly-original", 2, 40]]);
    assert.equal(result.manifest.fileCount, 42);
    for (const rel of Object.keys(result.manifest.files)) {
      assert.ok(rel.startsWith(`${dataRel}/roblox/`), rel);
      assert.ok(!/\.(csv|json)$/.test(rel), "csv/raw/json are not embedded");
    }
    const chunk = items.get("MarketReservoirLab/DataAssets/hourly-original/SPY/Chunk001");
    assert.equal(chunk.props.Source.value, readFileSync(join(realRoot, dataRel, "roblox/SPY/Chunk001.luau"), "utf8").replace(/\r\n?/g, "\n"));
  });
});

// ---------------------------------------------------------------------------------------------
// The real lab tree
// ---------------------------------------------------------------------------------------------

describe("real lab tree", () => {
  test("builds when the plugin entry points exist; otherwise fails with a clear message listing only truly missing files", () => {
    const { allowlist } = loadAllowlist(join(here, "build-plugin.allowlist.json"));
    let result;
    try {
      result = buildPackage({ projectRoot: realRoot, allowlist });
    } catch (err) {
      if (!(err instanceof PackageError) || !err.missing) throw err;
      assert.match(err.message, /^build-plugin: cannot build/);
      assert.ok(err.missing.length > 0);
      for (const rel of err.missing) {
        assert.equal(existsSync(join(realRoot, ...rel.split("/"))), false, `${rel} is reported missing but exists`);
        assert.ok(err.message.includes(rel));
      }
      return;
    }
    const items = allItems(parseRbxmx(result.xml).roots);
    assert.equal(items.get("MarketReservoirLab/src/Main").class, "Script");
    assert.equal(items.get("MarketReservoirLab/src/Types").class, "ModuleScript");
    assert.equal(items.get("MarketReservoirLab/generated/ConfigData").class, "ModuleScript");
    assert.ok(!items.has("MarketReservoirLab/generated/Sources"));
    assert.ok(!result.xml.includes("<![CDATA["));
    assert.equal(Object.keys(result.manifest.files).filter((p) => p.startsWith("data/")).length, 42);
  });
});

// ---------------------------------------------------------------------------------------------
// Writing, install path logic, CLI
// ---------------------------------------------------------------------------------------------

describe("output, install and CLI", () => {
  test("writePackage writes the rbxmx and package-manifest.json side by side", () => {
    const root = makeFixture();
    const result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const outDir = tempDir();
    const out = join(outDir, "nested", "MarketReservoirLab.rbxmx");
    const written = writePackage(result, out);
    assert.equal(written.outPath, out);
    assert.equal(written.manifestPath, join(outDir, "nested", "package-manifest.json"));
    assert.ok(readFileSync(out).equals(Buffer.from(result.xml, "utf8")));
    assert.equal(readFileSync(written.manifestPath, "utf8"), result.manifestJson);
    assert.ok(result.manifestJson.endsWith("}\n"));
    assert.ok(!result.manifestJson.includes("\r"));
    assert.equal(JSON.parse(result.manifestJson).package.sha256, sha256(readFileSync(out)));
  });

  test("defaultPluginsDir is %LOCALAPPDATA%/Roblox/Plugins from the injected environment", () => {
    assert.equal(defaultPluginsDir({ LOCALAPPDATA: "X:\\Users\\someone\\AppData\\Local" }), join("X:\\Users\\someone\\AppData\\Local", "Roblox", "Plugins"));
    assert.throws(() => defaultPluginsDir({}), /LOCALAPPDATA/);
  });

  test("installPlugin copies the rbxmx byte-for-byte into an injected directory, creating it and replacing an old copy", () => {
    const src = join(tempDir(), "MarketReservoirLab.rbxmx");
    writeFileSync(src, "<roblox version=\"4\"></roblox>\n");
    const pluginsDir = join(tempDir(), "Roblox", "Plugins");
    const dest = installPlugin(src, pluginsDir);
    assert.equal(dest, join(pluginsDir, "MarketReservoirLab.rbxmx"));
    assert.ok(readFileSync(dest).equals(readFileSync(src)));
    writeFileSync(src, "<roblox version=\"4\"><!-- newer --></roblox>\n");
    installPlugin(src, pluginsDir);
    assert.ok(readFileSync(dest).equals(readFileSync(src)));
    assert.deepEqual(readdirSync(pluginsDir), ["MarketReservoirLab.rbxmx"], "no temp file left behind");
  });

  test("main() builds to --out, writes the manifest, stamps BuildInfo, and installs only into the injected directory", () => {
    const root = makeFixture();
    const allowlistFile = join(root, "allowlist.json");
    writeFileSync(allowlistFile, JSON.stringify(fixtureAllowlist()));
    const outDir = tempDir();
    const local = tempDir();
    const logs = [];
    const res = main(
      ["--root", root, "--allowlist", allowlistFile, "--out", join(outDir, "out.rbxmx"), "--stamp", "run-1", "--install"],
      { env: { LOCALAPPDATA: local }, log: (line) => logs.push(line) },
    );
    assert.equal(res.outPath, join(outDir, "out.rbxmx"));
    assert.ok(existsSync(join(outDir, "out.rbxmx")));
    assert.ok(existsSync(join(outDir, "package-manifest.json")));
    const installed = join(local, "Roblox", "Plugins", "MarketReservoirLab.rbxmx");
    assert.equal(res.installedPath, installed);
    assert.ok(readFileSync(installed).equals(readFileSync(join(outDir, "out.rbxmx"))));
    const manifest = JSON.parse(readFileSync(join(outDir, "package-manifest.json"), "utf8"));
    assert.equal(manifest.stamp, "run-1");
    assert.ok(logs.some((l) => l.includes(manifest.buildId)));
    // without --install nothing is copied
    const local2 = tempDir();
    const res2 = main(["--root", root, "--allowlist", allowlistFile, "--out", join(outDir, "b.rbxmx")], { env: { LOCALAPPDATA: local2 }, log: () => {} });
    assert.equal(res2.installedPath, undefined);
    assert.deepEqual(readdirSync(local2), []);
  });

  test("main() rejects unknown flags and a --stamp without a value", () => {
    const quiet = { env: {}, log: () => {} };
    assert.throws(() => main(["--bogus"], quiet));
    assert.throws(() => main(["--stamp"], quiet));
    assert.throws(() => main(["positional"], quiet));
  });

  test("the CLI exits 0 on success and 1 with a message on a failed build", () => {
    const root = makeFixture();
    const allowlistFile = join(root, "allowlist.json");
    writeFileSync(allowlistFile, JSON.stringify(fixtureAllowlist()));
    const out = join(tempDir(), "cli.rbxmx");
    const ok = spawnSync(process.execPath, [scriptPath, "--root", root, "--allowlist", allowlistFile, "--out", out], { encoding: "utf8" });
    assert.equal(ok.status, 0, ok.stderr);
    assert.ok(existsSync(out));
    rmSync(join(root, "lab/src/Main.server.luau"));
    const bad = spawnSync(process.execPath, [scriptPath, "--root", root, "--allowlist", allowlistFile, "--out", join(tempDir(), "bad.rbxmx")], { encoding: "utf8" });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /Main\.server\.luau/);
  });
});

// ---------------------------------------------------------------------------------------------
// Adversarial review additions
// ---------------------------------------------------------------------------------------------

describe("review: dangling require-by-string targets", () => {
  const DANGLING_SPEC =
    [
      'local Test = require("./Test")', // resolves
      'local Missing = require("../generated/Missing")', // unresolved: no such file in the package
      'local Nope = require("./fixtures/Nope")', // unresolved
      'local Again = require("../generated/Missing")', // duplicate of an entry above: reported once
      '-- local Hidden = require("./InLineComment")', // comment: ignored
      '--[==[ require("./InBlockComment") ]==]', // block comment: ignored
      'local s = "-- not a comment"; local T = require("../generated/AfterString")', // "--" inside a string must not hide the call
      "local long = [[ -- not a comment either ]]; local U = require('./AfterLong')", // nor inside a long string
      '--[==[ require("./InBlockComment") ]==] local V = require("./AfterBlock")', // code resumes after a block comment
      'local a = require("@std/thing")', // alias, not a relative path: out of scope
      "local b = require(script.Parent.Test)", // dynamic: out of scope
      'local c = require("../../Outside")', // climbs above the plugin root
      'local d = require("../src/Data")', // resolves to a Folder, which cannot be required
      "local e = require('./Test')", // single quotes
    ].join("\n") + "\n";

  const withDangling = () => makeFixture({ "lab/tests/Dangling.spec.luau": DANGLING_SPEC });

  test("a fixture whose requires all resolve reports none", () => {
    const result = buildPackage({ projectRoot: makeFixture(), allowlist: fixtureAllowlist() });
    assert.deepEqual(result.manifest.unresolvedRequires, []);
  });

  test("requires that do not resolve to a packaged ModuleScript are listed (sorted, once each); comments and non-relative forms are ignored", () => {
    const result = buildPackage({ projectRoot: withDangling(), allowlist: fixtureAllowlist() });
    assert.deepEqual(result.manifest.unresolvedRequires, [
      { from: "lab/tests/Dangling.spec.luau", require: "../../Outside", target: null },
      { from: "lab/tests/Dangling.spec.luau", require: "../generated/AfterString", target: "lab/generated/AfterString" },
      { from: "lab/tests/Dangling.spec.luau", require: "../generated/Missing", target: "lab/generated/Missing" },
      { from: "lab/tests/Dangling.spec.luau", require: "../src/Data", target: "lab/src/Data" },
      { from: "lab/tests/Dangling.spec.luau", require: "./AfterBlock", target: "lab/tests/AfterBlock" },
      { from: "lab/tests/Dangling.spec.luau", require: "./AfterLong", target: "lab/tests/AfterLong" },
      { from: "lab/tests/Dangling.spec.luau", require: "./fixtures/Nope", target: "lab/tests/fixtures/Nope" },
    ]);
  });

  test("strictRequires turns the list into a build error that names each dangling require", () => {
    assert.throws(
      () => buildPackage({ projectRoot: withDangling(), allowlist: fixtureAllowlist(), strictRequires: true }),
      (err) =>
        err instanceof PackageError &&
        /unresolved require/.test(err.message) &&
        err.message.includes("lab/tests/Dangling.spec.luau") &&
        err.message.includes("../generated/Missing"),
    );
    buildPackage({ projectRoot: makeFixture(), allowlist: fixtureAllowlist(), strictRequires: true });
  });

  test("the unresolved list does not change the rbxmx or the sourceHash", () => {
    const a = buildPackage({ projectRoot: makeFixture(), allowlist: fixtureAllowlist() });
    const b = buildPackage({ projectRoot: makeFixture(), allowlist: fixtureAllowlist(), strictRequires: false });
    assert.equal(a.xml, b.xml);
    assert.equal(a.manifest.sourceHash, b.manifest.sourceHash);
  });

  test("CLI: warns about dangling requires by default and --strict fails the build before writing anything", () => {
    const root = withDangling();
    const allowlistFile = join(root, "allowlist.json");
    writeFileSync(allowlistFile, JSON.stringify(fixtureAllowlist()));
    const logs = [];
    main(["--root", root, "--allowlist", allowlistFile, "--out", join(tempDir(), "w.rbxmx")], { env: {}, log: (l) => logs.push(l) });
    assert.ok(logs.some((l) => /7 unresolved require/.test(l)), logs.join("\n"));
    assert.ok(logs.some((l) => l.includes("../generated/Missing")));
    const outDir = tempDir();
    assert.throws(
      () => main(["--root", root, "--allowlist", allowlistFile, "--out", join(outDir, "s.rbxmx"), "--strict"], { env: {}, log: () => {} }),
      /unresolved require/,
    );
    assert.deepEqual(readdirSync(outDir), []);
  });

  test("real tree: no packaged script requires a file that exists on disk but is left out of the package", () => {
    const { allowlist } = loadAllowlist(join(here, "build-plugin.allowlist.json"));
    let result;
    try {
      result = buildPackage({ projectRoot: realRoot, allowlist });
    } catch (err) {
      if (!(err instanceof PackageError) || !err.missing) throw err;
      return; // required entry points are still being written; the dangling check needs a complete build
    }
    const onDisk = (target) => [".luau", ".server.luau"].some((ext) => existsSync(join(realRoot, ...`${target}${ext}`.split("/"))));
    const leftOut = result.manifest.unresolvedRequires.filter((u) => u.target !== null && onDisk(u.target));
    assert.deepEqual(leftOut, [], "these files exist but the allowlist does not package them, so the spec that requires them cannot load in Studio");
  });
});

describe("review: allowlist and naming hardening", () => {
  test("neverPackage matches case-insensitively (Windows paths are case-insensitive)", () => {
    for (const p of ["lab/generated/sources.luau", "lab/GENERATED/SOURCES.luau"]) {
      const list = fixtureAllowlist();
      list.files.push(p);
      assert.throws(() => validateAllowlist(list), /never be packaged/, p);
    }
    const dirs = fixtureAllowlist();
    dirs.directories.push({ path: "lab/CLI", recursive: true });
    assert.throws(() => validateAllowlist(dirs), /never be packaged/);
    // scan time: a denied folder spelled with another case than on disk still stops the scan
    const list = fixtureAllowlist();
    list.neverPackage.push("lab/src/MODEL");
    assert.throws(() => buildPackage({ projectRoot: makeFixture(), allowlist: list }), /under neverPackage/);
  });

  test("a stamp may not contain characters that are illegal in XML", () => {
    const root = makeFixture();
    for (const stamp of ["a\uFFFEb", "a\uFFFF", "bell\u0007", "del\u007F"]) {
      assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist(), stamp }), /stamp/, JSON.stringify(stamp));
    }
    // legal non-ASCII text is fine and survives
    const ok = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist(), stamp: "run é\u{1F600} <1> & 'x'" });
    const info = JSON.parse(allItems(parseRbxmx(ok.xml).roots).get("MarketReservoirLab/BuildInfo").props.Value.value);
    assert.equal(info.stamp, "run é\u{1F600} <1> & 'x'");
  });

  test("a lab directory called DataAssets collides with the data-assets folder instead of merging into it", () => {
    const root = makeFixture({ "lab/DataAssets/Extra.luau": "return {}\n" });
    const list = fixtureAllowlist();
    list.directories.push({ path: "lab/DataAssets", recursive: false });
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /collision/);
  });

  test("file names with & and ' are escaped in the Name property and parse back unchanged", () => {
    const name = "Tom&Jerry's";
    const root = makeFixture({ [`lab/src/Util/${name}.luau`]: "return 1\n" });
    const result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    assert.ok(result.xml.includes('<string name="Name">Tom&amp;Jerry&apos;s</string>'));
    const item = allItems(parseRbxmx(result.xml).roots).get(`MarketReservoirLab/src/Util/${name}`);
    assert.ok(item);
    assert.equal(item.name, name);
  });
});

describe("review: data manifest checks that must fail independently", () => {
  test("a same-length edit of a chunk is caught by the sha256 check alone", () => {
    const root = makeFixture();
    const file = join(root, "data/fixture-hourly/roblox/SPY/Chunk002.luau");
    const original = readFileSync(file, "utf8");
    const edited = original.replace("1001", "1002");
    assert.equal(edited.length, original.length);
    assert.notEqual(edited, original);
    writeFileSync(file, edited);
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /sha256 mismatch/);
  });

  test("a wrong byte count in the data manifest is caught even when the sha256 is right", () => {
    const root = makeFixture();
    const path = join(root, "data/fixture-hourly/manifest.json");
    const manifest = JSON.parse(readFileSync(path, "utf8"));
    manifest.files.find((f) => f.path === "roblox/QQQ/Chunk001.luau").bytes += 1;
    writeFileSync(path, JSON.stringify(manifest));
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /byte count mismatch/);
  });

  test("the supplemental groups (daily, hourly-combined, hourly-context) are enumerated from their own manifests, not assumed to have twenty chunks", () => {
    const base = "data/alpaca-supplement-2016-01-01_2026-10-02";
    const groups = [
      { dir: "daily-context", symbols: ["SPY", "QQQ"] },
      { dir: "hourly-combined", symbols: ["SPY", "QQQ"] },
      { dir: "hourly-context", symbols: ["IWM", "TLT"] },
    ];
    for (const g of groups) {
      const chunkFiles = (sym) =>
        readdirSync(join(realRoot, base, g.dir, "roblox", sym)).filter((n) => /^Chunk\d{3}\.luau$/.test(n)).length;
      const perSymbol = g.symbols.map((s) => chunkFiles(s));
      const [out] = collectDataAssets(realRoot, [
        {
          group: g.dir,
          root: `${base}/${g.dir}`,
          manifest: "manifest.json",
          symbols: g.symbols,
          expectedLoaders: g.symbols.length,
          expectedChunks: perSymbol.reduce((a, b) => a + b, 0),
        },
      ]);
      assert.deepEqual(out.symbols.map((s) => s.chunks.length), perSymbol, g.dir);
      assert.ok(perSymbol.every((n) => n !== 20), `${g.dir} must not look like the 20-chunk original`);
    }
  });
});

describe("review: install leaves nothing behind on failure", () => {
  test("installPlugin removes its temporary copy when the final rename fails and still reports the error", () => {
    const src = join(tempDir(), "MarketReservoirLab.rbxmx");
    writeFileSync(src, '<roblox version="4"></roblox>\n');
    const pluginsDir = join(tempDir(), "Plugins");
    mkdirSync(join(pluginsDir, "MarketReservoirLab.rbxmx", "blocker"), { recursive: true }); // destination is a non-empty directory
    assert.throws(() => installPlugin(src, pluginsDir));
    assert.deepEqual(readdirSync(pluginsDir), ["MarketReservoirLab.rbxmx"], "no .tmp file left in the Plugins folder");
  });
});

describe("review: links anywhere in an allowlisted path are refused", () => {
  // Directory junctions need no privilege on Windows; a platform that cannot create one skips these cases.
  const junction = (target, path) => {
    try {
      symlinkSync(target, path, "junction");
      return true;
    } catch {
      return false;
    }
  };

  test("a junction as an intermediate directory of an explicit file entry is refused, not followed out of the tree", (t) => {
    const root = makeFixture();
    writeFiles(root, { "outside/Leak.luau": "return 'leaked'\n" });
    if (!junction(join(root, "outside"), join(root, "lab", "gen"))) return t.skip("cannot create a junction here");
    const list = fixtureAllowlist();
    list.files.push("lab/gen/Leak.luau");
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /symbolic link/);
  });

  test("an allowlisted directory that is itself a junction is refused even when it is marked optional", (t) => {
    const root = makeFixture();
    writeFiles(root, { "outside/Leak.luau": "return 'leaked'\n" });
    if (!junction(join(root, "outside"), join(root, "lab", "linked"))) return t.skip("cannot create a junction here");
    for (const optional of [false, true]) {
      const list = fixtureAllowlist();
      list.directories.push({ path: "lab/linked", recursive: true, optional });
      assert.throws(() => buildPackage({ projectRoot: root, allowlist: list }), /symbolic link/, `optional=${optional}`);
    }
  });

  test("a junction inside a scanned directory is still refused", (t) => {
    const root = makeFixture();
    writeFiles(root, { "outside/Leak.luau": "return 'leaked'\n" });
    if (!junction(join(root, "outside"), join(root, "lab", "src", "Linked"))) return t.skip("cannot create a junction here");
    assert.throws(() => buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() }), /symbolic link/);
  });
});

describe("review: ordering and hash scheme pinned independently of the code under test", () => {
  test("children are ordered by instance name, not by file path (folder A sorts before module A.b although 'A.b.luau' < 'A/')", () => {
    const root = makeFixture({ "lab/src/Order/A.b.luau": "return 1\n", "lab/src/Order/A/Inner.luau": "return 2\n", "lab/src/Order/a.luau": "return 3\n" });
    const result = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const order = allItems(parseRbxmx(result.xml).roots).get("MarketReservoirLab/src/Order").items.map((i) => i.name);
    assert.deepEqual(order, ["A", "A.b", "a"]);
  });

  test("sourceHash and buildId follow the documented scheme, recomputed here without the module's own helper", () => {
    const root = makeFixture();
    const { manifest } = buildPackage({ projectRoot: root, allowlist: fixtureAllowlist() });
    const hash = createHash("sha256");
    for (const rel of Object.keys(manifest.files).sort()) {
      const raw = readFileSync(join(root, ...rel.split("/")));
      hash.update(`${rel}\t${sha256(raw)}\t${raw.length}\n`, "utf8");
    }
    assert.equal(manifest.sourceHash, hash.digest("hex"));
    assert.equal(manifest.buildId, `mrl-${manifest.sourceHash.slice(0, 12)}`);
    assert.equal(manifest.sourceHashScheme.includes("path<TAB>sha256<TAB>bytes<LF>"), true);
  });
});
