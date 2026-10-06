# Indicator core delivery

Implemented `src/Core.luau`, `src/Meta.luau`, and standalone behavior tests. These modules are pure Luau and perform no I/O, account operations, or Studio calls.

## Verification

Executed with:

```powershell
luau indicator/tests/Core.spec.luau indicator/tests/Meta.spec.luau
```

Result: **16 Core tests and 7 Meta tests pass**. Initial red run failed on the intentionally missing Core/Meta implementations. Availability-time regressions also failed before implementation. No changes to existing lab/data/tools or Git initialization were made.

Core coverage: next-open entry/no duplicate positions; two-sided fees and adverse slippage; signal-time volatility frozen into barriers; stop-gap execution; stop-first ambiguity; target-price fills; chop gating only entries; next-open holding timeout; reset cancellation/closure; final open marking; warmup/reset; volatility scaling; prefix invariance of features/signals/equity; numerical state reset; malformed data rejection; frozen meta cutoff/score gate.

Meta coverage: insufficient and one-class samples; deterministic finite fitted scores; training-only normalization and future-label exclusion; strict exit/cutoff boundary; explicit outcome availability; exclusion of open/already-filtered trades; independent signal feature vectors.

## Fixed experimental defaults

Defaults were selected as clear starting settings, without optimizing against historical results.

| Parameter | Value |
|---|---:|
| Initial normalized equity | 1 |
| Bar duration | 300 seconds |
| Segment warmup | 12 bars |
| Return / absolute-return EWMA alpha | 0.20 |
| Squared-return EWMA alpha | 0.10 |
| Volume EWMA alpha | 0.10 |
| Volatility floor | 0.00001 |
| Maximum absolute drive | 2 |
| Entry fast / fast-minus-slow | > 0.12 / > 0.035 |
| Entry signed agreement | >= 0.30 |
| Minimum directional efficiency | 0.18 |
| Exit fast / fast-minus-slow | < -0.08 / < -0.025 |
| Stop / target volatility multiples | 2 / 3 |
| Minimum stop distance | 0.1% of signal close |
| Maximum holding period | 24 bars |
| Fee per executed side | 1 basis point |
| Adverse slippage per executed side | 1 basis point |
| Experimental meta score threshold | 0.55 |

Return input is the log close-to-close return inside each contiguous session. Volatility is the square root of the EWMA squared return, floored for stability. Drive is EWMA return divided by volatility and clamped. Efficiency is absolute EWMA signed return divided by EWMA absolute return. Volume ratio uses the previous causal volume average; it is an activity diagnostic and never called order flow. Session changes and missing bars reset feature/engine warmup and exclude the gap return.

The numerical control is an EWMA bank with alphas 0.55, 0.28, and 0.12. It shares decision and accounting rules with native physics; it is not claimed to reproduce the spring transfer function. Agreement is signed channel consensus with a 0.005 near-zero deadband.

## Accounting and timestamps

Each position invests the available cash without leverage. Entry quantity accounts for its fee; exits deduct their fee. Buy slippage raises the open fill, sell slippage lowers the exit fill. Stops and targets anchor to the entry fill, using distances fixed from the signal bar. Target gaps receive the target rather than favorable gap improvement. Bars touching both barriers from between the barriers execute the stop and increment the ambiguity counter. Stops crossed at the open execute at the worse open.

On a new session or missing-bar gap, pending buys are canceled and existing exposure closes at the next observed open. Bar-close SELL signals and timeouts execute at the following observed open. An intrabar protective execution is in `row.executions`; `row.signal` describes the separate close decision. A closed position cannot reenter on the same bar.

All `t`, `signalT`, `entryT`, and `exitT` fields identify UTC **bar starts**. A signal becomes known at the end of its bar. `exitAvailableT = exitT + 300` conservatively exposes labels only after the completed exit bar. Feature input is completed bars. The final open position stays open, marked at the final close; no sale or final exit cost is invented. `summary.pendingSignal` exposes an unexecuted final decision. Drawdown uses the marked equity series at bar closes. Exposure is the fraction of processed bars with intrabar exposure, not a wall-clock fraction across overnight gaps. `totalFees` contains commissions, while slippage is embedded in executed prices and net return.

## Integration fields

`Core.new(config?)`, `core:features(bar)`, `core:step(bar, feature, physical)`, `core:result()`, `Core.numeric()` and `Core.defaults` match the plan. `step` accepts supplied causal features without calling the same instance's `features`; this supports replay with frozen recorded states.

Rows contain required fields plus `o`, `h`, `l`, `volume`, `day`, `medium`, `feature`, `state`, `executions`, `pendingSignal`, `metaScore`, `reset`, and `gapSeconds`. `position` is a boolean. Each execution contains `side`, `t`, `label`, `rawPrice`, `price`, `fee`, and `reason`.

Closed trades contain `signalT`, `signalLabel`, `entryT`, `entryLabel`, optional `exitSignalT`, `exitT`, `exitAvailableT`, `exitLabel`, `entryPrice`, `entryRawPrice`, `exitPrice`, `exitRawPrice`, `quantity`, `entryFee`, `exitFee`, `totalFees`, `netReturn`, `pnl`, `reason`, `holdingBars`, `ambiguous`, `vector`, `metaFiltered`, `metaScore`, `stop`, `target`, and `entryVolatility`.

Summary contains required `netReturn`, `maxDrawdown`, `tradeCount`, `winRate`, `exposure`, `ambiguousBars`, and boolean `openPosition`. Extras: `finalEquity`, `totalFees`, `realizedPnl`, `rowCount`, `pendingSignal`, `markConvention`, and optional `openPositionDetails` with `markPrice`, `markValue`, and `unrealizedPnl`. All returns and proportions are decimal fractions.

## Meta fitting

`Meta.fit(trades, options?)` returns `(model, nil)` or `(nil, reason)`. It requires at least 30 valid closed unfiltered executions and both after-cost outcome classes. With `options.cutoff`, a trade must satisfy both `exitT < cutoff` and `exitAvailableT <= cutoff`. When availability is absent, the generic fallback is `exitT + 1`; Core always supplies the completed-bar availability. The default cutoff is the maximum included outcome availability. Core will score evaluation bars only at or after the model cutoff.

Nine signal-time features: drive, percentage volatility, log volume ratio, efficiency, fast, slow, velocity, energy, fast-minus-slow. Training-only means/scales normalize them, with standardized values bounded to +/-8. Deterministic full-batch logistic training defaults to 180 epochs, learning rate 0.08, L2 0.01; the intercept is not penalized. No automatic threshold search, online refitting, or evaluation-result tuning occurs. Returned models contain `means`, `scales`, `weights`, `sampleCount`, `cutoff`, `threshold`, `positiveCount`, `featureCount`, and explicit `calibrated=false`. The displayed value must be called an experimental model score, not calibrated confidence.
