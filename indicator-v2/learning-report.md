# Learning and execution implementation report

Status: DONE for owned modules and CLI behavior tests. Scope: historical exploratory research; earlier date ranges have already been inspected. Synthetic fixtures verify contracts; the small synthetic validation loss is not a market-profitability result. Native Studio verification belongs to the root task and is not claimed here. This worker performed zero native steps and made no Studio or Computer Use calls.

## Owned files

- `src/Learning.luau`: causal six-observation labels, train-only standardization, three ridge heads, validation-only lambda selection, serializable plain-table models and reconstructible mean contributions.
- `src/Execution.luau`: signed-share/cash ledger for longs and shorts, next-open orders, fixed signal-volatility barriers, costs, elapsed-time borrowing and final open-position marking.
- `tests/Learning.spec.luau` and `tests/Execution.spec.luau`: standalone Luau behavior suites.

No new dependencies or edits to existing indicator/lab/data/runs/tools were made.

## Contract and integration schema

`Learning.fit(records, options)` returns `(model, report)` on success and `(nil, report)` with `report.status = "insufficient_samples"` below 128 training or 32 validation labels. `Learning.predict(nil, record)` returns nil. Ready=false decision records never train. Labels anchor at the next observed open and end at the sixth future close; all six intervals must be exactly 300 seconds within the signal's session. Label availability is final future bar start plus 300 seconds, and must be <= the corresponding split cutoff. Training decisions precede trainEndT; validation decisions are in [trainEndT, validationEndT). No evaluation label selects or refits a model.

Model fields: `status="ok"`, `schemaVersion="roalgo-learning-v2-1"`, `variant`, `contextMode`, `inputNames`, `rawNames`, `rawIndices`, `rawDimension`, `stateNames`, `stateDimension`, `means`, `scales`, `weights`, `lambda`, `cutoffs`, `samples`, `sampleRanges`, `validationLosses`, `scope`, `provenance`, `readoutOnly=true`, `newNativeSteps=0`. Weights are three arrays, each containing intercept first and then coefficients on standardized inputs. Intercepts are unpenalized; Cholesky solves a centered design with positive diagonal ridge penalty. Candidate lambdas are exactly 0.1, 1 and 10, chosen by mean-return validation MSE, with deterministic smallest-lambda resolution of exact ties. No validation refit occurs.

Raw features are numeric arrays matched exactly to `feature.names`. Physical variants use retained raw predictors plus exactly 51 state predictors. `contextMode="reduced"` is raw-only and drops names containing hour, daily or regime (case insensitive), including associated missingness flags. It keeps five-minute peer features. Prediction rejects corrupt lengths, mismatched feature names and non-finite raw/state values. Contributions are `{name,value}` records beginning with `intercept`, followed by every input, and sum to gross predicted mean. Upside/downside predictions clamp at zero. Score is mean / max(1e-9, upside + downside).

`Learning.serialize` deep-copies the model to a plain table. `Learning.deserialize` deep-copies and checks schema, dimensions, scalers, indices and finite weights. Optional `options.provenance` carries caller-supplied source/config/data hashes and native step counters unchanged into report/model/serialization. The controller must supply real experiment provenance; modules do not fabricate data hashes or claim that fitting reruns physics.

Execution rows expose `t,label,close,signal,reason,position,equity,cash,shares,executions,prediction,signalT,holdBars,stop,target`. Position is numeric -1/0/+1. Signal is BUY/SELL/CLOSE/HOLD; signalT is t+300. Executions distinguish raw/adjusted price and contain `t,signalT,shares,quantity,fee,side,action,reason`. Historical prediction/contribution values are deep-copied. Existing positions close on mean crossing zero or timeout, with the close staged for the following observed open. A new entry signal can follow that executed close, and fills on the subsequent open; no direct reversal or pyramiding occurs.

Net liquidation equity is cash + signed shares * last close. Entry filled notional equals current equity. Fee and adverse slippage apply to both sides in both directions. A short sale credits cash and creates negative shares; covering consumes cash. Stops use worse adverse gap opens; if both barriers touch within an OHLC bar, stop wins. Stops/targets lock the signal's volatility, independently of future volatility. Result does not invent a future exit, exit fee, or future borrow period.

