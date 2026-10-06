# RoAlgo Learned Mechanics Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. The user's go-ahead authorizes this plan and execution. Independent file ownership permits parallel implementation. The directory is not a Git repository; do not initialize Git or create fictitious commits/worktrees. Persist the task ledger in indicator-v2/progress.md.

**Goal:** Install and verify a learned long/short mechanical trading research application in RoAlgo, with multiscale data, trained regime context, native coupled/uncoupled mechanics and honest comparisons.

**Architecture:** A loopback Node bridge transports cached data and joins completed contexts; all feature computation, regime filtering, readout fitting, decisions and accounting run in Luau. A verified native stepper advances two 24-body networks together. A mathematical counterpart and raw features provide controls. The Studio controller captures states, fits models chronologically and renders evaluation/replay results.

**Tech Stack:** Existing Node, Luau 0.741, Roblox Studio MCP and native constraints. No new package/runtime installation.

## Global constraints

- Workspace: the repository root. Create only indicator-v2/ and this plan/spec. Preserve indicator/, lab/, tools/, data/, runs/ and other Studio instances.
- Root alone operates RoAlgo Studio (the original private place). Discover transient MCP instance IDs. Never use Computer Use.
- No network data downloads required, account keys, brokerage orders, real-money execution, cloud publishing, or false profitability/novelty claims.
- Names: ServerStorage.RoAlgoResearch, CoreGui.RoAlgoResearchControl, RoAlgoResearchStatus, RoAlgoResearchDashboard, Workspace.RoAlgoResearchPhysics. Bridge 127.0.0.1:47623. Plugin file RoAlgoResearch.rbxmx.
- Every relevant output records source/config/data hashes, split boundaries, scope, native step counters and actual metrics. Labels: historical exploratory research; earlier date ranges have already been inspected.
- Behavior-first tests, including causality, cost signs and short positions. Record failing then passing runs; compile native-only code and test it in Studio before claiming native success.

## Shared interfaces

Bar: `{t,day,label,o,h,l,c,v,n,vwap,contexts={peerFive?,spyHour?,qqqHour?,iwmHour?,tltHour?,spyDaily?,qqqDaily?}}`. t is UTC bar start. Context bars also include `availableT`; all must be available by t+300. A daily bar must precede the current New York date. Missing context remains nil, never filled from future observations.

Dataset: `{bars,prehistory={targetDaily},split={trainEndT,validationEndT,testStartT},metadata}`. trainEndT is first validation bar start; validationEndT/testStartT is first evaluation bar start. Whole sessions form splits. Default20/5/5 sessions, end2024-12-31. Context history must be before the first target decision bar. Metadata includes actual counts/ranges/sessions, raw adjustment, source hashes and context availability convention.

`Features.new(prehistory,options?) -> object`, `:step(bar) -> feature`, `:info()`. Feature: `{t,raw,names,drive,volatility,ready,reset,regime,contextMissing}`. raw is a finite named vector of causal return/volatility/range/VWAP/activity/peer/hourly/daily/time/missingness features with regime probabilities appended. drive is exactly8 bounded [-2,2] values: trend, immediate return, range/activity, volume, peer-relative movement, hourly context, daily trend, regime stress. Use causal EWMA scales; do not divide by future/full-dataset statistics. `ready` after12 observations; `reset` first observation or missing intraday interval. Native time is one fixed simulation interval per observed market bar; overnight time is not simulated physically.

`Engine.new(workspace,options?)`, `:step(drive,reset?) -> {coupled,independent,numeric}`, `:stats()`, `:destroy()`, `.model`. Each state `{vector,names,banks,nodes,energy}`. Native coupled and independent vectors each contain24 normalized X positions followed by24 normalized X velocities, then3 bank energies (51 features). Numerical vector has identical ordering and modeled parameters. `banks` contains3 records `{name,displacement,velocity,energy}`; `nodes` contains24 `{x,v,force,bank}` diagnostics. Exactly12 verified dt=1/60 steps per observation, using copied VerifiedStepper. Independent rig has no coupling springs; all other inputs/axial parameters match. No assigning motion states except build/reset. Numeric simulation cannot substitute for native fields.

Record: `{bar,feature,states}` from the interfaces above. Dataset records may be cached; cache keys must include source data, source code, mechanics parameters, feature definitions and schema version. Readout operations may reuse immutable states without claiming to rerun physics.

