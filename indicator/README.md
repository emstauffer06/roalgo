# RoAlgo physics buy/sell indicator

A local Roblox Studio research tool for the place configured in the code (PlaceId 0 by default; see the root README). It processes completed SPY or QQQ five-minute candles, measures real spring dynamics, and generates long/flat BUY, HOLD and SELL decisions. It does not forecast a fixed eight-hour price and does not send orders.

The app is installed in the identified RoAlgo editor session, and the local plugin package is installed for future sessions. End-to-end SPY and QQQ historical runs, the completed-app probe, and the native physics probe have passed. The historical runs lost money after the configured costs. See `VERIFICATION.md` for the verification record and limits.

## Open and use

1. Run `Start-RoAlgo.ps1` to start the hidden local data bridge on 127.0.0.1:47622. Node is required. The currently installed environment has Node 24 at `node`.
2. Open RoAlgo in Studio **Edit mode**. The installed local plugin is configured to open the dashboard. The **RoAlgo** toolbar button shows/hides it. Startup after reopening Studio has not yet been exercised; the current session is installed and running.
3. Select **SPY** or **QQQ**, choose **5**, **20** or **60** sessions, and click **Run**. The built-in historical cutoff is December 31, 2024; the panel and export record the actual interval. Keep Studio foreground for normal simulation throughput.
4. Watch the progress counter. **Stop** keeps completed rows as a partial run. **View physics** collapses the panel and frames the native rig. **Replay** replays the recorded chart; it does not claim to recompute physics.
5. Completed results are written under `indicator/results/` with unique filenames. Each contains the trade ledger, signal rows, numerical comparison, optional meta result, costs/configuration, source identities and native step counts.

For an installation into the current session without restarting Studio: start the bridge, then run the contents of `Install-In-Studio.luau` in RoAlgo's Command Bar. It installs `ServerStorage.RoAlgoIndicator` and opens the app. It refuses to replace an active run.

## Files and persistence

- `src/Core.luau`: causal volatility/activity features, entry/exit state machine, execution model and numerical control.
- `src/Meta.luau`: experimental logistic take/skip model, trained only on earlier completed trades.
- `src/Engine.luau`: three actual bodies with passive rails, SpringConstraints and VectorForces.
- `src/VerifiedStepper.luau`: existing verified native stepping protocol, copied with provenance; two free-falling metronomes confirm each completed step.
- `src/Dashboard.luau`: live chart, signal/fill markers, metrics, trade list and controls.
- `src/App.luau`: orchestrates data, physics, financial logic, UI and exports.
- `bridge.mjs`: restricted loopback transport for local source, cached candles and result export. It never reads brokerage credentials.
- `build/RoAlgoIndicator.rbxmx`: inert importable model containing the source and probes.
- `build/RoAlgoIndicator.plugin.rbxmx`: local plugin package with a bootstrap guarded to the RoAlgo place.
- `build/manifest.json`: package and source hashes.

Build packages with `node indicator/package.mjs` from the repository root. The plugin package is installed at `%LOCALAPPDATA%/Roblox/Plugins/RoAlgoIndicator.rbxmx`; its SHA-256 matches the generated package. The existing MarketReservoirLab plugin is preserved. All nine installed source/probe modules match the package manifest. Live installation changes the current editor session, while the package keeps a recoverable local copy. No cloud publish is performed. The original `lab/`, `runs/exp-20261005/`, and data snapshot are preserved.

## Signal and execution semantics

The force input is an exponentially smoothed log return divided by an exponentially weighted root-mean-square return scale, clipped to a fixed range. It uses only the current completed candle and earlier observations. Fast, medium and slow native spring responses supply displacement, change rate, response activity and signed agreement. These are measured physical states, not calibrated financial confidence. Fixed mechanical parameters are disclosed in `engine-report.md`.

BUY is a candidate entry decided at a candle close. It is filled at the next available tradable open, with adverse slippage and fees. SELL closes a long; there are no short positions or pyramiding. Stop/target levels use information fixed at signal/entry time. A gap through a stop fills at the worse opening price. If both barriers lie inside the same five-minute bar, the conservative stop-first assumption is recorded. OHLC data cannot reveal the actual intrabar order.

Day changes and missing bars reset the physical/feature history, cancel pending buys, and close remaining exposure at the next observed open. The strategy can therefore carry exposure over the gap until that open; this is not a claim of avoiding overnight risk. The end of the dataset marks an open position rather than inventing a sale. Warmup periods suppress entries.

Default estimated costs are **1 basis point fee plus 1 basis point adverse slippage per side**. Slippage is a proxy for execution friction including spread; these are experimental assumptions, not a claim about any broker's actual costs. Inspect the exported config for the exact run settings.