Borrow uses a 365-day seconds denominator and actual elapsed holding seconds. Missing/overnight intervals use the prior close mark; observed held bars use their open mark. Because OHLC cannot identify the intrabar time of a stop or target, an observed short barrier exit is charged for the entire 300-second interval, conservatively. Scheduled or gap exits at the next open accrue only through that open. This convention is included in the result summary. It is an explicit research approximation, not a quote for brokerage borrow fees.

## Red and green evidence

Initial red run after writing both specs, before production modules: both exited 1 with expected missing-implementation assertions: `Learning must implement causal three-head fitting` and `Execution must implement signed-share next-open ledger`.

After initial implementation, Learning 9 and Execution 12 tests passed. A hand-derived synthetic expected return was corrected from -0.003 to -0.001 because session 1 has x=-0.5 and r=0.001+0.004*x. This corrected the independent fixture arithmetic, not the implementation.

Additional red behavior: historical prediction contributions changed after the caller mutated a later shared table, failing `99 != 0.01`. Deep-copying stored predictions fixed it. Additional red behavior: provenance forwarding was absent and failed on `report.provenance.dataHash`. Explicit deep-copy forwarding and zero-new-native-step reporting fixed it.

Final green: Learning **14/14**, Execution **15/15**, **29/29 total**. Coverage includes split boundaries and full completion, session/gap rejection, training scalers, validation-only selection, heldout mutation invariance, known synthetic relation, all three constant heads/excursions, contributions, insufficient samples, physical vector and schema validation, serialization and provenance; plus next-open longs/shorts, costs, signed short profit, overnight/next-open borrow, adverse short gaps, conservative barriers, learned continuation, reversal sequencing, no pyramiding, no-fit suppression, final marking, prefix invariance, immutable contributions, entry threshold, timeout and signal-volatility target locking.

Actual synthetic fit metrics: train=170 valid labels, validation=102 valid labels, selected lambda=0.1, validation mean MSE=9.216374316927977e-13. Fixture split starts are trainEndT=518700 and validationEndT=777900 UTC numeric seconds in the synthetic clock. Five training sessions (1–5), three validation sessions (6–8), two unused evaluation sessions (9–10), 40 observed bars per session. Six future bars are used for each eligible label, leaving 34 labels per whole session. The split-boundary fixture admits 33 labels when cutoff is the last signal bar start, and rejects all later completions. A missing timestamp fixture removes seven affected labels (170 -> 163). The short ledger fixture marks cash=2, shares=-0.01 and equity=1.01 after a 100 -> 99 move with costs disabled. This is ledger arithmetic, not measured market performance.

## Reproduction commands and results

Run from `.` in PowerShell:

```powershell
& luau indicator-v2/tests/Learning.spec.luau
& luau indicator-v2/tests/Execution.spec.luau
& luau-compile --null indicator-v2/src/Learning.luau indicator-v2/src/Execution.luau indicator-v2/tests/Learning.spec.luau indicator-v2/tests/Execution.spec.luau
```

Final command results: first exits 0, prints `Learning: 14 tests passed`; second exits 0, prints `Execution: 15 tests passed`; compiler exits 0, compiled all four files into approximately 40 KB bytecode. An earlier compiler invocation passed positional `null`, which the CLI treated as an extra filename and exited 1; the corrected mode is `--null`, verified by help and the successful run above. No native-only code belongs to this task.

SHA-256 source/fixture/config provenance (generated with `Get-FileHash ... -Algorithm SHA256`):

| Artifact | SHA-256 |
|---|---|
| Learning source | `3AAA25451D4360680320D73D17931AC52DC2A627ECEE566005437006D332E4B9` |
| Execution source (contains default config) | `9DB7FDA89AA17EA517B1241CF8A44B4B542E8E118FFFFF68B04AA065E47E8D5B` |
| Learning synthetic fixture/spec/split definitions | `19C1E29093898B61ABB1BCDCBA7F69064F6327A4AA5DE4E808CCCBE8240E74CD` |
| Execution synthetic fixture/spec/config overrides | `FD24DEC0B6AA2D380B6A5E793696C59A840E0A8727DAC3D5FC56FDE0C95BC5FD` |

These hash source files containing the deterministic synthetic generators and configuration; they are not claimed as downloaded market-data hashes. Actual market experiment hashes and native step counters must be supplied by the root integration.