`Learning.fit(records,{trainEndT,validationEndT,variant,contextMode?}) -> model,report` where variant is raw/coupled/independent/numeric. contextMode full/reduced drops slower inputs only for raw baseline comparison; it cannot pretend native states were computed without context. `Learning.predict(model,record) -> {mean,upside,downside,contributions,score}`. Use forward horizon6 observed five-minute bars entirely within one session; entry anchor next bar open, end sixth future bar close; excursions across those6 bars. Labels must not cross a session/missing interval. `labelAvailableT=endbar.t+300`; strict completion by split cutoff. Train on earlier records, choose ridge penalty from {0.1,1,10} by validation return MSE, no evaluation selection/refit. Fit means/scales on training. Minimum128 valid train and32 validation labels; explicit insufficient-sample status otherwise. At mostraw+51 predictors; no neural networks or physical parameter search. Prediction mean is gross fractional return; upside/downside estimates clamp nonnegative. Contributions sum to predicted mean within tolerance. Learned heads: mean, favorable excursion, adverse excursion. Penalty excludes intercept; solve with stable positive diagonal regularization and finite checks.

`Execution.new(config?)`, `:step(bar,feature,prediction) -> row`, `:result() -> {rows,trades,summary,config}`. Defaults initialEquity1,feeBps1,slippageBps1,borrowAnnual0.03,stopVol2,targetVol3,minStopFraction0.001,maxHoldBars24,entryMarginBps1. Long/short quantity uses one-times current equity notional; no leverage beyond that, no pyramiding. Flat entry if mean exceeds round-trip fee+slippage+margin, or negative equivalent; otherwise HOLD. Existing long closes when mean<=0; short closes when mean>=0; learned continuation controls exit with hard stops/targets/timeout. Action is a close-time signal, next-open execution; a close must execute before any new entry. Stop gaps use worse open; both barriers use conservative stop-first. Price markers distinguish signal and fills. Shorts use signed shares/cash accounting; charge borrow on actual elapsed seconds while held. Final marking charges no fictitious future exit. Model-fit absence suppresses entries.

## Task 1: Data and causal features (worker ownership)

Create indicator-v2/bridge.mjs, bridge.test.mjs, src/Features.luau, src/Regime.luau, tests/Features.spec.luau, tests/Regime.spec.luau, data-report.md.

- [ ] Write/run failing transport tests: finite OHLCV, timestamp order, New York DST, regular session/early close, strict completed context join, split sessions, unsafe route/path/body rejection. Reuse v1 ideas without editing v1.
- [ ] Implement GET /health, /tree, /dataset?symbol=SPY&train=20&validation=5&test=5&end=2024-12-31 and POST /result. Loopback host/origin allowlists, safe unique result names, max64MiB, no overwrites. /tree returns `{files:[{path:'src/Name'|'tests/Probe',source,sha256}]}` excluding .spec files. Export ROOT, sourceTree, parseCSV, loadDataset as useful Node APIs. Support total sessions up to1000 and cache cutoff through2026-10-02; use authoritative early-close schedule or explicitly audited calendar data. Cache raw files once per process. Daily join strictly prior date; hourly availability t+3600. Five-minute peer available at t+300, never later.
- [ ] Features tests: changing later bars does not change prior vectors, incomplete hourly/current-day daily context rejected, missing values finite with indicators, stable vector names/length, drive length8, no future fitted scales. Native reset only first/missing intraday gap.
- [ ] Implement3state diagonal Gaussian HMM fit from prehistory target daily returns/ranges, with standardized train-only inputs, deterministic initialization, bounded EM iterations, variance floor and stable forward/backward normalization. Forward filter uses only newly completed daily data, handles repeated same daily context without stepping twice, orders states by fitted volatility. Regime probabilities sum1; degenerate/insufficient histories return documented causal uniform/neutral fallback.
- [ ] Run tests/compile, report schema and evidence. No Studio calls.

## Task 2: Learned heads and long/short execution (worker ownership)

Create indicator-v2/src/Learning.luau, Execution.luau, tests/Learning.spec.luau, Execution.spec.luau, learning-report.md.

