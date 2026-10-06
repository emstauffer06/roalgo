# Roblox physics market forecast implementation and handover

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build and backtest a forecasting experiment in which Roblox's native physics transforms historical market observations into measured state, and Luau learns to predict eight-hour SPY and QQQ returns from that state.

**Architecture:** A local Studio plugin drives a fixed network of constrained, spring-coupled bodies with causal market features. Roblox computes the motion. Luau reads positions and velocities, fits regularized linear readouts, and compares their forecasts with equally informed statistical baselines and a separately fitted financial Markov chain. The primary expanded experiment includes completed five-minute observations, volume activity, prior-day context, and IWM/TLT context without changing the eight-hour target.

**Tech stack:** Roblox Studio, Luau, native constraints and forces, a local Studio plugin, the existing Alpaca dataset, and Node.js for packaging, hashing, validation, and report assembly.

**Status:** This is a plan, not an implemented forecasting model. The dataset has been downloaded and checked; it has not yet been run through a reservoir in Studio.

**Data and protocol:** All 603,900 supplemental source candles are local and audited. Read [SUPPLEMENT.md](../../../SUPPLEMENT.md) for files and provenance. This revision defines O14 (original hourly reference), R50 (primary richer-input experiment), H14 (longer hourly history), and an optional R60 regime-input experiment. Their feature dimensions, missingness, model budgets, and release order are specified below. No model has been trained, and additional information is not evidence of higher accuracy.

**Prepared:** October 4, 2026. **Revised:** October 5, 2026, using the user's local date, after inspecting the supplemental data and a separate MarkovJunior Luau port.

## Global constraints

- Project root: the repository root
- Preserve the existing collector, data exports, and credential arrangement.
- Keep credentials out of Roblox, source files, reports, prompts, and logs. Cached data is sufficient for this project.
- Roblox's native solver must perform the state evolution. Do not replace it with a hand-written differential-equation solver and animate its answer.
- Use historical backtesting. The earlier live eight-hour reveal idea has been superseded.
- Eight hours means eight elapsed clock hours under the explicit eligibility policy below.
- SPY is an S&P 500 ETF proxy; QQQ is a Nasdaq-100 ETF. No Nasdaq Composite dataset is present.
- Fit models and run inference in Luau. Node may package, validate, hash, and independently check exported arithmetic.
- Orders, account changes, paid data, public publishing, and live trading are outside scope.
- Final-test outcomes cannot influence preprocessing, geometry, hyperparameters, model selection, or the choice of a supposedly representative example.
- Measure repeatability; do not promise bit-for-bit deterministic native physics.
- Preserve the separate live project at mj-port (a separate MarkovJunior Luau port, not included). It is a reference, not this project's implementation destination or a runtime dependency.
- Supplemental missingness must not silently remove hourly origins. Give each raw comparator exactly the same causal information, masks, and history as its physics-augmented counterpart.
- Lighting is an optional follow-on experiment. It does not block the first physics result.
- The workspace is not currently a Git repository. Use saved checkpoints; do not claim commits exist or initialize Git incidentally.

## 1. Context for the next session

The user is developing a video around **“Can we use the Roblox engine to predict the stock market?”** They asked for physics, lighting, and other engine capabilities to perform meaningful computation, beyond an ordinary indicator written in Luau.

The proposed method is **physical reservoir computing**. Market observations drive a fixed mechanical system. Its response contains a mixture of current input, recent input history, damping, coupling, and nonlinear geometry. A small trained readout maps the measured response to a forecast.

The software can work correctly without discovering a forecasting advantage. A negative result is a valid experiment and a usable video outcome. A positive claim requires a comparison against a serious baseline with the same available historical information.

Read the existing README and this plan before changing the architecture. Build the data contract and native-physics proof first. Defer visual polish until those gates pass.

### Phase 0 documentation and reusable work

A separate project ports MarkovJunior into Luau and improving its Roblox catalog and showcase. MarkovJunior rewrites spatial patterns according to authored rules; its renderer creates anchored geometry. That is distinct from fitting transitions between financial states. Keep the native physical reservoir as the central computation experiment. The financial Markov model in Section 5 is new code with its own training and tests.

Read these reference locations before reusing a pattern; the sibling project is actively changing:

| Observed source | What can be reused or verified |
|---|---|
| mj-port/luau/src/Node.luau, MarkovNode:Go (separate project, not included) | Rule-priority semantics; not a learned temporal transition matrix. |
| mj-port/luau/src/OneNode.luau, OneNode:Go (separate project, not included) | Random spatial rule application. |
| mj-port/luau/src/MJ.luau, MJ.Generate(name, opts) (separate project, not included) | Procedural generator interface; no market forecasting integration is required. |
| mj-port/luau/src/DotNetRandom.luau (separate project, not included) | Random.new(seed), :Next(n), :NextDouble(); deterministic pure-Luau sampling pattern. |
| mj-port/luau/tests/test_random.luau, lines 3–29 (separate project, not included) | Seeded reference-vector tests; the inspected harness only prints mismatch counts, so add failing assertions in our own tests. |
| mj-port/tools/compare.py, lines 33–66 (separate project, not included) | Cross-implementation traces and first-divergence reporting for pure arithmetic. |
| mj-port/showcase/MJShowcaseServer.server.luau, lines 256–293 (separate project, not included) | Budgeted UI work, cancellation tokens, and cleanup after errors. Never use task.wait or os.clock as the physics clock. |

Pin copied material locally with provenance, source hash, and required attribution after checking its license. Do not load mutable sibling files at runtime or edit that session's files. Its module-global Interpreter.yieldHook is not a safe shared scheduler for concurrent jobs. Its per-step hash comparison is useful for pure algorithms, not a requirement for bit-identical native physics.

Allowed engine APIs remain documented native constraints, VectorForce, BasePart measurements, and plugin-context WorldRoot:StepPhysics. Pure feature construction, Markov fitting, matrix fitting, and tests are Luau code, not invented Roblox APIs. Consult the official sources in Section 12 before capability-sensitive implementation.

### Existing assets

Paths below are relative to the project root unless absolute.

| Path | Existing purpose |
|---|---|
| README.md | Data provenance, caveats, commands, and module import layout. |
| download.mjs / download.test.mjs | Read-only Alpaca collector and tests. |
| export-data.mjs / export-data.test.mjs | CSV and chunked Luau exporter and tests. |
| prepare.mjs | Regenerates exports from cached raw data without credentials or network. |
| data/alpaca-2021-10-04_2026-10-02/raw/ | Downloaded native hourly arrays. |
| data/alpaca-2021-10-04_2026-10-02/SPY.csv | 19,962 bars. |
| data/alpaca-2021-10-04_2026-10-02/QQQ.csv | 19,887 bars. |
| data/alpaca-2021-10-04_2026-10-02/manifest.json | Metadata, exported-file paths, and SHA-256 hashes. |
| data/alpaca-2021-10-04_2026-10-02/verification.json | Existing audit; explicitly says Studio execution has not occurred. |
| data/alpaca-2021-10-04_2026-10-02/roblox/SPY/ | init.luau and Chunk001–Chunk020. |
| data/alpaca-2021-10-04_2026-10-02/roblox/QQQ/ | init.luau and Chunk001–Chunk020. |
| SUPPLEMENT.md | Supplemental provenance, exact counts, audit evidence, and import instructions. |
| data/alpaca-supplement-2016-01-01_2026-10-02/five-minute/ | SPY 236,059 and QQQ 237,287 native 5Min bars, October 2021 onward. |
| data/alpaca-supplement-2016-01-01_2026-10-02/hourly-combined/ | SPY 42,543 and QQQ 42,334 native 1Hour bars, January 2016 onward; includes the original data. |
| data/alpaca-supplement-2016-01-01_2026-10-02/daily-context/ | SPY/QQQ, 2,703 native 1Day bars each, January 2016 onward. |
| data/alpaca-supplement-2016-01-01_2026-10-02/hourly-context/ | IWM 41,857 and TLT 38,263 native 1Hour bars, January 2016 onward. |
| data/alpaca-supplement-2016-01-01_2026-10-02/verification.json | Full raw/CSV/Luau/hash audit; 714 supplemental export files verified. |
| data/alpaca-supplement-2016-01-01_2026-10-02/cross-resolution-verification.json | Timestamp coverage of five-minute children; partial hours remain explicit. |
| download-supplement.mjs / prepare-supplement.mjs / audit-supplement.mjs | Existing acquisition, export/merge, and independent audit tools. No redownload is required. |

The complete existing suite passed 84 tests at the supplemental data handoff. Establish the current baseline once and record the actual result:

~~~powershell
node --test download.test.mjs export-data.test.mjs download-supplement.test.mjs supplement-export.test.mjs prepare-supplement.test.mjs audit-supplement.test.mjs
~~~

Node.js 24.19.0 was available. The standalone binary luau now exists, although it need not be on PATH. Verify its launch and save its version/hash in environment.json. Use it for dependency-free Luau data, Markov, and numerical tests; it does not provide Roblox engine classes. Native mechanics and plugin permissions still require Studio. Rojo and Lune are not prerequisites.

### Dataset meaning and profile scope

All resolutions preserve volume, trade_count, and vwap in addition to OHLC. Volume is aggregated traded volume, not a buy/sell aggressor classification or an order book. The following exact counts describe the frozen original hourly source used by O14 and R50, not the larger H14 training population:

- Market dates: 2021-10-04 through 2026-10-02.
- First bar for both symbols: 2021-10-04T08:00:00Z.
- Last bar for both: 2026-10-02T23:00:00Z.
- Alpaca native 1Hour aggregates, SIP feed, raw adjustment.
- Includes extended hours; not regular-session-only.
- Timestamps denote bar starts. Treat completed OHLCV as available at timestamp + 3,600 seconds.
- That availability time is the retrospective experiment's assumption. Downloaded historical bars can incorporate late trades or corrections; the dataset does not prove those final values were delivered at that exact moment. This is not a point-in-time data-delivery audit.
- Gaps remain unfilled.
- Common timestamps: 19,887. SPY has 75 extra timestamps; QQQ has none absent from SPY.
- No normalization, returns, targets, or split assignment has already been applied.
- Raw adjustment is not a total-return series. The within-day target below avoids crossing overnight distributions, without converting the source to adjusted prices.
- Native 09:00–10:00 New York bars can straddle the 09:30 regular-session open.
- Structural validation does not independently establish complete exchange coverage.

The exported Luau rows contain:

~~~lua
-- 1 timestamp_unix: UTC bar start, seconds
-- 2 open, 3 high, 4 low, 5 close
-- 6 volume, 7 trade_count, 8 vwap
type Bar = {number}
~~~

Each original init.luau becomes a ModuleScript named SPY or QQQ with its twenty Chunk modules as children. Requiring it returns metadata, schema, and bars. For supplemental groups, use the group's manifest to enumerate its actual loaders and chunks; do not assume twenty chunks. Preserve separate group folders and the loader/child relationship. Never concatenate combined hourly bars with the original bars a second time.

## 2. Define the experiment before fitting

### 2.1 Model families

Use one joint reservoir for SPY and QQQ inputs, with two separately fitted output coefficient vectors. Prefix every model ID with its profile ID. Numerical dimensions below exclude the intercept.

| Profile | Inputs and training interval | Status | Input D | Raw 1 / 4 / 8 lags including lag masks | Eight raw lags plus physics |
|---|---|---|---:|---|---:|
| O14 | Original fourteen hourly features; 2021-10-04 through 2023 | Required reference | 14 | 15 / 60 / 120 | 168 |
| R50 | O14 plus the exact supplemental features in Section 3; same training dates | Required primary experiment | 50 | 51 / 204 / 408 | 456 |
| H14 | Same fourteen-feature formula, combined hourly training from 2016-01-04 through 2023 | Required history-length comparison | 14 | 15 / 60 / 120 | 168 |
| R60 | R50 plus ten train-fitted Markov probability/mask values | Optional; disabled by default | 60 | 61 / 244 / 488 | 536 |

