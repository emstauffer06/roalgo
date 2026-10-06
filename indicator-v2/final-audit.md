# Independent audit of completed RoAlgo v2 SPY run

**PASS, no audit findings.** Audited only `results/RoAlgoV2_SPY_1791205420530.json` and its five state chunks. Earlier cancelled/failed runs were excluded. Scope: historical exploratory research; earlier date ranges have already been inspected. This audit reads actual cached outputs and makes no profitability, novelty, or untouched-holdout claim. The audit worker performed **zero new native steps** and no Studio actions.

## Artifact and provenance

| Item | SHA-256 |
|---|---|
| Completed result | `bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828` |
| Source manifest, 14 entries | `b0bd546303dded5c30fcc68374e0e96473caefb02ee6f64684b46e1a72f069d2` |
| Dataset metadata dataHash | `789e6e64453e3c019e365b17604800e2f7750b04de85cfa827cef7beccec49d4` |
| Dataset metadata configHash | `015a2eca66db0ab3d8fd9a5d1d1f0ce401a9512fd01465038c524ac8c8cedd39` |
| Dataset metadata cacheKey | `a528bf46dfa217bbadeaee0af467a65c50fc45b60d33302c5b56ae4e8eadbc92` |
| States 0001, indices 1–512 | `d75e3a65a34750e2e54bf394a6d3ac5c1eae63810a1724e911bac2b80640b74a` |
| States 0002, indices 513–1024 | `7ef24f376cdc10d6784ade62d2a61e104d7f063d85a631aa61d9f8a34f4a69f5` |
| States 0003, indices 1025–1536 | `55c352c0a752ce6c58713030463c3543a557e7a4d62f4d8ee4e472a5d932cab0` |
| States 0004, indices 1537–2048 | `b79751d37ba5c6cc193983437e4e63c2b155cfcf4f910386042a50a7235b7ca3` |
| States 0005, indices 2049–2268 | `109aab90b951a60623db3c683dff06dba0e1a293dd2954d420fe1db243bdfa76` |

All **14 runtime source hashes match the current local Luau files and the bridge metadata**. All **8 CSV source hashes** match the actual cache files. All **5 chunk receipt hashes** match saved bytes. Source manifest hash is SHA-256 of UTF-8 `JSON.stringify(Object.entries(result.sourceHashes).sort(([a],[b])=>a<b?-1:a>b?1:0))`. Earlier chunk hashes remained unchanged on repeated reads. Final replay raw/drive/state vectors exactly match their corresponding chunk records.

## Native capture and causality

- **2,268** observed bars, sequential without duplicate timestamps or chunk index gaps, spanning **2024-11-18 09:30 ET through 2024-12-31 15:55 ET**.
- **27,216** recorded verified native intervals: exactly **12 per observed bar**, dt=1/60. Numerical counters also equal 27,216 intervals / 2,268 bars. **0 corrupt steps, 0 failed bars, 0 step failures**.
- Hardened scheduler evidence: lossFrames=3, postBarQuietFrames=2, **4,536 recorded quiet frames**. Metronomes=2, native nodes=48, rails=48, coupled edges=37, independent edges=0.
- Every raw vector has **33 finite values**, drive has **8 finite values bounded [-2,2]**, and each coupled/independent/numeric vector has **51 finite values** with consistent names, 24 nodes and 3 banks. Node x/v diagnostics match vector entries exactly; bank energies match the final vector entries and remain finite/nonnegative.
- All **15,876 context joins** meet decision-time availability. Peers use the same five-minute start and complete by t+300; hourly bars complete by t+300; daily bars precede the current New York date and satisfy the bridge's conservative t+93600 convention. No unavailable context found.
- All cached target OHLCV/trade-count/VWAP fields match the underlying SPY CSV exactly: **0 mismatches**. Replay/cache vectors have **0 mismatches**.

These checks audit recorded native evidence; they do not independently rerun or prove the Roblox solver. Root-owned Studio verification remains separate.

