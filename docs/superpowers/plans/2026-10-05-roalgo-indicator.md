# RoAlgo buy/sell indicator implementation plan

> Execute with subagent-driven development and behavioral tests. User approved implementation in the existing RoAlgo Studio instance on 2026-10-05.

**Goal:** Deliver a working local Roblox Studio indicator with real native physics, causal five-minute market inputs, buy/hold/sell decisions, an executable historical trade ledger, a numerical control, and an optional learned entry filter.

**Architecture:** A new `indicator/` tree contains pure Luau financial logic, native Studio physics, and the dashboard. A separate loopback bridge on 127.0.0.1:47622 serves allowlisted source and existing SPY/QQQ candles. It never reads account credentials or sends orders. The prior experiment, its code and results remain intact. This folder is not a Git repository; do not initialize Git.

## Scope and contracts

- Target Studio: RoAlgo (the original private place; this release gates on PlaceId 0, see the root README). MCP instance IDs are transient; discover the current instance by place ID. Root agent alone operates Studio.
- All new files live in `indicator/` except this plan. Do not modify frozen lab/, tools/, data/, runs/ or sibling projects. Integration imports a copy of the existing verified stepper, preserving attribution and its verification protocol.
- Input bars: `{t:number, label:string, day:string, o:number,h:number,l:number,c:number,v:number}`; t is UTC bar-start seconds, label is New York time, all are completed 300-second bars. Node only transports/validates/packages data; finance calculations and decisions run in Luau.
- Start with regular-hours historical SPY/QQQ, explicitly labeled historical/exploratory. No assertion of untouched holdout or proven edge. No fixed eight-hour price target. Maximum holding bars controls stale trades only.
- Long/flat: BUY opens one position, SELL closes it; no shorts, leverage or pyramiding. Signals at bar close execute on the next available bar open with adverse per-side costs. Stop gaps fill at worse opening price; both barriers in one bar use stop-first and record ambiguity. Daily/missing-bar resets cancel pending buys and close existing exposure at next observed open, recording the gap. Final open exposure is marked, never invented as an executed sale.
- Warmup and volatility use past/current completed observations only. Entry volatility/stop distance is fixed at signal time. Separate entry/exit thresholds; chop suppresses entries only. Volume is activity, not buy/sell order flow.
- Native bodies move only through SpringConstraint/VectorForce/StepPhysics. Reset placement is permitted; simulated integration or decorative animation cannot substitute for engine states.

### Pure API (worker 1 owns)

`indicator/src/Core.luau` exports `new(config?)`, `numeric()`, and `defaults`.

```luau
local core = Core.new({symbol="SPY"})
local f = core:features(bar)
-- f: drive, volatility, volumeRatio, ready, reset, plus causal diagnostics
local row = core:step(bar, f, physical)
-- physical: fast, medium, slow, velocity, energy, agreement (all finite numbers)
local result = core:result()
-- result: rows, trades, summary, config
-- row: t,label,close,signal,reason,fast,slow,equity,position, plus features/state
-- summary: netReturn,maxDrawdown,tradeCount,winRate,exposure,ambiguousBars,openPosition
local numerical = Core.numeric()
local controlState = numerical:step(f.drive, f.reset)
```

`indicator/src/Meta.luau` exports `fit(trades, options?) -> model?`, `score(model, vector)`, `vector(feature,state)`; models contain train-only means/scales/weights, sampleCount and cutoff. Fewer than 30 closed trades or one-class outcomes returns nil with a reason. Core config accepts `metaModel`; candidate entry is accepted only if calibrated/selected fixed threshold is passed (default .55 as an explicitly experimental setting). Training examples are unfiltered executed trades, features captured at signal time, labels after costs. No online fitting on evaluation rows. Report probabilities as model scores, not calibrated confidence unless calibration has been measured.

Behavioral tests: prefix invariance, volatility scaling, warmup/reset, next-open entry, fees on both sides, gap-stop, stop-first ambiguity, no duplicate positions, exits not suppressed by chop, final open marking, meta training leakage guards and insufficient-sample behavior. Run standalone Luau tests, observe failing tests before implementation.