All profiles retain calendar 2024 validation and the final period starting January 2025. O14 and R50 use the original paired hourly stream, so their input and scoring timestamps are identical. R50 may read older completed observations to initialize causal trailing context, but its fitting rows still begin October 2021. H14 uses no fabricated five-minute history. Record profile inclusion before any validation search; enable R60 only then, or treat it as a later exploratory experiment with a new untouched evaluation period.

| Model | Inputs | Role |
|---|---|---|
| ZERO | None; predicts zero log return | No-price-change baseline. |
| MEAN | Training mean target, separately by symbol | Constant-return baseline. |
| RAW-RIDGE | Joint causal features and masks, with 1, 4, or 8 lags | Main non-physics comparator. |
| PHYSICS-RIDGE | Forty-eight measured physical values | Diagnostic of the reservoir alone. |
| RAW+PHYSICS | All eight raw lags and masks, plus physical values | Primary proposed model. |
| MARKOV | Per-asset hourly return/volatility state, a training-fitted transition matrix, and state-conditioned return means | Separate temporal probabilistic baseline, defined in Section 5. |

The headline comparison is **R50/RAW+PHYSICS versus R50/RAW-RIDGE**, selected on validation within their fixed budgets. Retain the eight-lag RAW-RIDGE result separately because it uses the exact raw block in RAW+PHYSICS. Report O14's corresponding comparison as the simpler reference, R50 versus O14 as the extra-information comparison, and H14 versus O14 as the training-history comparison. These answer different questions. Do not pick a headline profile after seeing final errors.

MARKOV is a deliberately smaller information comparator, not the equally informed control for attributing value to physics. O14, R50, and enabled R60 share the same Markov fit because its hourly training data and definitions are identical; cache and report that identity rather than pretending these are independent models. H14 fits its own chain on the longer training history.

Beating ZERO alone does not show that physics contributes value.

### 2.2 Exact eight-hour target

For the current bar starting at t:

~~~text
decision_time = t + 3,600
target_bar_start = t + 8 × 3,600
outcome_time = target_bar_start + 3,600
target_return[symbol] = ln(close[symbol, target_bar_start] / close[symbol, t])
~~~

The outcome occurs exactly 28,800 seconds after the decision. A 07:00–08:00 candle produces an 08:00 decision evaluated against the 15:00–16:00 candle's close.

Primary scoring requires:

1. Both assets have the current bar.
2. At least four consecutive paired observations have been processed in the current segment, including the current bar.
3. Both assets have every hour t + k × 3,600 for k = 1 through 8.
4. Current and target bar starts share an America/New_York date.
5. Decision and outcome satisfy the split boundaries below.

Find the endpoint by timestamp, never row index + 8. Do not fill missing intermediate hours.

The evaluator checks future availability. The physical input stream must process every paired observation whether or not it will later qualify for scoring. Generating state only at retrospectively eligible origins would leak future availability into the dynamics.

This is an **eight-hour, within-day, extended-session forecasting experiment**. It is not eight regular trading hours or a close-to-next-morning forecast. State that restriction in the report and video.

### 2.3 Expected counts

These O14/R50 counts were computed from timestamp structure during planning, using four observations of warmup, same-date endpoints, and complete intervening hourly coverage. R60, if enabled, must preserve the same population. Reproduce them in the implementation:

| Split | Paired input bars | New York dates | Eligible origins per symbol |
|---|---:|---:|---:|
| Training: 2021-10-04 through 2023-12-31 | 8,850 | 564 | 2,646 |
| Validation: calendar 2024 | 4,022 | 252 | 1,249 |
| Final test: 2025-01-01 through 2026-10-02 | 7,015 | 439 | 2,186 |
| Total | 19,887 | 1,255 | 6,081 |

Each paired origin has two targets; the two ETFs are not independent replications. There is one paired date with an internal hourly gap; the strict continuity rule removes one candidate whose endpoint alone exists.

H14's combined-source timestamp audit gives:

| Split | Paired input bars | New York dates | Eligible origins per symbol | Non-overlapping origins |
|---|---:|---:|---:|---:|
| Training: 2016-01-04 through 2023-12-31 | 31,292 | 2,012 | 9,103 | 2,003 |
| Validation: calendar 2024 | 4,022 | 252 | 1,249 | 252 |
| Final test: 2025-01-01 through 2026-10-02 | 7,015 | 439 | 2,186 | 439 |
| Total | 42,329 | 2,703 | 12,538 | 2,694 |

Nine H14 training dates have no eligible origin, so its non-overlap count is not the number of observed dates. Its validation/final paired-input, eligible-origin, and non-overlap timestamp arrays were checked against the original and are exactly identical. Reproduce these structural checks before fitting; no target values or predictive performance were inspected to obtain these counts. Supplemental masks never enter target eligibility.

A two-observation warmup would create more origins, but four is the fixed version-1 choice. Do not silently switch between these counts. An eight-observation warmup followed by predicting on the ninth would eliminate nearly all origins in a sixteen-hour day.

### 2.4 Splits and purging

~~~text
validation_start = 2024-01-01T05:00:00Z
test_start       = 2025-01-01T05:00:00Z
dataset_end      = 2026-10-03T04:00:00Z
~~~

- Training: decision < validation_start and outcome < validation_start.
- Validation: validation_start <= decision < test_start and outcome < test_start.
- Final: test_start <= decision and outcome < dataset_end.

Upper boundaries are exclusive. Test a label reaching the boundary even if the existing within-day data never generates that case.

Each profile fits preprocessing and coefficients on its own training period only, selects settings on validation, then freezes everything. This includes Markov state thresholds, transition probabilities, and return means. **Do not refit on training plus validation for this first result.** A later walk-forward/refit experiment needs its own protocol.

Finish selection and lock every included profile before releasing any final performance. Export every included model's final prediction ledger before joining final targets. If a required profile is blocked, record its exclusion and reason before that release; a result from a completed profile cannot guide repairs, feature changes, or inclusion decisions for another profile on the same final period.

