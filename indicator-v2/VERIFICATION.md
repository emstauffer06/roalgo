# RoAlgo Research v2 verification

The expanded application is installed in RoAlgo and completed its default historical experiment. Five models trained successfully. An independent audit reproduced every evaluation prediction and financial ledger row. This sample did not demonstrate a benefit from mechanical features.

## Completed experiment

Final result: `results/RoAlgoV2_SPY_1791205420530.json`, SHA256 `bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828`.

- **Capture:** 2,268 five-minute SPY bars across 30 regular sessions, November 18–December 31, 2024. Both early closes are included; no missing intraday intervals.
- **Training:** 20 sessions through December 16; 1,393 eligible labels.
- **Validation:** December 17–23; 360 eligible labels. Only this split selects the ridge penalty.
- **Evaluation:** December 24–31; five sessions and 354 bars. Every variant starts flat and uses identical costs and execution rules.
- **Regime history:** 2,234 prior daily bars from January 4, 2016 through November 15, 2024 produce 2,233 HMM observations. Parameters remain frozen; 29 newly completed daily observations update the forward filter.
- **Native execution:** 27,216 verified intervals, 9,071 cumulative checks and 4,536 request-free observation frames. Zero corrupt intervals, failed bars, barrier failures, off-axis observations or saturation. Three delayed completions were observed within the longer wait window. The 3,888 dropped requests were retried, not counted as completed intervals.
- **Provenance:** Five sequential checkpoints retain all states. The exact 14 runtime modules are in `results/RoAlgoV2_SPY_1791205420530_source.json`, SHA256 `ecbee1e2e639acd7e9b51d0b81a0d9541e24cc1ec23fdc4e033a2860a16dee58`.

## Observed results

| Model | Predictors | Penalty | Net return | Max drawdown | Closed trades | Final position |
|---|---:|---:|---:|---:|---:|---|
| Coupled native | 84 | 1 | −0.7263% | 2.5145% | 35 | Short |
| Independent native | 84 | 1 | −0.7263% | 2.5145% | 35 | Short |
| Numerical coupled | 84 | 1 | −0.7263% | 2.5145% | 35 | Short |
| Full raw inputs | 33 | 10 | +0.6374% | 2.5145% | 33 | Flat |
| Reduced fast inputs | 16 | 10 | −0.4326% | 1.7373% | 18 | Flat |

The mechanical variants have different coefficients, predictions and validation losses. Their evaluation decisions crossed the same thresholds and produced identical fills. The full raw model outperformed them here. Five previously inspected sessions cannot establish broad profitability or financial novelty.

Fees and adverse slippage are each one basis point per side. Short borrow is modeled at 3% annually using elapsed seconds and the documented OHLC timing approximation. Ambiguous stop/target bars use stop first. Final shorts are marked to the last close without inventing exit fees. The raw model's final SELL remains unfilled.

Three learned heads estimate six-bar gross return and upside/downside excursions. The mean head drives entry and continuation; excursions are diagnostics. Scores are not calibrated probabilities. Mechanical coefficients and projections are fixed, not trained.

## Checks and integration

- Bridge **6/6**, package **8/8**, and scheduler **2/2** Node tests pass. Features, Regime and Mechanics Luau suites pass; Learning **14/14** and Execution **15/15** pass. All production Luau modules compile.
- App lifecycle **9/9 assertions** pass against actual App source with scoped service mocks, covering controller preservation, load locking/identity/failure, native provenance, save failures and replay without stepping.
- Native dashboard **21/21** checks pass for callbacks, layout, data binding, real fixture fills, clearing stale values and computed/measured labels. These do not claim physical mouse automation in Edit mode.
- Hardened native probe **13/13** passes: 94 bars, 1,128 intervals, 48 signal bodies, 37 coupling springs, 48 axial springs/rails/forces and two metronomes. The unrelated sentinel remains unchanged.
- Native/numerical normalized x/v RMSE is **0.0017977014**; maximum position difference **0.0199398018**, velocity difference **0.0079835024**. Reset replay difference is zero on the tested sequence. Coupled amplitude residual **0.0032778978** exceeds independent residual **0.0006431365**. These establish mechanics within declared tolerances, not a financial advantage.
- A cancellation smoke stops at **128 completed bars / 1,536 intervals** and saves explicitly partial evidence.
- Native `AppProbe` passes on the completed real run, checking all five fitted models, matching samples/evaluation rows, causal cutoffs, valid actions, next-open entries and provenance.
- Saved loading and model selection work. Replay finishes without adding intervals. A second replay compares all **50 moving bodies**: maximum pose/linear-velocity/angular-velocity change is **zero**, and native counts remain **27,216**.
- `final-audit.md` independently verifies every prediction, selected penalty, fill, cash/share balance, cost, borrow charge, trade PnL, equity and drawdown. All **1,770 evaluation prediction/equity rows** reconstruct exactly. It also verifies eight CSV hashes, 14 source hashes, five checkpoint receipts and 15,876 causal context joins.

