# RoAlgo Market Lab v3 — integration evidence

Status: saved-state readout repair completed and installed. The user instructed that no additional native capture be run, and none was run after that instruction. The implementation is isolated from v2. No completed v3 architecture performance result is claimed here.

## Verified native behavior

Roblox Studio the RoAlgo place, Edit mode, accessed through Roblox MCP only.

| Fixture | Bars | Verified intervals | Corrupt intervals | Reset replay maximum difference | Native/scalar maximum normalized position deviation |
|---|---:|---:|---:|---:|---:|
| 24 coupled + 24 independent nodes | 12 | 144 | 0 | 0 | 0.0128083328 |
| 48 coupled + 48 independent nodes | 12 | 144 | 0 | 0 | 0.0205056914 |

Both fixtures passed zero equilibrium, positive drive response, ordered bank response, disconnected-control difference, release dissipation, dynamic inventories, world-X rails, no saturation, unrelated-body isolation, reset replay, and cleanup. Scalar comparison tolerance was 0.10; it is a numerical approximation, not a replacement for native measurements.

Evidence files:

- `results/native_probe24_1791210466227.json`, SHA256 `857f1cb72ceec3e8f390ff65f6d4fe99051003d0ae9a7a98e0ed5eaed985d212`.
- `results/native_probe48_1791210512323.json`, SHA256 `fe111b5aced113eb2ab95c3205cc6ae6fdd290d753e0c192d7276036f28e42cb`.
- `results/dashboard_probe_1791210610255.json`, SHA256 `026018861c25f8856706fc72acdb90db70778b512986cb7abb18c281ae3a8a70`: all 29 native UI checks passed. This verifies native construction, data binding, layout and shared callback handlers; it does not claim physical mouse input.

The initial real-data run `RoAlgoV3_SPY_1791210628345` was intentionally stopped after 351 bars and 4,212 verified intervals to fix export sizing. Its checkpoint and partial result files are retained. It is not a completed backtest and must not be included in performance aggregates.

## Model interpretation

The model uses 49 direct observations and missingness flags, 12 physical drive channels, and 48 ordinary causal memory features for a nonphysical comparison. The physical state has 59 coordinates at 24 nodes and 107 at 48 nodes. Coordinates include normalized measured positions and velocities plus derived bank/group summaries. Energies and force readouts are computed from the measured state and declared mechanical parameters.

Five readouts share direct inputs and eligible timestamps: coupled native, independent native, scalar numerical, direct market, and direct market plus lag/EWMA memory. Three ridge penalties and four declared policy candidates use development/validation data. Evaluation data selects no model or architecture winner.

Each fold starts a separate equity ledger. Arithmetic mean fold returns, worst drawdown and summed trade counts do not describe one continuously funded portfolio. The study is historical and exploratory, including previously inspected date ranges.

## Known research limits

- Training labels cover six future bars within a session. Execution may carry positions or pending orders overnight, so near-close use is outside that intraday label horizon.
- Provider prices are raw. The execution ledger models specified fees, slippage and borrow, but not dividends or short payment-in-lieu cashflows. Results are price-only ledger outcomes under those assumptions.
- The physical network is a designed nonlinear memory transform. More springs or a more complicated policy do not establish predictive value. A 48-node advantage requires evidence beyond a development comparison.
- Floating labels and enlarged markers are decorative. They do not add forces, bodies or extra physics steps.

## Readout failure and amended validation

The saved v2 model-to-zero validation MSE ratios were 91.41938 (coupled), 87.26171 (independent), 91.96620 (numeric), 367.35616 (raw), and 1.15882 (reduced). The common zero-return MSE was 7.959595470945455e-6. RegimeHigh's training mean/std were 0.002053603487591173 / 0.004269691033939613. Its maximum standardized input was 233.434 in validation and 92.6746 in evaluation. Training-only normalization is required for causality, but the previous unbounded transform amplified this distribution shift.

The new v3-2 readout retains a coordinate only when its training standard deviation exceeds max(1e-6, 1e-4 times training RMS). It clips retained standardized inputs to +/-5 in training, validation and prediction, corrects the intercept for the clipped training mean, and records dropped coordinates and clipping statistics. Model validation loss is always compared with the zero forecast on the same matured labels.

