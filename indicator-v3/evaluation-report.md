# v3 evaluation implementation and verification

Task 3 source work is implemented in `src/Learning.luau`, `src/Execution.luau`, and `src/Study.luau`. The completed v2 source and results were not changed. This report concerns local Luau verification; it does not claim a completed native Roblox study or improved historical performance.

The later **Training normalization safeguard revision** section supersedes the original v3-1 fitting/preprocessing description below. It responds to the user's observed covariate-shift failure and accompanies a refit of saved observations, with no new native capture.

## Interfaces

`Learning.fit(records, options)` retains `trainEndT`, `validationEndT`, `variant`, and `provenance`. Its return is `(model, report)`. The five v3 variants are `coupled`, `independent`, `numeric`, `raw`, and `memory`. `memory` appends `feature.memory` with `feature.memoryNames`; physical variants append the recorded `states[variant].vector` with its recorded names. Dimensions are inferred and checked, including the native 59- and 107-value schemas. Reduced raw context remains an explicit compatibility option but is absent from the v3 study comparison set.

Each current model records schema `roalgo-learning-v3-2`, version 3, names, dimensions, training normalization and clipping, ridge penalty, split cutoffs, sample/label maturity ranges, and copied caller provenance. Its three ridge candidates are 0.1, 1, and 10. Six contiguous same-session future bars form the target, measured from the next open. Training and validation labels must have matured by their own cutoff. Validation chooses the penalty; training coefficients and normalization are never refitted on validation. Expected upside/downside are nonnegative magnitudes. Prediction `score` is explicitly labeled a signed mean-to-expected-excursion ratio and `isProbability=false`.

Training state diversity reports the participation ratio of the standardized state covariance, the active-state dimension count, and the total recorded state dimensions. It uses the same matured-label training rows as fitting. It is a redundancy diagnostic, not evidence of independent predictive factors.

`Execution.policies()` returns fresh recursively frozen descriptors. `Execution.new({policyId=..., ...numericOverrides})` accepts existing numeric configuration and applies the named policy's defaults first.

| Policy ID | Entry margin above round-trip fees and slippage | Scheduled exit rule | Maximum observed holding bars |
|---|---|---|---:|
| continuation | 1 bp | Directional mean reaches zero/adverse | 24 |
| horizon6 | 1 bp | No mean-sign exit | 6 |
| buffered | 4 bps | Directional mean reaches -2 bps | 24 |
| excursion | 4 bps | Same buffered exit; experimental entry requires favorable magnitude >= 1.2 × adverse magnitude | 24 |

All policies preserve signal-at-completed-bar / fill-at-next-observed-open behavior; locked signal-time volatility stops/targets; adverse gap execution; stop-first resolution of ambiguous OHLC barriers; signed short shares; fees/slippage; and elapsed-time short borrow. Favorable/adverse excursion mapping reverses correctly for shorts, and the favorable magnitude must be positive so clamped zero/zero heads do not qualify. Exposure is reported using bar-end marked equity and may exceed one because original all-equity sizing is preserved. No new risk-sizing parameter grid was introduced.

`Study.evaluate(records, split, options)` accepts `options.cancelled()` and `options.onProgress(messageString)`, plus copied `provenance`. It returns:

- `comparisons`: ordered `{id, model, report, result}` entries for the five fitted variants plus the unfitted `zero` forecast / cash baseline. `report.selectedPolicyId`, `report.policyCandidates`, `model.selectedPolicyId`, and `result.policyId` identify the frozen policy. Candidate outcomes contain full cost configuration, validation summary, block evidence, selection score, and closing-cost reserve. The baseline has no fitted model and always uses `no_trade`.
- `selection`: `scope="validation_only"`, exact ridge/policy candidates, objective, deterministic declared-order tie break, and `byModel[id]` entries. Evaluation selects no model, policy, or architecture.
- `diagnostics`: status, fitted model count, common schema, availability reasons, and `coverage.train/validation/evaluation` each containing total, available, unavailable, first/last timestamp.

All models use the same eligible feature timestamps. Missing/nonfinite/schema-changed inputs suppress that timestamp for every readout; observed bars remain in the ledger and labels, preserving time, barriers, and borrow. Capture records are not mutated. Policy eligibility requires model validation MSE strictly below zero, at least three chronological blocks with five sessions and 64 available bars each, at least one closed trade per block and six overall, positive median return and a majority of positive blocks. Among eligible candidates, selection uses min(mean block return, median block return) minus downside RMS, mean drawdown, and a further one-basis-point turnover cost stress. The score must be positive. The rule and thresholds are fixed, not optimized over evaluation. Insufficient evidence selects `no_trade`, which is outside the four-policy search budget. Open block positions reserve closing fee/slippage for scoring without inventing a fill. No positions or pending signals cross validation/evaluation boundaries.

