# Roblox physics market forecast: results

Experiment `exp-20261005`. Protocol sha256 `0cd34b780e534d0b…`, frozen before any validation search.

This is an eight-hour, within-day, extended-session forecasting experiment on SPY (S&P 500 ETF proxy) and QQQ (Nasdaq-100 ETF). It is not a trading strategy and makes no profitability claim.

## 1. Did Roblox's native solver generate the features?

Yes. Every physical feature is a position or velocity read from Roblox parts moved by native PrismaticConstraint rails, SpringConstraints and VectorForces under `WorldRoot:StepPhysics(1/60)` in Studio 0.741 Edit mode, from a local plugin thread.
Studio applies each StepPhysics request on a later frame and drops about one request in eight, so every step was verified: two free-falling metronome parts rode in every call and each completed step was confirmed as exactly one dt before the next was issued (docs/stepping-capability.md).
Across all recorded jobs: 171,660 verified steps from 196,182 requests (24,522 dropped and re-issued), 0 corrupt steps, 0 segment replays.

## 2. Software, causality, numerical and export checks

- Structural audit reproduces every count in plan section 2.3 (O14/R50 2,646/1,249/2,186 eligible origins; H14 9,103/1,249/2,186) in Luau and independently in Node.
- Tests at delivery: see README (Luau pure suite, Node suites, Studio Physics.spec).
- Inputs: training-only scaler; inputs sha256 O14 `66e9de7079a1…`, R50 `ae9bf8ae7f6a…`, H14 `ff7829a41860…`.
- Release gate: all profiles locked and final ledgers exported before outcomes were joined: true.
- Node recomputation of point metrics: 42 groups, 0 disagreements beyond 1e-10.

## 3. Final-period comparison (all eligible origins)

### O14  (status: complete; forecasts 79772, failures 0)

| Model | SPY RMSE bp | SPY MAE bp | SPY direction | QQQ RMSE bp | QQQ MAE bp | QQQ direction |
|---|---:|---:|---:|---:|---:|---:|
| ZERO | 84.87 | 50.04 | 0.0% | 107.15 | 66.77 | 0.0% |
| MEAN | 84.85 | 50.00 | 52.3% | 107.11 | 66.55 | 55.1% |
| MARKOV | 84.85 | 50.01 | 52.3% | 107.16 | 66.68 | 55.1% |
| RAW-RIDGE | 84.44 | 50.26 | 50.4% | 106.58 | 67.00 | 50.3% |
| RAW-RIDGE (8 lags) | 84.81 | 50.42 | 49.2% | 107.09 | 67.28 | 49.0% |
| PHYSICS-RIDGE | 84.77 | 50.20 | 50.2% | 106.93 | 66.86 | 51.0% |
| RAW+PHYSICS | 84.77 | 50.54 | 49.7% | 106.96 | 67.38 | 48.2% |

Eligible final origins per symbol: 2186. Always-up direction benchmark: SPY 52.3%, QQQ 55.1%.

### R50  (status: complete; forecasts 79772, failures 0)

| Model | SPY RMSE bp | SPY MAE bp | SPY direction | QQQ RMSE bp | QQQ MAE bp | QQQ direction |
|---|---:|---:|---:|---:|---:|---:|
| ZERO | 84.87 | 50.04 | 0.0% | 107.15 | 66.77 | 0.0% |
| MEAN | 84.85 | 50.00 | 52.3% | 107.11 | 66.55 | 55.1% |
| MARKOV | 84.85 | 50.01 | 52.3% | 107.16 | 66.68 | 55.1% |
| RAW-RIDGE | 84.80 | 50.17 | 50.8% | 106.52 | 66.90 | 50.9% |
| RAW-RIDGE (8 lags) | 85.03 | 50.58 | 51.9% | 107.01 | 67.67 | 50.4% |
| PHYSICS-RIDGE | 84.87 | 50.00 | 51.9% | 106.95 | 66.65 | 52.4% |
| RAW+PHYSICS | 85.09 | 50.61 | 51.7% | 107.13 | 67.81 | 50.2% |

Eligible final origins per symbol: 2186. Always-up direction benchmark: SPY 52.3%, QQQ 55.1%.

### H14  (status: complete; forecasts 79772, failures 0)