Policy selection requires at least three chronological validation blocks of at least five sessions each, positive and sufficiently distributed trade evidence, and a forecast that beats zero validation MSE. A declared cost/risk score replaces selection by aggregate five-session net return. No-trade is the explicit fallback, outside the four-policy search budget.

The default future capture profile is 80 training / 20 validation / 20 evaluation sessions. Only 30 sessions of compatible hardened v2 native states exist. The controlled repair keeps the original 20/5/5 split; an additional maximum-history fit uses 25/5 with no evaluation period remaining. Neither creates native states or validates the new v3 physical architecture.

## Completed refit and installation

The saved-state refit is `results/RoAlgoV3_refit_saved_v2_24_1791212057087_readout.json`, SHA256 `4c7748f0c7a6fd1e5e895acafb2b4b848216ac863ccf52f4f78ee8c3430bc413`, 23,680,334 bytes. It explicitly records readoutOnly=true, newNativeSteps=0, and historicalNativeSteps=27,216. Original raw33/native51 observations are preserved; the ordinary memory comparison adds 32 causal coordinates from the eight recorded drives. This is a saved v2 architecture refit, not new v3 native evidence.

The controlled 20/5/5 fit uses 1,393 matured training and 360 validation labels. MSE/zero ratios after repair are coupled 1.235194, independent 1.229765, numeric 1.232532, raw 1.203408 and memory 1.454269; the separate reduced-context diagnostic is 1.095286. All are worse than zero. Each of the six study ledgers contains 354 evaluation observations, no trades, no positions and no equity changes. No-trade is selected because the forecasts fail the zero benchmark and the five-session validation cannot satisfy the block requirement.

The separate 25/5/0 diagnostic uses 1,753 training and 324 validation labels, reusing the former evaluation period as validation. Its five ratios range from 1.175129 to 1.488639. There is no remaining evaluation period. Detailed tables and hashes are in `refits/saved-v2-24-20261005T144956543/report.md` and `report.json`.

An independent JavaScript verification recomputed the coupled, independent, numerical and raw validation predictions from their saved weights, training mask/scalers and original native records. It reproduced reported MSE within 6.8e-21, confirmed 360 validation labels and zero MSE 7.959595470945455e-6, and observed no standardized input outside [-5,5]. It did not fit coefficients. Original manifest/checkpoint hashes were verified unchanged before and after the actual Luau refit.

Fresh verification includes 23 Learning, 26 Execution and 15 Study tests; 19 App lifecycle checks; five saved-refit runner tests; eleven bridge tests; ten packaging tests; and the import/probe/feature/mechanics checks. The eligible-policy test proves that drastic evaluation-only changes do not alter fitted weights, ridge selection, policy choice or candidate gates. Relevant changed Luau sources and probes compile successfully.

Native UI-only verification passed all 46 checks, saved at `results/dashboard_readout_probe_1791211869760.json`, SHA256 `0ea66c9d0393deb111b1c21c38466ca5ea27515119160a7aa2e73b9f6ed033ea`. This constructs UI and synthetic ledgers, not physical captures. Saved-only replay passed with no engine created and zero native steps, recorded in `results/saved_refit_replay_probe_1791212157827.json`, SHA256 `b1c38476243008db1909fedab608a15dff5e8d648f0c4eb33013723fdd61cf84`. The final App probe passed all six comparisons, source/sample accounting, actual native-record provenance, and 2,124 HOLD observations: `results/saved_refit_app_probe_1791212309380.json`, SHA256 `5e2174688e342598162455ad89457c10d2717d732a8cf8103bfa4fe6bd6c830a`.

Installed plugin: `%LOCALAPPDATA%/Roblox/Plugins/RoAlgoMarketLab.rbxmx`, SHA256 `d17a0f6fe5f24bb0b0b7cf95d62c2f89b5076413054577b1561a8ef130abc867`. Earlier local plugins were moved intact to `build/previous-plugins-20261005-readout/`. Their data/source history remains available. All 16 currently staged Studio module sources matched the final build manifest and current bridge source tree. RoAlgo is idle, the corrected saved-state study is loaded, and no native engine was created for the readout repair. The existing v2 presentation remains viewable and is labeled as a saved-state presentation.

A larger native study is deferred in accordance with the user's no-capture instruction. The 80/20/20 profile is the default for any future capture; it was not retroactively claimed for this 30-session history.
