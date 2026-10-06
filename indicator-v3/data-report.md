# RoAlgo Market Lab v3 data transport evidence

Status: **implemented and verified**. Historical exploratory research only; inspected periods are not an untouched project holdout. No Studio tools or brokerage/order endpoints were used by the data worker.

## Implementation and request results

- Inspected the existing download and CSV export tooling. Reused the existing strict CSV parser and credential parser without changing v2 or original caches.
- Added tests before implementation. Initial RED run: 5 existing tests passed, 6 new/changed tests failed for missing v3 behavior.
- Added v3 loopback identity/port, completed hourly joins with maximum age 7,200 seconds, explicit context availability and provenance, and chronological trading-session fold descriptors with stride at least the evaluation-window length.
- Downloader focused GREEN run: 2 tests passed, 0 failed. Tests exercised request pagination, exact raw-page hashes, duplicate rejection, unavailable network outcomes, exclusive file writes and safe error reporting.
- Sandbox download attempt made 9 failed connection attempts, saved 0 pages, and recorded all three sources unavailable in `data/sector-hourly/manifest.json`.
- Authorized network retry completed a separate immutable cache under `data/sector-hourly-sip/`. It made **190 successful requests**, retained **190 exact raw response pages**, and exported **57,315 real provider bars**. All series use SIP/raw/1Hour, include provider-native extended hours and leave gaps unfilled. No rejected auto-review or user approval interruption occurred.
- Full post-download Node suite: **11 passed, 0 failed**, exit0. Coverage includes CSV duplicate/nonfinite/blank/OHLCV rejection, calendar/DST/early closes, future/stale joins, explicit missingness, source-definition cache invalidation, newly available sector cache invalidation and tamper rejection, query limits, chronological nonoverlapping evaluation windows, real HTTP routes, loopback protection, immutable results, safe saved reads, malformed requests, pagination and network failures.
- Independent cache audit rehashed all 190 response pages and all three CSV files, then compared every exported OHLCV/trade-count/VWAP field against the corresponding provider bar. All **57,315 records** matched. The audit checked the actual credential values in memory against generated v3 outputs without displaying either credential; no leak was found.

Requested range: **2021-10-01T04:00:00Z through 2026-10-03T03:59:59Z**. All three actual series begin **2021-10-01T08:00:00Z** and end **2026-10-02T23:00:00Z**. This covers the existing supported five-minute target interval, with an extra prior session for initial context.

| Sector | Bars | Successful requests/pages | CSV SHA256 |
|---|---:|---:|---|
| XLK | 18,282 | 58 | `67c3b45d03290248d60d792813635c938e88a111dabc50cadd1c5ba6b1f7f95d` |
| XLF | 19,684 | 66 | `5c69b061d478f38861e31d7c1a42724fb33d7f6ec393adc27048d52390810a15` |
| XLE | 19,349 | 66 | `64e16f4bf9213115dedd4384f2d317a64f5d09a65da9d3f516eb315e6b481f36` |

Successful manifest SHA256: `c699fa92baade957def3916934e858dec1e4ec0259a375a0f2f415030e838959`. The failed sandbox attempt remains in its separate directory as explicit unavailable evidence, and is not selected by the bridge. The downloader's default output now matches the bridge's `data/sector-hourly-sip` location; reruns refuse nonempty output directories.

## Actual default fold audit

All six combinations of **SPY/QQQ × three folds** were checked using train20/validation5/test5, stride60 and end2024-12-31. The pairs below have identical ranges/counts for both symbols. Every audited dataset has **zero intraday gaps**, **zero future/stale accepted contexts**, **zero same-day final daily contexts**, and **zero missing contexts** across all ten context channels. Training/validation windows can overlap under smaller requested strides; evaluation windows cannot overlap because stride must be at least the test count.

| Fold | First target date | Validation starts | Evaluation dates | Target bars | Prior daily bars |
|---|---|---|---|---:|---:|
| fold01_2024-07-11 | 2024-05-29 | 2024-06-27 | 2024-07-05–2024-07-11 | 2,304 | 2,114 |
| fold02_2024-10-04 | 2024-08-23 | 2024-09-23 | 2024-09-30–2024-10-04 | 2,340 | 2,174 |
| fold03_2024-12-31 | 2024-11-18 | 2024-12-17 | 2024-12-24–2024-12-31 | 2,268 | 2,234 |

The machine-readable audit, per-fold data hashes, source hashes and exact split timestamps are in `data/verification.json`. The reproducible audit is `data/verify-data.mjs`. This audit verifies data transport; it does not claim native capture or investment performance.

## Public API contract