### Native engine API (worker 2 owns)

`indicator/src/Engine.luau` exports `new(parent, options?)`. Instance methods: `reset()`, `step(drive) -> physical`, `stats()`, `destroy()`. Expose `.model`. Build interpretable fast/medium/slow channels with same signed input, explicit fixed dynamics and readable physical nodes. Step via copied verified stepper, 12 completed 1/60-second steps per market bar, no global simulation stepping or changes to unrelated scene content. Default origin away from previous lab replay. Include `indicator/tests/EngineProbe.luau` exposing `run(parent)` for finite states, directional response, measured nonzero motion, reset repeatability and impulse decay. Root executes probes in the identified Studio.

### Dashboard API (worker 3 owns)

`indicator/src/Dashboard.luau` exports `mount(parent, callbacks) -> ui`. Parent CoreGui for Edit-mode ScreenGui; no dependency on plugin globals. Methods `setStatus(text)`, `setProgress(done,total)`, `render(result, comparison?, meta?)`, `append(row)`, `destroy()`. Callbacks `run(symbol,days)`, `stop()`, `select(symbol)`, `replay()`, `viewRig()` optional; buttons call only provided callbacks. Include SPY/QQQ selector and small historical session-count selector (5/20/60), Run, Stop, Replay, View physics, collapse panel. Dark legible dashboard, real candles/close curve, BUY/SELL markers at signal time (execution recorded separately), fast/slow oscillator, metrics and most recent trades/reasons. No fake figures. Labels: historical research, five-minute bars, long/flat, cost assumptions, physics measured, optional model untrained when absent. Draw bounded recent window (e.g. 180 rows), resize robustly, disconnect events on destroy. Show stop/progress/error state. Root integration controller invokes API.

### Transport and integration (root owns)

Files: `indicator/bridge.mjs`, `indicator/bridge.test.mjs`, `indicator/src/App.luau`, `indicator/README.md`, generated `indicator/build/`, `indicator/results/`, and `indicator/progress.md`.

- Write Node tests for symbol/date/path allowlists, New York DST conversion, strict sorted OHLCV parsing, regular-hours filter, count limits and loopback binding.
- Implement GET /health, /tree, /bars?symbol=SPY&days=20&end=2024-12-31; POST /result with constrained output name/body limit. Server binds loopback only. `/tree` exposes only indicator/src .luau, plus copied stepper. Source changes use hash attributes. Cached historical files require no network/account keys.
- App builds dashboard and Engine, streams completed bars through both physical and numerical Core instances, yields during physics, reports progress/cancellation and preserves partial results. All native state is generated before optional meta fitting. Fit only earlier closed trades; replay remaining causal rows with frozen classifier. Label this exploratory chronological split; never optimize from the evaluation result.
- Save source and result hashes, config, costs, native step counters and return/trade metrics. Install under ServerStorage.RoAlgoIndicator, produce a local model package for persistence; bootstrap command is documented. No Roblox cloud publish.
- Root verifies live installation and UI, native finite/moving state and repeatability, historical complete run, no unresolved console errors, exported record counts, and comparison consistency. Reviewer audits causality/fills/native use before final delivery.

## Execution ledger

- [x] Pure signal/backtest/meta modules and tests: 16 Core and 7 Meta checks passed.
- [x] Native engine adapter and Studio probes: 19 checks, 1,512 verified steps, zero corrupt steps.
- [x] Dashboard and controls: native callback/rendering probe passed; direct Edit-mode mouse delivery is outside the MCP input tool's supported mode.
- [x] Loopback transport, data packaging and controller: 9 Node checks passed.
- [x] Studio installation, complete SPY/QQQ historical runs and saved evidence; local plugin copied and hash-verified.
- [x] Independent review, fixes, final documentation. See indicator/README.md and indicator/VERIFICATION.md for evidence and limitations.
