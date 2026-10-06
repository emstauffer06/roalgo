# Spring Indicator — frozen build contract (spring-consensus-v1)

Written 2026-10-05, before any spring score, intent or P&L was computed on history. It sharpens the handover
`docs/superpowers/plans/2026-10-05-spring-driven-indicator-handover.md` (internal handover, not included)
(read it first). Where this file and the handover differ, this file wins; every difference is listed in section 1 with
its reason. A later change to any protocol value is a new protocol version, never an edit of this one. Any code change
made after the first real-data run must be logged with its justification in the run report ("post-run changes").

Backups of every file the build may change: `backups/pre-spring-20261005/` (with `BACKUP-SHA256.tsv` and the
pre-build hash snapshot `hashes-before.tsv`). Paths below are relative to `indicator-v3` unless absolute.

## 1. Decisions that resolve handover ambiguities (measured facts in brackets)

| # | Topic | Decision |
|---|---|---|
| D1 | Calibration set | Coupled variant, training partition (`bar.t < split.trainEndT`), valid samples whose **segment position >= 12** (post-warm-up; the observations that can count toward confirmation). [n = 1513; records 1-11 are the startup transient after the reset at record 1.] Std is the **population** std (divide by n), as in `Learning.luau`; RMS = sqrt(mean^2 + std^2). |
| D2 | Frozen-state ablation | The first sample of the D1 calibration set (record 12), repeated for every row. |
| D3 | Fast-bank structural tilt | Protocol kept exactly as the handover wrote it. Disclose, do not fix: Fast nodes 1/4/7 carry +0.12 x rangeActivity (strictly positive), Medium 11/14 carry -0.08 x rangeActivity, Slow 17/20/23 carry +0.12 x regimeStress (training mean about -1.45). [Training: Fast bank mean +0.0695, 65.6% positive; total score positive on 61.0% of rows.] The report must publish the bank means/positive shares, the positive/negative setup counts, and the long/short split of coupled-vs-zero action differences. |
| D4 | Exit bar and cooldown | Any position close (next-open CLOSE fill, stop, target, stop_gap) makes that observed bar the exit bar: `exitedThisBar=true`, `barsSinceExit=0`. `barsSinceExit` counts completed observed bars since the most recent exit bar. A never-exited ledger has `barsSinceExit=nil` (no cooldown); JSON omits it. Entries are blocked at barsSinceExit 0,1,2; confirmation may begin at 3; earliest entry 4. |
| D5 | Ledger rejects | `stepIntent` never asserts on a well-formed intent it cannot execute; it overrides to HOLD and records why: BUY/SELL while positioned -> `rejected_entry_while_positioned`; BUY/SELL on an exit bar -> `rejected_exited_this_bar`; CLOSE while flat -> `rejected_close_while_flat`. A malformed intent (bad action/source/type, availableT mismatch) or an error inside `decide` is a programming error: assert/propagate. |
| D6 | Risk context | `riskContext = {volatility = record.feature.volatility, ready = record.feature.ready}`. Built only by SpringStudy, passed only to Execution. Entry blocks (override to HOLD, source `risk`): not ready -> `risk_not_ready`; volatility non-finite or < 0 -> `invalid_risk_volatility`; equity <= 0 -> `equity_exhausted`. [feature.ready is false only on records 1-11.] |
| D7 | Invalid physics state | The physical wrapper returns `{action="CLOSE", source="risk", reason="invalid_physics_state"}` when positioned and the sample is invalid; HOLD with reason `invalid_physics_state` when flat. Execution recognises it by exactly that triple. |
| D8 | Override priority (position still open after intrabar barriers) | `invalid_physics_state` > `timeout` > the intent. Row records `riskConditions` (all that held, in that order), `primaryReason`, `overridden`, and the unmodified pre-override `intent`. `decide` is called exactly once per bar, after fills and barriers, even when an override will apply. |
| D9 | signalT | Intent mode takes `signalT = intent.availableT` and asserts it equals `bar.availableT` (or `bar.t + 300` when the bar has no availableT). At fill time intent mode asserts `pending.signalT <= bar.t`. Forecast mode is unchanged (hard-coded `bar.t + 300`). |
| D10 | Ledger mode | A ledger is either forecast mode (`step`) or intent mode (`stepIntent`); mixing asserts. All spring runs use the **continuation** policy defaults (fee 1 bp, slippage 1 bp, borrow 3%/yr, stop 2 vol, target 3 vol, min distance 0.001, max hold 24). The no-trade comparator is `decide -> HOLD`, not `policyId="no_trade"`. |
| D11 | Forecast shape preserved | Forecast-mode rows, fills, trades and summary keep exactly their current key sets and values (the 26 Execution, 23 Learning, 15 Study tests stay green unchanged). New keys appear only in intent mode. |
| D12 | Gaps | [0 intraday gaps, 29 overnight boundaries, `feature.reset` true only at record 1.] Segment break = `reset` or (same `day` and `t - prevT > 300`). Overnight alone is not a break. Missing-interval behaviour is demonstrated by fixtures only; the report says history never exercises it. |
| D13 | Allowed metadata | SpringState copies only: `bar.t`, `bar.availableT`, `bar.day`, `feature.reset` (the single documented exception from the feature table: one boolean), and the 48 x/v values. Nothing else from `bar`/`feature`/`states.*.nodes` (never `drive`, `force`, `energy`, `banks`). |
| D14 | Rest geometry | No absolute rest positions are saved. Capture rest = origin + (0, y_i, z_i) with restX = 0. The replay uses a declared display origin + (visualScale * D * x_i, y_i * layoutScale, z_i * layoutScale) and states "rest offsets derived from saved config; capture origin not saved". |
| D15 | Capture provenance | Record `manifest.sourceHashes` as the capture source. Do not hash on-disk `indicator-v2/src/Engine|App|PhysicsView.luau` as capture source (3 of 14 were edited after capture). Pin manifest SHA `bd4ef4f0...8b38828`, the 5 checkpoint SHAs from `manifest.cacheChunks`, and `_source.json` (`ecbee1e2...`, from indicator-v2/VERIFICATION.md:15) as verified-unchanged inputs. |
| D16 | Fixtures module | Keep the handover name `tests/SpringFixtures.luau`; it ships with the plugin like the existing probes, so the Studio synthetic fixture scene can use it. Fixtures are synthetic and labelled so everywhere. |
| D17 | Spec style | Every new `*.spec.luau` is self-running under `luau.exe <file>`: `pcall(require, "../src/X")`, `test(name, fn)` printing `PASS name`, and a final `print("<Suite>: N tests passed")`; any failure raises (non-zero exit). No return-a-function specs (they pass silently with 0 tests). |
| D18 | Output text | Luau-emitted JSON is ASCII only (escape non-ASCII as \uXXXX); the runner decodes stdout with a StringDecoder. Luau source may contain UTF-8 UI strings. All new files use LF line endings. |
| D19 | Luau execution mode | The runner executes Luau with no `--codegen` flags (same mode as the specs). |
| D20 | Studio scene | `Workspace.RoAlgoSpringReplay` is a separate, anchored, non-colliding model near spawn, not overlapping the v2 rigs (they span x -2048..-1312, y 80..1360, z -896..896; spawn view at (0,32,0)). It carries `FocusPosition`, `ViewPosition`, `ViewFieldOfView` attributes. It does not hide the v2 presentation by default (separate location, no conflicting diagram). Independent runs draw no coupling connectors (the recorded independent rig had 0 couplings). |
| D21 | Spring panel | A separate docked ScreenGui `RoAlgoSpringPanel` visible together with the 3D replay (the 1260x1000 terminal is full and collapses on framing). Entering spring mode collapses the main dashboard; exiting restores it. |
| D22 | Busy semantics | Spring playback never sets `status.busy`. `stop` also pauses playback. While spring mode is active, `run`, `replay`, `load`, `variant`, `selectFold`, `selectConfiguration` return false with a message. `destroy` stops playback and removes the replay model and panel. |
| D23 | Labels | Node text: `<name> · dominant input: <driveNames[dominantChannel]>` using `manifest.featureInfo.driveNames` (`trend, immediateReturn, rangeActivity, volume, peerRelative, hourlyContext, dailyTrend, regimeStress`). Non-voting nodes say "visible, not a direct vote". The report discloses hourlyContext = equal-weight SPY/QQQ/IWM/TLT hourly return with TLT unflipped, and that the range channel enters voting nodes through their minor projection terms. |
| D24 | Sample id | `"<variant>:<recordIndex>"`, recordIndex 1-based over the 2268 records. |
| D25 | Camera must see the motion axis | Measured in a 2026-10-05 playtest: the v2 showcase view (ViewPosition (0,32,0) -> FocusPosition (-1536,720,0)) looks straight down the rail/displacement axis, so 50-stud spring motions are invisible from it; looking along the rows stacks all 8 nodes. The replay's view attributes must put the displacement axis across the screen (an oblique view such as camera (-1000,1700,-1450) -> (-1520,1000,-250) relative to the v2 layout showed motion, banks and couplings clearly). A spec checks that the view direction is at least 45 degrees from the displacement axis. The view is an initial framing only: never hold, lock or re-apply the camera every frame, in Edit or in a playtest (owner request, 2026-10-05: "when it's running can the camera not be locked"); the viewer must keep free mouse orbit/zoom. In a playtest use `CameraType.Custom` with an anchored part of the replay as `CameraSubject` and a generous `CameraMaxZoomDistance`. |

