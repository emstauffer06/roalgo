// Canonical JSON and SHA-256 for model/config/artifact hashes (plan Task 5, "Concrete export path").
// Shared helper; Node 24 built-ins only.
//
// Canonical form:
//   * object keys sorted recursively by Unicode code point (identical to UTF-8 byte order and to the key order
//     lab/src/Util/Json.luau emits), arrays kept in order, no insignificant whitespace;
//   * numbers in ECMAScript shortest round-trip form (as JSON.stringify writes them; -0 is written as 0);
//   * strings escaped exactly as JSON.stringify escapes them;
//   * NaN/Infinity, undefined, functions, symbols, BigInt, sparse arrays, cycles, lone surrogates and non-plain
//     objects (Date, Map, class instances) are rejected rather than silently converted.
// The hash is SHA-256 over the UTF-8 bytes of the canonical text, as lowercase hex.
import { createHash } from "node:crypto";

export function compareCodePoints(a, b) {
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

function fail(msg) {
  throw new Error(`canonical-json: ${msg}`);
}

function isPlainObject(v) {
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

function encode(value, path, ancestors) {
  if (value === null) return "null";
  switch (typeof value) {
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) fail(`non-finite number at ${path}`);
      return JSON.stringify(value);
    case "string":
      if (!value.isWellFormed()) fail(`lone surrogate in string at ${path}`);
      return JSON.stringify(value);
    case "object":
      break;
    default:
      fail(`unsupported ${typeof value} at ${path}`);
  }
  if (ancestors.has(value)) fail(`cycle at ${path}`);
  ancestors.add(value);
  let out;
  if (Array.isArray(value)) {
    const parts = [];
    for (let i = 0; i < value.length; i++) {
      if (!(i in value)) fail(`sparse array at ${path}[${i}]`);
      parts.push(encode(value[i], `${path}[${i}]`, ancestors));
    }
    out = `[${parts.join(",")}]`;
  } else {
    if (!isPlainObject(value)) fail(`non-plain object at ${path}`);
    if (Object.getOwnPropertySymbols(value).length > 0) fail(`symbol keys at ${path}`);
    const keys = Object.keys(value).sort(compareCodePoints);
    const parts = [];
    for (const k of keys) {
      if (!k.isWellFormed()) fail(`lone surrogate in key at ${path}`);
      parts.push(`${JSON.stringify(k)}:${encode(value[k], `${path}.${k}`, ancestors)}`);
    }
    out = `{${parts.join(",")}}`;
  }
  ancestors.delete(value);
  return out;
}

export function canonicalJson(value) {
  return encode(value, "$", new Set());
}

export function sha256Hex(data) {
  const bytes = typeof data === "string" ? Buffer.from(data, "utf8") : data;
  return createHash("sha256").update(bytes).digest("hex");
}

export function canonicalSha256(value) {
  return sha256Hex(canonicalJson(value));
}
