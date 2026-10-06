// Deterministic JSON-value -> Luau literal serializer shared by the lab's Node generators.
// Object keys are emitted in sorted order; numbers use JS shortest round-trip text (exact for doubles).
export function toLuau(value, indent = "") {
  const next = indent + "\t";
  if (value === null || value === undefined) return "nil";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error(`toLuau: non-finite number ${value}`);
    return Object.is(value, -0) ? "-0" : String(value);
  }
  if (typeof value === "string") return luauString(value);
  if (Array.isArray(value)) {
    if (value.length === 0) return "{}";
    if (value.every((v) => typeof v === "number")) return `{ ${value.map((v) => toLuau(v)).join(", ")} }`;
    return `{\n${value.map((v) => `${next}${toLuau(v, next)},`).join("\n")}\n${indent}}`;
  }
  const keys = Object.keys(value).sort();
  if (keys.length === 0) return "{}";
  return `{\n${keys.map((k) => `${next}${luauKey(k)} = ${toLuau(value[k], next)},`).join("\n")}\n${indent}}`;
}

export function luauString(s) {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (c < 32 || c === 127) out += `\\${c}`;
    else out += ch;
  }
  return out + '"';
}

function luauKey(k) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && !RESERVED.has(k) ? k : `[${luauString(k)}]`;
}

const RESERVED = new Set([
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
  "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "continue",
]);
