// Runs every pure Luau spec in the repository with the local Luau CLI (LUAU_EXE, or `luau` on PATH).
// None of these specs needs Roblox Studio or market data. Exit code 1 if any spec fails.
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { LUAU } from "../tools/luau-run.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const specs = ["lab/tests/RunPure.luau"];
for (const dir of ["indicator/tests", "indicator-v2/tests", "indicator-v3/tests"]) {
  for (const name of readdirSync(join(root, dir)).sort()) {
    if (name.endsWith(".spec.luau")) specs.push(`${dir}/${name}`);
  }
}

let failed = 0;
for (const spec of specs) {
  const run = spawnSync(LUAU, [join(root, spec)], { cwd: root, encoding: "utf8", timeout: 300000 });
  const ok = run.status === 0;
  if (!ok) failed++;
  const last = `${run.stdout ?? ""}${run.stderr ?? ""}`.trim().split(/\r?\n/).pop() ?? "";
  console.log(`${ok ? "PASS" : "FAIL"}  ${spec}${last ? `  ${last.slice(0, 100)}` : ""}`);
  if (!ok && run.error) console.log(`      ${run.error.message} (is Luau installed? set LUAU_EXE or put luau on PATH)`);
}
console.log(`\n${specs.length - failed}/${specs.length} Luau spec files passed (Luau CLI: ${LUAU})`);
process.exitCode = failed ? 1 : 0;
