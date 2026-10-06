# Spring Indicator — measured result (lean build, 2026-10-05)

Status: **working proof of concept, installed in RoAlgo Studio.** Built under the frozen contract
`spring-indicator-contract.md` (protocol `spring-consensus-v1`). Phase 1 was cut short at the owner's request; a lean
`src/SpringStudy.luau` (lean-1) and `src/SpringShowcase.luau` were written to measure and show what was done. Neither
has had an independent review yet.

## What ran

- One run: `node run-spring-indicator.mjs --manifest ../indicator-v2/results/RoAlgoV2_SPY_1791205420530.json --protocol spring-consensus-v1`.
- Result: `results/RoAlgoV3_spring_v1_1791220038839.json`.
  - SHA-256 `3fdcd3b57e0b9224117169c24a23ee8724efbfc968b7811f06a682f2bd0a5d6d`.
  - 8,871,677 bytes, single file, written once.
- Run directory: `spring-runs/RoAlgoV3_spring_v1_1791220038839/`.
- Inputs were re-verified unchanged after writing. `newNativeSteps = 0`: only previously captured states were read.
- Data: 2,268 five-minute SPY rows (2024-11-18 to 12-31), split 1,524 training, 390 validation and 354 evaluation.
  All 30 sessions had already been inspected, so **no fresh holdout exists**.

## Evidence verdict (three separate fields)

| Field | Value | Basis |
|---|---|---|
| implementationStatus | **pass** | Contribution sums equal the score (max error 1.1e-16). Zero-state rows score exactly 0. Every ledger is complete. The synthetic self-check passes: BUY at observation 13, SELL at 13, physics CLOSE at 16, no entries from a zero stream. |
| physicsDependence | **history_verified** | Coupled vs zero-equilibrium: 128 of 2,268 rows differ in the emitted action. Coupled emitted 128 physics actions; zero emitted 0. |
| marketEvidence | **development_only_no_fresh_holdout** | Not approved for trading. |

## Frozen calibration (coupled, training, post-warm-up rows, population std)

- n = 1,513 rows; 0 of 26 directional coordinates were dropped.
- Eligible voting nodes per bank: Fast 3, Medium 5, Slow 5.
- Thresholds: entry 0.11277 (nearest rank 984 of 1,513, inside the 0.10–0.35 bounds), exit 0.05075, bank deadband 0.02819.
- **Structural long tilt (contract D3), measured:**
  - The training score is positive on 61.5% of rows.
  - The Fast bank's mean is +0.070, and it is positive on 65.8% of rows.
  - Over the full history there were 553 positive setups against 299 negative, and 58 long entries against 41 short.

## What the coupled indicator did (full history, 2,268 rows)

- Intents: 58 BUY, 41 SELL, 29 physics CLOSE (24 loss of conviction, 5 bank reversal). Every other row was a HOLD.
- Risk exits: 26 stop, 3 stop-gap, 34 target, 7 timeout.
- 99 closed trades. Time in market: 524 bars long, 279 short, 1,465 flat.

## Controls: same history, same ledger, same costs

Paired against coupled, on the full-history rows.

| Comparison | Mean abs score diff | Emitted-action differences (long / short / close side) | Final-action differences |
|---|---:|---:|---:|
| Zero equilibrium | 0.0994 | 128 (58 / 41 / 29) | 135 |
| Frozen state | 0.1217 | 128 (58 / 41 / 29) | 135 |
| Independent (coupling removed) | 0.0090 | 74 (34 / 13 / 27) | 78 |
| Numerical comparator | 0.0015 | 27 (19 / 0 / 8) | 31 |
| EMA trend baseline | 0.1068 | 253 (87 / 77 / 89) | 262 |

The frozen state (record 12, repeated) never reached the entry threshold, so it traded exactly like zero.

Removing the coupling changed 74 emitted actions. The numerical comparator tracks native physics closely: 27 differences.

## Trading result (each partition ledger starts flat; 1 bp fee + 1 bp slippage per fill)

| Run | Training (in-sample) | Validation | Evaluation | Validation then evaluation, compounded |
|---|---:|---:|---:|---:|
| Coupled native | −2.323% | −0.108% | −2.478% | **−2.584%** |
| Independent native | −3.513% | +0.014% | −1.750% | −1.736% |
| Numerical | −2.773% | −0.178% | −1.458% | −1.633% |
| EMA baseline | −4.027% | −0.584% | −1.675% | −2.249% |
| Zero / frozen / no trade | 0.000% | 0.000% | 0.000% | 0.000% |

**Verdict:**
- **Physics participation is demonstrated.** Decisions come only from measured spring states, and removing those states removes every action.
- **There is no trading edge.** After costs, the coupled indicator lost 2.58% over the post-training sessions, which is worse than not trading. It was also slightly worse than the EMA baseline and the uncoupled rig.
- Five development sessions cannot establish or rule out an edge either way.

## In Studio (installed 2026-10-05)

- **Source tree:** `ServerStorage.RoAlgoMarketLab` now holds 24 modules, including SpringState, SpringSignals, SpringPolicy, SpringStudy, SpringReplayView, SpringPanel and SpringShowcase. The previous tree is kept as `RoAlgoMarketLab_backup_1791220221604`. The App's saved readout was reloaded; the App is idle and no Engine is running.
- **Replay model:** `Workspace.RoAlgoSpringReplay` has 50 parts, all anchored and non-colliding, with zero constraints or forces. It draws 61 stretch-coloured spring lines and 25 labels.
- **Panel:** `CoreGui.RoAlgoSpringPanel` provides run buttons, play/pause/step/scrub, and shows contributions, intent vs final, the pending order, fills, evidence and an aligned EMA comparison.
- **Control:** `CoreGui.RoAlgoSpringControl` accepts `status`, `run`, `compare`, `seek`, `play`, `pause`, `rate`, `find` and `exit`.
- **Restarting after a Studio restart** (Edit-mode command bar, bridge running):
  `require(game.ServerStorage.RoAlgoMarketLab.src.SpringShowcase).start({name="RoAlgoV3_spring_v1_1791220038839.json", sha256="3fdcd3b57e0b9224117169c24a23ee8724efbfc968b7811f06a682f2bd0a5d6d"})`
- **Demo row:** #1915 (2024-12-24 09:30, evaluation).
  - The second positive confirmation gives a BUY; Fast04, Fast07 and Fast01 contribute most.
  - #1916 fills it at the next open, 596.20.
  - The zero-state control holds on the same row.

## Tests at handoff

- **Luau specs:** SpringState 14, SpringSignals 23, SpringPolicy 24, SpringExecution 33, SpringReplay 26 and SpringPanel 12 pass.
- **Unchanged regression suites:** Execution 29 (the 26 originals untouched), Learning 23 and Study 15 pass.
- **Node:** 40 of 40 pass (runner, refit, AppLifecycle 19 checks, StudyImports, AppProbe, bridge, package).

## Not done / open

- SpringStudy (lean-1) and SpringShowcase are unreviewed. SpringStudy has no spec of its own; it self-checks invariants at run time.
- Phase-1 fixers for signals and view were interrupted. Several material review findings, mostly missing test coverage, are not closed, for example:
  - short-side counter resets;
  - gap rules exercised through the physical wrapper;
  - leak channels the boundary tests cannot see;
  - panel bar geometry.
- The plugin file was not rebuilt. After a Studio restart the plugin starts its embedded App; the spring modules remain in ServerStorage, and the showcase starts with the command above.
- No missing intraday intervals exist in this data, so gap resets are fixture-tested only.