The numerical fast/slow control receives the same data and execution rules. Its response times are an explicit comparison configuration, not a claim of perfectly matched lag or complexity. A profitable chart by itself does not establish that physics is better.

## Learned entry filter

After a completed run, the app uses the 65% time boundary to select only trades closed before that boundary for training. The model also checks that each trade outcome was available by the boundary; candle timestamps identify the start of a five-minute bar, so its close is available five minutes later. If there are fewer than 30 eligible examples or only one outcome class, it reports **not trained**. Otherwise, a frozen logistic model is evaluated on later rows alongside fresh ungated and numerical strategies starting flat at the same boundary. Probability outputs are experimental scores; calibration has not been established. The fixed 0.55 acceptance threshold is not tuned against the displayed evaluation result.

These are exploratory historical comparisons. The prior experiment's test interval was already examined, and this tool does not relabel observed data as a new untouched holdout. Choosing or adjusting rules using these charts requires a later untouched evaluation before making a predictive-performance claim.

## Data and verification

Cached source: `data/alpaca-supplement-2016-01-01_2026-10-02/five-minute/{SPY,QQQ}.csv`. Prices are raw, not split-adjusted. Data are restricted to New York regular hours and the published early-close schedule for 2021–2024. The loader validates finite OHLCV values, strict timestamp order, alignment and timezone conversion. It reports observed intraday gaps and hashes the source file.

Verified on October 5, 2026:

- 16 Core behavior tests and 7 Meta behavior tests passed.
- 9 Node tests for the bridge and package builder passed.
- The final native engine probe passed all 19 checks: 126 input bars, 1,512 completed simulation steps, zero corrupt steps, and exact measured reset repeatability in the probe. It also checks that unrelated scene objects are not stepped.
- The synthetic dashboard probe passed its callback and programmatic selector checks after the final interaction changes. The dashboard was visually confirmed on the actual Studio screen. Buttons use `MouseButton1Click` with explicit active/interactable settings. Physical mouse clicks in Edit mode remain unverified: the authorized Roblox MCP input tools target Client mode only.
- The completed-app probe passed, including full data coverage. The final SPY export records the installed source hashes. Package and installed-module hashes were checked after the final changes.
- Replay completed with all 354 recorded rows, the same export path and net return, and the native step count unchanged at 4,248. The app returned to its completed, idle state with SPY and five sessions selected.

The first complete integration runs used the five sessions from December 24 through December 31, 2024: 354 candles per symbol, including the 42-candle December 24 early close. Both completed 4,248 verified native steps with zero corrupt steps or failed bars. These short runs verify integration, not a trading advantage.

| Export | Closed trades | Physics net return | Physics maximum drawdown | Numerical control net return | Learned entry filter |
| --- | ---: | ---: | ---: | ---: | --- |
| `results/RoAlgo_QQQ_1791199397782.json` | 13 | −0.5451% | 0.9709% | −1.5016% | Not trained: 10 earlier closed trades |
| `results/RoAlgo_SPY_1791200667556.json` | 15 | −0.6922% | 0.7987% | −0.9537% | Not trained: 10 earlier closed trades |

Both listed exports include the final outcome-availability guard in Core/Meta. The SPY run was repeated after the final UI/controller changes and reproduced its earlier financial results. The earlier SPY export remains available as historical evidence. Neither listed run ends with an open position. All figures include the configured fee and slippage assumptions.

Run local checks:

```powershell
node --test indicator/bridge.test.mjs indicator/package.test.mjs
luau indicator/tests/Core.spec.luau
luau indicator/tests/Meta.spec.luau
```

Studio probes under `tests/` verify native response/decay/reset, UI rendering/callbacks and live application coverage. They run in the explicitly identified RoAlgo Edit DataModel. The native probe checks that unrelated workspace parts are not stepped. Source compilation alone is not native verification.

Research sources: [EWMA variance](https://arch.readthedocs.io/en/latest/univariate/generated/arch.univariate.EWMAVariance.html), [López de Prado's labeling and validation methods](https://www.quantresearch.org/Innovations.htm), [backtest overfitting](https://www.davidhbailey.com/dhbpapers/backtest-prob.pdf), [NYSE 2021–2023 early closes](https://ir.theice.com/press/news-details/2020/NYSE-Group-Announces-2021-2022-and-2023-Holiday-and-Early-Closings-Calendar/default.aspx), [NYSE 2024 calendar](https://www.nyse.com/publicdocs/ICE_NYSE_2024_Yearly_Trading_Calendar.pdf).
