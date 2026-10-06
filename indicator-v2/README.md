# RoAlgo Research v2

RoAlgo Research is a local Roblox Studio instrument for historical market experiments. It combines causal five-minute, hourly and daily market features with measured mechanical states, fits simple forecasting readouts, and evaluates BUY, SELL, HOLD and CLOSE decisions on later sessions. It uses cached SPY and QQQ data and sends no brokerage orders.

The supported place is the place configured in the code, **PlaceId 0** by default (an unpublished local place file; see the root README), in **Studio Edit mode**. All displayed results are historical exploratory research. Earlier date ranges in this project have already been inspected; none is described as an untouched project-level holdout. See `VERIFICATION.md` for measured run results, native counters, installed hashes and remaining limitations. The data, engine and learning reports describe their separate checks.

## Start and use

1. Run `Start-RoAlgo.ps1` from this folder. It starts the local bridge at `http://127.0.0.1:47623`, or checks an existing service at that address. Restart the bridge process after editing `bridge.mjs`; Luau source modules are served from the current files.
2. Open the RoAlgo place in Studio Edit mode. Use the installed **RoAlgo Research** local plugin, or run `Install-In-Studio.luau` in that place's Command Bar. The plugin's toolbar button shows or hides the dashboard.
3. Select **SPY** or **QQQ**, a chronological session profile, and an end date. Profiles are **20 / 5 / 5**, **40 / 10 / 10**, and **80 / 20 / 20** training / validation / evaluation sessions. The default end date is **2024-12-31**. The bridge supports cached cutoffs through **2026-10-02** and up to 1,000 total sessions, subject to available target history.
4. Click **Capture + train**. The controller captures coupled and disconnected native states together, records the mathematical counterpart, fits the readouts, and evaluates each comparison from a flat position on the same later sessions. Progress distinguishes capture, fitting and evaluation.
5. Select a comparison to inspect its trades and scores. **View physics** focuses the native rig. Node buttons inspect displacement, velocity and modeled force; bank energies are included in the saved state vectors and learned readout. The contribution inspector shows the largest terms in the learned return estimate. Enlarged markers and beams follow existing bodies without changing their dynamics.
6. **Replay** displays recorded evaluation rows and mechanical measurements. It adds no native steps. **Stop** requests cancellation after the current verified bar during capture, or the current readout during fitting; partial evidence is saved separately and is not presented as a completed fit/evaluation.

Wait until both the v1 and v2 controllers are idle before reinstalling. The installer checks that condition before mutation and again after fetching the source tree. It preserves the previous `ServerStorage.RoAlgoResearch` source folder under a collision-free `RoAlgoResearch_backup_<milliseconds>` name. Backups remain in ServerStorage for inspection or recovery. The v1 source package and market caches remain available; v2 hides the earlier dashboard when it starts.

## Saved results and programmatic controls

The bridge writes JSON files under `indicator-v2/results/` using unique names and refuses overwrites. Completed results use `RoAlgoV2_<symbol>_<timestamp>.json`. Native state checkpoints use the same run prefix with `_states_0001`, `_states_0002`, and subsequent suffixes; partial runs end with `_partial`. Keep a completed result together with its referenced checkpoint files and hashes.

The dashboard controller is `CoreGui.RoAlgoResearchControl`, a BindableFunction. For example, in the RoAlgo Command Bar:

```luau
local control = game:GetService("CoreGui"):FindFirstChild("RoAlgoResearchControl")
assert(control, "Open RoAlgo Research first")
print(control:Invoke("status"))
-- Profile 1 means 20 / 5 / 5 sessions. Capture is asynchronous.
control:Invoke("run", "SPY", 1, "2024-12-31")
```

Other commands are `stop`, `result`, `replay`, `variant` (one of `coupled`, `independent`, `numeric`, `raw`, `reduced`), `viewRig`, `inspect`, and `load`. Loading requires an idle controller and a completed v2 result basename:

```luau
control:Invoke("load", "RoAlgoV2_SPY_<timestamp>.json")
control:Invoke("variant", "coupled")
control:Invoke("replay")
```

Replace `<timestamp>` with an existing saved file's timestamp. `load` and `replay` reuse saved measurements; they do not claim to rerun physics. `destroy` is permitted only when `status.busy` is false. Plugin unloading requests stop, waits for activity to finish, and then destroys the controller.

## What is measured