The executable bridge listens only on `127.0.0.1:47624`. GET `/health` returns `{ok:true,app:"RoAlgo Market Lab",schemaVersion:3,root:<absolute indicator-v3 root>}`. The data worker does not start this listener; root controls the Studio lifecycle.

GET `/dataset?symbol=SPY&train=20&validation=5&test=5&end=2024-12-31` retains `{bars,prehistory,metadata,split}`. Added contexts are `xlkHour`, `xlfHour`, `xleHour` using the existing context bar shape `{t,o,h,l,c,v,n,vwap,day,label,minute,availableT}`. Hourly contexts become available at start+3,600 seconds, can include extended sessions, and expire 7,200 seconds after availability. Missing/stale observations remain absent. Daily bars retain the existing prior-New-York-date and start+93,600-second availability rules. ETF volume is ETF traded volume, not total constituent-index volume. VIX is excluded.

Metadata adds `sourceProvenance`, `contextStatus`, `hourlyMaxAgeSeconds`, `volumeMeaning`, and `excludedContexts`. Each `contextStatus[name]` reports source-level `available`/`status` plus joined `present`/`missing`, `reason`, source count and source first/last timestamps. `sourceProvenance` records feed, adjustment, source manifest hash and raw provider response hashes where present.

GET `/folds?symbol=SPY&train=20&validation=5&test=5&count=3&stride=60&end=2024-12-31` returns `{folds,metadata}`. Folds are in chronological order; stride counts observed trading sessions, not calendar days. Count is 1..20; stride must be at least test and at most 1,000. Dataset split sessions total at most 1,000. Insufficient history is rejected rather than silently reducing fold count. Each descriptor contains:

```text
id, symbol, endDate, end, train, validation, test, stride,
datasetQuery = {symbol,train,validation,test,end},
sessions, trainSessions, validationSessions, testSessions,
firstDate, trainEndDate, validationStartDate, validationEndDate,
testStartDate, testEndDate,
firstT, trainEndT, validationEndT, testStartT, testEndT
```

`trainEndT`/`validationEndT` are exclusive split boundaries, matching the dataset API. `testEndT` is also exclusive: the last observed five-minute bar start plus300 seconds. The fold metadata states that equity restarts per fold; fold outcomes are not a continuously funded portfolio. `/tree` and immutable POST `/result` retain their existing contracts. GET `/saved?name=<basename.json>` remains compatible and now accepts an optional `sha256=<64 lowercase hex characters>` precondition. A mismatching saved-file hash returns HTTP409 before parsing the file.

## Reference storage integration correction

The first native integration exposed that duplicating all replay records into the completed study could exceed the bridge's64MiB request cap. App now persists a `storage="fold-references-v1"` study manifest. Its `folds` contain only `id`, `foldId`, `foldIndex`, `configurationId`, `phase`, `endDate`, `dataHash` and `saved={name,sha256}`; the in-memory study retains full folds.

Each referenced `version="roalgo-fold-v3"` artifact uses `storage="checkpoint-references-v1"`. It omits `replayRecords`, retains `replayCount` and existing native `cacheChunks`, and stores each comparison as `storage="row-references-v1"`. Comparison `result.rows` are replaced by `rowCount` and `rowChunks` references to `version="roalgo-rows-v3"` artifacts of at most128 rows. Each row artifact carries fold/configuration/comparison identity, dataHash, first/last indexes and exact rows. Existing native checkpoints remain at most128 records each.

Loading validates each receipt hash through the bridge, matching fold/configuration/data identity and record coverage before atomically replacing the active study. Embedded older v3 study files still load. Replay hydration skips checkpoint chunks wholly before evaluation when receipt time bounds are available. Partial exports reference completed folds and retain a compact failed/current-fold checkpoint summary. Failed/stopped folds now remain in aggregation with their phase, error and actual native counters. Progress totals are computed from all requested datasets before capture.

The storage regression fixture includes successful reference export/hydration, tampered fold identity, partial export, embedded-load compatibility, native-counter preservation and a129-row case crossing both128-record chunk boundaries. These are mocked lifecycle checks and make no new native capture claim. Final source packaging is deferred until the separately requested learning/scaling changes are complete.

## Verification commands

```powershell
node --test './indicator-v3/bridge.test.mjs'
node './indicator-v3/fetch-sector-context.mjs' '<path-to-your-alpaca-credentials-file>' './indicator-v3/data/sector-hourly-sip'
node './indicator-v3/data/verify-data.mjs' '<path-to-your-alpaca-credentials-file>'
```

Credentials are read in memory and are never written to logs, cache metadata, URLs or report output. Only GET requests to the fixed Alpaca historical stock-bars endpoint are permitted by the downloader.
