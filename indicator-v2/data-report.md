# RoAlgo v2 data and causal feature evidence

Scope: **historical exploratory research; earlier date ranges have already been inspected**. This report verifies cached transport, causal feature construction and the daily regime model. It makes no profitability or untouched-holdout claim. Native simulation steps performed by this worker: **0**. Studio/native integration belongs to the root worker and is not verified here.

## Verification runs

- RED transport: initial five Node behavior tests failed with explicit missing-API assertions (0 passed/5 failed). GREEN: all five passed after implementation.
- RED saved-result route: existing transport behavior returned404 instead of expected200. GREEN after adding read-only `/saved`.
- RED blank trade-count validation: parser silently converted an empty trade-count cell to zero; new test failed with missing expected exception. GREEN after rejecting empty CSV cells.
- RED source cache invalidation: isolated real-file fixture changed a Luau source definition and received the earlier source hash. GREEN after including source-definition hashes in dataset cache keys.
- Final Node run: `node --test indicator-v2/bridge.test.mjs`: **6 passed,0 failed**, exit0. It tests finite ordered CSV/OHLCV/activity, DST/early closes/closed dates, real cached completed joins and whole-session split boundaries, query restrictions, source-aware caching, host/origin/path/body rejection, 64MiB body cap, unique no-overwrite results and safe read-only saved results.
- Luau tests were written first and initially failed because the feature/regime modules were absent. After implementation, `luau indicator-v2/tests/Features.spec.luau` and `luau indicator-v2/tests/Regime.spec.luau` both exited0. Feature tests cover33 finite predictors,8 bounded drive values,12-bar readiness, prefix determinism, unavailable hourly/current-date daily rejection, prehistory completion filtering, QQQ target selection and first/intraday-gap/overnight reset behavior. Regime tests cover actual EM fit, volatility ordering, normalized probabilities, a high-volatility shock, duplicate daily filtering, determinism and explicit insufficient/degenerate fallbacks.
- `luau-compile indicator-v2/src/Features.luau` and `luau-compile indicator-v2/src/Regime.luau`: exit0, no diagnostics. CLI/runtime used: Luau0.741; Node at `node`.
- Synthetic deterministic HMM fixture:179 prior daily observations,12 EM iterations, log likelihood **-76.685458**, fitted fractional range proxies **0.002610 /0.020954 /0.065498**. A +10% subsequent daily shock produced low/mid/high probabilities approximately **0/0/1**. The repeated same daily context did not increment the filter count. These are behavior-test metrics, not market performance metrics.

## Actual cached dataset audit

Both SPY and QQQ had identical observed bar/session ranges for the configurations below. All audited configurations had **0 intraday gaps**, **0 sessions with unexpected78/42 bar counts**, and **0 missing peer/hourly/daily context joins**. No data requests or downloads were made.

| Train/validation/test sessions | End date | Observed bars | First decision (ET) | Last decision (ET) | Prior target daily bars | Validation start UTC Unix | Evaluation start UTC Unix |
|---|---|---:|---|---|---:|---:|---:|
|20/5/5|2024-12-31|2268|2024-11-18 09:30|2024-12-31 15:55|2234|1734445800|1735050600|
|40/10/10|2024-12-31|4608|2024-10-07 09:30|2024-12-31 15:55|2204|1733236200|1734445800|
|80/20/20|2024-12-31|9288|2024-07-12 09:30|2024-12-31 15:55|2144|1730730600|1733236200|
|990/5/5|2026-10-02|77676|2022-10-07 09:30|2026-10-02 15:55|1703|1789997400|1790602200|

Prior target daily history begins2016-01-04 in every configuration. Its last date is respectively2024-11-15,2024-10-04,2024-07-11 and2022-10-06, strictly before the first target decision date. The 2024 profiles contain13:00 early closes2024-11-29 and2024-12-24. The1000-session range also contains2022-11-25,2023-07-03,2023-11-24,2024-07-03,2025-07-03,2025-11-28 and2025-12-24.

