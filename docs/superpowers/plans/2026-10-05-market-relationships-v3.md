# RoAlgo Market Relationships v3 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement and review the owned tasks. The user approved the proposed expansion with “go ahead”; continue without another design approval.

**Goal:** Build and install an auditable Roblox experiment with market-specific physical inputs, varied memory responses, policy comparisons and chronological rolling evaluation; test 24 versus 48 nodes per rig without assuming the larger system is better.

**Architecture:** Develop in `indicator-v3`, preserving v2 source/results. A separate localhost bridge (47624) transports historical observations and saves immutable results. Luau owns causal features, native physics, fitting, policy selection and evaluation; native capture uses the existing hardened VerifiedStepper unchanged.

**Tech Stack:** Roblox Studio Edit-mode MCP, Luau0.741, Node.js, PowerShell. No repository exists, so no Git operations or fabricated commits. Root alone operates Studio.

## Global constraints

- Target the configured RoAlgo place (the original private place; this release uses PlaceId 0). No Computer Use; Roblox MCP only for Studio.
- Historical research only: no brokerage orders, publication, live-money actions or performance guarantees.
- Keep existing v2 experiment and files intact. Install v3 under distinct controls/models/package names; retire the idle v2 display only at final handover.
- Preserve completed-bar availability, session/calendar filtering, train-only normalization, matured labels, missingness, next-open execution and provenance hashes.
- ETF volume is ETF volume, not total underlying index volume. VIX is optional and excluded unless a usable historical source is actually obtained.
- Native intervals remain12×1/60 per5min observation. Never drive native positions during capture or fake native results with numerical states.
- Every policy/architecture candidate and validation choice is recorded. Evaluation rows never choose thresholds or hyperparameters.
- Historical periods already inspected remain explicitly exploratory; no claim of an untouched project holdout.

## Task1 — Isolated transport and sector context

Files: `indicator-v3/bridge.mjs`, `bridge.test.mjs`, `fetch-sector-context.mjs`, `data/`, data verification report. Owner: data worker.

Keep dataset return `{bars,prehistory,metadata,split}` and add causal completed hourly contexts `xlkHour`, `xlfHour`, `xleHour` alongside existing context. Fetch/cache the three ETFs with the existing authorized Alpaca credentials without printing secrets; retain raw response provenance, timestamps and adjustment/feed flags. Network failures must produce explicit unavailable context, not synthetic prices.

Expose GET `/folds?symbol=SPY&train=20&validation=5&test=5&count=3&stride=60&end=2024-12-31`. Return `{folds:[{id,endDate,train,validation,test,...}],metadata}`. Each fold uses existing `/dataset` arguments; test windows do not overlap and stride>=test. Include `/health` schema3 and app identity `RoAlgo Market Lab`; root path must match v3.

- [ ] Test future/stale context rejection, missingness, sector availability, duplicate timestamps, and nonoverlapping chronological folds.
- [ ] Implement and run transport checks against cached data; report actual ranges/counts.
- [ ] Review data/provenance and ensure no credential leaks or order endpoints.

## Task2 — Market relationships and dynamic native reservoir

Files: `src/Features.luau`, `Mechanics.luau`, `Engine.luau`, `PhysicsView.luau`; associated feature/mechanics/native probe tests. Owner: physics worker.

Retain `Features.new(prehistory,{symbol})`, `step(bar)` and `info()`. Feature records keep existing fields and add `memory`, `memoryNames`; direct names and vectors stay dynamically described. Twelve drive channels in exact order: trend, immediateReturn, rangeActivity, volume, qqqMinusSpy, iwmMinusSpy, tltReturn, xlkMinusSpy, xlfMinusSpy, xleMinusSpy, targetDailyReturn, regimeStress. Preserve separate direct market observations and missing flags; add inexpensive causal lag/EWMA memory features for the comparison baseline. Feature validity uses completed timestamps; no same-day final daily close.

`Mechanics.config(options)` and `Engine.new(parent,options)` accept `{nodeCount=24|48,topology="grouped"|"grid",response="diverse"|"balanced"}`. Default24 grouped/diverse. Three response banks; four financial groups; two nodes per group per bank at24 and four at48. Each node records group, bank, dominant drive and actual fixed signed projection. Couplings are nonnegative physical springs with bounded, fixed parameters; no asserted universal market-correlation sign. Model/state dimensions derive from configuration, never hardcoded24/48. State keeps `.vector`, `.names`, `.nodes`, `.banks`, `.energy`; vector includes normalized x/v and named derived mechanics measurements. Coupled/independent/numerical representations share schema.

Keep full-size geometry and cached rest positions consistent; place default display relative to spawn and retain floating non-fading labels. Configurations have distinct identities and provenance. VerifiedStepper remains unchanged.

- [ ] Test causal/missing inputs, twelve drives, dynamic24/48 dimensions, graph endpoints, geometry and finite deterministic numerical response.
- [ ] Add bounded native probe for24 and48, verifiedinterval counts, disconnected control, cleanup and no unrelated-body movement.
- [ ] Review hardcoded counts and distinguish measured states from derived forces/energies.

## Task3 — Fair baselines, policies and fold evaluation

Files: `src/Learning.luau`, `Execution.luau`, new `Study.luau`; associated learning/execution/study tests. Owner: evaluation worker.

Preserve `Learning.fit(records,options)` and `predict`; add `variant="memory"` for direct raw features plus `feature.memory`. All dynamic schemas are named and checked; native state names/count are obtained from recorded state. Comparison IDs are coupled, independent, numeric, raw, memory. Keep six-bar targets and train-only preprocessing. Do not treat mean/(upside+downside) as probability.

