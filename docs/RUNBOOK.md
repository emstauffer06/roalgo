# Market reservoir lab: how to run and reproduce

Everything below runs locally. No credentials, network access or trading is involved. Commands run from the
project root (`.`) with Node 24 and the pinned Luau CLI
`luau`.

## What runs where

| Layer | Where | What |
|---|---|---|
| Data, features, scaling, ridge, Markov, selection, evaluation, bootstrap | Luau CLI (`lab/cli/*.luau`) on pure modules in `lab/src` | All modelling; the same modules load in Studio |
| Native mechanical reservoir | Roblox Studio Edit mode, local plugin `MarketReservoirLab` | Every physical state: native rails, springs, forces, `WorldRoot:StepPhysics` |
| Orchestration, hashing, transport | Node (`tools/*.mjs`) | Packages data, writes hashed artifacts, enforces the release gates |

Studio and the host exchange data through a local bridge (`tools/bridge-server.mjs`, `127.0.0.1:47621` only).
The plugin steps physics; a pump (`lab/src/Studio/Pump.luau`, run through Studio MCP) moves pages between the
bridge and the plugin. Read `docs/stepping-capability.md` first: in Studio 0.741 `StepPhysics` is applied on a
later frame and drops requests, so the runner verifies every step with two metronome parts.

## Tests

The commands below (except the pure Luau suite) need the downloaded data from the root README's "Getting the data" section. Without data, use `npm test` and `npm run test:luau` from the repository root.

```powershell
& luau --codegen -O2 lab/tests/RunPure.luau        # pure Luau suite
node --test tools/build-plugin.test.mjs tools/prepare-lab.test.mjs tools/validate-results.test.mjs tools/integration.test.mjs
node --test download.test.mjs export-data.test.mjs download-supplement.test.mjs supplement-export.test.mjs prepare-supplement.test.mjs audit-supplement.test.mjs
& luau lab/cli/audit.luau                           # plan section 2.3 counts
```

Studio engine tests run inside the plugin: `tests/RunAll.fromPlugin` (Physics.spec needs real native stepping).

## Studio setup

This lab was driven through the Roblox Studio MCP server (`execute_luau`); without it, run the same snippets from the Studio Command Bar. The plugin built in step 1 embeds your downloaded market data, so it is for local use only: do not publish or share it.

1. Build and install the plugin: `node tools/build-plugin.mjs --strict --install`, then reopen the lab place
   (PlaceId 0, i.e. an unpublished local place file, or any place whose ServerStorage has a Folder `MarketReservoirLabPlace`).
   Studio loads local plugins only at startup. The plugin is inert in any other place.
2. Start the bridge: `node tools/bridge-server.mjs`.
3. In the lab place, through Studio MCP `execute_luau` (Edit DataModel), install the dev helpers once:
   fetch `http://127.0.0.1:47621/devtools`, put the source in `ServerStorage.MarketReservoirLabTools`, then
   `require(ServerStorage.MarketReservoirLabTools:Clone()).sync()` mirrors `lab/` into
   `ServerStorage.MarketReservoirLabDev` (stamped with sha256 attributes).
4. Keep the Studio window in the foreground during long runs; background windows throttle to ~7-12 frames/s.

## Pipeline

```powershell
node tools/run-lab.mjs prepare O14; node tools/run-lab.mjs prepare R50; node tools/run-lab.mjs prepare H14
node tools/write-protocol.mjs                       # frozen before any validation search
node tools/run-lab.mjs streams C1 --profiles O14,R50,H14 --from 2021-10-04T00:00:00Z --to 2023-12-31T00:00:00Z --max-pairs 1200 --presets P1,P2,P3 --drive-grid 0.15,0.3,0.6 --lanes 1 --page 300
#   Studio: Pump.queue("exp-20261005", {"C1"})
node tools/analyze-calibration.mjs C1               # -> calibration.json (inputs only)
node tools/mechanism-jobs.mjs                       # R1-R3 repeatability, SP superposition
#   Studio: Pump.queue("exp-20261005", {"R1","R2","R3","SP"})
node tools/analyze-mechanism.mjs                    # -> mechanism.json
node tools/run-lab.mjs streams D1 --profiles O14,R50,H14 --from 2021-10-04T00:00:00Z --to 2025-01-01T05:00:00Z --presets P1,P2,P3 --drives O14=0.6,R50=0.6,H14=0.6 --lanes 3 --page 600
node tools/run-lab.mjs streams D0 --profiles H14 --from 2016-01-01T00:00:00Z --to 2021-10-04T00:00:00Z --presets P1,P2,P3 --drives H14=0.6 --lanes 8 --page 1200
#   Studio: Pump.queue("exp-20261005", {"D1","D0"})
node tools/run-lab.mjs assemble O14 dev D1; node tools/run-lab.mjs assemble R50 dev D1; node tools/run-lab.mjs assemble H14 dev D0,D1
node tools/run-lab.mjs fit O14; node tools/run-lab.mjs fit R50; node tools/run-lab.mjs fit H14
node tools/run-lab.mjs lock O14; node tools/run-lab.mjs lock R50; node tools/run-lab.mjs lock H14
node tools/run-lab.mjs streams F1 --profiles O14,R50,H14 --from 2025-01-01T05:00:00Z --to 2026-10-03T04:00:00Z --final --lanes 8 --page 1200
#   Studio: Pump.queue("exp-20261005", {"F1"})
node tools/run-lab.mjs assemble O14 final F1; node tools/run-lab.mjs assemble R50 final F1; node tools/run-lab.mjs assemble H14 final F1
node tools/run-lab.mjs predict O14 final; node tools/run-lab.mjs predict R50 final; node tools/run-lab.mjs predict H14 final
node tools/run-lab.mjs manifest                     # freezes the release manifest
node tools/run-lab.mjs evaluate                     # first and only join of final outcomes
node tools/report.mjs
```

Pump status: `CoreGui.MarketReservoirLabPumpStatus` / `MarketReservoirLabQueueStatus` (JSON). Cancel with the
status value's `Cancel` attribute. An interrupted job resumes from its last saved page with `Pump.start` (the
bridge's `/progress`); every saved page is immutable and hashed.

## Gates enforced by the tools

- `streams` refuses development windows that reach 2025-01-01T05:00Z, refuses final windows until every included
  profile is locked, and takes the final preset and drive only from each lock.
- The bridge serves only declared, hash-matching job streams; final rows only for a final job after all locks.
  Studio cannot write locks, ledgers or protocol files.
- `assemble` checks drive, presets, input hashes and stream hashes of every job, and full coverage.
- `lock` checks the model was fitted on the protocol inputs and assembled states, and proves the saved artifact
  reproduces 100 reference predictions through JSON -> Luau within 1e-12.
- `evaluate` requires a frozen release-ready manifest, byte-identical ledgers, and lock-matching model hashes, and
  recomputes every point metric independently in Node.

## Replay for the video

After evaluation: `GET /replay?profile=R50&segment=818` on the bridge returns the preregistered demonstration day;
pass it to `src/UI/Replay` through the plugin mailbox (`runDev` `play`). The board labels the display as a recorded
experiment replay, interpolates motion between saved states and shows realized returns only after their outcome time.
