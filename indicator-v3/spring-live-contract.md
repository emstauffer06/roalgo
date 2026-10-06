# Spring live forward test: build contract and plan addendum A

Written 2026-10-05 before any 2025–2026 spring state exists. It extends `forward-test-2025-2026-plan.md` (SHA-256 `11C7F75D…`, recorded in `forward-test-2025-2026-plan.sha256`) and `spring-indicator-contract.md`.

**Authorization.** The owner said "can we run 2025-2026 sp 500 data on it and I want to see it make decisions live". That authorizes, for this phase only, new native stepping of the capture-time v2 rig in Studio Edit mode and new write-once result files. The decision protocol stays `spring-consensus-v1` with the frozen 2024 calibration, and none of its modules change. The design facts behind this contract were measured during development (scout notes not included).

## 1. Decisions (L1–L14)

| # | Topic | Decision |
|---|---|---|
| L1 | Window and start | **One continuous run from 2024-11-18 09:30 to 2026-10-02 15:55 ET**: 36,402 bars over 469 sessions, from the unchanged v2 loader query {SPY, train 20, validation 5, test 444, end 2026-10-02}. Rows 1–2268 are the 2024 **calibration lead-in**. They have the same inputs, prehistory and HMM fit as the capture (measured bit-exact drives), and they re-step the native rig so it can be compared with the saved 2024 states. Rows 2269–36402 (2025-01-02 onwards, 34,134 bars) are the **forward test**. |
| L2 | Lead-in handling | During the lead-in every machine steps with a flat position context. Intents are shown but never traded. At row 2269 every machine calls `resetBoundary()` and every forward-test ledger starts flat at equity 1. Overnight 2024-12-31 → 2025-01-02 is not a segment break (D12). |
| L3 | Native reproducibility gate | Two checks. (a) Pre-flight: before the run, re-step 2024 records 1–78 natively and compare the coupled, independent and numeric vectors with the saved ones. Numeric must match exactly; native gets a probe tolerance of 0.002. (b) In-run: the lead-in compares all 2,268 re-stepped states with the saved ones and reports the maximum absolute difference per variant. A failure is disclosed, not hidden; the run is then labelled "re-captured physics differs from the 2024 calibration capture". |
| L4 | Corrupt step | The run aborts with an `aborted` manifest (reason, last index, native stats). Any re-run starts from row 1 with the code unchanged, and every attempt is reported. No in-place recovery and no mid-run reset. |
| L5 | Comparators | All seven 2024 runs: coupled, zero, frozen, independent, numeric, ema_baseline and no_trade. Coupled and independent are `live_native`. The frozen state is 2024 coupled record 12 at full precision. EMA keeps its 2024 calibration (coordinates and thresholds). |
| L6 | Primary criterion | Fixed before row 1. **An edge is claimed only if coupled net return after costs over the whole forward test is > 0 (no-trade) and > ema_baseline.** Physics dependence is the coupled-vs-zero emitted-action difference count. Secondary metrics are as in `spring-indicator-report.md`. A single path is not statistical proof, and the report will say so. |
| L7 | Sub-periods | Quarter and year figures are sub-period returns of the one continuous ledger per run: the equity ratio between period boundaries. |
| L8 | Completion | The run goes to the last bar whatever the interim P&L shows. Code changed after row 1 is logged. Frozen values never change. |
| L9 | Data serving | A new loopback-only server, `spring-live-server.mjs`, **default port 47627**. Port 47625 was the first choice. On 2026-10-05 it was in use by another local service, which must not be touched. The port is a start option; the controller takes the base URL as an option, and the default must match the server. The server is started by this session; the running v3 bridge on 47624 is left alone. It is read-only over data, apart from write-once chunk posts. It imports v2's pure `loadDataset` and edits nothing under indicator-v2. |
| L10 | Storage | Write-once compact JSON chunks under `results/spring-live/<runId>/`, one chunk per 5 sessions. States are hex-packed exact doubles. Rows are stored for coupled, independent, numeric and ema_baseline; zero, frozen and no_trade are regenerated exactly on replay. Bars carry the 8 display fields only. A plan seal goes first and a manifest last. |
| L11 | Pacing and viewing | Capture runs at native speed (about 3 bars/s with Studio in the foreground). The UI follows the newest row by default. Play, pause and scrub move over decided rows without pausing the capture. Panel Exit closes the UI only; the run stops only with the control's `stop`. The camera is framed once and never locked (D25). |
| L12 | Labels | Run kind `live_native`: "Live-captured native physics · 5-minute observations · 2025-2026 forward test." Partitions: `calibration_lead_in` ("2024 lead-in · calibration period · not traded") and `forward_test` ("forward test · 2025-2026 · frozen 2024 protocol, never tuned here"). These are append-only additions to SpringReplayView and SpringPanel. |
| L13 | Live rig | The capture-time Engine is built from `_source.json` at origin (0,1024,1024) as model `RoAlgoSpringLiveRig`. It is never `Workspace.RoAlgoResearchPhysics`. StepPhysics only ever receives its 50-part list. An isolation snapshot of every other unanchored part is checked at start, at every chunk and at the end (max delta below 1e-6). The rig is kept after the run for inspection. |
| L14 | Exclusivity | The live run refuses to start, and stops between bars, if CoreGui `RoAlgoMarketControl`, `RoAlgoResearchControl` or `RoAlgoIndicatorControl` reports busy, or if any other spring controller or stepper is active. `RoAlgoSpringControl`, the 2024 showcase, is exited first. |