## Training and prediction reference checks

Independent Node computations used the saved immutable records, without calling the production Learning or Execution modules. The reference reconstructed labels from the next open through the sixth future close, rejected session/interval crossings, and enforced full label availability before each split cutoff.

Actual mature samples: **1,393 training** and **360 validation** for every variant. Train cutoff=1734445800, validation/test cutoff=1735050600. Last train label availability=1734382800; last validation label availability=1734987600, both strictly earlier than their cutoff. All five variants evaluate the identical **354-bar** interval, t=1735050600 through 1735678500.

Two-pass training-only means/stds independently match saved scalers; maximum mean error **7.106e-15**, maximum std error **1.721e-15**. Intercepts match independent training target means within **8.674e-19**. Three-head ridge stationarity residual is at most **1.638e-14**. A separate Gaussian-elimination solver with partial pivoting reproduced all three candidate validation return MSEs, with maximum difference **1.503e-15**, and selected the same penalties. This differs from the production Cholesky solver.

Saved mean/upside/downside predictions were recomputed from serialized weights, scalers and cached inputs. Across all **1,770 evaluation rows**, maximum prediction error is **0**. Every contribution array sums to its mean within the audit tolerance. Upside/downside clamps are respected.

## Independent signed-share ledger

The reference reconstructed cash and signed shares directly from raw fill prices, quantities, configured adverse slippage, and fees. It recomputed short borrow from elapsed seconds, using prior close marks over gaps and open marks over observed held intervals, with the documented conservative full interval for OHLC barrier exits. It then marked equity as cash + signed shares * close.

Across all **1,770 rows**, maximum equity reconstruction error is **0**. Final cash, signed shares, net return, total fees, borrow, drawdown, trade count, each closed trade's net PnL/return and final open-position marking match the saved results. All entries follow a previous close-time signal and fill at the next observed open. Exit quantity closes the existing signed exposure, entry notional equals current equity, and there is no pyramiding. Stop gaps use adverse opens, simultaneous barrier touches use stop-first, and learned/timeout closes follow the previous signal at the next open. No fictitious final exit or fee was found.

Audit tolerance: 2e-10 * max(1, absolute expected value) for ledger/prediction comparisons; independent validation-loss tolerance=1e-12 and ridge stationarity tolerance=1e-8. Observed errors were far smaller than these limits.

| Variant | Predictors | Selected lambda | Validation mean MSE | Closed trades | Final position | Net return | Max drawdown |
|---|---:|---:|---:|---:|---:|---:|---:|
| Coupled | 84 | 1 | 0.000727661284323 | 35 | -1 | -0.726312% | 2.514531% |
| Independent | 84 | 1 | 0.000694567933254 | 35 | -1 | -0.726312% | 2.514531% |
| Numeric | 84 | 1 | 0.000732013786713 | 35 | -1 | -0.726312% | 2.514531% |
| Raw full | 33 | 10 | 0.002924006397931 | 33 | 0 | +0.637388% | 2.514531% |
| Raw reduced | 16 | 10 | 0.000009223725129 | 18 | 0 | -0.432611% | 1.737335% |

All variants start flat with initial equity=1, use identical cost/risk configuration and evaluation timestamps, and select penalties using validation only. Reduced raw contains no hourly/daily features, associated missingness flags, regime probabilities or physical states. Physical variants retain the full-context states actually captured. The physical models have distinct weights/losses but identical observed fill paths: 36 entries, 35 exits, 16 stops and 10 targets, leaving a marked short at the final close. Their total fees=0.0070144299783680124 and borrow=0.0004779685450111967 in initial-equity units. Raw full fees=0.0065525964705089495, borrow=0.0004945148258048868; reduced fees=0.0035817859528607435, borrow=0.00022843050289542114.

The physical variants did not outperform the raw full baseline in this inspected interval. The positive raw result is one exploratory sample, not evidence of reliable profitability.
