# Forward test plan: spring indicator on 2025–2026 SPY (pre-registered)

Written 2026-10-05, **before any 2025–2026 spring state was captured or any 2025–2026 decision was computed.**
The request came from the owner on 2026-10-05: "can we run 2025-2026 sp 500 data on it and I want to see it make decisions live".

## Frozen and unchanged (no retuning, whatever the outcome)

- **Protocol:** `spring-consensus-v1` (`src/SpringPolicy.luau`).
- **Calibration and thresholds:** taken from the 2024 result `results/RoAlgoV3_spring_v1_1791220038839.json`, SHA-256 `3fdcd3b57e0b9224117169c24a23ee8724efbfc968b7811f06a682f2bd0a5d6d`. The calibration covered 1,513 training rows from Nov 18 to Dec 16, 2024. The fixed values are:

  | Threshold | Value |
  |---|---|
  | entry | 0.11277320613367355 |
  | exit | 0.0507479427601531 |
  | bankDeadband | 0.028193301533418386 |

- **Directional nodes:** Fast {1,4,7}, Medium {9,11,12,14,15}, Slow {17,19,20,22,23}. Equilibrium-referenced z-scaling uses the 2024 training standard deviations.
- **Rig and capture:** the capture-time v2 24-node rig (coupled with 37 couplings, plus the independent rig) at the 2024 capture settings: 12 verified steps of 1/60 s per 5-minute bar, the same Mechanics projections, and the same Features drive construction. If any of these cannot be reproduced, the run is labelled as a different capture and not compared directly.
- **Ledger:** continuation defaults, as in 2024. That means next-open fills, 1 bp fee plus 1 bp slippage per fill, 3%/yr short borrow, stop at 2 vol, target at 3 vol, minimum distance 0.001, maximum hold 24 bars, and full-equity sizing.
- **Comparators:** zero-equilibrium state, frozen state, EMA trend baseline and no-trade. Each runs on the same bars with the same ledger.
- **The EMA baseline keeps its 2024 calibration:** entry 0.11727020501488576.

## Data

- **Bars:** SPY regular-session 5-minute bars, 2025-01-02 to 2026-10-02 (the last cached complete session). Source: `data/alpaca-supplement-2016-01-01_2026-10-02/`.
- **Context:** QQQ, IWM, TLT and daily context from the same cache, built with the same rules as 2024.
- **Holidays and early closes:** the NYSE schedule for 2025–2026.
- **Feature warm-up:** the first sessions warm the causal feature scalers and the 12-bar signal warm-up. All rows are reported; the warm-up rows are marked.

## Why this counts as out-of-sample

The indicator's rules, thresholds and calibration were fixed in 2024 data and written to disk on 2026-10-05, before any 2025–2026 state existed. 2025–2026 SPY bars were never used to design or tune this protocol.

Earlier, unrelated RoAlgo forecast studies did touch 2025 data. This test is out-of-sample for this indicator only, and the report will say exactly that.

## What will be reported, whatever it shows

- Every BUY, SELL and CLOSE, with source (physics, risk or baseline) and reason.
- Fills, trades, win/loss counts and time in market.
- Net return after costs, maximum drawdown, fees, borrow and turnover. These are reported overall, per calendar quarter, and per year.
- Every figure above is compared with no-trade, the EMA baseline, the zero state and the frozen state.
- Paired counts of action differences between coupled and zero (physics dependence).
- Long-side versus short-side counts, given the structural long tilt (D3).
- Capture audit: native steps, dropped or re-issued requests, and corrupt steps.
- Nothing will be selected, trimmed or re-run to improve the numbers. Any code fix made after decisions start appearing is logged with its reason. Fixes cannot change the frozen settings above.

## How it is shown live

The run steps the native rig in Studio Edit mode, bar by bar. After each completed bar:
1. The frozen indicator decides.
2. The ledger executes at the next open.
3. The spring panel and replay update as it happens.

Rows are saved write-once through the v3 bridge as the run proceeds, so the session can be replayed and audited afterwards.