| Model | SPY RMSE bp | SPY MAE bp | SPY direction | QQQ RMSE bp | QQQ MAE bp | QQQ direction |
|---|---:|---:|---:|---:|---:|---:|
| ZERO | 84.87 | 50.04 | 0.0% | 107.15 | 66.77 | 0.0% |
| MEAN | 84.85 | 50.00 | 52.3% | 107.11 | 66.55 | 55.1% |
| MARKOV | 84.84 | 49.98 | 52.3% | 107.11 | 66.56 | 55.1% |
| RAW-RIDGE | 84.01 | 50.19 | 49.9% | 106.23 | 66.88 | 50.2% |
| RAW-RIDGE (8 lags) | 84.54 | 50.39 | 51.2% | 106.89 | 67.12 | 49.4% |
| PHYSICS-RIDGE | 84.34 | 50.19 | 50.5% | 106.62 | 66.93 | 50.3% |
| RAW+PHYSICS | 84.40 | 50.41 | 51.3% | 106.71 | 67.17 | 49.2% |

Eligible final origins per symbol: 2186. Always-up direction benchmark: SPY 52.3%, QQQ 55.1%.

## 4. Size and uncertainty of the differences

Paired moving-block bootstrap over New York dates (5-date blocks, 2,000 replicates), difference in mean-over-symbols RMSE divided by training target std (negative = model A better).

| Comparison | Estimate | 2.5% | 97.5% |
|---|---:|---:|---:|
| **R50 RAW+PHYSICS - R50 RAW-RIDGE (PRIMARY)** | 0.0040 | -0.0001 | 0.0093 |
| R50 RAW+PHYSICS - R50 RAW-RIDGE, SPY | 0.0031 | -0.0012 | 0.0087 |
| R50 RAW+PHYSICS - R50 RAW-RIDGE, QQQ | 0.0049 | 0.0008 | 0.0100 |
| R50 RAW+PHYSICS - R50 exact eight-lag RAW | 0.0008 | -0.0004 | 0.0022 |
| R50 RAW+PHYSICS - R50 MARKOV | 0.0011 | -0.0112 | 0.0146 |
| R50 RAW+PHYSICS - R50 ZERO | 0.0011 | -0.0115 | 0.0147 |
| R50 PHYSICS-RIDGE - R50 RAW-RIDGE (diagnostic) | 0.0021 | -0.0033 | 0.0068 |
| O14 RAW+PHYSICS - O14 RAW-RIDGE (reference) | 0.0033 | 0.0010 | 0.0066 |
| H14 RAW+PHYSICS - H14 RAW-RIDGE | 0.0046 | 0.0003 | 0.0089 |
| R50 RAW+PHYSICS - O14 RAW+PHYSICS (extra information) | 0.0024 | -0.0031 | 0.0094 |
| R50 RAW-RIDGE - O14 RAW-RIDGE (extra information, raw) | 0.0017 | -0.0028 | 0.0069 |
| H14 RAW+PHYSICS - O14 RAW+PHYSICS (training history) | -0.0030 | -0.0088 | 0.0033 |
| H14 RAW-RIDGE - O14 RAW-RIDGE (training history, raw) | -0.0037 | -0.0116 | 0.0045 |

The primary interval includes zero: no evidence of incremental value from the physics features on this holdout. The point estimate (0.0040) favours the raw baseline (adding physics features made the normalized RMSE slightly worse).

Exploratory: R50 RAW+PHYSICS - R50 RAW-RIDGE, QQQ; O14 RAW+PHYSICS - O14 RAW-RIDGE (reference); H14 RAW+PHYSICS - H14 RAW-RIDGE have intervals above zero, i.e. the physics-augmented readout was worse than its raw comparator there.

Context: every model's RMSE is within about 1% of the no-change forecast (R50 SPY ZERO 84.87 bp vs best 84.80 bp), and no model's direction accuracy beats simply predicting "up" (always-up SPY 52.3%, QQQ 55.1%). Eight-hour SPY/QQQ returns were essentially unpredictable from this information for all methods.

Secondary comparisons are exploratory (no multiplicity adjustment). Overlapping eight-hour forecasts and the two ETFs are not independent trials.

## 5. Consistency across ETFs, months and origin hours