- [ ] Failing tests for future label exclusion, full outcome availability, session gap rejection, train-only scaler, validation-only selection, synthetic known relation learning, contribution reconstruction, insufficient data. Implement shared API above.
- [ ] Failing tests for next-open long and short, costs both directions, borrow charges, adverse short gap, simultaneous stop/target, no direct reversal/pyramiding, final open marking, close uses learned continuation, prefix invariance under later data changes. Implement explicit ledger and net liquidation equity using signed shares/cash.
- [ ] Provide serializable trained weights/scalers/schema/cutoffs/samples/validation losses. `Learning.predict` validates feature/vector lengths. Execution rows include `{t,label,close,signal,reason,position,equity,executions,prediction}` with position -1/0/+1 and BUY/SELL/CLOSE/HOLD.
- [ ] Run tests/compile; report reproducible commands and actual results. No Studio calls.

## Task 3: Joint native and numerical mechanics (worker ownership)

Create indicator-v2/src/Engine.luau, Mechanics.luau, VerifiedStepper.luau (copy provenance), tests/Mechanics.spec.luau, tests/EngineProbe.luau, engine-report.md.

- [ ] Read old lab native geometry and v1 scaling fixes, then implement24nodes in3banksof8. Use fixed deterministic input projection dominated by matching bank timescale; varied omega/damping, D64 scale or measured stable equivalent. Coupling edges have explicit initial geometry, free length, stiffness and relative-velocity damping. Expose the exact constants/schema in mechanics config.
- [ ] Two native rigs share one VerifiedStepper.new({rigA,rigB},{dt=1/60,stepsPerBar=12,settleSteps=0,parent=model}). Required rig methods movingParts/reset/drive/read. Axial constrained movement plus geometric coupling produces measured nonlinearity. Keep rails within safety limits; unrelated workspace parts excluded from native step parts.
- [ ] Numerical model evaluates the same axial, coupling and force equations with documented integrator. Independent/native/numeric inputs and resets match. Test numerical stability/response/reset and coupling-disabled behavior.
- [ ] Native probe returns finite/directional response, effect of coupling, nonlinearity measurement, reset replay tolerance, node/edge counts, saturation/off-axis counters, numeric deviation, metronome completion, unrelated sentinel unchanged. Root executes and repairs with worker if needed. No claim of native pass before evidence.

## Task 4: Studio controller and inspectable dashboard (root ownership)

Create indicator-v2/src/App.luau, Dashboard.luau, tests/AppProbe.luau, DashboardProbe.luau, package.mjs/package.test.mjs, Install-In-Studio.luau, Start-RoAlgo.ps1.

- [ ] Controller validates target Edit mode, streams/caches completed inputs, captures native states with progress/stop, then fits four variants and evaluates all on exactly the same later bars/costs/start-flat boundary. Include raw reduced-context comparison separately. Preserve partial evidence on cancellation/error and do not fit partial runs by accident.
- [ ] Expose Bindable control status/run/stop/replay/inspect/viewRig/destroy; optional saved-result loading for durable review. Dashboard uses desktop MouseButton1Click, programmatic setSelection, deterministic bounded charts, explicit dataset split/model status and no fabricated zero metrics. Show long vs short and CLOSE independently.
- [ ] Provide measured nodes/banks/action-score contribution inspector and variant selector. Replay recorded measurements rather than re-running physics. Coupled/disconnected ablation comes from jointly simulated native variants. Zeroing/shuffling recorded state is labeled an analysis intervention, never physical execution or causal proof.
- [ ] Package source hashes and target-place guard; install distinct local plugin, preserve v1 package. `/result` saves data/model/native/source hashes and full comparison evidence. Root validates runtime behavior with MCP, no physical Edit-click claim.

## Task 5: Integration, independent review and evidence

- [ ] Pure test suites pass; package/bridge tests and source compilation pass.
- [ ] Native probe passes and reveals numerical deviation honestly; fix stability before running historical experiment.
- [ ] Complete default30session20/5/5 dataset in RoAlgo, fit real models and evaluate all variants; export evidence. Test cancellation on a separate short probe; load/replay completed result afterward.
- [ ] Independent review of causality, label availability, training boundaries, full short accounting, native use, dataset joins and control comparisons. Fix material findings and rerun affected checks.
- [ ] Verify installed source/package hashes and plugin copy. Write README/VERIFICATION with coverage, exact commands, results and limitations. Leave v2 usable in selected Studio with current result, v1 data intact.