## 1b. Multi-lane capture amendment (declared 2026-10-05, before any 2025–2026 state exists)

**Authorization.** The owner said "for parallizing the coming run, I want that done", and chose to layer the copies "infront of each other" as a design choice. They also set a standing rule: "the computing kind of stay in studio engine, pre computing outside kinda cheats that". This amendment replaces L1's single continuous rig with the scheme below. The decision protocol, frozen calibration and ledger rules are unchanged. The single-lane build (W1–W4) stays as the reference implementation and fallback.

| # | Topic | Decision |
|---|---|---|
| L15 | Everything in Studio | Only raw candles come from outside, via the :47627 data server. A **Studio-side features pass** runs the capture-time Features over all 36,402 bars in order, once, with no physics. It produces drive[8], volatility, ready, reset and regime for each bar and holds them in memory. Lanes consume those drives. Decisions and ledgers run in Studio. Offline luau.exe is used for tests only. |
| L16 | Lanes | **N copies** of the capture-time Engine (target 8; the final N is fixed from a measured frame-rate probe before any 2025–2026 bar). Each copy is built with the unchanged Engine at `CAPTURE_ORIGIN + (0, 0, laneOffsetZ)`, offset along **Z only**: the motion axis X and the vertical layout keep the capture's coordinates. Lane offsets are **centred on the capture origin** (offsets ±k·S) to keep coordinates small. The spacing S is at least the lane footprint, including full rail travel, plus a 512-stud gap. No constraint, part or attachment is shared between lanes, and no two lanes' parts can touch at any rail position (asserted at build time). |
| L17 | One stepper | A multi-lane verified stepper issues **one** StepPhysics(1/60, parts of all lanes) request per frame, with the capture's barrier, metronome and quiet-frame protocol and 12 steps per bar per lane. Each lane's drives are applied before the step and its 51-vectors are read after it, exactly as `Engine:step` does. A corrupt, dropped or fractional step on any lane aborts the run (L4). Lanes never step separately. |
| L18 | Block schedule | Blocks of 5 sessions are assigned round-robin to lanes. Each lane starts its block **one full session earlier from rest**, using the continuous Studio drives for those bars. Those warm-up rows are stepped and recorded as warm-up, never decided on. The rig forgets a cold start within about 2¼ hours of candles (calculated from stiffness and damping), and one session is 6½ hours. The 2024 lead-in runs in the same multi-lane mode. |
| L19 | Decisions | One SpringLiveSession steps through all rows **in time order**, in Studio, as soon as the next block in time order is complete. Every run keeps one continuous ledger, as before. Panel and chart follow this decision front. |
| L20 | Validation gate (pre-declared) | Over the 2024 lead-in rows, multi-lane mode is compared with the saved continuous 2024 states. Reported: max abs dx and dv per variant, and the number of rows whose decision or ledger row differs from the offline 2024 result. With 0 differences, 2025–2026 multi-lane results stand as the forward test. With any differences, they are reported with that count and disclosed beside the headline, never hidden. The single-lane continuous run remains available as the reference. |
| L21 | Visual layering | **Clarified at the owner's 2026-10-05 request before any forward run:** native grids lie in Y–Z, so their visual front-to-back axis is **X**. The native solver copies retain L16’s centered Z-only coordinates. A separately owned, translation-only live display stacks those grids along X using body-adorned markers and Beams attached through additional visual-only Attachments; original bodies, constraints, forces, attachment references, masses and the explicit stepper part list remain unchanged. The display follows actual native poses without a pose-update loop. Each layer carries compact block-date and warm-up labels. The camera is framed once and never locked (D25). Check native-copy draw distance and the stacked live display by screen capture before the run; record their mapping and source receipts. |