## 2. Data facts (measured 2026-10-05)

- Manifest `../indicator-v2/results/RoAlgoV2_SPY_1791205420530.json`; checkpoints `_states_0001..0005.json` each `{records, firstIndex, lastIndex, native, split, ...}`.
- Record: `{bar={t,o,h,l,c,v,n,vwap,label,day,minute,availableT,contexts}, feature={raw,names,drive,volatility,ready,reset,regime,...}, states={coupled|independent|numeric = {vector[51], names[51], nodes[24]={x,v,drive,force,bank}, banks[3], energy}}}`.
- Vector layout: `x_i = vector[i]` (i=1..24), `v_i = vector[24+i]`, bank energies `vector[49..51]` (Fast, Medium, Slow). Names derive from `native.config.nodes[i].name`; describe() must rebuild the 51 expected names from config and require equality for all three variants.
- `manifest.native.config`: `nodes[24]={index,name,bank,column,omega,k,c,zeta,mass,y,z,projection[8]}`, `edges[37]={a,b,k,c,dy,dz,freeLength,...}`, `D=64`, `spacing`, `bankNames`, `bankChannels`. Every projection has one +0.72 dominant term (L1 = 1).
- Directional nodes and dominant channels (verified 0 mismatches): Fast {1,4,7} immediateReturn; Medium {9,12,15} trend, {11,14} hourlyContext; Slow {17,20,23} dailyTrend, {19,22} trend.
- `manifest.split = {trainEndT=1734445800, validationEndT=1735050600, testStartT=1735050600}`: training `t < trainEndT` (1524 rows, 20 sessions, 2024-11-18..12-16), validation `trainEndT <= t < validationEndT` (390 rows, 5 sessions), evaluation `t >= testStartT` (354 rows, 5 sessions).
- `bar.availableT == bar.t + 300` on 2268/2268 rows; every variant vector finite.
- Label-free calibration preview (coupled, training): 0 of 26 directional coordinates dropped; clipping only on some v coordinates (max 0.66%); eligible nodes per bank 3/5/5; entry about 0.1129 (inside [0.10, 0.35]), exit about 0.0508, bankDeadband about 0.0282. The Luau implementation is authoritative; these are feasibility numbers only.

