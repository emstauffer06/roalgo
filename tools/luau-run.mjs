// Runs a Luau CLI script with the local Luau binary (see resolveLuau).
// The script prints "@@JSON <json>" once (its result) and optionally many "@@ROW <json>" lines (records).
// Any other stdout line is a log line.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { delimiter, join } from "node:path";

// The Luau CLI: LUAU_EXE when set, otherwise the first `luau` (luau.exe on Windows) found on PATH.
export function resolveLuau(name = process.env.LUAU_EXE || "luau") {
  if (existsSync(name)) return name;
  const exts = process.platform === "win32" ? [".exe", ""] : [""];
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    for (const ext of exts) {
      const candidate = join(dir, name + ext);
      if (dir && existsSync(candidate)) return candidate;
    }
  }
  return name;
}

export const LUAU = resolveLuau();

export function luauIdentity() {
  if (!existsSync(LUAU)) throw new Error(`Luau CLI missing at ${LUAU}`);
  return { path: LUAU, sha256: createHash("sha256").update(readFileSync(LUAU)).digest("hex") };
}

export function runLuau(script, args = [], { cwd, codegen = true, onLog, onRow } = {}) {
  return new Promise((resolve, reject) => {
    const argv = [...(codegen ? ["--codegen", "-O2"] : []), script, "-a", ...args.map(String)];
    const child = spawn(LUAU, argv, { cwd, windowsHide: true });
    const rows = [];
    const logs = [];
    let result = null;
    let err = "";
    let carry = "";
    const handle = (line) => {
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line.startsWith("@@ROW ")) {
        const rec = JSON.parse(line.slice(6));
        if (onRow) onRow(rec);
        else rows.push(rec);
      } else if (line.startsWith("@@JSON ")) {
        if (result !== null) throw new Error("two @@JSON results");
        result = JSON.parse(line.slice(7));
      } else if (line.length) {
        logs.push(line);
        if (onLog) onLog(line);
      }
    };
    child.stdout.on("data", (b) => {
      const text = carry + b.toString("utf8");
      const lines = text.split("\n");
      carry = lines.pop();
      try {
        for (const l of lines) handle(l);
      } catch (e) {
        child.kill();
        reject(e);
      }
    });
    child.stderr.on("data", (b) => (err += b.toString("utf8")));
    child.on("error", reject);
    child.on("close", (code) => {
      try {
        if (carry) handle(carry);
      } catch (e) {
        return reject(e);
      }
      if (code !== 0) return reject(new Error(`luau ${script} exited ${code}\n${err}\n${logs.slice(-40).join("\n")}`));
      if (result === null) return reject(new Error(`luau ${script} printed no @@JSON result\n${logs.slice(-40).join("\n")}`));
      resolve({ result, rows, logs });
    });
  });
}