`Study.evaluate(records,split,options)` returns `{comparisons,selection,diagnostics}`; options has `{cancelled?,onProgress?,provenance?}`. Fit five readouts once per fold. Compare a small declared policy set on validation, then freeze selected policy per readout for evaluation: original continuation; six-bar timeout without sign-based close; buffered continuation with distinct adverse exit threshold; a clearly marked excursion-filter experiment. Policies share conservative fill/cost assumptions and expose explicit reason codes. Excursion forecasts are expected magnitudes, not barrier probabilities. Keep long/short/CLOSE semantics and no same-bar entries. Include training-only state diversity diagnostics where practical. Evaluate all candidates on the same available timestamps; report missing/insufficient cases.

Each comparison remains dashboard-compatible `{id,model,report,result}` with selected-policy provenance and validation outcomes. `Study.aggregate(folds)` summarizes per-configuration/per-model fold counts, net outcomes, turnover, exposure, drawdown and variability without silently choosing the best evaluation model. Individual folds restart equity and must not be mislabeled a continuously funded portfolio. Any architecture recommendation must derive from development/validation evidence, not evaluation selection.

- [ ] Test train/validation/evaluation separation, dynamic dimensions, fee thresholds, horizon exits, hysteresis, short adverse/favorable mapping and all policy budgets.
- [ ] Test fold aggregation avoids inventing continuity or omitting failed folds.
- [ ] Review labels, cost accounting and policy-selection leakage.

## Task4 — Studio orchestration, dashboard and packaging

Files: `src/App.luau`, `Dashboard.luau`, package/installer/launcher, controller probes, docs. Owner: root.

Use `RoAlgoMarketControl`, `RoAlgoMarketStatus`, `RoAlgoMarketDashboard`, `RoAlgoMarketPhysics`, `ServerStorage.RoAlgoMarketLab`; bridge47624 and schema3. App coordinates configurations `{id="grouped24",nodeCount=24,topology="grouped",response="diverse"}` and `{id="grouped48",nodeCount=48,...}` over fold descriptors; controller has run/stop/result/load/replay/viewRig plus rolling-study controls. Capture per-configuration/per-fold states separately, checkpoint in bounded chunks, fit/evaluate with Study, persist immutable fold artifacts and aggregate manifest. Cancellation/failure must not present incomplete studies as completed. Show fold/configuration progress, policy identity, native measurements, fold outcomes and actual coverage. Existing inspector/replay should support dynamic nodes or clearly selected node ranges.

- [ ] Test controller cancellation, failed writes, saved-result identity, dynamic UI selection and missing datasets.
- [ ] Compile and package; inspect source/dependency hashes.
- [ ] Review integration with a fresh agent and fix substantive findings.

## Task5 — Native execution, verification and installation

- [ ] Keep active v2 idle and available while validating v3 modules in temporary fixtures.
- [ ] Run native24/48 probes and meaningful multi-fold end-to-end study; record exact actual sample, parameters, native counters and results. Do not invent a performance improvement.
- [ ] Verify trade accounting and selection provenance independently from saved results.
- [ ] Save source/result hashes and evidence, update documentation with measured limitations.
- [ ] Install local v3 plugin with previous artifacts preserved; retire only idle v2 controller/display at handover; keep its data/source history. Verify current v3 controls, native geometry, labels and loaded completed study via MCP.

## Progress ledger

- Data implementation and cache audit complete: 57,315 sector hourly bars, with original provider pages and hashes retained. Six SPY/QQQ default fold datasets pass causal-join checks.
- Dynamic features, mechanics, five readouts, four validation-selected policies, rolling controller, dashboard and packaging are implemented in the isolated v3 directory.
- Native 24- and 48-node probes passed all checks: 144 verified intervals each, zero corrupt intervals, exact reset replay in these bounded fixtures. The native dashboard passed 29 construction, binding, layout and callback checks.
- First historical integration capture was deliberately stopped after 351 bars / 4,212 verified intervals. Checkpoints and stopped-state evidence were saved. Export sizing showed that the final study must use references to fold/checkpoint artifacts; that storage correction is in progress before restarting.
- Fresh reviews identified the exclusive fold-end metadata boundary and two research limitations: intraday training labels do not cover overnight risk, and raw-price ledgers omit dividend cashflows. The boundary is being corrected; the limitations will be documented with the results.
- User steering supersedes the planned new capture: repair the scaler/validation failure and refit from saved native states only. No further native capture is authorized for this continuation.
- Confirmed original v2 zero-forecast validation MSE 7.959595470945455e-6. Original model/zero ratios: coupled 91.41938, independent 87.26171, numeric 91.96620, raw 367.35616, reduced 1.15882. RegimeHigh reached 233.434 training standard deviations in validation and 92.6746 in evaluation.
- New readout schema v3-2 uses a training-only variance mask, standardized-input clipping at +/-5, and explicit validation MSE relative to zero. Study adds the flat zero/no-trade baseline and selects policies through declared session blocks, quality gates and cost/risk penalties; short validation defaults to no trade.
- Default future study profile is 80/20/20. Available compatible v2 states cover only 30 sessions. The primary controlled refit retains 20/5/5; a separate maximum-history diagnostic uses 25/5 with no remaining evaluation period. Other historical native architectures will not be pooled into this state history.
- Saved-state refit, independent MSE/accounting audit, final source verification and plugin installation are complete. The corrected artifact is RoAlgoV3_refit_saved_v2_24_1791212057087_readout.json and is loaded in Studio. All fitted readouts remain worse than zero on validation and select no_trade. The original inputs remain unchanged; new native steps are zero. Full evidence is in indicator-v3/INTEGRATION-EVIDENCE.md.
- The expanded 24/48 v3 architecture has bounded native verification performed before the no-capture instruction. Its full rolling performance study remains deliberately deferred under that instruction, with no performance improvement claim.