Calendar handling is an explicit audit of NYSE regular sessions for the supported target interval2021-10-04 through2026-10-02 against the [NYSE calendars](https://www.nyse.com/markets/hours-calendars), with weekdays, full closures and13:00 early closes enumerated in bridge.mjs. Special2025-01-09 Carter funeral closure is included. Cache rows on weekends, closures, before09:30 or at/after the session close are excluded. Five-minute target data starts2021-10-04;2016 daily/hourly history is used as prior context, not fabricated five-minute target data.

Availability convention: target decisions occur at bar start+300 seconds. Peer five-minute context must have the same start and be available at start+300. Hourly context is the latest hourly observation with start+3600 completed by decision time; cached hourly bars can include extended hours. Daily context is delayed conservatively to daily start+93600 seconds (next day approximately02:00 ET, accounting conservatively for offset changes) and must precede the current New York date. Missing context remains absent. Raw price adjustment is **raw**, feed is the local cached Alpaca SIP OHLCV export.

## Feature and regime schema

`Features.new(dataset.prehistory,{symbol=dataset.metadata.symbol})` selects SPY or QQQ target daily context correctly. `step(bar)` returns `{t,raw,names,drive,volatility,ready,reset,regime,contextMissing}`. The raw vector's33 names in order are:

```text
return1, trend, volatility, range, body, vwapDeviation, logVolume,
volumeActivity, tradeActivity, peerReturn, peerRelative,
spyHourReturn, qqqHourReturn, iwmHourReturn, tltHourReturn,
targetDailyReturn, spyDailyReturn, qqqDailyReturn, dailyRange,
minuteSin, minuteCos, missingPeer, missingSpyHour, missingQqqHour,
missingIwmHour, missingTltHour, missingSpyDaily, missingQqqDaily,
gap, overnight, regimeLow, regimeMid, regimeHigh
```

Drive order: trend, immediate return, range/activity, volume, peer-relative movement, hourly context, daily trend, regime stress. All eight values lie within[-2,2]. Return/range/VWAP features are fractional values; volume/trade activity uses the deviation of current log activity from a causal EWMA mean. EWMA return mean and second moment estimate trend/volatility. Drive normalization uses causal EWMA RMS scales, never future/full-dataset statistics. The first return falls back to current candle close/open. A missing intraday interval flags reset; overnight changes flag overnight without a mechanical reset. Readiness begins at observation12.

Reduced-context raw comparison should drop hourly returns, target/SPY/QQQ daily returns, dailyRange, their hourly/daily missingness indicators and regime probabilities, since regime probabilities themselves depend on daily context. It may retain peer context and intraday/time features. Native state ablations must identify the actual drive that generated those states.

Regime inputs are close-to-close log daily return and log fractional daily range. Prior-history mean/std estimates are frozen. Deterministic range-quantile initialization, persistent initial transitions, scaled forward/backward EM, positive transition pseudocounts and standardized diagonal variance floor0.05 bound numerical behavior. Default20 EM iterations, capped30. Fitted states are ordered by estimated fractional range. Forward filtering processes only increasing completed daily timestamps and skips repeated contexts. Fewer than30 usable return observations yields `insufficient-history`; constant degenerate history yields `degenerate-history`. Both return documented uniform probabilities with neutral drive stress.

## Hashes and cache records

Every dataset metadata record carries source hashes, source-code hashes, configHash, dataHash, cacheKey, actual ranges/counts, availability convention, split boundaries and scope. Raw files are read/parsed once per process; code-definition changes invalidate dataset-level caches. Dataset keys include schema, source data hashes, source definitions and split/config. Mechanical state caches must also include runtime mechanics parameters in the calling App; bridge does not manufacture native states.

| Configuration | SPY dataHash | QQQ dataHash |
|---|---|---|
|20/5/5 through2024-12-31|789e6e64453e3c019e365b17604800e2f7750b04de85cfa827cef7beccec49d4|28d9bfa233e944248cd113f48c15d123c741c5cf9752c1fbee966bca8a03065c|
|40/10/10 through2024-12-31|4eb0acea7d6951c397db641a48d9bfc285c7a2cdf2ac80cff910bcd4857ce870|1fceda47afa65cbaa351ad17658227467899e1c6a70a5a743f7fc7dff5355a43|
|80/20/20 through2024-12-31|db3c91bc45dbe52f2866d202ea891d179617cd4cc19b4007e4b4e57b75c14e9a|0df50cea5ee94826b1291ed3b988cfe73f2c4bec5cd7e86d2fc16602a12920c1|
|990/5/5 through2026-10-02|2b3bf4b7c0bd991a12cedb8d64d4c0234c5e4e0221275ba60d9306b3704914a2|46a1cd62e177289e2ea03df0157c42c3a1dd82c643bf9fd5d04e1caf2e21659b|

Source CSV SHA256:

```text
five-minute/SPY    d60afb08f621fee9c0ddb00b2c57512afc4c38e7d9d8f88a79705541bc168671
five-minute/QQQ    9177b0598ad2fc3fbf887a18af7216acdca1f26a6b9dbc47a6af725ce59362d9
hourly-combined/SPY de8c79a62f6d61bbafc7bd0cce50f087e97f5dcb7bec5469497dbdd3762cfebb
hourly-combined/QQQ 4d30da6e5a0bdc9ec8bbe11879c3eb669fc10efc39e9fb98f8aa2b7ca2d7a3a5
hourly-context/IWM c986dc7814e2b2bab11fbd1f361989f25453f799499277ccba9fd01a11628791
hourly-context/TLT 1ddff2c3a4ecc5304c334eea1da5b2b63a247e74a5a67337107c116d1698409a
daily-context/SPY  0fd8526e2e425674547170e1ab0a2a9ff28cc8037992c3d226d67b5f3f321fe6
daily-context/QQQ  a3f6f25c1b48f2c42b878811c2cc6c0742faa003d7b4346521e9a7c7b79d0eee
```

Owned implementation/test SHA256 at this report run:

```text
bridge.mjs                 13b18e8ee06a4b0a38e12c1e75f98d245d4eabc8d57ae910e78e55f73c9a2456
bridge.test.mjs            641d90fb3426699205e82fcba85d30209846229566412962f2126afecb4b4f0f
src/Features.luau          f84dd9f11b9ef7bd9c14b03a209dd6dc526ab2da2debd2122ba3e904e6fc7260
src/Regime.luau            5b8ac36eac95fb2e9f7c100c89202bbe9267f24ff0787fafbdf8bbe35bdb0d4f
tests/Features.spec.luau    c91541c24b5d152567d51b886fdf4ee115e7c8ffdea7e9a1ab6e1d54ee55931a
tests/Regime.spec.luau      5c42c380bcce0b850498fa48689dea05b750ac703d8a69f9d2620da70d820d16
```

Transport: loopback127.0.0.1:47623 only; no-Origin Studio requests or same-loopback-origin requests are allowed. `/tree` excludes `.spec` files. `/result` allows safe unique names, JSON objects, maximum64MiB and no overwrites. `/saved?name=<safe basename.json>` reads only the result directory. No paid/API requests, Studio/Computer Use, original cache edits, or changes to other workers' files were made.
