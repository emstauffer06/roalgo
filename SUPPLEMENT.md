# Supplemental market data for the Roblox experiment

> **Note for the public repository:** this file records the original private data download of 2026-10-04. The data itself is **not included** (Alpaca does not allow redistribution); regenerate it with your own Alpaca key as described in the root README. The R50/H14 contracts mentioned below were later implemented and run; see `runs/exp-20261005/report.md`.

Downloaded and validated on October 4, 2026 (America/Los_Angeles). The API records UTC timestamps on October 5.

**603,900 new source candles are saved.** They are exported as CSV and chunked Luau modules, with original Alpaca JSON, provenance, and checksums. The physics model and additional features have not been implemented or evaluated.

Dataset directory: **data/alpaca-supplement-2016-01-01_2026-10-02/**

## What is available

| Group directory | Symbol | Timeframe | Source rows | Actual market dates |
|---|---|---|---:|---|
| five-minute | SPY | 5Min | 236,059 | 2021-10-04–2026-10-02 |
| five-minute | QQQ | 5Min | 237,287 | 2021-10-04–2026-10-02 |
| hourly-earlier | SPY | 1Hour | 22,581 | 2016-01-04–2021-10-01 |
| hourly-earlier | QQQ | 1Hour | 22,447 | 2016-01-04–2021-10-01 |
| daily-context | SPY | 1Day | 2,703 | 2016-01-04–2026-10-02 |
| daily-context | QQQ | 1Day | 2,703 | 2016-01-04–2026-10-02 |
| hourly-context | IWM | 1Hour | 41,857 | 2016-01-04–2026-10-02 |
| hourly-context | TLT | 1Hour | 38,263 | 2016-01-04–2026-10-02 |

A derived **hourly-combined** directory joins the earlier download to the frozen original hourly dataset:

| Symbol | Combined hourly rows | Actual market dates |
|---|---:|---|
| SPY | 42,543 | 2016-01-04–2026-10-02 |
| QQQ | 42,334 | 2016-01-04–2026-10-02 |

The combined view is an exact chronological concatenation. It adds no interpolation, replacement prices, adjustment, or invented candles. Its 84,877 rows include 45,028 newly downloaded earlier rows and 39,849 original rows; do not count the combined view as another independent download.

The five-minute dataset has 473,346 rows across both assets. The longer hourly data and daily/context series each cover 2,703 observed New York dates; the five-minute series cover 1,255 dates.

## Files to use

For each group and symbol:

- **SYMBOL.csv**: timestamp_utc, timestamp_unix, open, high, low, close, volume, trade_count, vwap.
- **raw/SYMBOL-TIMEFRAME.json**: untouched source bar objects assembled across all response pages.
- **roblox/SYMBOL/init.luau**: a loader returning metadata, schema, and bars.
- **roblox/SYMBOL/ChunkNNN.luau**: ordered numeric chunks, maximum 1,000 rows each.
- **source-metadata.json**: request bounds, feed, adjustment, retrieval times, and original raw-file hashes.
- **manifest.json**: actual counts/coverage, CSV and Luau paths, timeframe metadata, and SHA-256 checksums.

At the supplemental dataset root:

- **download-report.json**: all eight downloaded series, 749 successful API requests/pages, and rate-limit snapshots.
- **supplement-manifest.json**: machine-readable group index and downloaded versus derived row totals.
- **verification.json**: independent complete raw/CSV/Luau/hash audit.
- **cross-resolution-verification.json**: timestamp-only five-minute versus original-hourly coverage audit.
- **preservation-verification.json**: original-file preservation, credential scan, and local test evidence.

For a ModuleScript import, place a symbol's Chunk files underneath its init ModuleScript. Each row has eight fields:

~~~text
1 timestamp_unix
2 open
3 high
4 low
5 close
6 volume
7 trade_count
8 vwap
~~~

Keep groups in separate folders so SPY at 5Min is never confused with SPY at 1Hour or 1Day. Load the required groups in manageable batches; the supplied full-series loader should not be mistaken for an optimized streaming data store. These modules have been validated as numeric exports, but have not been imported or executed in Roblox Studio.

## How to use the additional information

The eight-hour forecast target does not change merely because five-minute inputs are available.

1. **Five-minute detail:** the revised R50 profile defines intrahour realized variation, final-fifteen-minute return, path efficiency, and volume concentration from completed bars, with an exact twelve-child timestamp requirement and explicit coverage/missingness values.
2. **Earlier hourly training:** the combined hourly series can expand a training-only historical period back to 2016 while retaining calendar 2024 validation and the existing final period starting in 2025.
3. **Daily context:** use only fully completed previous-day bars for previous-day return, trailing daily volatility, and other slow context. A daily bar's midnight timestamp is its start, not the time its final OHLCV became knowable.
4. **IWM/TLT context:** R50 joins the latest fully completed observation, requires a contiguous same-date predecessor for the return, and caps observation age at two hours. Store a mask and normalized age. Missing extended-hour context must not be filled from a future bar or assumed to mean zero return.
5. Give the simple baseline the same additional information before attributing any gain to Roblox's physical computation.

The five-minute history currently begins in October 2021. Do not fabricate five-minute inputs for 2016–2021. The [revised handover](docs/superpowers/plans/2026-10-04-roblox-physics-market-forecast.md) defines O14 as the original hourly reference, R50 as the richer-input experiment on the common 2021–2026 period, and H14 as the longer-history hourly experiment. Each has an explicit feature contract and training-fitted scaling. R60 optionally appends ten financial Markov probability/mask values if included before validation.

The handover was revised on October 5, 2026 and is authoritative for feature formulas, order, dimensions, masks, context availability, and model budgets. O14/H14 keep fourteen physical inputs; R50 uses fifty; optional R60 uses sixty. The primary comparison is R50 physics versus an equally informed R50 raw baseline. All included profiles must be locked and their final prediction ledgers exported before final outcomes are released. These contracts are specified but remain unimplemented and unevaluated.

## Missing intervals and availability

Timestamp-only coverage against the frozen original hourly dataset:

| Symbol | Original hourly bars | Hours with all 12 five-minute children | Partial hours | Empty hours |
|---|---:|---:|---:|---:|
| SPY | 19,962 | 18,217 | 1,745 | 0 |
| QQQ | 19,887 | 18,969 | 918 | 0 |

The two five-minute series share 234,819 timestamps. SPY has 1,240 timestamps absent from QQQ; QQQ has 2,468 absent from SPY. Every five-minute timestamp maps into an existing hourly interval for its own symbol.

Therefore:

- Join on actual timestamps, never row numbers.
- Track observed five-minute child counts and masks.
- Do not assume every hour contains twelve rows.
- Do not invent missing five-minute prices or zero-volume candles.
- If a feature requires all twelve child candles, preregister that requirement and compare every model on the resulting common population. Alternatively define a partial-coverage feature and expose its coverage to all models.
- A missing candle is not automatically proof of provider failure; these are native qualifying-trade aggregates, and completeness against exchange tick data has not been independently audited.

Intraday data includes available extended hours. Daily data retains the provider's native daily aggregation and is not resampled from our hourly files. Raw prices retain corporate-action effects; they are not a total-return series.

Intraday timestamps denote interval starts. Completed-bar time is the retrospective availability convention; the frozen historical records may include later corrections. They do not prove that final values were delivered exactly at the interval close. New York daily boundaries follow daylight saving and must not be advanced by a blindly fixed 86,400 seconds.

## Validation evidence

- **84 local tests passed** across existing and supplemental download, export, merge, and audit code.
- **714 supplemental export files** had their byte lengths and SHA-256 hashes independently checked.
- Every CSV row and every numeric Luau row matched its source bar values.
- All raw series passed positive/finite price, OHLC-bound, volume/trade-count, timestamp-order, uniqueness, request-bound, and interval-alignment checks.
- Both combined hourly series exactly matched earlier source rows followed by the frozen original rows.
- All **44 original export hashes** still matched, and all **39,849 original raw rows** still matched those frozen CSV exports.
- A project scan found **zero matches** for the user's real credential values.
- No model training, predictive-performance evaluation, order placement, or Studio import occurred during this data task.

The complete download used **749 paginated requests**. This is compatible with a 200-requests-per-minute allowance because the requests were paced over time. The final response reported a limit of 200 and 199 remaining in that then-current window; it is a historical snapshot, not a permanent balance. No paid subscription change was made.

## Reproduction

From the project root, regenerate exports and rerun the audit without credentials or network:

~~~powershell
node prepare-supplement.mjs
node audit-supplement.mjs data/alpaca-supplement-2016-01-01_2026-10-02
~~~

Run the local tests:

~~~powershell
node --test download.test.mjs export-data.test.mjs download-supplement.test.mjs supplement-export.test.mjs prepare-supplement.test.mjs audit-supplement.test.mjs
~~~

To deliberately fetch a new snapshot, use a new empty output directory:

~~~powershell
node download-supplement.mjs '<absolute-local-credential-file>' '<new-empty-output-directory>'
node prepare-supplement.mjs '<new-empty-output-directory>'
node audit-supplement.mjs '<new-empty-output-directory>'
~~~

The collector sends credentials only as headers to the fixed Alpaca market-data endpoint, rejects redirects, applies bounded retries and rate-aware delays, follows pagination, and refuses a nonempty output root. A failed run preserves partial files; this collector does not claim resumability. Reuse existing completed downloads rather than rerunning it casually.

The audit defaults to the original dataset beside the supplement. If exporting elsewhere, call auditDataset(root, {originalRoot}) with the actual frozen original location.

## Next-session handoff

Read this guide together with **docs/superpowers/plans/2026-10-04-roblox-physics-market-forecast.md**. All requested supplementary sources are now local; no new Alpaca call is necessary to begin implementation. Preserve the untouched final test and test the richer inputs against equally informed baselines. Do not claim the extra data has already improved forecasts.

References: [Alpaca historical bars](https://docs.alpaca.markets/us/reference/stockbars), [market-data plans](https://docs.alpaca.markets/us/docs/about-market-data-api), and [historical SIP access](https://docs.alpaca.markets/us/docs/market-data-faq).