### W1: data lane (Node)

`spring-live-data.mjs` is pure and memoised.
- **Exports:**
  - `LIVE_QUERY`
  - `PAGE_SIZE = 512`
  - `EXPECT`: sessions 469, bars 36402, captureRows 2268, liveStartIndex 2269, liveStartT 1735828200, captureDataHash `789e6e64…cec49d4`, liveDataHash `b8a3ce22…bb41a26`, split equal to the capture's
  - `loadLive()`
  - `liveManifest()`
  - `livePage(k)`
  - `captureCheck(first, last)`
- **What `captureCheck` returns:** the saved 2024 per-record `{index, t, drive[8], reset, coupled[51], independent[51], numeric[51]}`, read from the pinned v2 checkpoints. It serves the pre-flight and the lead-in comparison.

`spring-live-server.mjs` binds 127.0.0.1:47627 with the same Host/Origin checks as the v3 bridge.

| Route | Returns |
|---|---|
| `GET /health` | `{ok, app:"RoAlgo Spring Live", schema:"roalgo-spring-live-server-1"}` |
| `GET /spring-live/manifest` | `liveManifest()`: schema `roalgo-spring-live-data-v1`, datasetId, query, split, prehistory, pageSize, pageCount, bars, captureRows, liveStartIndex, liveStartT, metadata |
| `GET /spring-live/page?index=k` | `{datasetId, page, pageCount, firstIndex, lastIndex, bars}` (unmodified v2 bars including contexts) |
| `GET /spring-live/capture-check?first=a&last=b` | at most 512 records |
| `POST /spring-live/chunk {runId, name, payload}` | Writes compact JSON with flag `wx` to `results/spring-live/<runId>/<name>.json`, then returns `{ok, path, sha256, bytes}`. A repeat gives 409. Body limit 48 MB. Names match `^[A-Za-z0-9_-]{1,100}$`. |
| `GET /spring-live/chunk?runId&name[&sha256]` | the saved chunk (sha mismatch gives 409) |

Tests (`tests/spring-live-data.test.mjs`, node --test):
- the capture dataHash reproduces;
- the EXPECT values hold;
- pages partition 1..36402 exactly;
- the calendar (18 closures, 3 early closes in 2025–26);
- the first 2,268 page bars are deep-equal to the capture bars;
- every route's validation;
- write-once behaviour;
- the server binds loopback only.

### W2: capture lane (Luau, Studio)

New verbatim copies:
- `src/SpringV2Mechanics.luau` = indicator-v2/src/Mechanics.luau, sha d4680345…
- `src/SpringV2Features.luau` = indicator-v2/src/Features.luau, sha c1ac95b2…; it requires v3 Regime, which is byte-identical to the capture's.

Plus `src/SpringV2Engine.luau`: the capture-time Engine from `_source.json` (sha 5dbebef9…), with exactly one line changed, `require(script.Parent.Mechanics)` → `require(script.Parent.SpringV2Mechanics)`. It keeps v3 VerifiedStepper, which is byte-identical.

`src/SpringLiveCapture.luau`:
```lua
SpringLiveCapture.CAPTURE_ORIGIN -- Vector3.new(0,1024,1024)
SpringLiveCapture.new({prehistory, symbol="SPY", name="RoAlgoSpringLiveRig", guard=fn}) --> cap
cap:step(bar) --> record {bar, feature, states}   -- exactly one bar; yields; asserts guard() first
cap:stats() --> engine stats + isolation + Studio/physics settings
cap:verifyIsolation() --> maxDelta
cap:destroy()
SpringLiveCapture.replayCheck(rows, opts) --> {count, maxAbs={coupled,independent,numeric}, pass}
  -- builds a temporary engine at CAPTURE_ORIGIN, applies each row's saved drive/reset, compares the 51-vectors with the
  -- saved ones, then destroys the engine. Never runs while another engine exists.
```
`new` asserts the identities, part count, masses and runner options, and a deep-equal of `engine.config` against the 2024 `native.config`. It refuses to run if a module hash differs. Tests: a node test pins the hashes, including the one-line revert check; a luau orchestration spec with injected doubles follows the `tests/stepper-driver.mjs` pattern.