## 3. Module contracts

All new modules use the dual require pattern `local X=if script then require(script.Parent.X) else require("./X")`.
No module below may require Engine, VerifiedStepper, Mechanics, PhysicsView, Learning or Features.

### SpringState (`src/SpringState.luau`)
```lua
SpringState.describe(nativeConfig, stateNames, driveNames, protocol) --> descriptor (deep-frozen)
-- descriptor = {schema="spring-v2-descriptor-1", nodeCount=24, D, spacing,
--   nodes={ {index,name,bank,bankName,omega,y,z,projection={8},dominantChannel,dominantName,dominantCoefficient,directional} x24 },
--   edges={ {a,b} x37 }, banks={ {name, nodes={...8}, directional={...}} x3 }, directional={13 ids},
--   driveNames={8}, xIndex(i)=i, vIndex(i)=24+i (stored as arrays) }
-- Rejects (error with reason): node count ~= 24, banks not 1-8/9-16/17-24, stateNames ~= expected 51 names,
-- a declared directional node whose dominant term is not +0.72 on a declared directional channel,
-- a non-declared node in a bank whose dominant channel is directional, v3-shaped input (59/107 names, 48 nodes).
SpringState.fromRecord(record, variant, descriptor, sampleId) --> sample
-- sample = {id, t, availableT, day, reset, valid, invalidReason, x={24}, v={24}}  (fresh tables, not frozen)
-- valid=false (with invalidReason) for missing variant, names mismatch, non-finite x/v, availableT ~= t+300.
-- No reference to record/bar/feature/states is reachable from sample.
SpringState.synthetic(descriptor, id, t, availableT, day, reset, x, v) --> sample  -- for zero/frozen/fixtures; copies x/v
```