`Study.aggregate(folds)` accepts `{id, foldId, configurationId, comparisons, diagnostics, metadata, split, phase, ...}` wrappers. It creates six comparison groups per configuration, including the explicit baseline. Group fields include `configurationId`, `id`, `folds`, `attemptedFolds`, `failedFolds`, `insufficientFolds`, `missingFolds`, `netReturns`, `meanNetReturn`, population `netReturnStdDev`, `minNetReturn`, `maxNetReturn`, `worstDrawdown`, `totalTrades`, `totalTurnover`, `totalFees`, `totalBorrow`, `meanExposure`, `meanGrossExposure`, `totalEvaluatedBars`, and `totalAvailableBars`. Empty groups omit mean-return estimates. `meanExposure` is the arithmetic mean of fold bar-end position fractions; it is not elapsed-time-weighted exposure. Failed/missing/insufficient model folds remain in the attempted denominators. Aggregate coverage identifies actual fold and model-fold completion. Equity restarts per fold; no compounded portfolio equity or evaluation winner is emitted.

## Local verification

TDD failures were observed before implementing dynamic state/memory fitting, study policy selection/common coverage, and training-only state diversity. The execution worker likewise verified newly added policy tests failed against the v2 behavior before implementation.

Commands (from `<workspace>`):

```powershell
luau 'indicator-v3/tests/Learning.spec.luau'
luau 'indicator-v3/tests/Execution.spec.luau'
luau 'indicator-v3/tests/Study.spec.luau'
& 'luau-compile' --null 'indicator-v3/src/Learning.luau' 'indicator-v3/src/Execution.luau' 'indicator-v3/src/Study.luau' 'indicator-v3/tests/Learning.spec.luau' 'indicator-v3/tests/Execution.spec.luau' 'indicator-v3/tests/Study.spec.luau'
```

Current verification: Learning 23 tests; Execution 26 tests; Study 15 tests; source/test compilation passes. Tests exercise real fitting, policy ledgers, and fold aggregation. Coverage includes matured labels, chronological split boundaries, both dynamic native dimensions, train-only masking/clipping/diversity, test-data perturbation invariance of genuinely eligible policies and their weights, missing common inputs, policy holding budgets, conservative costs/borrow/barriers, cancellation, incomplete fold accounting, zero-forecast comparisons, and explicit no-trade behavior.

Independent review identified two edge cases, both reproduced by failing tests and fixed: empty/all-unavailable evaluation windows could appear as successful zero-return model folds, and zero favorable excursion could qualify the experimental ratio. Review reran all 49 tests and reported no unresolved substantive findings. Empty/all-unavailable windows now have explicit `report.evaluationStatus` values and cannot count as successful aggregate outcomes. Native/real-data integration evidence is tracked by the root task separately. No Git operations, Studio actions, external orders, or Python fitting were performed for this task.

## Controller integration follow-up

Read-only review of the new App controller confirmed that `Features:step`, `feature.reset`, `Engine:step` state wrappers, cumulative native counters, split forwarding, and `Features:info()` match the actual module APIs. The review reported the dashboard mounting argument mismatch, full comparison tables assigned to the numeric model-count status field, and successful completion being declared despite unavailable evaluation diagnostics. Root owns those App fixes and reported passing lifecycle checks after correction. The review additionally reported that partial-study aggregation should include the failed current fold in attempted denominators.

Study imports now select sibling ModuleScripts in Studio and relative module paths in CLI. A new `StudyImports.test.mjs` regression failed before the change and passes with it. The eight existing Study integration checks still pass.

`tests/AppProbe.luau` now validates rolling study wrappers, every configuration/fold's native counters, dynamic recorded schema dimensions, matched learning samples/evaluation timestamps, matured-label cutoffs, validation-only policy provenance, frozen policy identities, signed marked-equity accounting, and nonoverlapping evaluation windows. `Probe.replay(control, timeoutSeconds)` uses live `nativeStats` before and after replay, checking unchanged native interval/request/bar/corruption counters; it does not rely on immutable result copies. The separate `AppProbe.test.mjs` verifies valid rolling wrappers, rejection of missing folds, rejection of new live replay steps, and successful zero-step replay. Both Node regressions and Luau compilation pass locally. Native execution remains the root task's responsibility.

```powershell
node --test 'indicator-v3/tests/StudyImports.test.mjs' 'indicator-v3/tests/AppProbe.test.mjs'
& 'luau-compile' --null 'indicator-v3/tests/AppProbe.luau' 'indicator-v3/src/Study.luau'
```

