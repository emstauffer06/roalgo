# Saved v2 native-history readout refit

This run used 2268 original observations over 30 sessions, with 27216 historical native intervals and **zero new native steps**. Raw33/state51 vectors and all original records were preserved; only32 causal memory values from the eight recorded v2 drives were added. This is a legacy24-node capture, not a v3 native24/48 experiment. All original input file hashes matched before and after.

## Controlled original20/5/5 comparison

The original training/validation/evaluation split is unchanged. Zero-forecast validation MSE comes from the same matured labels under the actual Luau learning code. The six study comparisons include five fitted readouts and the zero baseline; reduced-context raw is a separate diagnostic.

| Model | Old validation MSE | Refit validation MSE | Old / zero | Refit / zero | Dropped inputs | Selected policy |
|---|---:|---:|---:|---:|---:|---|
| coupled | 0.0007276613 | 0.000009831648 | 91.41938 | 1.235194 | 8 | no_trade |
| independent | 0.0006945679 | 0.000009788430 | 87.26171 | 1.229765 | 8 | no_trade |
| numeric | 0.0007320138 | 0.000009810454 | 91.96620 | 1.232532 | 8 | no_trade |
| raw | 0.002924006 | 0.000009578642 | 367.3562 | 1.203408 | 8 | no_trade |
| memory | — | 0.00001157539 | — | 1.454269 | 8 | no_trade |
| zero | — | 0.000007959595 | — | 1.000000 | 0 | no_trade |
| reduced | 0.000009223725 | 0.000008718033 | 1.158818 | 1.095286 | 2 | diagnostic only |

Five validation sessions provide only one five-session block. They cannot satisfy the fixed requirement of at least three such blocks; the result is no_trade rather than permission to trade an unreliable model. The detailed JSON retains clipping counts, dropped-feature reasons, feature statistics and every failed policy gate. Evaluation remains historical and previously inspected.

## Maximum existing-history diagnostic25/5/0

The final five sessions, which were evaluation observations above, are reused here as validation. There is **no remaining evaluation period** and no untouched-holdout claim. These are only five Luau Learning fits, not a second Study or trading evaluation. The history cap remains30 sessions.

| Model | Mature training labels | Mature validation labels | Validation MSE | MSE / zero |
|---|---:|---:|---:|---:|
| coupled | 1753 | 324 | 0.000003782186 | 1.242597 |
| independent | 1753 | 324 | 0.000003812389 | 1.252520 |
| numeric | 1753 | 324 | 0.000003780527 | 1.242052 |
| raw | 1753 | 324 | 0.000003576828 | 1.175129 |
| memory | 1753 | 324 | 0.000004531083 | 1.488639 |

## Evidence

- Source manifest SHA256: bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828
- Frozen record SHA256: 259314fd0f73c708a128398b23e16948bbf3ef681647bfbe5f00a7b4f1aa1e5a
- Study output: indicator-v3\results\RoAlgoV3_refit_saved_v2_24_1791212057087_readout.json
- Study SHA256: 4c7748f0c7a6fd1e5e895acafb2b4b848216ac863ccf52f4f78ee8c3430bc413
- Study bytes: 23680334
- Native history: 1731940200 through 1735678500; no additional source period was read.
- Learning, Study, Execution, JSON utility, generated memory module and runner hashes are recorded in preparation.json and report.json.

The corrected artifact adds the explicit `readoutOnly=true` flag. The prior artifact is preserved byte-for-byte; no model was refitted. Executed source hashes still identify the original Luau snapshots. The metadata correction is recorded separately in report.json.