- **Transport:** `bridge.mjs` validates the local CSV files and regular New York sessions, including DST, closures and early closes. Peer five-minute bars are available at start + 300 seconds; hourly bars at start + 3,600 seconds. Daily bars must precede the current New York date and use a conservative completion delay. Missing context is recorded rather than filled from future data. Dataset metadata includes actual counts, ranges, source hashes, configuration hashes and chronological split boundaries.
- **Features and regime:** `Features.luau` emits 33 finite raw predictors and eight bounded mechanical drive inputs. Scales use causal EWMAs. `Regime.luau` fits a deterministic three-state diagonal Gaussian HMM on target daily history completed before the first decision bar. Its standardization and fitted parameters remain fixed; only newly completed daily observations update forward probabilities. Insufficient or degenerate histories receive an explicit neutral fallback.
- **Native mechanics:** `Engine.luau`, `Mechanics.luau` and `VerifiedStepper.luau` build and step two matched 24-node, three-bank rigs. The coupled rig has links between nodes; the independent rig omits those coupling springs while retaining the other inputs and modeled parameters. Each observed market bar receives exactly 12 verified steps of 1/60 second. The numerical counterpart uses the same modeled mechanics. Native and numerical states are reported separately, including measured solver differences.
- **Learning:** `Learning.luau` fits regularized heads for forward return and favorable/adverse excursion. The six-bar label enters at the next open and ends at the sixth future close, stays within one uninterrupted session, and must finish before its split cutoff. Means/scales are fitted on training records. Validation selects a ridge penalty from 0.1, 1 or 10; evaluation does not choose parameters or refit the model. Insufficient samples have an explicit status and suppress model-driven entries.
- **Execution:** `Execution.luau` applies close-time signals at the next observed open. BUY opens a long position, SELL opens a short position, and CLOSE exits existing exposure. It holds at most one position with equity-sized notional and no pyramiding. Per-side fees and adverse slippage, elapsed-time short borrow, stops, targets, conservative stop-first ambiguity and a maximum holding duration are included. Final open exposure is marked without inventing a future exit.
- **Controller and dashboard:** `App.luau` coordinates capture, immutable checkpoints, learning, evaluation and recorded replay. `Dashboard.luau` shows the selected comparison, coverage/splits, model status, actions, ledger and measured mechanics.

The comparisons are raw features, raw features plus coupled native states, raw features plus independent native states, raw features plus numerical states, and a reduced-context raw baseline. The reduced baseline removes slower market/regime inputs; it does not pretend that existing native measurements were driven without those inputs. Recorded state interventions are analysis diagnostics, not new physical execution or proof of economic causality.

## Build and checks

Run from the repository root (the bridge test needs the downloaded data; see the root README):

```powershell
node --test indicator-v2/bridge.test.mjs indicator-v2/package.test.mjs
& 'luau' indicator-v2/tests/Features.spec.luau
& 'luau' indicator-v2/tests/Regime.spec.luau
& 'luau' indicator-v2/tests/Mechanics.spec.luau
& 'luau' indicator-v2/tests/Learning.spec.luau
& 'luau' indicator-v2/tests/Execution.spec.luau
node indicator-v2/package.mjs
```

The build generates `build/RoAlgoResearch.rbxmx` (inert source model), `build/RoAlgoResearch.plugin.rbxmx` (guarded local plugin), and `build/manifest.json`. Each module has a `SourceSHA256` child and a `sha256` attribute. The manifest records artifact, source, installer and launcher hashes. Rebuild after source changes. Install the **plugin artifact** under the local plugin filename **RoAlgoResearch.rbxmx**; the inert model is a source/archive artifact. Building and pure tests do not establish native Studio success; use the native probes and verification evidence for that.

## Evaluation limits

The default experiment is a small integration and research demonstration. A chronological split within previously inspected history does not make this an untouched research holdout. Returns in the UI are historical outcomes under the stated execution assumptions, not live trading forecasts, calibrated probabilities, or evidence of a proven edge.

Raw adjustment can expose corporate-action effects. Cached hourly inputs can include extended hours, while target decisions use regular-session bars. A mechanical reservoir transforms existing causal inputs and does not create new market information. Coupled/independent/numerical comparisons measure incremental readout performance and implementation differences for the fixed setup; they do not establish broad profitability, financial novelty, or economic causation. Read `VERIFICATION.md` for the actual sample, fitted models, native step counts, costs, cancellation/replay checks and measured limitations of the installed run.