### W3: decision and session lane (pure Luau)

- **`src/SpringFrozenV1.luau`** is generated by `make-spring-frozen.mjs` from the sha-pinned 2024 result and capture. It is a deep-frozen literal containing calibration, baselineCalibration, descriptor, nativeConfig2024, frozenState (record 12, full precision), hex pins and resultSha256.
- **`src/SpringLiveSession.luau`** requires only SpringPolicy, SpringState, SpringSignals, Execution, SpringStudy and SpringFrozenV1. Its API:
  ```lua
  SpringLiveSession.new({frozen, engineConfig, driveNames, planSha256, leadInRows=2268, saved2024=fn?}) --> session
  session:step({bar={t,o,h,l,c,availableT,day,label}, feature={reset,ready,volatility,drive}, states}) --> index
  session:displayRow(runId, i) ; session:runs() ; session:context(runId, compareId)
  session:rows(runId) --> compact rows ; session:bars() --> {t,o,h,l,c}
  session:drainChunk() --> chunk ; session:summary() ; session:evidence() ; session:reproducibility()
  ```
- **Behaviour:**
  - Lead-in rows (index ≤ leadInRows) step every machine with the flat context, record intents, and are not traded. Their compact rows carry `fa="HOLD"`, `fr="lead_in_not_traded"`, `po=0`, `eq=1`, and partition `calibration_lead_in`.
  - At leadInRows+1 the session calls `resetBoundary()` on every machine and creates one continuous `Execution.new()` ledger per run.
  - Forward-test rows have partition `forward_test`.
  - Evidence: `marketEvidence = "forward_test_predeclared"`, plus the implementation invariants and the coupled-vs-zero counts.
  - `compactRow` and the EMA stream are verbatim copies of SpringStudy's.
- **Required spec** (`tests/SpringLiveSession.test.mjs` plus `.spec.luau`): with `leadInRows=0`, replaying the 2024 saved inputs (row-by-row records) through the session must reproduce **all 2,268 stored 2024 rows for all 7 runs with 0 differences**. Other cases: lead-in flat and untraded; boundary reset; chunk drain and regenerate; label checks.
- **Append-only label edits** in SpringReplayView and SpringPanel (L12), with spec cases. The existing assertions stay valid.

### W4: controller (Studio)

`src/SpringLive.luau` is modelled on SpringShowcase.
```lua
SpringLive.start({runId?, rate?, preflight=true}) --> control (CoreGui BindableFunction "RoAlgoSpringLiveControl")
  -- commands: status, run, compare, seek, play, pause, follow, rate, find, stop, exit
SpringLive.replay({runId}) -- later playback from saved chunks, no stepping
```
Sequence:
1. Exit the other controllers (L14).
2. GET the manifest and pages from :47627, prefetching the next page.
3. Pre-flight (L3a).
4. Seal the plan (POST chunk `plan`: plan and addendum SHA-256s, pins, module Source receipts, bar universe).
5. Build `SpringLiveCapture` and `SpringLiveSession`.
6. Mount SpringReplayView, SpringPanel and SpringChart (chart fed from `session:bars()` and `session:rows(runId)`), and frame the camera once.
7. `task.spawn` the loop. For each bar: guard, `cap:step`, `session:step`, then render when following (UI errors are caught with pcall and never abort). Every 5 sessions: `session:drainChunk()` and POST it. Every chunk: `cap:verifyIsolation()`.
8. At the end, POST the manifest: status, chunk receipts, summaries, evidence, reproducibility, native stats, and a check that totalSteps equals 12 × bars.

A failed POST, a step or decision error, or an isolation breach aborts the run with an `aborted` manifest.

## 3. Fences (in addition to contract section 4)

Never edit:
- `indicator-v2/**`;
- SpringState, SpringSignals, SpringPolicy, Execution, SpringStudy (the decision modules, pinned by the 2024 result);
- the 2024 result and bars files;
- the v3 bridge.

Never:
- call `workspace:StepPhysics` without the rig's part list;
- run Play;
- touch `Workspace.RoAlgoResearchPhysics`;
- lock the camera;
- send mail or messages to other seats.
