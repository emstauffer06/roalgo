# RoAlgo Market Lab v3

RoAlgo Market Lab is a local Roblox Studio experiment comparing market features, inexpensive memory features, and measured mechanical reservoir states. It runs historical chronological folds using SPY or QQQ, completed market/sector context, and declared trading-policy candidates. Its two configurations contain 24 and 48 nodes per rig. The larger configuration is an experiment, not an assumed improvement.

Use the place configured in the code, **PlaceId 0** by default (an unpublished local place file; see the root README), in **Studio Edit mode**. All periods are historical exploratory research; previously inspected dates are not an untouched project holdout. The downloader requests historical bars only, and the experiment sends no brokerage orders. Data and packaging checks do not establish native capture success or investment performance; consult the native verification and result records (INTEGRATION-EVIDENCE.md and the reports) for those outcomes.

## Start and install

1. Run `Start-RoAlgo.ps1` from this directory. It starts the bridge at `http://127.0.0.1:47624`, checks the app identity **RoAlgo Market Lab**, schema **3**, health status and exact workspace root. The process is hidden. An existing matching bridge is reused. Restart it after editing `bridge.mjs`; `/tree` reads current Luau sources.
2. Open the supported place in Edit mode. Use the installed **RoAlgo Market Lab** local plugin, or run `Install-In-Studio.luau` in the Command Bar. The plugin button toggles the v3 dashboard.
3. Choose SPY or QQQ, a session profile, and a historical end date. Profiles are **20/5/5** (legacy short profile), **40/10/10**, and **80/20/20** training/validation/evaluation sessions. Defaults are **profile3 (80/20/20)**, end2024-12-31, **three folds**, **60 trading sessions of stride**, and both **grouped24/grouped48** configurations.
4. Start capture only when a new native experiment is intended. Each configuration/fold captures coupled and disconnected native rigs together, records the numerical counterpart, fits five readouts, compares a zero-forecast baseline, selects policies using validation, and evaluates the frozen choices. Native intervals remain **12 verified steps of 1/60 second per five-minute observation**. Recorded replay and separately authorized refitting of saved native measurements add no physics intervals.
5. Select a configuration, fold and model to inspect its historical results. `viewRig` focuses the physical display. `stop` requests bounded cancellation; incomplete studies remain incomplete and cannot be loaded as completed studies.

The installer checks **v1, v2 and v3** controllers for active work before mutation, immediately after each HTTP fetch, and before replacing live v3 objects. It verifies `/health`, loads `/tree`, and requires `Study` with the other runtime dependencies. Only an idle `RoAlgoMarketControl` is destroyed. Existing `ServerStorage.RoAlgoMarketLab` source is preserved as a collision-free `RoAlgoMarketLab_backup_<milliseconds>` folder. The installer does not destroy or rename the v2 source folder, controller or saved results. Final retirement of an idle earlier display is a separate handover action.

Identities are `ServerStorage.RoAlgoMarketLab`, `CoreGui.RoAlgoMarketControl`, `CoreGui.RoAlgoMarketStatus`, `CoreGui.RoAlgoMarketDashboard`, and `Workspace.RoAlgoMarketPhysics`. v2 retains its separate names, source tree, results and bridge port47623.

## Controls and saved artifacts

The controller is a BindableFunction:

```luau
local control = game:GetService("CoreGui"):FindFirstChild("RoAlgoMarketControl")
assert(control, "Open RoAlgo Market Lab first")
print(control:Invoke("status"))
control:Invoke("run", "SPY", 3, "2024-12-31", {
    foldCount = 3,
    stride = 60,
})
```

Capture is asynchronous. Programmatic `foldCount` accepts 1..6; stride must cover the evaluation session count. Set `nodeCount=24` or `nodeCount=48` in the settings table to run one configuration; omit it to compare both. The transport `/folds` endpoint separately supports up to20 fold descriptors. Folds are chronological, use observed trading-session strides, and reject insufficient history or overlapping evaluation windows. Exact evaluation dates depend on the selected profile and are recorded in the fold descriptors.

Other commands include `status`, `result`, `stop`, `viewRig`, `inspect`, `variant`, `selectFold`, `selectConfiguration`, `load`, `replay`, and idle-only `destroy`:

```luau
control:Invoke("variant", "memory") -- coupled, independent, numeric, raw, memory, zero
control:Invoke("selectConfiguration", "grouped48")
control:Invoke("selectFold", 2)
control:Invoke("load", "RoAlgoV3_SPY_<timestamp>.json")
control:Invoke("replay")
```

Replace the example filename with a real completed v3 result. Results live in `indicator-v3/results/` and use immutable, unique JSON names. Preserve the completed study manifest, per-fold artifacts, comparison-row chunks and referenced native-state checkpoint files together. Study manifests use `storage="fold-references-v1"`; fold files use `storage="checkpoint-references-v1"`; comparison rows and native records are saved in chunks of at most128. Loading verifies saved-file hashes and matching identities before restoring the complete in-memory result. Legacy embedded five-comparison studies remain readable; newly completed studies require six comparisons including the zero baseline. Fold equity restarts independently; an aggregate of fold outcomes must not be represented as one continuously funded portfolio. Plugin unload requests stop, waits for the controller to become idle, then destroys it.