## Training normalization safeguard revision

The user supplied evidence that the old readouts had validation error far above a zero-return forecast and that a low-variance regime feature later reached roughly 93 training standard deviations. The old `max(std, 1e-9)` scaler retained near-constant predictors and allowed unbounded standardized extrapolation. The current model schema is **`roalgo-learning-v3-2`**; application version remains 3. Old v3-1 models are rejected by the new deserializer rather than silently treated as safeguarded models.

The training-only active mask retains a coordinate only when its training population standard deviation exceeds `max(1e-6, 1e-4 × training RMS)`, where training RMS is `sqrt(mean² + population variance)`. Statistics use only the matured-label training rows already eligible for fitting. The absolute floor is expressed in the feature's coordinate units; these model inputs are dimensionless return fractions, probabilities, log activity, or normalized mechanics. For a return fraction, `1e-6` is 0.01 basis point of variation. The relative criterion excludes coordinates whose variation is at most 0.01% of their training RMS. Both thresholds are fixed preprocessing criteria, not a validation/evaluation-tuned grid. The criteria and each coordinate's mean, standard deviation, RMS, threshold, active status, and rejection reason are recorded.

Every retained standardized input is clipped to **[-5, +5]** during training, validation, and prediction. Dropped coordinates contribute exactly zero. Clipping can move the training design mean away from zero, so the fit centers the clipped training design for its ridge solve and corrects the unpenalized intercept afterward. Prediction contributions use the identical clipped coordinates; their sum still equals the mean prediction. The original input dimensions, names, normalization positions, and full coefficient arrays remain intact; the ridge matrix contains only active predictors. An all-dropped schema yields an explicit intercept-only model rather than a failed linear solve.

Stable diagnostic interfaces:

- `model.activeMask`: boolean array aligned with original `inputNames`; `activeIndices` contains retained original indices; `effectiveDimension` is their count; `clipZ=5`.
- `report.preprocessing` and copied `model.preprocessing`: `schemaVersion="train-mask-clip-v1"`, `trainingOnly=true`, `absoluteStdFloor`, `relativeStdFloor`, `clipZ`, `originalDimension`, `activeDimension`, `activeMask`, `activeIndices`, `featureStats`, and `droppedFeatures`. Rejection reasons distinguish absolute and relative near-zero variance.
- `preprocessing.trainingClipping` and `validationClipping`: `rows`, `clippedRows`, `clippedValues`, `byFeature` counts aligned with original inputs, `maxAbsRawZ`, `maxAbsStandardized`, and `overflowValues`.
- Each prediction includes `standardizedFeatures` and `clipping`, whose `clippedFeatures` entries identify original `index`, `name`, pre-clip `rawZ`, post-clip `standardized`, and any arithmetic overflow. Dropped coordinates are zero and are not counted as clipped. Contribution entries include `active` and `standardized`.

Each readout now reports a zero-forecast comparator on exactly the same matured validation targets. `validationBaseline` records mean/upside/downside zero-forecast MSE and sample count. Top-level report/model fields are `validationZeroMeanMSE`, existing `validationMeanMSE`, `validationMseRatioToZero`, `validationMseSkillToZero`, and `validationZeroComparisonStatus`. For a positive zero-forecast MSE, ratio is model MSE divided by zero MSE and skill is one minus that ratio. When both errors equal zero, ratio 1 and skill 0 explicitly mean no improvement (`both_zero`). When the zero forecast has zero error but the model does not, ratio/skill are omitted with `zero_baseline_model_error`, avoiding infinity/NaN in saved JSON. Each ridge candidate also records the corresponding mean-head comparison. These diagnostics do not imply that bounded predictions are useful; the Study owner separately gates policy selection on forecast quality and sufficient validation evidence.

Fresh verification: **23 Learning tests pass** and Learning/source-test compilation exits 0. Added behavior checks cover absolute/relative feature rejection, unchanged mask/scalers when later periods change, the regime standard deviation 0.0043 / evaluation z=93 case clipping to 5, contribution equality, exact train/validation clipping counts, zero mean training residual with a clipped-design intercept, manually recomputed validation MSE, a hand-derived zero-return baseline, zero-error edge cases, intercept-only fitting, and deserializer mask consistency. Original chronological label maturity, evaluation perturbation invariance, dynamic 59/107-dimensional native schemas, and legacy reduced-raw compatibility checks remain passing. The same dynamic API accepts saved v2 raw33/state51 observations for the readout-only refit.

No new native capture, physical model writes, or live-money actions were performed for this revision. Saved-data refit outcomes and source snapshots belong to the root/data-worker evidence; this section records implementation and local verification only.
