// Spring indicator runner CLI (contract spring-indicator-contract.md, Runner contract; handover sections 11 and 13).
//   node run-spring-indicator.mjs --manifest <path> --protocol spring-consensus-v1 [--out-dir results]
//        [--reports-dir spring-runs] [--timeout-ms <n>] [--keep-run-dir]
// Verifies the pinned v2 capture, runs the real Luau SpringState/SpringStudy modules with luau.exe (no --codegen),
// writes a write-once result to <out-dir>/RoAlgoV3_spring_v1_<ms>.json (sha256-referenced parts above 16 MB) and
// <reports-dir>/<id>/report.{json,md}, then re-verifies the inputs. Never starts Studio and never steps physics.
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {parseCliArgs, runSpringIndicator} from './spring-runner-lib.mjs';

export async function main(argv = process.argv.slice(2)) {
  const options = parseCliArgs(argv);
  const report = await runSpringIndicator({...options, onProgress: message => console.error('[spring] ' + message)});
  console.log(JSON.stringify({
    status: report.status,
    runId: report.runId,
    result: {path: report.result.path, sha256: report.result.sha256, bytes: report.result.bytes, chunked: report.result.chunked,
      parts: report.result.parts.map(p => ({path: p.path, sha256: p.sha256, bytes: p.bytes}))},
    reportDir: report.reportDir,
    inputsUnchangedAfterWrite: report.postWriteVerification.status === 'unchanged',
    newNativeSteps: report.provenance.newNativeSteps,
  }, null, 2));
  return report;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url)
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