### SpringPolicy (`src/SpringPolicy.luau`) — shared by physical and baseline callers
```lua
SpringPolicy.segmentBreak(prevObservation, observation) --> boolean   -- D12; asserts t strictly increasing
SpringPolicy.new(thresholds, protocol, source) --> policy   -- thresholds={entry,exit,bankDeadband}; source "physics"|"baseline"
policy:step(diagnostics, observation, positionContext) --> SignalIntent
-- diagnostics: {valid, reason, score, bankScores={3}, nodeContributions={24}?, ...}; must not be a market record.
-- observation: {id, t, availableT, day, reset}
-- positionContext: {position=-1|0|1, pending=boolean, exitedThisBar=boolean, barsSinceExit=number?}
policy:resetBoundary()   -- ledger boundary: clears entry confirmation and exit counters; keeps warm-up count
policy:state() --> {warmup, posConfirm, negConfirm, longExit, shortExit}  -- serializable snapshot
-- SignalIntent = {action="BUY"|"SELL"|"CLOSE"|"HOLD", source="physics"|"risk"|"baseline", reason, availableT, sampleId,
--   diagnostics = {score, bankScores, nodeContributions?, setup="positive"|"negative"|"none", state=policy:state(), blocked=string?}}
```
Rules (handover 6.3, exact): segment break or invalid diagnostics -> warm-up 0 and all counters cleared (invalid while positioned -> risk CLOSE, D7). Valid -> warm-up += 1. Positive setup: `score >= entry` and at least 2 banks `>= bankDeadband`; negative is sign-reversed. Long: CLOSE when `score <= exit` on 2 consecutive observations (`physics_loss_of_conviction`) or at least 2 banks `<= -bankDeadband` on one observation (`physics_bank_reversal`); short symmetric (`score >= -exit`, banks `>= bankDeadband`). Exit counters run regardless of warm-up and reset when flat. Flat: entries blocked (confirmation reset, reason `pending` / `exited_this_bar` / `cooldown`) when pending, exitedThisBar, or barsSinceExit in {0,1,2}; while warm-up < 12 confirmation stays 0 (`warmup`); at warm-up >= 12 a positive setup increments posConfirm and zeroes negConfirm (and vice versa; no setup zeroes both); posConfirm >= 2 -> BUY (`confirmed_positive_setup`), negConfirm >= 2 -> SELL (`confirmed_negative_setup`); emitting an entry zeroes both counters. While positioned, entry counters stay 0. Same-observation reversal is impossible (no entry while positioned).

### SpringSignals (`src/SpringSignals.luau`) — physical scorer; sees only samples
```lua
SpringSignals.calibrate(trainingSamples, descriptor, protocol) --> calibration (deep-frozen)
-- Uses only valid samples at segment position >= 12 (D1), population std (D1), drop rule, clip counts.
-- calibration = {available, unavailableReason?, n, firstSampleId, lastSampleId, coordinates={ {node, kind="x"|"v", mean, std, rms, active, clipFraction} },
--   eligible={bank -> {node ids}}, thresholds={quantile, unclamped, entry, exit, bankDeadband, rank, n}, protocolId}
SpringSignals.score(sample, calibration) --> diagnostics
-- {valid, reason?, zX={24}, zV={24} (0 when inactive/non-voting), nodeScores={24}, nodeContributions={24}, bankScores={3}, score, clipped=count}
-- sum(nodeContributions) == score within 1e-12; zero sample -> score 0 exactly.
SpringSignals.new(calibration, protocol) --> machine
machine:step(sample, positionContext) --> SignalIntent    -- score(sample) then SpringPolicy; source "physics"
machine:resetBoundary()
```
Unavailable calibration (fewer than 100 samples, a bank with fewer than 2 eligible nodes) -> every intent is HOLD with an explicit reason; never a market fallback.