## Failure retained and corrected

The first long capture stopped before bar 1,537 when both metronomes showed 13 intervals instead of 12. Its partial evidence and exact source remain under `RoAlgoV2_SPY_1791204626696`. It is excluded from the completed comparison.

The evidence is consistent with a delayed request completing after a one-frame timeout treated it as dropped. The repaired protocol waits three frames before retrying, checks two request-free frames before publishing a bar, and checks cumulative counts before applying the next drive. The injected delayed-acknowledgement test fails against the original runner and passes against the repaired one. The entire experiment was rerun from the beginning. No pose rollback, numerical substitution or acceptance of extra intervals occurs. This finite observation window cannot guarantee every future scheduler or engine version.

## Installation and evidence

Installed plugin: `%LOCALAPPDATA%/Roblox/Plugins/RoAlgoResearch.rbxmx`. Its bytes match `build/RoAlgoResearch.plugin.rbxmx`, SHA256 `e8532c483c14be843b09b1bb8f5d354e439882a250963e366149a39f15362c82`. The source model hash is `ddd1d77c2ac0d2879d15f89e551a3131e23530781ab1caffbf7ba96d4984f987`. `build/manifest.json` records source, installer and launcher hashes. V1 remains intact. Restart-time plugin activation has not been exercised; its bootstrap lifecycle is tested.

Native evidence:

- `results/RoAlgoV2_hardened_native_1791205420519.json`: final mechanics probe; SHA256 `21cc1d2856a7d0619e867dd606a418de19c65e476ca5182881194b19f74bd0c7`.
- `results/RoAlgoV2_dashboard_1791204626658.json`: dashboard/cancellation; SHA256 `b1ddac8aa94ed55abfcc3563ef3f5d8a8fa2c551c53abef5449ad630e6ad9e6a`.
- `results/RoAlgoV2_app_probe_1791206221556.json`: application/load/selection; SHA256 `52cba61a5c0c74c2a6eb7584f2f955291e6f1a9bfae2ab4a59c2b9bd973e7bca`.
- `results/RoAlgoV2_replay_1791206431275.json`: unchanged native bodies during replay; SHA256 `97a46c858878f8d827b2bc875fc54aaca9a4907a19f996e21dbbf2be62830c64`.

From the repository root, with Node and the Luau CLI installed:

```powershell
node --test indicator-v2/bridge.test.mjs indicator-v2/package.test.mjs indicator-v2/tests/AppLifecycle.test.mjs indicator-v2/tests/Stepper.test.mjs
luau indicator-v2/tests/Features.spec.luau
luau indicator-v2/tests/Regime.spec.luau
luau indicator-v2/tests/Learning.spec.luau
luau indicator-v2/tests/Execution.spec.luau
luau indicator-v2/tests/Mechanics.spec.luau
node indicator-v2/package.mjs
```

Runtimes: `node`, `luau`. Native probes require RoAlgo Edit mode. `EngineProbe` owns and cleans its fixture; `AppProbe` audits a completed controller; run `DashboardProbe` while idle because it mounts its own UI.

## Practical limits

This is historical exploratory research using previously inspected dates. Raw prices can include corporate-action effects. Hourly contexts may include extended hours, while target decisions use regular-session bars. No live orders or proven trading edge are claimed.

Decorative markers and beams follow native bodies without changing the physics inventory: 48 markers, 85 beams and two labels. Early MCP captures omitted the 3D surface, but the final capture showed the coupled grid, colored markers, connections and label. The scene retains its original atmospheric haze; temporary diagnostic changes were restored. Dashboard construction, camera projection, native motion and the final grid appearance were checked through Roblox MCP. Physical Edit-mode mouse input and restart-time plugin activation remain untested. All Studio interaction used Roblox MCP, as requested.