- O14: RAW+PHYSICS had lower RMSE than RAW-RIDGE in SPY months 9/22, QQQ months 10/22, SPY hours 1/5, QQQ hours 1/5.
- R50: RAW+PHYSICS had lower RMSE than RAW-RIDGE in SPY months 11/22, QQQ months 10/22, SPY hours 2/5, QQQ hours 2/5.
- H14: RAW+PHYSICS had lower RMSE than RAW-RIDGE in SPY months 8/22, QQQ months 11/22, SPY hours 2/5, QQQ hours 1/5.

Full per-month, per-origin-hour and per-segment-age breakdowns: `evaluation-final.json` (profiles.<P>.breakdowns).

## 6. Repeatability and speed of the native computation

- O14: soft-reset repeats max 2.03e-5, median 0.00e+0; clean builds max 1.80e-5 (gate max 1e-3, median 1e-5): pass.
- R50: soft-reset repeats max 4.41e-5, median 0.00e+0; clean builds max 0.00e+0 (gate max 1e-3, median 1e-5): pass.
- H14: soft-reset repeats max 1.91e-5, median 0.00e+0; clean builds max 1.91e-5 (gate max 1e-3, median 1e-5): pass.
- Superposition (O14 inputs, u/2u/v/u+v): homogeneity deviation P1 21.1%, P2 14.5%, P3 11.1%; additivity P1 15.7%, P2 11.5%, P3 8.4% of response RMS.
- Drive calibration (inputs only): chosen {"O14":0.6,"R50":0.6,"H14":0.6} studs; no saturation at any grid value.
- Cross-session check (new Studio session and plugin build vs the earlier session, recorded before final physics): R50:P2 max 3.07e-3; every locked preset matched within 0.0e+0. The engine's small-velocity quantisation can turn ~1e-7 float differences into discrete ~1e-3 jumps; native repeatability is therefore high but not bit-for-bit across sessions.
- Job C1: 1187 observations at 2.99 obs/s (47.4 verified steps/s).
- Job D0: 22442 observations at 22.64 obs/s (47.3 verified steps/s).
- Job D1: 12872 observations at 7.54 obs/s (41.3 verified steps/s).
- Job F1: 7015 observations at 24.59 obs/s (52.1 verified steps/s).
- Job R1: 404 observations at 3.29 obs/s (52.2 verified steps/s).
- Job R2: 404 observations at 3.29 obs/s (52.2 verified steps/s).
- Job R3: 404 observations at 3.29 obs/s (52.2 verified steps/s).
- Job SP: 156 observations at 3.28 obs/s (51.9 verified steps/s).
- Job T1: 48 observations at 3.99 obs/s (41.9 verified steps/s).
- Job V1: 202 observations at 3.29 obs/s (52.1 verified steps/s).

## 7. Limitations

- One train/validation/final split; no walk-forward refit. Raw (not total-return) prices; extended-hours native hourly bars; QQQ is not the Nasdaq Composite.
- StepPhysics in this Studio build is deferred and lossy; the verified protocol guarantees exactly-one-dt requests but cannot observe the engine's internal adaptive sub-stepping of each assembly. Repeatability is measured, not assumed.
- Independent segments ran in parallel lanes; lane layout changes states by at most ~7e-5.
- The engine reports exactly-zero velocities for a small fraction of slow nodes (small-velocity quantisation); this is part of the measured native response.
- Validation-selected hyperparameters within a fixed 147-candidate budget; equal candidate counts do not imply equal capacity.

## 8. Extra information and longer history

See the secondary rows of the table in section 4 (R50 vs O14, H14 vs O14; O14 training target std as the common denominator).

## 9. Regime inputs (R60)

Not preregistered; disabled. No R60 result exists.

## Validation-period selection (for reference; selection used validation only)

- O14: RAW-RIDGE L4 λ=0.1; RAW+PHYSICS P1 λ=1; PHYSICS-RIDGE λ=1; model sha256 `254be2c24066…`.
- R50: RAW-RIDGE L4 λ=1; RAW+PHYSICS P3 λ=1; PHYSICS-RIDGE λ=1; model sha256 `6fc8e0787358…`.
- H14: RAW-RIDGE L4 λ=0.01; RAW+PHYSICS P3 λ=0.1; PHYSICS-RIDGE λ=0.00001; model sha256 `71f681433767…`.