Final forecasts must be stored before final targets are joined for scoring. The final report cannot decide which hyperparameters should have been used. Chronological evaluation follows the future-exclusion principle in [Forecasting: Principles and Practice](https://otexts.com/fpp3/tscv.html).

## 3. Causal feature pipeline

~~~mermaid
flowchart LR
    A[Immutable paired bars] --> B[Causal feature stream]
    B --> C[Training-fitted transform]
    C --> D[Native Roblox physics]
    D --> E[Measured state]
    B --> F[Raw historical baseline]
    E --> G[Luau readout]
    F --> G
    G --> H[Immutable forecasts]
    A --> I[Separate target lookup]
    H --> J[Evaluator]
    I --> J
    J --> K[Metrics and replay]
~~~

Only the training-label join and evaluator may look forward. Base Features receives the current and preceding pair. SupplementalFeatures receives a bounded context view containing only observations available by the current decision time. The native runner receives a numeric input vector, not the Dataset or a target. The optional regime stage receives a frozen Markov artifact and current/past hourly states.

Precompute New York date/hour metadata using Node Intl.DateTimeFormat with timeZone = "America/New_York". Embed that metadata in the plugin. Do not approximate daylight saving with one UTC offset.

### Original hourly inputs for O14 and H14

For each symbol compute six features:

| Feature | Formula | Special case |
|---|---|---|
| One-hour return | ln(C / previous C) | Zero at a segment start. |
| Body | ln(C / O) | Current completed bar. |
| Range | ln(H / L) | Current completed bar. |
| Close location | 2(C − L)/(H − L) − 1 | Zero when H = L. |
| Volume | ln(1 + V) | Reject negative volume. |
| VWAP displacement | ln(C / VWAP) | Reject nonpositive VWAP. |

Append sin(2πh/24) and cos(2πh/24), where h is the New York bar-start hour. Input order is six SPY, six QQQ, then the two clock features: fourteen values.

Reject non-finite values and nonpositive OHLC/VWAP. A rejected input is an explicit run failure to investigate, not an opportunity to drop a difficult period.

Fit mean and population standard deviation for the first twelve dimensions using all training-period paired inputs and Welford accumulation. If standard deviation < 1e-12, output zero and record the constant-column flag. Standardize and clip those twelve values to [-4, 4]. Keep the two clock features in [-1, 1]. Freeze this transform for validation/test.

Scaler.transform preserves the profile's declared column count and emits zero for a constant column. Ridge, rather than the input scaler, owns the later retained-column projection. O14/H14 therefore remain fourteen-dimensional.

Training-wide preprocessing is allowed for fitting the training model. Do not describe training fit scores as out-of-sample forecasts. Record clipping rates by feature and split.

### Rich input contract for R50

R50 retains the base fourteen values, then appends thirteen SPY context values, thirteen QQQ context values, five IWM values, and five TLT values, in that order. This is exactly **50 values**. Context features and masks go to both the raw baseline and the physical projection. The hourly stream, resets, four-observation warmup, and target population remain unchanged.

The contracts below are proposed experiment choices, not claims that Alpaca supplies these derived features. Calculate them in Luau from preserved source bars. Node may construct timestamp/availability indices and independently check fixtures, but must not fit the production transforms.

For the current hourly bar [t,t+3600), let j=0..11 denote expected five-minute starts t+300j. Use only those exact timestamps with completed time <= t+3600; never substitute the first twelve nearby rows. If all twelve exist, define x0=O0 and x(j+1)=Cj, then rj=ln(x(j+1)/xj). These twelve returns include the initial open-to-close move and subsequent close-to-close moves. This convention is fixed even when opens differ from previous closes.

| Per-symbol context position | Value | Availability and zero handling |
|---|---|---|
| 1 | Intrahour realized variation sqrt(sum(rj²)) | Requires all twelve children. |
| 2 | Final-fifteen-minute return ln(C11/C8) | Requires all twelve children under this common contract. |
| 3 | Path efficiency abs(sum(rj))/sum(abs(rj)) | Requires all twelve; zero when denominator is zero. Bounded [0,1]. |
| 4 | Final-fifteen-minute volume share (V9+V10+V11)/sum(Vj) | Requires all twelve; zero when total volume is zero. Bounded [0,1]. |
| 5 | Five-minute-complete mask | 1 for exactly all twelve timestamps, otherwise 0. |
| 6 | Five-minute coverage | Number of observed expected children / 12, including partial hours. |
| 7 | Relative hourly volume ln(1+Vcurrent) minus mean ln(1+V) over previous twenty observed dates at this same NY bar-start hour | Exclude current date; require at least five prior observations; use at most twenty. |
| 8 | Relative-volume-available mask | 1 when position 7 meets the history requirement. |
| 9 | Previous completed daily bar's intraday return ln(Cday/Oday) | Latest available daily bar must be from a strictly earlier NY date and no older than seven calendar dates. |
| 10 | Daily return volatility sqrt(mean((q-mean(q))²)) over twenty prior close-to-close daily returns q=ln(Cd/CpreviousObservedDay) | Requires twenty returns from twenty-one available daily bars, latest bar satisfying the same freshness rule. |
| 11 | Previous-day-return-available mask | Availability for position 9. |
| 12 | Daily-volatility-available mask | Availability for position 10. |
| 13 | Daily age min(calendar-date difference,7)/7 | Latest available bar's age; 1 if missing or stale. |

Positions 1–4 are unavailable together when any five-minute child is absent. Preserve the actual coverage in position 6. Do not interpolate prices or turn missing children into zero-volume candles. The current native hourly OHLCV remains authoritative; do not replace it with a sum/resample of five-minute data or assume the two native aggregations must match exactly.

Daily availability is conservatively defined as the next **New York calendar midnight after the bar's NY date**, computed with timezone-aware metadata. The bar's midnight start timestamp is not availability. Do not add a fixed 86,400 seconds over DST. Use prior completed native daily bars; never use any part of today's final daily aggregate. Twenty daily returns refer to observed daily records and may cross weekends and corporate actions; these raw prices are not total-return data. Keep the distinction in the report.

The same-hour volume buffer uses each symbol's own native hourly observations and can initialize from earlier combined hourly history; it does not require those past rows to belong to the paired input intersection. The daily context buffer can initialize from the 2016 onward daily records. These are past observations, not extra fitting rows. Preserve these rolling buffers across daily physical resets, and reconstruct them causally on resume. Duplicate dates, invalid values, or out-of-order context rows are audit failures, not missingness masks.

For each of IWM and TLT, at decision T=t+3600 select the latest hourly bar u whose u+3600 <= T. A usable context observation requires age=T-(u+3600) <=7200 seconds and a valid predecessor exactly u-3600 on the same NY date as u. Append:

| Position | Value |
|---|---|
| 1 | ln(Cu/C(u-3600)) |
| 2 | ln(Hu/Lu) |
| 3 | ln(1+Vu) |
| 4 | Usable-context mask |
| 5 | min(age,7200)/7200; 1 if there is no usable observation |

If any prerequisite fails, positions 1–3 are unavailable together and mask=0. Do not search backward for a different apparently favorable pair. A missing/old context bar cannot remove the SPY/QQQ origin or reset the physical stream. Carrying a latest observed bar within this bounded age is an explicit feature rule, not a fabricated bar at the current timestamp.

### Rich scaling, masks, and feature identity

Keep a FeatureRow with values and a per-column observed flag before transformation. For R50, standardize only the twelve original continuous values; positions 1,2,7,9,10 within each thirteen-value SPY/QQQ context block; and positions 1–3 within each IWM/TLT block. This is 28 continuous columns. Fit each column's mean and population deviation on its observed training values only, then clip transformed observed values to [-4,4]. Unavailable continuous values become zero **after** scaling, and their explicit masks remain present. A column never observed in training is recorded and kept at zero for every split; do not fit it on validation.

Keep clock sin/cos, masks, coverage, efficiency, volume share, and normalized ages at their defined bounds without z-scoring. Masks, coverage, and age sentinel values are themselves always observed; underlying feature missingness must not erase those signals. Unavailable efficiency/share become zero with complete-mask=0. R50 has 22 such bounded columns and 28 continuous columns. Record names, index, formula version, observed-flag rule, transform, units, and availability policy in feature-schema.json; assert D=50 at every boundary. The final ridge-column scaler still operates on eligible training design rows as described in Section 5.

Missingness indicators are information and must be shared by both comparators. Save feature-observation counts, coverage distributions, clipping rates, and context ages by split. These diagnostics never authorize deleting inconvenient final rows.

### Optional regime inputs for R60

This optional experiment uses the observed-state Markov chain defined in Section 5, not an HMM. Append, for SPY then QQQ, four one-step state probabilities plus one state-available mask. For an available current state i, probabilities are row i of frozen P. During the first three observations of a segment, use pi*P, where pi_j=(trainingStateCount_j+1)/(totalTrainingStates+4), and mask=0. At the fourth observation onward use the state-conditioned row and mask=1. These ten bounded columns make D=60; no extra z-scaling is applied to them at the physical input stage.

Fit the chain on training only before generating R60 states, and freeze it through validation/final replay. Give the exact same R60 features and lag history to RAW-RIDGE. Do not tune damping, geometry, or spring constants dynamically by regime in this first protocol. R60 adds another declared input experiment; its success cannot be credited to physics unless it beats its equally informed raw comparator.

A hidden Markov model is deferred. If later implemented, fit parameters on training only and use filtered probabilities based on observations up to the decision. Full-series smoothed probabilities use later observations and are prohibited forecast inputs. That extension needs a new state/emission/fitting specification and a preregistered budget before accessing an untouched evaluation period.

### Segments and warmup

A new segment starts on the first pair, a New York date change, or timestamp delta other than 3,600 seconds.

At each segment start:

1. Clear the lag buffer.
   Preserve or causally reconstruct the supplemental rolling context buffers; physical reset does not erase legitimately available prior-day information.
2. Reset bodies to equilibrium, zero linear/angular velocity, clear input forces.
3. Execute sixty zero-input steps of 1/60 simulated second.
4. Set observed count to zero.
5. Feed real paired observations in order; the fourth may produce a scored forecast.

Settling steps are mechanical initialization, not synthetic market candles. Do not simulate an overnight gap as fabricated prices or thousands of implied hourly observations.

Daily resets intentionally discard cross-day physical memory. This is a bounded intraday reservoir, with a known initial state. Four observations are a chosen startup policy, not a claim that every slow mode has reached equilibrium.

Compare soft resets with a complete rebuild. Native solver warm-start state might survive CFrame/velocity resets. If repeated segments fail the repeatability gate, rebuild the owned reservoir at every segment boundary and include that cost in throughput.

### Lag baseline

Retain eight transformed D-value inputs for the selected profile. Flatten current first, then earlier inputs, and append one availability mask per lag. Pad missing pre-segment history with zeros after transformation; use lag-mask zero for padding and one for a real vector. The per-feature masks already inside R50/R60 are separate from these lag masks.

Dimensions are (D+1)*L for L in {1,4,8}, as listed in Section 2. At every eligible origin in the original frozen dataset, the reservoir has seen at most eight observations since reset. Recheck this property for H14. If a new source allows longer eligible prefixes, the eight-lag comparator still has its declared bounded history and that difference must be reported rather than silently changed.

RAW+PHYSICS has 8*(D+1)+48 columns before constant-column removal: 168 for O14/H14, 456 for R50, and 536 for optional R60.

## 4. Native mechanical reservoir

### Why this computation is meaningful

Native constraints and the physics solver evolve the state. Luau sets forces and reads measurements; it does not move nodes directly during processing.

Physical systems with memory and nonlinear responses can support trained readouts; [Information processing via physical soft body](https://www.nature.com/articles/srep10487) is a research basis for this approach. It is not evidence of a financial edge.

### Execution: explicit native stepping in a local plugin

[WorldRoot:StepPhysics](https://create.roblox.com/docs/reference/engine/classes/WorldRoot) is a PluginSecurity API that advances native simulation by a positive dt and can restrict simulation to an explicit BasePart array. Omitted connected parts are treated as anchored. The [official announcement](https://devforum.roblox.com/t/new-stepphysics-plugin-api/3093140) describes Workspace/WorldModel use.

Use Edit mode. Mixing ordinary Play-mode advancement with explicit stepping on the same bodies would change the experiment.

Create only an owned Workspace.MarketReservoirLab model. Pass all twenty-four moving parts on every call; anchors remain anchored. Do not simulate one node at a time.

~~~lua
local RunService = game:GetService("RunService")
assert(not RunService:IsRunning(), "Offline lab requires Edit mode")
workspace:StepPhysics(1 / 60, reservoir:movingParts())
~~~

The Studio MCP execute_luau tool's security identity has not been verified. A permission error should route to a legitimate local plugin, not an invented workaround. A runtime adapter is an explicit fallback described later.

### Concrete geometry

Defaults are engineering starting values to test mechanically, not financially optimized settings.

~~~text
24 nodes: 4 rows × 6 columns
i = row*6 + column + 1; row=0..3, column=0..5
rest_i = Vector3.new(0, 8 + row*4, column*4)
node Size = Vector3.new(1,1,1)
node Anchored=false, CanCollide=false, CanTouch=false, Massless=false
density=1; read actual AssemblyMass after construction
rail: passive PrismaticConstraint along world X
rail limits: -3 to +3 studs, restitution=0, no motor/servo
axial spring anchor: rest_i - Vector3.new(6,0,0)
axial FreeLength=6
coupling: horizontal/vertical nearest neighbors, no diagonals
coupling anchor separation at equilibrium=4; FreeLength=3
~~~

Each rail uses an anchored guide at equilibrium and a centered attachment on the node. Attachment axes point along world +X, with matching secondary axes. The axial spring uses a separate anchor. Rails react gravity; do not change global Workspace gravity.

Set the PrismaticConstraint actuator to None. Confirm the installed API and orientation in the one-node probe. [Prismatic constraints](https://create.roblox.com/docs/physics/constraints/prismatic) constrain motion to an axis; [SpringConstraint](https://create.roblox.com/docs/reference/engine/classes/SpringConstraint) supplies stiffness, damping, and readable CurrentLength.

Use:

~~~text
omega by column = [2, 3, 4.5, 6, 9, 12] radians/second
zeta by row = [0.18, 0.25, 0.35, 0.50]
k_i = measured_mass_i * omega_i²
c_i = 2 * zeta_i * measured_mass_i * omega_i
coupling stiffness_ij = 0.15 * sqrt(k_i*k_j)
coupling damping_ij = 0.05 * sqrt(c_i*c_j)
spring MaxForce = 100000
~~~

There are twenty-four axial and thirty-eight coupling springs. Use limits as safety stops, not a deliberate source of collision chaos. Reject a training-calibration candidate if more than 0.1% of measured node states reach |x| >= 2.9.

### Nonlinearity

Neighboring nodes slide on parallel rails. Their coupling spring length is sqrt(4² + (x_i − x_j)²); its projected force changes nonlinearly with relative displacement. Pretension supplies small-motion coupling.

This expression explains the geometry. **Do not implement it as a scripted force law.** Roblox's SpringConstraint must compute the response. Verify nonlinear response experimentally; a nonlinear geometry operated over tiny displacements can still behave almost linearly.

### Driving the network

Generate a 24×D projection with Roblox Random.new(20261004), entries uniform in [-1,1], each row normalized to Euclidean norm one. D comes from the profile schema: 14, 50, or 60. Save the actual matrix, PRNG identity, and seed, not only the seed. Reinitialize the generator for each profile; O14 and H14 share the same saved 24×14 matrix. Do not substitute a different PRNG and expect identical projections. Pure CLI tests can use an injected numeric matrix fixture.

Use a linear projection after the shared feature clipping:

~~~text
q_i = dot(projection_row_i, input) / sqrt(D)
force_i = Vector3.new(k_i * drive_displacement * q_i, 0, 0)
~~~

No additional nonlinear projection clipping is used, so hidden software nonlinearities do not get credited to physics. q remains bounded because the input vector is bounded.

A VectorForce per node uses RelativeTo = World and ApplyAtCenterOfMass = true. Hold its force for the entire simulated candle interval. During training-only mechanical calibration, test drive_displacement in [0.15, 0.30, 0.60] studs and select the largest that passes stability and repeatability. Do not use targets for that selection.

One market observation receives twelve explicit StepPhysics calls at dt=1/60 second, totaling 0.2 simulated second. This is a computation timescale, not a physical model of real market time.

### Readout and candidate settings

After the twelfth completed step, read all node X displacements divided by 3, then all X velocities divided by 3*omega_i. This gives forty-eight features in stable index order.

Record spring lengths, rail contacts, and maximum excursions as diagnostics, not extra version-1 model inputs.

Compare three physical presets:

| ID | Omega multiplier | Projection | Geometry and driving |
|---|---:|---|---|
| P1 | 0.75 | Same saved matrix | Same rules |
| P2 | 1.00 | Same saved matrix | Same rules |
| P3 | 1.25 | Same saved matrix | Same rules |

Recompute k and c from multiplied omega; derive coupling and forces from those resulting values. Do not apply the multiplier twice.

For each profile, calibrate one common drive displacement against all three presets on that profile's training-only mechanical probes, then freeze it. Log the calibration window, feature transform, profile, and value. If no declared value passes, stop that profile, diagnose mechanically, and record any revised design before validation.

Yield to Studio between small batches without changing dt or step count. Prevent concurrent runs and abort if Studio enters Play mode. Benchmark 200 observations before estimating full runtime.

A real-time 0.2-second-per-bar pass over 19,887 pairs would take about 66 minutes before reset overhead. Explicit stepping might be faster; no speedup has been measured.

For O14/R50 search, run only training plus validation (12,872 bars per profile) for each physical preset. H14 uses 35,314 development bars, including its longer training stream and the same validation period. R60, if preregistered, has the same 12,872-bar development count as R50. After every included profile is locked, run each chosen preset on the 7,015 final bars. Do not simulate final periods for rejected configurations.

Cache state rows by profile, source-group hashes, feature-schema hash, observed-value scaler hash, optional Markov-artifact hash, physical-config hash, runner mode, Studio version, and run ID. Seven ridge penalties reuse one physical trajectory. Different profiles have different state identities even if their timestamps coincide.

Resume only at a segment boundary and replay that segment from its beginning. Restore supplemental rolling context by scanning only available prior source records, or from a verified cursor checkpoint with the same source/schema hashes. Position and velocity alone may not capture hidden native solver state.

## 5. Fitting in Luau

### Ridge regression

Fit two output columns, one per symbol. Fit readout-column means/scales on eligible training rows, separately from the physical input scaler. Remove columns with training standard deviation < 1e-12.

Center targets and leave the intercept unpenalized:

~~~text
A = XᵀX / n + lambda*I
B = Xᵀ(Y - mean(Y)) / n
beta = CholeskySolve(A, B)
prediction = mean(Y) + standardized_row * beta
lambda grid = [0.00001, 0.0001, 0.001, 0.01, 0.1, 1, 10]
~~~

Use double-precision Luau numbers. Implement Cholesky factorization and triangular solves, not matrix inversion. Share the factorization across the two outputs.

Check finite entries, symmetry, positive pivots, and relative residual ||Aβ−B|| / max(1,||B||) <= 1e-8 on the small reference fixtures. A production candidate failing numerical validation is rejected and logged; do not silently change its lambda.

Compute means/scales and sufficient statistics in passes over cached rows rather than constructing several large matrix copies. The maximum covariance dimension is 168 for O14/H14, 456 for R50, or 536 with optional R60. Benchmark accumulation and Cholesky on the actual required dimension before estimating total runtime; the original 168-column estimate does not cover the expanded experiment.

### Financial Markov baseline

Implement a small observable-state Markov reward model independently for SPY and QQQ. This is a proposed finite-state comparator, not the MarkovJunior spatial generator, not a hidden-state model, and not evidence that returns actually obey a stable Markov process.

At a paired observation with segmentOffset >=4, compute three consecutive hourly log returns ending at the current bar, r0,r1,r2, using the four most recent paired closes from the same segment. Define v=sqrt((r0²+r1²+r2²)/3). Fit a per-symbol threshold tau as the median v over all valid training input observations; for an even count use the mean of the two middle sorted values. No validation/final values influence tau.

Four states use the current r0 and the fitted threshold:

| State index | Definition |
|---|---|
| 1 | r0 >=0 and v <=tau |
| 2 | r0 <0 and v <=tau |
| 3 | r0 >=0 and v >tau |
| 4 | r0 <0 and v >tau |

Zeros and threshold ties follow those inequalities. The first three inputs have no state. The fourth and later inputs have a state even when their future eight-hour target will be unscoreable.

Fit transition counts N_ij only from consecutive state-bearing observations one hour apart in the same segment, with both completed times strictly before validation_start. Never connect two dates, bridge a missing hour, or connect training to validation. Include all such training transitions, not only observations later eligible for eight-hour scoring. Fit state reward means from each state-bearing training observation's current one-hour return, without reading its future eight-hour target.

~~~text
P_ij = (N_ij + 1) / (sum_j N_ij + 4)
globalReward = mean(r0 over all state-bearing training observations)
mu_j = (sum(r0 for state j) + 20*globalReward) / (count(state j) + 20)
p_0 = one-hot vector for current state
p_k = p_(k-1) * P, k=1..8
eight_hour_log_return_forecast = sum(k=1..8, dot(p_k, mu))
~~~

P is row-stochastic: row i means transitions **from** i; p is a row vector. Laplace pseudocount 1 and reward shrinkage strength 20 are fixed design choices, not validation-search parameters. An unobserved state's row is uniform and its reward shrinks to the global mean. An entirely empty training set is a hard failure. The forecast is the expected sum of eight one-hour log returns; P^8 alone gives endpoint state probabilities and is not itself a return forecast.

Use exact finite sums and matrix/vector arithmetic, with no Monte Carlo draws. This model has one declared setting per unique training history. Emit a forecast at every warmed origin and let the common evaluator decide horizon eligibility. No transition/reward updates occur during validation or final replay. Save tau, state/reward counts, transition counts, P, mu, globalReward, pi, source hashes, and the state-definition version in markov-model.json.

Test row sums and bounds, unseen states, state ties, restart boundaries, train/validation boundaries, and independence from future values. With every mu_j=c the eight-step forecast must be 8c for any valid P. With P=identity and a one-hot starting state i it must be 8*mu_i. Those are arithmetic fixtures; production P still uses the stated smoothing.

Financial Markov-switching models motivate a regime comparison, but this observable-state reward model is an intentionally simpler design. It does not reproduce a published HMM or imply that quiet/volatile states capture all relevant market behavior.

### Selection budget

Within each included profile, RAW-RIDGE: three lag lengths × seven lambdas = twenty-one settings.

RAW+PHYSICS: three physical configurations × seven lambdas = twenty-one settings.

Also retain seven lambda fits for PHYSICS-RIDGE at the selected physical preset and seven eight-lag raw fits already contained in RAW-RIDGE's search. ZERO, MEAN, and MARKOV have no validation hyperparameter search. Three required profiles therefore declare 147 ridge candidates (3*(21+21+7)); optional R60 adds 49. This accounting does not count repeated use of a fitted candidate or a shared Markov artifact twice. Mechanical drive calibration uses only inputs and has its separate fixed grid.

A setting uses a shared lambda for the two output heads. Select by the average of each symbol's validation RMSE divided by its training target standard deviation. Reject zero target variance. Tie tolerance is 1e-12; choose larger lambda, then smaller lag count or lower physical ID.

Keep all candidate results, including failures. Equal candidate count makes search transparent; it does not prove equal effective model capacity.

PHYSICS-RIDGE uses the physical configuration selected for RAW+PHYSICS and chooses its own lambda on validation. It is diagnostic, not another route to redefining the primary winner.

This protocol does not refit after validation. Freeze profile inclusion and headline comparison, input scaler and observed-value rules, context availability/age policies, projection, geometry, masses, step schedule, reset method, feature order, Markov thresholds/P/rewards, readout scaler, retained columns, coefficients, lambda, target means, split rules, and all source/schema/code hashes.

## 6. Evaluation and claims

Per symbol and split, report:

- Eligible origins, issued forecasts, missing forecasts, excluded horizons, and physical failures.
- RMSE and MAE of log returns, displayed ×10,000 in basis points.
- Direction accuracy on nonzero actual returns. A zero prediction counts as neither up nor down and is incorrect for a nonzero target; report its count.
- Always-up and training-majority-direction benchmarks.
- Correlation, undefined if either series has zero variance.
- Mean prediction, mean realized return, and forecast dispersion.
- Monthly, origin-hour, and segment-age breakdowns.

Use the same structural scoring population for all models within each split. O14/R50/R60 have identical populations; H14 has more training rows but identical validation/final origins. A missing physics prediction stays visible; do not quietly restrict comparison to periods where it succeeded or supplemental masks are all one. Report error breakdowns by supplemental coverage as descriptive diagnostics, never as a replacement headline population.

### Overlap and uncertainty

Also score a deterministic non-overlapping subset: sort eligible origins and accept one only if its decision time is at or after the previous selected outcome time. For O14/R50/R60 expect one origin per New York date: 564/252/439 by split. H14 has 2,003/252/439, with nine observed training dates lacking an eligible origin; its validation/final subsets must match exactly.

Implement an approximate paired moving-block bootstrap over ordered dates: blocks of five consecutive observed dates, 2,000 replicates, a fixed saved seed. A sampled date carries all origins, both assets, and all models together. Recompute metric differences and show 2.5th/97.5th percentiles. Do not bootstrap individual overlapping forecasts.

The primary aggregate uncertainty statistic is the R50 physics-minus-raw difference in selection-style normalized RMSE, with training target scales fixed. Also report per-symbol differences. Cross-profile secondary comparisons use O14's fixed training target scales for a common denominator; within-profile selection uses that profile's own training scales. Report all preregistered comparisons, identify the primary one, and label secondary intervals exploratory rather than treating many unadjusted intervals as independent confirmatory discoveries. Do not treat correlated SPY/QQQ predictions as independent experiments.

Freeze mechanism checks before final targets are shown:

1. Exact eight-lag raw block without physical features.
2. Physics-only readout.
3. Repeat the selected physical setup three times on a fixed 200-observation training window.
4. Optional reset-every-observation ablation, with omission declared before final evaluation if runtime prevents it.

Initial repeatability gate: maximum absolute difference in normalized physical features <=1e-3 and median <=1e-5 across repeated training probes. These are engineering tolerances, not proven universal properties. If they fail, investigate and record any revision before proceeding; do not round away discrepancies.

Claim “evidence of incremental value on this holdout” only when the frozen primary metric improves and its paired uncertainty estimate supports that interpretation. Small mixed or uncertain differences should be reported as such.

Forecast confidence intervals require separate calibration on prior out-of-sample errors. Native simulation variability is not forecast uncertainty.

P&L is a separate project requiring fill timing, costs, spreads, slippage, overlapping-position rules, and exposure limits.

## 7. Files and interfaces to build

~~~text
lab/config/default.json                    experiment settings
lab/src/Main.server.luau                    plugin lifecycle and toolbar
lab/src/Types.luau                          shared contracts
lab/src/Config.luau                         validated/generated config
lab/src/Data/Dataset.luau                   paired access and segments
lab/src/Data/Features.luau                  causal 14-value input
lab/src/Data/ContextCursor.luau             bounded as-of supplemental access
lab/src/Data/SupplementalFeatures.luau      R50 construction and observed flags
lab/src/Data/FeatureSchema.luau             profile order, dimensions, transforms
lab/src/Data/Scaler.luau                    training-fitted transforms
lab/src/Data/History.luau                   lag buffer and masks
lab/src/Data/Targets.luau                   future lookup, evaluator only
lab/src/Physics/Reservoir.luau              build/reset/drive/read/destroy
lab/src/Physics/ExplicitRunner.luau         plugin native stepping
lab/src/Physics/Diagnostics.luau            physical gates and throughput
lab/src/Model/Cholesky.luau                  numerical solver
lab/src/Model/Ridge.luau                     statistics, fit, predict
lab/src/Model/Markov.luau                    four-state fit and eight-step reward forecast
lab/src/Model/RegimeFeatures.luau            optional ten-column R60 probability block
lab/src/Model/Selection.luau                 ranking and tie policy
lab/src/Experiment/Controller.luau          phase state machine
lab/src/Experiment/Cache.luau               causal state chunks
lab/src/Experiment/Ledger.luau              append-only forecasts
lab/src/Experiment/Evaluator.luau           labels and metrics
lab/src/Experiment/Bootstrap.luau           paired date-block resampling
lab/src/Experiment/ResultStore.luau         bounded JSON export pages
lab/src/UI/Panel.luau                       controls, progress, metrics
lab/src/UI/Replay.luau                      recorded-state replay
lab/tests/RunAll.luau                       dependency-free Studio harness
lab/tests/RunPure.luau                      standalone CLI entry point, no engine globals
lab/tests/Data.spec.luau
lab/tests/Features.spec.luau
lab/tests/Context.spec.luau
lab/tests/Markov.spec.luau
lab/tests/Physics.spec.luau
lab/tests/Ridge.spec.luau
lab/tests/Experiment.spec.luau
lab/tests/Export.spec.luau
lab/fixtures/synthetic-bars.json
lab/fixtures/ridge-reference.json
tools/prepare-lab.mjs
tools/prepare-lab.test.mjs
tools/build-plugin.mjs
tools/build-plugin.test.mjs
tools/validate-results.mjs
tools/validate-results.test.mjs
build/                                     generated local plugin package
runs/<run-id>/environment.json
runs/<run-id>/data-audit.json
runs/<run-id>/protocol.json
runs/<run-id>/feature-schema.json
runs/<run-id>/progress.json
runs/<run-id>/state-cache/
runs/<run-id>/candidates.json
runs/<run-id>/model-lock.json
runs/<run-id>/model.json
runs/<run-id>/markov-model.json
runs/<run-id>/predictions.jsonl
runs/<run-id>/outcomes.jsonl
runs/<run-id>/metrics.json
runs/<run-id>/diagnostics.json
runs/<run-id>/report.md
~~~

Each run ID identifies a profile and attempt. Add experiment-manifest.json above the profile runs to record required/optional inclusion, primary and secondary comparisons, and all model-lock hashes before final release. Only add Physics/RuntimeRunner.luau if the fallback is actually required. Add a lighting plugin module only in the optional extension.

The generated plugin embeds copies of source modules, the existing dataset modules, and session metadata. On-disk sources remain authoritative. Record source hashes to identify stale installed copies.

### Shared contracts

The following are planned project interfaces, not existing Roblox APIs. Put concrete definitions in Types.luau before delegating implementation.

~~~lua
export type Pair = {
    index: number, t: number, dateNY: string, hourNY: number,
    segmentId: number, segmentOffset: number,
    spy: {number}, qqq: {number},
}
export type StateRow = {
    index: number, t: number, segmentId: number,
    profileId: string, featureSchemaHash: string,
    input: {number}, state: {number}, valid: boolean,
}
export type FeatureRow = {
    values: {number}, observed: {boolean},
    decisionTime: number, profileId: string,
}
export type FeatureSchema = {
    profileId: string, dimension: number,
    names: {string}, continuous: {boolean}, version: string,
}
export type OutcomePair = {
    eligible: boolean, reason: string?,
    spy: number?, qqq: number?, outcomeTime: number,
}
export type Forecast = {
    id: string, runId: string, modelId: string, symbol: string,
    t: number, decisionTime: number, outcomeTime: number,
    prediction: number, modelHash: string, dataHash: string,
}
export type Outcome = {
    forecastId: string, eligible: boolean,
    actual: number?, exclusionReason: string?,
}

Dataset.load(spyModule, qqqModule, sessionIndex): Dataset
Dataset:get(index: number): Pair?
Dataset:count(): number
Features.compute(current: Pair, previous: Pair?): {number}
ContextCursor.new(sourceGroups, availabilityIndex): ContextCursor
ContextCursor:advance(decisionTime: number): CausalContext
SupplementalFeatures.new(schema: FeatureSchema): SupplementalFeatures
SupplementalFeatures:push(current: Pair, previous: Pair?, context: CausalContext): FeatureRow
Scaler.fit(rows: {FeatureRow}, schema: FeatureSchema): Scaler
Scaler:transform(row: FeatureRow): {number}
History.new(maxLag: number): History
History:reset(): ()
History:push(input: {number}): ()
History:vector(lags: number): {number}
Targets.lookup(dataset: Dataset, origin: Pair, splitName: string): OutcomePair
Reservoir.build(parent: Instance, config): Reservoir
Reservoir:reset(): ()
Reservoir:drive(input: {number}): ()
Reservoir:read(): {number}
Reservoir:movingParts(): {BasePart}
Reservoir:destroy(): ()
ExplicitRunner.new(reservoir: Reservoir, config): ExplicitRunner
ExplicitRunner:stepBar(input: {number}): {number}
Cholesky.solve(A: {{number}}, B: {{number}}): {{number}}
Ridge.fit(rows, targets, lambda: number): RidgeModel
Ridge.predict(model: RidgeModel, row: {number}): {number}
Markov.fit(trainingPairs, options): MarkovModel
Markov.state(model: MarkovModel, fourRecentPairs): {number}?
Markov.predict(model: MarkovModel, states: {number}, horizon: number): {number}
RegimeFeatures.compute(model: MarkovModel, states: {number}?): {number}
Selection.rank(candidateMetrics, trainingTargetStd): {Candidate}
Ledger.new(metadata): Ledger
Ledger:append(record: Forecast): ()
Ledger:page(startIndex: number, limit: number): {Forecast}
Evaluator.score(forecasts, outcomes): Metrics
Bootstrap.compare(joinedRecords, options): Interval
ResultStore:put(kind: string, records): ()
ResultStore:page(kind: string, pageIndex: number): string
Controller:start(phase: string): ()
Controller:cancel(): ()
Controller:status(): Progress
~~~

Define RidgeModel as retained-column indices, column means/scales, target means, coefficient matrix, lambda, and schema version. Candidate carries model/config/lag/lambda/score/status. Metrics carries the Section 6 counts and statistics. Interval carries estimate/lower/upper/seed/blockLength/replicateCount. Progress carries phase/runId/processed/total/segment/status/error.

MarkovModel contains two per-symbol parameter records: tau, training counts, P, mu, pi, global reward, and provenance. Markov.state returns the two state IDs in SPY/QQQ order, or nil before four consecutive observations. Markov.predict returns two expected log returns and production calls assert horizon=8. RegimeFeatures returns four probabilities and a mask per symbol. Training streams passed to fit must be explicitly sliced and boundary-validated, not unrestricted final-inclusive Datasets.

CausalContext exposes only rows whose availability time is <= its decisionTime, plus source timestamps, ages, and prior observed history. Define its typed views for five-minute children, same-hour volume history, completed daily history, and IWM/TLT as-of pairs in Types before implementation. It must not expose backing arrays with future rows. ContextCursor advances monotonically; resume creates a new cursor and reconstructs past-only buffers. Preserve one shared current/past pair stream for O14/R50 so context cannot change primary segmentation. Wrap O14/H14 base vectors as FeatureRows with all observed flags true; R60 appends its bounded regime block to the R50 row.

Input Scaler is distinct from Ridge's design-column scaler. Pure data/model modules must not assume game, script, Vector3, or Roblox Random exists in the CLI. Use dependency injection for module dependencies and randomness, or a tested explicit resolver in the package build; both entry points must exercise the same source functions. Do not maintain a separate untested CLI reimplementation.

Modules owning Dataset, Reservoir, Scaler, History, and Controller export their instance types. Keep these signatures stable across tasks; change Types and all consumers together when a justified implementation adjustment is necessary.

## 8. Implementation tasks and acceptance gates

Each task ends with a reviewable saved checkpoint. Update runs/<run-id>/progress.json and this checklist as work completes. If Git is deliberately introduced later, commits may accompany these checkpoints; Git is not a prerequisite.

Dependency order:

~~~text
Task 1: packaging/contracts/Studio and CLI harnesses
    ├─ Task 2: data and causal features for O14/R50/H14
    ├─ Task 3: native mechanics (synthetic proof first; data calibration after Task 2)
    └─ Task 4: numerical fitting and financial Markov model (data fitting after Task 2)
Tasks 2+3 -> Task 5: causal replay and export
Tasks 2+4 -> optional R60 features -> Task 3 profile calibration -> Task 5
Tasks 4+5 -> Task 6: validation selection and model lock
Tasks 2+4 -> Task 7: evaluation; final release also requires Task 6
Tasks 5+7 -> Task 8: display and replay
Tasks 1–8 -> Task 9: controlled full experiment and delivery
~~~

Independent agents may own Data, Physics, and Model modules after the shared contracts are established. Give each agent exact files and tell them they are not alone in the workspace; they must preserve others' changes. Controller, shared Types, and final integration should have one owner.

### Task 1 — Reproducible package and Studio test harness

**Files:** create lab/config/default.json, lab/src/Types.luau, lab/src/Config.luau, lab/src/Main.server.luau, lab/tests/RunAll.luau, lab/tests/RunPure.luau, tools/build-plugin.mjs, tools/build-plugin.test.mjs. Generated output: build/MarketReservoirLab.rbxmx and build/package-manifest.json.

**Consumes:** existing Luau data exports and the contracts in Section 7.

**Produces:** an installable local plugin Script with child modules, a visible source-version identifier, and a RunAll.run(filter) test entry point.

- [ ] Run the complete existing Node suite (84 tests at the last handoff) and record the actual result, not a copied historical count.
- [ ] Verify the local Luau binary launches; record its path/hash and validate a deliberate failing pure-Luau assertion produces failure. Keep native-physics tests in Studio.
- [ ] Inspect connected Studio instances before selecting one. Use a dedicated experiment place or a clearly owned namespace in an appropriate place; preserve unrelated content.
- [ ] Write a failing Node package test proving that script text containing ampersands, angle brackets, quotes, and a literal CDATA terminator survives XML encoding/decoding unchanged. Require script source to use escaped XML text rather than unsafe string concatenation around CDATA.
- [ ] Write a failing manifest test requiring the original forty data chunks and both loaders, plus every required supplemental loader/chunk enumerated from the selected group manifests, source hashes, and a stable group/symbol-to-Instance mapping. Import only required groups and avoid embedding duplicate original/combined history unnecessarily.
- [ ] Build the package by reading an explicit allowlist of project files. Do not recursively embed the workspace or hidden files. Copy no secrets.
- [ ] Map Main.server.luau to a Script named MarketReservoirLabPlugin. Put the source folders and embedded DataAssets underneath that Script; preserve each SPY/QQQ loader's Chunk children.
- [ ] Implement the test harness with pcall around named tests, fail/pass counts, and an error containing the failing test name. A failing assertion must make RunAll.run return failure, not print “done”.
- [ ] Implement RunPure against the same pure modules with no engine globals; test the module mapping/dependency injection in both CLI and plugin packaging. Keep the sibling MarkovJunior harness as a pattern only, since its printed failure count does not itself fail a test run.
- [ ] Load the RBXMX through Studio's local model insertion path, select the Script, and use Plugins → Save as Local Plugin. Verify that its toolbar loads and package hash matches the on-disk manifest.
- [ ] Run the package tests and a deliberately failing Studio smoke test, then correct the smoke test and verify a pass.
- [ ] Save environment.json with Studio version, operating system, plugin source hash, selected runner mode, place identification, and verification timestamp.

Example package round-trip test contract:

~~~javascript
import assert from "node:assert/strict";
const source = 'return "<&> ]]> \\"quoted\\""';
const escaped = escapeXml(source);
const decoded = decodeXmlForTest(escaped);
assert.equal(decoded, source);
~~~

Define escapeXml in build-plugin.mjs, replacing ampersand first, then less-than, greater-than, double quote, and apostrophe. Define decodeXmlForTest in the test file, decoding ampersand last so escaped entity-looking source remains literal.

The [Studio plugin guide](https://create.roblox.com/docs/studio/plugins) documents Save as Local Plugin. The installed copy may differ from the original Script; show its version prominently and rebuild/reinstall deliberately after source changes.

**Acceptance:** the plugin starts in Edit mode, identifies its source build, resolves the required group/symbol data without collisions, and reports an intentional failure correctly. CLI and Studio pure harnesses use the same functions. No physics claim is made yet.

### Task 2 — Dataset contract, target policy, and causal features

**Files:** create tools/prepare-lab.mjs and its test, Data/Dataset.luau, Features.luau, ContextCursor.luau, SupplementalFeatures.luau, FeatureSchema.luau, Scaler.luau, History.luau, Targets.luau, Data.spec.luau, Features.spec.luau, Context.spec.luau, and lab/fixtures/synthetic-bars.json.

**Consumes:** immutable source bars and split/config values.

**Produces:** paired streams and availability indices, O14/R50/H14 FeatureRows, profile schemas, mask-aware input transforms, history vectors, evaluator-only targets, and data-audit.json.

- [ ] Write synthetic hourly bars with known close progression. Include a missing intermediate hour, a date boundary, zero range, a bad VWAP, and a split-crossing outcome.
- [ ] Observe failures for target lookup before implementing it. Require exact target timestamps and completed-bar availability.
- [ ] Build the timestamp intersection and metadata index. Assert strictly increasing timestamps, no duplicates, and matching source rows.
- [ ] Use Intl for New York metadata. Test 2024-03-08T14:00:00Z and 2024-03-11T13:00:00Z both map to 09:00 New York; include a November transition fixture.
- [ ] Implement feature formulas, Welford scaling, clipping diagnostics, segment resets, lag padding, and masks.
- [ ] Implement the exact 50-column schema, as-of cursor, five-minute expected grid, same-hour volume buffer, prior-day availability, and bounded-age IWM/TLT joins. Test complete, partial, empty, and zero-volume synthetic hours without changing the primary origin stream.
- [ ] Test missing values are omitted from scaler fitting, become zero after transform, and retain masks; real zero values remain observed. A never-observed training column must stay zero even when a validation value appears.
- [ ] Verify the 28 continuous and 22 bounded R50 columns, and dimensions 51/204/408/456. Test original O14 dimensions and H14 formula identity separately.
- [ ] Mutate today's daily bar and a five-minute bar ending after the decision; neither may affect current features. Check next-local-midnight across both DST changes, exactly-two-hour context acceptance, older-than-two-hour rejection, and a missing hourly predecessor. A 59-hour-old TLT observation must be masked.
- [ ] Verify daily and same-hour volume buffers survive physical resets and reconstruct identically from a past-only resume checkpoint. Test the current hour/date is excluded from its own relative-volume history.
- [ ] Test that future mutations cannot change current features and that a gap never creates a close-to-close return spanning that gap.
- [ ] Implement target lookup in the evaluator-facing module only.
- [ ] Recompute the full-dataset structural counts in Section 2 and save them with hashes. Reading timestamps for this audit does not authorize inspecting final target performance.
- [ ] Run Node preparation tests, CLI pure Data/Features/Context tests, and a Studio import smoke test on those same fixtures. Preserve every immutable source directory.

Concrete target fixture, to define in Data.spec.luau:

~~~lua
local function makeBar(t, close)
    return {t, close, close, close, close, 100, 10, close}
end

-- Use a real same-day New York timestamp for t0 in the fixture file.
-- All bars t0 through t0+12h exist; both symbols use the same progression.
local t0 = 1704186000 -- 2024-01-02 09:00 UTC, 04:00 New York
local bars = {}
for i = 0, 12 do
    bars[i + 1] = makeBar(t0 + i * 3600, math.exp(i * 0.001))
end
-- Construct the fixture's Dataset using Dataset.load and generated metadata.
-- At origin index 4, the expected target is index 12:
local expectedReturn = 0.008
assert(math.abs(math.log(bars[12][5] / bars[4][5]) - expectedReturn) < 1e-12)
assert((bars[12][1] + 3600) - (bars[4][1] + 3600) == 28800)
~~~

The production test must call Targets.lookup for that fixture and assert eligible=true and both outputs equal expectedReturn. Remove bar index 7 in a second fixture; the endpoint still exists, but lookup must return eligible=false with reason="missing_intermediate_hour".

Future-invariance test contract:

~~~lua
local first = Features.compute(currentPair, previousPair)
-- currentPair and previousPair are fixed; mutate a separate future fixture.
for _, field in ipairs({2, 3, 4, 5, 8}) do
    futurePair.spy[field] = futurePair.spy[field] * 100
end
local second = Features.compute(currentPair, previousPair)
for i = 1, #first do
    assert(first[i] == second[i])
end
~~~

Also test integration-level future invariance in Task 5; a pure function test alone cannot detect a controller that passes the wrong rows.

**Acceptance:** O14/R50 eligible counts equal 2,646/1,249/2,186 on identical timestamps; H14's larger training population is separately audited; final/validation timestamps match every profile. Availability, masks, scales, dimensions, and boundaries have real fixtures; future source mutations cannot change current features under frozen transforms.

### Task 3 — Prove and build the native reservoir

**Files:** create Physics/Reservoir.luau, ExplicitRunner.luau, Diagnostics.luau, and Physics.spec.luau.

**Consumes:** config, input vector, and measured BasePart masses.

**Produces:** native geometry, explicit stepping, stable forty-eight-value readouts, a mechanical diagnostic report, and measured throughput.

- [ ] Write a one-node force-response test that fails before the constructor and runner exist.
- [ ] Build one passive rail, one native spring, one moving body, and a VectorForce in an owned probe model. Verify the local plugin can call StepPhysics in Edit mode.
- [ ] Apply a nonzero X force, step sixty times, and assert nonzero X motion while Y/Z remain within 1e-3 studs of their constrained coordinates.
- [ ] Remove the drive and sample for ten simulated seconds. Verify the average energy proxy sum(v² + omega²*x²) over the final second is below its first-second value.
- [ ] Add a second native coupled node. Drive only the first and verify the second responds when both are included in the step list.
- [ ] Expand to the twenty-four-node geometry and verify counts: 24 moving nodes, 24 rail constraints, 24 axial springs, 38 coupling springs, and 24 VectorForces.
- [ ] Implement drive/read/reset/destroy. Only constructor/reset may set moving-node transforms or zero velocities.
- [ ] Verify exactly twelve completed native steps per observation. Use a recording test adapter for scheduling, and a real native run for motion.
- [ ] Compare clean builds and segment resets on repeated input. Apply the repeatability thresholds before financial selection.
- [ ] Compare responses to u, 2u, and u+v after identical resets. Record the superposition deviation relative to response RMS. If it is negligible, describe the initial operating range as nearly linear; do not advertise measured nonlinearity.
- [ ] Calibrate the common drive displacement using a fixed training-input probe, with no targets. Record saturation, clipping, state variance, and the selected value.
- [ ] Time 200 bars and report measured throughput, estimated train/validation runtime, and projected final runtime.

Illustrative runner body:

~~~lua
function ExplicitRunner:stepBar(input)
    self.reservoir:drive(input)
    for _ = 1, self.config.stepsPerBar do
        workspace:StepPhysics(self.config.dt, self.reservoir:movingParts())
        self.totalSteps += 1
    end
    return self.reservoir:read()
end
~~~

Use configuration assertions dt=1/60 and stepsPerBar=12 for the frozen version. Reset settling is a separately counted operation.

**Acceptance:** actual Roblox bodies move under native forces and constraints; coupling works; repeats are characterized; the engine computes state without scripted motion integration. Failure here blocks fitting against purported “physics features”.

### Task 4 — Numerically verified ridge and Markov fitting

**Files:** create Model/Cholesky.luau, Ridge.luau, Markov.luau, RegimeFeatures.luau, Selection.luau, Ridge.spec.luau, Markov.spec.luau, and lab/fixtures/ridge-reference.json. RegimeFeatures needs full implementation only when R60 is preregistered.

**Consumes:** numeric feature rows, two target columns, training masks, lambda.

**Produces:** serializable RidgeModel and MarkovModel artifacts and prediction functions. Markov state thresholds/counts require Task 2's training stream; pure numerical fixtures can be built independently.

- [ ] Write the small matrix test below, observe its failure, then implement the solver.
- [ ] Add a singular unregularized matrix fixture that fails with an explicit numerical error.
- [ ] Implement symmetric accumulation, centering, scaling, constant-column removal, unpenalized intercept, and shared factorization for two outputs.
- [ ] Add positive regularization and verify the formerly singular duplicated-feature fixture becomes solvable.
- [ ] Fit a simple known relationship with lambda=0 on full-rank test data and verify intercept/slope recovery. Production candidates still use the positive fixed grid.
- [ ] Verify that adding a constant feature does not alter predictions and permuting training rows only changes results within the declared floating-point tolerance.
- [ ] Check predictions against an independently calculated small reference fixture, including after JSON round trip.
- [ ] Implement deterministic selection and tie rules; test a tie chooses larger lambda and then the documented simpler setting.
- [ ] Implement the four-state Markov contract: training-only median threshold, three-return volatility, state ties, within-segment transitions, Laplace smoothing, reward shrinkage, and the eight-step expected reward sum.
- [ ] Test constant rewards give 8c, identity transitions give 8*mu_i, every probability row sums to one, unseen states are defined, and no transition bridges a gap/date/split boundary. Assert an empty training sample fails.
- [ ] Test frozen Markov predictions through time t remain unchanged when later prices are changed. Verify state-bearing observations without an eligible eight-hour target still contribute to training counts.
- [ ] If R60 is enabled, test the ten-column probability/mask block at segment start and after warmup, assert D=60 and raw/augmented dimensions 61/244/488/536, and verify both comparators receive the same block.
- [ ] Run CLI pure Ridge/Markov tests and Studio integration smoke tests; save numerical residuals and probability/count diagnostics.

Exact solver fixture:

~~~lua
local A = {{4, 1}, {1, 3}}
local B = {{1, 0}, {2, 1}}
local W = Cholesky.solve(A, B)
assert(math.abs(W[1][1] - 1/11) < 1e-12)
assert(math.abs(W[2][1] - 7/11) < 1e-12)
assert(math.abs(W[1][2] + 1/11) < 1e-12)
assert(math.abs(W[2][2] - 4/11) < 1e-12)
~~~

For the regression fixture use X={{-1},{0},{1}} and Y={{-1,3},{1,1},{3,-1}}; at X={{2}}, predictions should be {5,-3} with lambda=0, within 1e-10. This simultaneously checks two heads and intercept handling.

**Acceptance:** genuine ridge and Markov arithmetic/causality tests pass; artifacts reload with the same predictions. A plausible plot is not a substitute for verifying either model.

### Task 5 — Causal replay, cache, ledger, and export transport

**Files:** create Experiment/Controller.luau, Cache.luau, Ledger.luau, ResultStore.luau, Experiment.spec.luau, Export.spec.luau, tools/validate-results.mjs and its tests.

**Consumes:** Dataset, feature transforms, Reservoir/ExplicitRunner, and model artifacts.

**Produces:** ordered causal caches, immutable predictions, resumable progress, bounded export pages.

- [ ] Write a controller test with a fake stepper that records only the numeric input it receives.
- [ ] With already-frozen fitting artifacts, run two short fixtures identical through time t but radically different afterward across hourly, five-minute, daily, and context sources. Assert input commands, states from a deterministic test stepper, and issued forecasts through t are identical for each profile.
- [ ] Assert that removing a future target changes evaluator eligibility but does not change commands or forecasts at the current origin.
- [ ] Implement the phase state machine: idle → audit → prepare_training_transforms → mechanical_probe → generate_development_states → fit_readouts → select → locked → generate_final_predictions → evaluate → complete. The preparation phase fits input transforms and Markov artifacts on training only; R60 requires its chain before physical-state generation. Errors enter failed; cancellation enters cancelled.
- [ ] Gate final evaluation on a saved model lock and an exported complete prediction ledger.
- [ ] Gate experiment-wide final release on all included profile locks and all required model ledgers. Missing context features are masked inputs; missing model predictions are failures and remain visible.
- [ ] Cache every causal input/state row, including origins later excluded by the evaluator. Hash each exported chunk.
- [ ] Make ledger IDs deterministic from run/model/symbol/timestamp. Reject duplicate IDs instead of overwriting.
- [ ] Use independent Outcome records. Adding an outcome must not mutate a Forecast.
- [ ] Implement cancellation between batches and segment-boundary resume.
- [ ] Use cancellation/budget patterns only for orchestration and UI. Verify arbitrary host yields do not change the explicit dt or completed-step count. Reconstruct context cursors and Markov state history causally on resume.
- [ ] Implement ResultStore pages capped at 48 KiB of UTF-8 JSON, measured with actual serialized bytes. Use adaptive record counts, not a fixed “500 rows” assumption.
- [ ] Export and validate a small real native run. Confirm record order, counts, finite values, model/data hashes, and no duplicate forecasts.

Ledger immutability test:

~~~lua
ledger:append(forecast)
local ok = pcall(function()
    ledger:append(forecast)
end)
assert(not ok, "Duplicate forecast IDs must be rejected")
local saved = ledger:page(1, 1)[1]
assert(saved.prediction == forecast.prediction)
~~~

Copy/freeze stored records so mutating the caller's table after append cannot alter the saved value. Test that separately.

Use forecast ID = runId .. ":" .. modelId .. ":" .. symbol .. ":" .. tostring(t), with run/model IDs restricted to letters, digits, underscores, and hyphens. Store outcomes and failure records separately; a failure never becomes a numeric zero forecast.

#### Concrete export path

Roblox does not supply ordinary unrestricted local file writing to a game Script. Do not invent writefile or assume console text persists.

The plugin exposes serialized pages in an owned ServerStorage.MarketLabBridge Folder. Each page is a StringValue named Page000001, Page000002, and so forth, with a Manifest StringValue listing kind, page count, row count, byte count, and run ID. A page is immutable once published.

Export one artifact kind at a time. The host reads pages through Studio MCP, saves them under runs/<run-id>, validates them, then acknowledges the exported artifact before the plugin clears that transport batch. Keep the actual underlying run data until acknowledgement.

The MCP read itself can be small and explicit:

~~~lua
local bridge = game:GetService("ServerStorage"):FindFirstChild("MarketLabBridge")
assert(bridge, "Market lab export bridge missing")
local page = bridge:FindFirstChild("Page000001")
assert(page and page:IsA("StringValue"), "Requested page missing")
return page.Value
~~~

Available tools discovered during planning include list_roblox_studios, get_studio_state, execute_luau, multi_edit, and script_read. execute_luau requires studio_id and datamodel_type; use Edit for this export. Inspect its returned structure on a one-page probe before automating extraction. Preserve the JSON bytes, not a human-formatted console rendering.

When writing host files, use normal file-writing tools with exact content and safe quoting. Do not concatenate credential files or execute returned JSON as code. This is a local transfer of generated experiment records.

Calculate SHA-256 on the host with Node's built-in crypto module. For model/config hashes, canonicalize JSON by sorting object keys recursively while preserving array order, then hash the UTF-8 bytes. Reject NaN/Infinity before serialization. Export the selected model before the final phase, calculate and save its hash, and pass that verified hash back in a small host-acknowledgement StringValue in the bridge. The plugin must match the acknowledged run ID and artifact identity before stamping subsequent forecasts or advancing to final prediction. Document the acknowledgement schema and test stale/wrong-run acknowledgements are rejected. There is no assumption that HttpService provides a SHA-256 method.

**Acceptance:** a complete small run survives Studio-to-host export with counts and hashes intact; future changes cannot rewrite past predictions; interrupted work resumes without pretending hidden physics state was restored.

### Task 6 — Candidate search and frozen selection

**Files:** complete Model/Selection.luau and Controller's development phases; produce per-profile candidates.json, protocol.json, feature-schema.json, markov-model.json, model.json, model-lock.json, and the experiment-wide experiment-manifest.json.

**Consumes:** training/validation causal caches and their permitted labels.

**Produces:** all candidate metrics and an immutable selected model bundle.

- [ ] Write a synthetic selection test in which validation favors a different setting from training error; require validation to determine the winner.
- [ ] Assert fitting rejects any row whose outcomeTime reaches the next split.
- [ ] Fit input scaling on training inputs and freeze it before native feature generation.
- [ ] Freeze profile inclusion, primary R50 comparison, secondary comparisons, and the optional R60 decision before validation search. Reuse the identical O14/R50 Markov artifact and fit H14's separately.
- [ ] Generate development state caches for P1/P2/P3 only through validation end.
- [ ] Per profile, fit the twenty-one RAW-RIDGE settings and twenty-one RAW+PHYSICS settings; account for the seven diagnostic PHYSICS-RIDGE fits and the single fixed Markov baseline. Record the full 147-ridge-candidate required budget, or 196 if R60 was included.
- [ ] Compute the fixed normalized validation score and deterministic ranking.
- [ ] Select the diagnostic PHYSICS-RIDGE lambda for the chosen physical configuration.
- [ ] Freeze the exact eight-lag raw comparator, including its validation-selected lambda.
- [ ] Save rejected candidates with their reasons; do not hide a failed mechanical preset.
- [ ] Serialize selected preprocessing, feature schemas, context policies, source-group identities, Markov parameters, and coefficients. Reload them and verify identical predictions within 1e-12 on saved reference rows.
- [ ] Write the model lock containing code/data/config/model hashes, the chosen settings, validation summary, and the statement “final metrics not yet evaluated”.
- [ ] Verify changing final-period fixture prices cannot change the selected artifact. Exclude whole-dataset integrity hashes from this semantic comparison, since those hashes should correctly change.
- [ ] Include an omission/failure status for any blocked profile before final release. A completed profile's final errors must never guide another profile's feature or parameter changes.

Store the protocol before search begins, then store the model lock after selection. This provides a visible record of which rules existed before which results.

**Acceptance:** another session can load the frozen model without rerunning selection, and no final target was needed to choose it.

### Task 7 — Metrics, non-overlap population, and uncertainty

**Files:** create Experiment/Evaluator.luau and Bootstrap.luau; extend Experiment.spec.luau and host result validation.

**Consumes:** immutable forecasts plus separately joined outcomes.

**Produces:** metrics.json, uncertainty intervals, and population/exclusion tables.

- [ ] Write the metric fixture below and observe failure before implementing metric accumulation.
- [ ] Implement exclusion reasons: insufficient_warmup, missing_intermediate_hour, missing_target, different_local_date, split_boundary, and invalid_input. Use one deterministic priority order in that sequence, except invalid_input takes precedence. Define missing_intermediate_hour using k=1 through 7 only; missing_target means the k=8 endpoint is absent. Both checks are required for the complete k=1 through 8 coverage policy.
- [ ] Implement zero-target and zero-prediction direction handling exactly as Section 6 states.
- [ ] Implement non-overlap selection using timestamps and verify expected per-date counts.
- [ ] Implement paired five-date moving-block bootstrap with a stored seed and 2,000 replicates; truncate the sampled date list to the original date count.
- [ ] Verify comparing a model with itself gives zero difference and a [0,0] interval.
- [ ] Verify resampling preserves both assets and every model for each sampled date.
- [ ] Assert original and rich models have identical eligible timestamp sets, not just matching counts. Include Markov forecasts and all preregistered profiles in joined outputs. Keep H14's training population separate.
- [ ] Verify the primary R50 paired statistic and cross-profile secondary statistics use their documented fixed training scales; report comparison identities and missing coverage explicitly.
- [ ] Recompute exported point metrics independently in Node and require agreement within 1e-10 in log-return units.
- [ ] Test that an intentionally missing physics forecast remains in missing-coverage counts and prevents a “complete comparison” status.

Metric fixture:

~~~text
actual     = [0.01, -0.02, 0.03]
prediction = [0.00, -0.01, 0.02]
MAE        = 0.01
RMSE       = 0.01
direction accuracy = 2/3
zero prediction count = 1
~~~

The integration fixture must include duplicate timestamps across model IDs and both symbols so joins use forecast IDs/model identity instead of accidentally treating different models as repeated records.

**Acceptance:** population, pairing, errors, and uncertainty are reproducible from exported files. Overlapping forecasts are never described as independent trials.

### Task 8 — Honest visual display and video replay

**Files:** create UI/Panel.luau and Replay.luau; connect Main.server.luau to Controller and ResultStore.

**Consumes:** run progress, causal input/state records, frozen forecasts, and revealed outcomes.

**Produces:** a usable experiment interface and reproducible video scenes.

- [ ] Add controls for audit, mechanical probe, development run, select/lock, final prediction pass, export, evaluate, cancel, and replay.
- [ ] Show the active data hash prefix, model/config ID, split, bar timestamp, decision time, target time, progress, reset events, and runner mode.
- [ ] Show the oscillator motion in the owned model, color driven nodes by input magnitude, and plot predicted versus realized return after outcome release.
- [ ] Show SPY and QQQ labels accurately. Use “S&P 500 ETF proxy” and “Nasdaq-100 ETF”; do not introduce a fabricated Composite series.
- [ ] Show the selected input profile and explain volume/coverage masks in an inspection view. Keep the main video display simple: market input, native motion, raw/Markov/physics forecasts, and later outcome. Label MarkovJunior examples as procedural-generation references if shown at all.
- [ ] In prediction playback, hide future outcomes until the replay clock reaches outcomeTime. Store the original forecast marker; never replace it with the realized price.
- [ ] Label cached visual playback “recorded experiment replay”. It may animate saved poses for presentation; it must not be described as a fresh computation.
- [ ] Ensure visual camera movement, colors, and rendering effects cannot feed back into the primary physics readout.
- [ ] Record at least one mechanically successful case, one poor forecast, and the aggregate final results. Do not choose only winners.
- [ ] Test controls against the state machine: evaluate before lock/export must fail clearly, concurrent run requests must be rejected, and Cancel must stop at a safe batch boundary.

For efficient replay, retain exact state snapshots for a preregistered demonstration date and a small regular sample during the physical pass. When using an inferred/interpolated animation between saved states, label it as interpolation. Do not alter forecast numbers.

A useful video sequence is: explain the hypothesis; show a candle driving springs; explain the trained readout; show the honest baseline; reveal held-out results; explain what worked or failed.

**Acceptance:** the viewer can distinguish historical input, prediction, later outcome, training, validation, and final testing.

### Task 9 — Run the controlled experiment and deliver

**Files:** complete run artifacts and runs/<run-id>/report.md; update the project's README with installation, usage, limitations, and links to the run.

- [ ] Run the existing Node suite and newly added host tests.
- [ ] Run the CLI pure-Luau suite and Studio pure/native integration tests. Record which require real physics and which use test doubles; do not report CLI passes as engine verification.
- [ ] Complete the data audit and mechanical calibration without final outcomes.
- [ ] Run all included development profiles, select, export artifacts, and verify every model lock and the experiment manifest before any final result is viewed.
- [ ] Run final-period inputs with only each profile's selected physical configuration. Issue raw, Markov, and physics forecasts for every sufficiently warmed origin, including those later marked unscoreable.
- [ ] Export and checksum every included prediction ledger before any final outcome joining. A partial run is labeled partial and cannot become a hidden basis for redesign on this holdout.
- [ ] Evaluate all frozen models together, using the fixed eligible origins and non-overlap subset.
- [ ] Calculate the paired uncertainty intervals and monthly/hour/segment-age breakdowns.
- [ ] Export final diagnostics and verify host/Studio point-metric agreement.
- [ ] Write the report with actual settings, elapsed time, reproducibility measurements, candidate budget, failures, and limitations.
- [ ] Create the recorded replay and final metric panel from the saved run.
- [ ] Reopen the exported model/results in a fresh Studio session and verify saved-artifact replay and prediction reconstruction on reference states.
- [ ] Update README with exact run commands, plugin build/install instructions, result location, and the strongest defensible conclusion.

The report must answer:

1. Did Roblox's native solver actually generate the features?
2. Did the software pass causality, timing, numerical, and export checks?
3. How did primary R50/RAW+PHYSICS compare with equally informed RAW-RIDGE, exact eight-lag RAW-RIDGE, ZERO, MEAN, MARKOV, and PHYSICS-RIDGE?
4. How large and uncertain was the improvement or deterioration?
5. Was behavior consistent across both ETFs, months, and origin hours?
6. How repeatable and fast was the native computation?
7. Which design limitations constrain the conclusion?
8. Did richer information (R50 versus O14) or longer training history (H14 versus O14) change outcomes, separately from the incremental contribution of physics?
9. If preregistered, did R60's Markov probability inputs help both raw and physical models, and which comparisons remain exploratory?

**Completion:** working local plugin/source, verified cached data ingestion, a frozen auditable backtest, exported forecasts and outcomes, comparison results, and an honest replay. A profitable or superior result is not a completion requirement.

## 9. Optional lighting experiment

Only begin after the physics pipeline works and its protocol is saved.

The meaningful lighting variant reads actual rendered image information. Raycasting computes geometric intersections; it is not a measurement of Roblox's rendered light/shadow pixels.

The current [StudioCaptureService](https://create.roblox.com/docs/reference/engine/classes/StudioCaptureService) is Studio-only with plugin-security APIs. The documented path is to request screenshot permission, check capture availability, capture a screenshot, and use [StudioScreenshotCapture](https://create.roblox.com/docs/reference/engine/classes/StudioScreenshotCapture) buffer access when ready. Confirm the installed API signatures and actual permission flow before implementing.

A controlled extension would:

1. Keep the same oscillator inputs and mechanics.
2. Add fixed opaque geometry and a fixed light/camera arrangement.
3. Capture a fixed region after each measured physical state, with a defined render synchronization point.
4. Downsample RGBA pixels into a fixed small grid of luminance averages, such as 8×8 = 64 features.
5. Fit a Luau readout with training-only scaling.
6. Compare raw-only, direct-physics, rendered-pixel, and combined readouts under a new declared selection protocol.

Record graphics quality, renderer/device, exposure, lighting settings, camera transform, capture resolution, and dropped/late captures. Test that repeated identical static scenes produce acceptably repeatable features. Capture permissions and GPU/renderer effects are part of the engineering feasibility gate.

Do not claim a per-frame RenderStepped wait guarantees every lighting system has settled; test capture timing. Do not use screenshot tool images as a substitute for an automated, measured pixel pipeline.

This is a separate experiment because capture overhead and rendering variation may dominate the benefit. If the final period has already been inspected for the physics experiment, it cannot become a fresh untouched holdout for repeated lighting design choices. Use a new future period, or explicitly label subsequent comparisons exploratory.

## 10. Runtime fallback if explicit plugin stepping fails

Do not fall back automatically merely because the MCP execution context lacks plugin permissions. First install and test the legitimate local plugin.

If the installed environment cannot support explicit stepping:

- Implement Physics/RuntimeRunner.luau behind the same stepBar contract, with asynchronous completion as an explicit interface change.
- Use a server-controlled lab in Play/Run mode, set moving-assembly network ownership to the server where supported, and avoid client-dependent simulation.
- Verify [RunService:BindToSimulation](https://create.roblox.com/docs/reference/engine/classes/RunService) and fixed-simulation support locally. Current documentation restricts this mode to synchronized properties/methods.
- Configure Workspace.UseFixedSimulation and physics stepping through Studio-supported settings. Do not assume ordinary scripts may assign non-scriptable [Workspace properties](https://create.roblox.com/docs/reference/engine/classes/Workspace).
- Use a fixed 60 Hz callback if supported, and verify sampling phase with the one-node fixture. Counting twelve pre-physics callbacks and reading immediately can yield only eleven completed intervals.
- Keep UI/logging outside restricted simulation callbacks.
- Record callback timing, actual simulation intervals, runner mode, and performance. Do not treat task.wait or rendering frame rate as a fixed physics clock.

Caches and results from explicit and runtime runners have different identities. Do not mix their feature rows in one model.

If neither native runner can be established, preserve the code and diagnostic evidence and report the precise capability blocker. Do not substitute a custom integrator and claim the original experiment is implemented.

## 11. Failure handling and scope boundaries

| Observed problem | Required response |
|---|---|
| StepPhysics permission error | Verify local plugin context; do not infer the API is unavailable from MCP identity alone. |
| Native bodies do not move | Check Edit context, moving-parts list, rail axes, actuator mode, force attachment, anchoring, and spring parameters. |
| Rail saturation or unstable state | Reject the mechanical setting, retain diagnostics, and revise before validation with a new protocol version. |
| Repeats disagree | Check creation order, ownership/context, reset versus rebuild, Studio version, and hidden stepping; measure the difference. |
| Counts differ from the expected table | Inspect timestamp join, DST conversion, warmup, continuity, and split inequalities before model fitting. |
| Cholesky fails | Check constants, symmetry, finite inputs, and regularization. Reject the candidate; do not silently alter its identity. |
| Supplemental context is absent or stale | Apply the frozen masks and age policy; preserve the paired hourly origin and record coverage. |
| A context value is invalid, duplicated, or out of order | Fail the source audit and diagnose; do not disguise corrupt data as ordinary missingness. |
| Markov probabilities fail bounds/row sums | Check count orientation, smoothing, and serialization; do not normalize silently around a bug. |
| A profile is unfinished when another reaches final prediction | Complete all locks/ledgers or declare the omission before releasing final targets. No final-driven redesign. |
| Export is incomplete | Resume the page transfer and verify hashes before deleting transport pages or evaluating final outcomes. |
| Physics fails to beat the baseline | Report that finding. Do not expand the search against the final test. |
| User wants regular-session-only predictions | Version a new target policy and obtain finer bars/calendar handling; native hourly bars straddling the open are insufficient for an exact clean RTH construction. |
| User wants Nasdaq Composite | Obtain and verify a distinct index dataset; do not rename QQQ. |
| User wants a live demo | Build it after the offline experiment; preserve bar-close availability, saved forecasts, and later outcome release. |
| User wants trading profitability | Define a separate execution/P&L protocol with costs and position accounting. |

## 12. Sources and what they support

Consult current official API documentation again when implementing capability-sensitive code.

- [Alpaca historical stock bars](https://docs.alpaca.markets/us/reference/stockbars): source endpoint, bar schema, adjustment, and pagination.
- [Alpaca market-data FAQ](https://docs.alpaca.markets/us/docs/market-data-faq): feed/access context and bar aggregation behavior.
- [Physical soft-body information processing](https://www.nature.com/articles/srep10487): physical reservoir concept, not financial efficacy.
- [Roblox WorldRoot](https://create.roblox.com/docs/reference/engine/classes/WorldRoot) and [official StepPhysics announcement](https://devforum.roblox.com/t/new-stepphysics-plugin-api/3093140): native explicit simulation and execution context.
- [Prismatic constraints](https://create.roblox.com/docs/physics/constraints/prismatic): passive single-axis motion.
- [SpringConstraint](https://create.roblox.com/docs/reference/engine/classes/SpringConstraint): mechanical spring properties and measured length.
- [VectorForce](https://create.roblox.com/docs/reference/engine/classes/VectorForce): continuous force, relative frame, and center-of-mass application.
- [BasePart](https://create.roblox.com/docs/reference/engine/classes/BasePart): measured transforms, velocities, and mass/ownership APIs.
- [Studio plugins](https://create.roblox.com/docs/studio/plugins): legitimate local installation.
- [RunService](https://create.roblox.com/docs/reference/engine/classes/RunService) and [Workspace](https://create.roblox.com/docs/reference/engine/classes/Workspace): runtime fixed-simulation fallback.
- [StudioCaptureService](https://create.roblox.com/docs/reference/engine/classes/StudioCaptureService) and [StudioScreenshotCapture](https://create.roblox.com/docs/reference/engine/classes/StudioScreenshotCapture): optional rendered-image readout.
- [Time-series cross-validation](https://otexts.com/fpp3/tscv.html): chronological separation of training information and future outcomes.
- [MarkovJunior official repository](https://github.com/mxgmn/MarkovJunior): spatial rewrite rules and constraint-based procedural generation; not evidence of financial prediction.
- [Statsmodels Markov-switching examples](https://www.statsmodels.org/stable/examples/notebooks/generated/markov_autoregression.html): temporal regime-transition models and the distinction between filtered and smoothed probabilities. Our fixed observable-state reward baseline is a separate proposed design, not a reproduction of those fitted examples.
- [Supplemental dataset guide](../../../SUPPLEMENT.md): local source groups, volume fields, counts, hashes, and known coverage limitations.

Numerical defaults, geometry, splits, and acceptance tolerances in this plan are proposed engineering decisions. They have not been experimentally validated in this workspace.

## 13. Ready-to-paste prompt for the next session

> Implement the Roblox physics market-forecast experiment described in:
>
> docs/superpowers/plans/2026-10-04-roblox-physics-market-forecast.md
>
> Read that plan, the project README, and SUPPLEMENT.md first. Work in the repository root. Original hourly data and 603,900 supplemental source candles are already downloaded, verified, and exported as CSV and chunked Luau modules. Use cached files and their manifests; do not redownload or expose credentials.
>
> Build a local Studio plugin whose native SpringConstraints, PrismaticConstraints, VectorForces, and Roblox physics solver perform the reservoir dynamics. Use the planned StepPhysics capability probe first. Implement O14, primary R50, and H14, including their exact feature/missingness contracts and equally informed raw baselines. Implement the separate four-state financial Markov reward baseline in Luau. R60 is optional and disabled unless included before validation. Preserve the causal eight-hour target, chronology, masks, comparison identities, and sealed final test.
>
> Reuse engineering patterns from mj-port (a separate MarkovJunior Luau port, not included) only after checking current sources and attribution; preserve that live project. Its MarkovJunior spatial generator is not our financial chain and its anchored visual output is not native physics computation. luau is available for pure-module tests; native mechanics still require Studio.
>
> Start with Tasks 1–3 and the numerical solver tests. Delegate independent modules with explicit file ownership where useful. Continue through the full implementation, verification, export, and replay if capabilities permit. Do not turn this into a normal indicator with decorative physics, do not place trades, and do not promise the model will outperform the baseline.
>
> Record progress and actual evidence at each acceptance gate. Lock every included profile and export all final prediction ledgers before revealing any final outcomes; do not use one profile's final errors to redesign another. If an engine capability is unavailable, follow the documented fallback and report the exact blocker. A scientifically honest negative forecasting result is an acceptable completed experiment.

## 14. Plan review checklist

- [x] Existing assets and unimplemented components are distinguished.
- [x] Native engine computation has a concrete mechanical design and a capability gate.
- [x] Eight-hour timing, session scope, gaps, warmup, and expected population are explicit.
- [x] Training/validation/final boundaries and label purging are defined.
- [x] Baselines receive the available history; incremental physics value is the primary question.
- [x] Original, richer-input, longer-history, and optional regime-input profiles have explicit roles and dimensions.
- [x] Volume, five-minute completeness, prior-day availability, stale context, and mask-aware scaling are specified.
- [x] The temporal Markov model has exact states, train-only fitting, reward forecasting, and verification fixtures.
- [x] MarkovJunior reference patterns and the installed CLI are separated from required native engine execution.
- [x] All included profiles share a final-release gate; final outcomes cannot guide cross-profile redesign.
- [x] Readout fitting, regularization, search budget, and numerical checks are specified.
- [x] Forecast immutability, final-test release, exporting, and interrupted-run recovery are covered.
- [x] Reproducibility, runtime cost, and statistical dependence are addressed.
- [x] Lighting is an optional measured-rendering experiment with a separate holdout policy.
- [x] The handoff does not claim implementation, profitable trading, or forecasting success.

## 15. Implementation record (2026-10-05)

Implemented and run end to end by Claude in the RoAlgo Studio place. Evidence lives in
`runs/exp-20261005/` and `runs/{O14,R50,H14}-a1/`; the narrative result is `runs/exp-20261005/report.md`.

Deviations from this plan, each recorded before validation search or final release:

- **Stepping (Section 4):** `WorldRoot:StepPhysics` in Studio 0.741 is applied on a later frame, drops about one
  request in eight and leaves fractional sub-steps after bursts. The runner uses verified deferred stepping: two
  metronome parts in every call, one outstanding request, each step confirmed as exactly one dt, drops re-issued,
  corrupt steps replay the segment (`docs/stepping-capability.md`). dt = 1/60, 12 steps per bar and 60 settle steps
  are unchanged.
- **Execution split:** feature construction, scaling, fitting, selection and evaluation run in Luau through the
  standalone CLI on the same pure modules the plugin embeds; Studio runs only the native physics. Transport is a
  local HTTP bridge (127.0.0.1) instead of MCP page reads.
- **Lanes:** independent segments run side by side inside one verified StepPhysics call; lane layout changes states by
  at most ~7e-5 (within the repeatability gate).
- **Lighting extension (Section 9), R60, walk-forward refit, reset-every-observation ablation:** not run (declared
  omitted before final release).

Gates met: structural counts reproduced exactly; protocol frozen before validation search; calibration chose drive
0.6 for all profiles (no saturation); repeatability passed (max 4.4e-5, median 0); O14/R50/H14 locked with
artifact round-trip verification; final physics only after all locks, pinned to locked presets; ledgers exported
and hashed before the first outcome join; Node recomputation agrees (42 groups, 0 disagreements); Studio
reconstruction of sampled forecasts exact.

Primary result: R50 RAW+PHYSICS minus R50 RAW-RIDGE normalized RMSE +0.0040, 95% interval [-0.0001, +0.0093]:
no evidence of incremental value from the physics features on this holdout.