## Data and causal conventions

The v3 transport reuses the original validated SPY/QQQ five-minute cache and SPY/QQQ/IWM/TLT hourly and daily context without editing those files. The separate sector cache adds actual XLK, XLF and XLE hourly observations: **57,315 bars**, obtained in **190 successful Alpaca SIP requests/pages**. All three actual ranges are 2021-10-01T08:00:00Z through2026-10-02T23:00:00Z. Raw provider pages, CSV files, request/adjustment/feed metadata and hashes are retained in `data/sector-hourly-sip/`. The first network-restricted attempt is preserved separately as unavailable evidence.

Targets use regular New York sessions with audited closures and early closes. Peer five-minute bars complete at start+300 seconds. Hourly context completes at start+3,600 seconds and expires7,200 seconds after completion. Daily context must precede the target's New York date and satisfy the conservative completion delay. Missing inputs remain explicit; no price series is fabricated. Relative hourly features require contemporaneous completed bars. ETF volume represents the ETF's traded volume, not all constituent-index volume. VIX is excluded.

Twelve physical drive channels separate trend, immediate return, range/activity, volume, QQQ–SPY, IWM–SPY, TLT return, XLK–SPY, XLF–SPY, XLE–SPY, target daily return, and regime stress. Comparisons are `coupled`, `independent`, `numeric`, `raw`, `memory`, and a `zero` forecast baseline. Six-bar labels must mature before their split boundary. Training data alone fit preprocessing; validation selects model/policy choices, which remain frozen during evaluation. Excursion estimates are expected magnitudes, not calibrated barrier probabilities. Policy assumptions and historical execution costs are recorded with results.

See `data-report.md` and `data/verification.json` (generated locally by `data/verify-data.mjs`; not included) for actual ranges, missingness, exact source hashes, raw-page/CSV matching, and fold leakage checks. See the engine/learning/native reports for the final implemented mechanics, policy details and measured limitations.

## Current saved-state result

In the original run, the installed dashboard was loaded with `results/RoAlgoV3_refit_saved_v2_24_1791212057087_readout.json` (not included: saved results contain market data). This is a **readout-only refit of the saved v2 native states**, not a newly captured v3 architecture test. It reuses 2,268 observations from 30 sessions and 27,216 previously captured intervals; new native steps are zero. The original v2 manifest and all five checkpoint files are unchanged.

The repaired readout drops near-constant training inputs and clips standardized inputs to +/-5 consistently. Every fitted model's validation MSE still exceeds zero-forecast MSE: coupled 1.235x, independent 1.230x, numeric 1.233x, raw 1.203x, and ordinary memory 1.454x. Every comparison therefore uses `no_trade`. Five validation sessions also fail the minimum policy-evidence requirement of three five-session blocks. The separate 25/5/0 maximum-history diagnostic also loses to zero and has no remaining evaluation period. Longer native history cannot be manufactured from these saved states; the 80/20/20 default is for a future explicitly intended capture.

Policy choice uses a fixed set of validation-block gates and a downside/drawdown/turnover-penalized score. It no longer maximizes five-session net return alone. See `refits/saved-v2-24-20261005T144956543/report.md` for the before/after comparison and `INTEGRATION-EVIDENCE.md` for the native/UI, replay, source and installation evidence. No additional capture was run after the user requested the saved-state repair.

## Build and verification

From the workspace root:

```powershell
node --test './indicator-v3/bridge.test.mjs' './indicator-v3/package.test.mjs'
node './indicator-v3/package.mjs'
```

The build creates `build/RoAlgoMarketLab.rbxmx` (inert source model), `build/RoAlgoMarketLab.plugin.rbxmx` (guarded local plugin), and `build/manifest.json`. Install the **plugin artifact** under the local plugin filename **RoAlgoMarketLab.rbxmx**. Building does not copy anything into the plugin directory and does not start Studio or the bridge. Install it after native validation.

Every module contains an inspectable `SourceSHA256` child and `sha256` attribute. The manifest records source, artifact, installer and launcher hashes. **Rebuild after any source change**, including dashboard or probe updates. Package tests execute the actual bootstrap and installer source under a bounded Luau fixture, and execute the PowerShell launcher against simulated health responses without starting a real process. They verify correct isolation, busy guards, preservation, dependency requirements, artifact hashes and hidden-launch behavior.

Raw price adjustment retains corporate-action effects. Hourly contexts include extended sessions; target decisions use regular sessions. Mechanical states transform existing observations and create no new market information. Neither extra nodes nor visually distinctive motion establishes a repeatable net forecasting/trading benefit. All comparisons must retain common timestamps, conservative execution assumptions, actual sample counts and the full recorded validation choices.