### Execution (`src/Execution.luau`)
```lua
Execution:stepIntent(bar, riskContext, decide) --> row   -- intent mode (D10)
```
Order: validate bar -> gap borrow -> fill prior pending at open (intent mode asserts signalT <= bar.t) -> intrabar barriers (stop-first) -> build positionContext -> `decide(positionContext)` once -> resolve (D5-D8) -> set pending -> mark -> row. Shared ledger mechanics are refactored into private helpers used by both `step` and `stepIntent`; there is one copy of fee, slippage, borrow, gap and barrier accounting.
Intent-mode row = every forecast row key (`signal` is the final action) plus `mode="intent"`, `signalSource`, `primaryReason`, `riskConditions={...}`, `overridden`, `intent` (copy of decide's return, pre-override), `positionContext` (copy), `pending` (copy of the order created this bar, or nil), `exitedThisBar`, `barsSinceExit`.
Intent-mode fills add `source`, `sampleId`, `intentReason` (barrier fills: `source="risk"`, `signalT=nil`); short cover stays `action="CLOSE", side="BUY"`. Intent-mode trades add `entrySource`, `entrySampleId`, `exitSource`, `exitSampleId`, `exitSignalT`. Intent-mode `result().summary` adds only `mode="intent"`.
Timeout: `holdBars >= maxHoldBars` (the entry bar counts as 1) -> risk CLOSE `timeout`, exactly the existing rule, now in the shared path.

### SpringStudy (`src/SpringStudy.luau`) — phase 2
```lua
SpringStudy.evaluate(records, split, descriptor, protocol) --> springResult   -- schema "roalgo-spring-indicator-v1"
SpringStudy.validateResult(result) --> ok, err      -- strict; used by App.loadSpring
SpringStudy.runs(result) --> { {id, kind, label, header, rowCount} }
SpringStudy.displayRow(result, runId, index) --> displayRow   -- pure expansion of stored rows
```
Runs: `coupled` (recorded_native), `zero` (artificial_intervention), `frozen` (artificial_intervention), `independent` (recorded_native, coupling removed), `numeric` (numerical), `ema_baseline` (market_baseline), `no_trade` (no_trade). Each run: three partition ledgers (training = `training_retrospective`, validation, evaluation; each starts flat; the policy machine is warmed on all earlier rows with a flat context and intents discarded, then `resetBoundary()`), plus one continuous `full_history_development` ledger whose rows drive the replay. Fresh policy machine and ledger for every ledger; zero/frozen states supplied for every row including warm-up history.
EMA baseline (handover section 8): close-to-close returns, EMAs spans 3/12/48 (`alpha = 2/(span+1)`, initialised at the first valid return), reset on segment break, training-only population std about zero with the same drop/clip rule, bank score `clamp(EMA/std,-5,5)/5`, equal weights, its own D1-membership 0.65 quantile entry with the same bounds/ratios, then SpringPolicy with source `baseline`.
Evidence: `{implementationStatus, physicsDependence, physicsDependenceCounts, marketEvidence="development_only_no_fresh_holdout"}`; history_verified needs at least one emitted historical action that differs between coupled and zero (count published). Training-partition P&L never enters post-training totals.

### displayRow (what the replay and panel consume)
```lua
displayRow = {
  index, t, availableT, label, day, partition = "training_retrospective"|"validation"|"evaluation",
  runId, runKind = "recorded_native"|"artificial_intervention"|"numerical"|"market_baseline"|"no_trade"|"synthetic_fixture",
  runLabel, header, sampleId,
  x = {24}?, v = {24}?,                       -- nil for market_baseline and no_trade
  diagnostics = {valid, reason?, score?, bankScores={3}?, nodeContributions={24}?},
  thresholds = {entry, exit, bankDeadband},
  policy = {setup, warmup, posConfirm, negConfirm, longExit, shortExit, blocked?},
  intent = {action, source, reason},          -- pre-override
  final = {action, source, reason, overridden, riskConditions={...}},
  pending = {action, source, reason, signalT}?,
  position, holdBars, equity, stop?, target?,
  executions = { {t, action, side, price, reason, source?, signalT?} },
  evidence = {implementationStatus, physicsDependence, marketEvidence},
}
```
Headers: recorded native = "Recorded native physics · 5-minute observations · no live simulation."; zero/frozen = "Artificial state intervention · not a recording"; numeric = "Numerical comparator · not native physics"; ema_baseline = "Market-only baseline · no physical input"; no_trade = "No-trade baseline · no physical input"; fixtures = "Synthetic fixture · not historical evidence".

### SpringReplayView (`src/SpringReplayView.luau`)
```lua
SpringReplayView.mount(parent, descriptor, options) --> replayView   -- options: {origin?, visualScale?, layoutScale?, Instance?, showHeader?} (Instance factory injectable for tests)
replayView:update(displayRow)    -- moves anchored markers, colours contributions, sets header/labels; atomic
replayView:destroy()
```
Header card (owner request, 2026-10-05, "take this off"): the floating Header BillboardGui above the grid is built and kept current but `Enabled=false` unless `options.showHeader`; the provenance header and the interpolation note stay visible in SpringPanel.
Anchored, `CanCollide=false`, `CanQuery=false`, `CanTouch=false` parts; Beams between Attachments for connectors (no constraints, no forces); labels BillboardGui `MaxDistance=0` (never fade with distance), `AlwaysOnTop=true`. Label style (owner request, 2026-10-05, supersedes the handover's "opaque"): compact cards at about 75% of the v2 112x38 px size (about 84x29 px), card background about 35% transparent, text about 15% transparent, outline about 40% transparent. Node-to-anchor "tail" connectors clearly visible: Beam transparency about 0.45 or lower and width at least 2.5 studs at the v2 scale (the v2 values 0.65 / 2 were too faint). Stretch colouring (owner request, 2026-10-05, "for more showcase-y ness"): every connector's colour encodes how stretched its spring is in the displayed recorded row, with a visible legend "spring colour = stretch". Anchor tails: signed stretch from the recorded x_i (in the restored v2 presentation the anchors sit 512 studs on the -X side, measured 2026-10-05: coupled Fast07 at +51.6 studs of x had its anchor spring 51.6 studs longer than FreeLength, so stretch = +D*x_i; verify against the capture-time Engine in `_source.json` before relying on the sign); neutral grey at rest (terminal palette, the owner 2026-10-05: black/amber/white, green up, red down, blue accents; nodes Fast amber, Medium white, Slow blue; contributions glow green for an up vote and red for a down vote), ramping to amber then yellow (stretched) or blue then cyan (compressed), full colour at |stretch| of about 0.75 D, the node end strongest, transparency down to about 0.12 and LightEmission up to 1 as |stretch| grows. Couplings: extra length sqrt(T^2 + (D*(x_b - x_a))^2) - T with T the 256-stud rest gap; neutral grey at rest, warm when lengthened, hottest mid-span, full at about 6 studs. Computed from the displayed row only (no live physics), so it is deterministic and identical on every replay. Never touches `Workspace.RoAlgoResearchPhysics`.

### Runner (`run-spring-indicator.mjs`)
`node run-spring-indicator.mjs --manifest <path> --protocol spring-consensus-v1 [--out-dir results]`: verifies inputs (verifySavedCapture + the D15/section 2 checks), writes Luau data modules to an OS temp dir, runs the real Luau modules (`SpringStudy.evaluate`) with `luau.exe` (D19), reads `@@JSON` ASCII output via StringDecoder (D18), adds SHA-256 provenance, writes the result with `wx` (refuses overwrite) to `results/RoAlgoV3_spring_v1_<ms>.json` (bridge-loadable name: `^[A-Za-z0-9_-]{1,100}\.json$`; split into sha256-referenced chunk files if over 16 MB), writes `spring-runs/<id>/report.md` + `report.json`, then verifies the inputs are unchanged. Never starts Studio, never steps physics, never substitutes JavaScript for the Luau signal logic (JS may only re-check invariants).

## 4. Fences (never, in this phase)
- Never call `Engine.new`, `engine:step`, `StepPhysics`, VerifiedStepper, capture controls, `App` `run`, or MCP `start_stop_play` (live v2 bodies are unanchored with enabled forces).
- Never modify: `../indicator-v2/**`, existing files under `results/` and `refits/`, `refit-saved.mjs`, `../tools/luau-run.mjs`, `Learning.luau`, `Study.luau`, `Features.luau`, `Mechanics.luau`, `Engine.luau`, `Regime.luau`, `VerifiedStepper.luau`, `PhysicsView.luau`, `build/**` (Task 6 backs it up first), the installed plugin (Task 6 only, after backup).
- Existing test assertions are never edited or weakened. Specs may only be appended to; hard-coded counts (AppLifecycle 19) may be raised only when new checks are added, with the old checks intact.
- The camera fix stays: `CameraType.Fixed`, no `Scriptable`, no camera-follow loop.
- No live orders, no new market data, no new native capture. No mail or messages to other seats.
