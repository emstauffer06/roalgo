# RoAlgo dashboard implementation

`Dashboard.mount(parent, callbacks)` creates an Edit-mode `ScreenGui` named `RoAlgoDashboard` under the supplied parent. The screen uses local Roblox instances and built-in fonts only. Its 1140 × 830 logical layout scales to the available viewport; collapse leaves a compact status strip with Open and Stop controls.

Public methods:

- `setStatus(text)` displays current progress, cancellation, or errors; messages containing “error” or “failed” receive error color.
- `setProgress(done, total)` updates both a progress bar and exact work counts.
- `setSelection(symbol, sessions)` synchronizes controls at the start of a programmatic run without overriding a user's pending selection during result rendering.
- `render(result, comparisonResult?, metaReport?)` consumes the Core result and optional numerical-control result. Missing values display an em dash. Meta accepts the controller’s `status`, `reason`, `trainTrades`, and `cutoff` fields.
- `append(row)` adds a completed row to the bounded 180-row chart. The controller should pass every row, or call `render` with all available result rows when throttling; skipping rows in `append` intentionally creates disconnected chart segments.
- `setCollapsed(boolean)` lets View Physics reveal the physical scene. The compact Stop button remains available.
- `destroy()` disconnects every event, destroys the GUI, and clears row/trade references. Repeated calls are safe.
- `buttons`, `screenGui`, and `testActivate(name)` support root-controlled Studio verification. `testActivate` invokes the same handler attached to the named button's `MouseButton1Click` event. Buttons explicitly enable `Active` and `Interactable`.

Callbacks are `run(symbol, sessions)`, `stop()`, `select(symbol)`, `replay()`, and `viewRig()`. No callback is required. Symbols are SPY/QQQ and sessions are 5/20/60. Callback errors become visible status messages.

The price curve uses supplied close values. B/S tags mark close decisions; diamonds show supplied `row.executions` at their actual fill price and execution bar. Signal attributes distinguish bar-start timestamp from close-time timestamp. Lines do not cross a missing five-minute interval. Fast/slow curves share a zero-centered scale and use the supplied engine displacement. Curve and marker instances are reused; no external asset or invented candle data is used.

Metrics, the numerical-control comparison, fees/slippage per side, recent closed-trade ledger, open-position disclosure, current position, signal reason, and experimental-model state all come from supplied results. The UI explicitly labels historical/exploratory research and makes no live-order, calibrated-confidence, or proven-edge claim.

`DashboardProbe.run(parent)` mounts with conspicuously synthetic fixture data, exercises all callback paths and collapse/expand, verifies metrics, independently counted signal/fill markers, the 180-row bound and missing-value handling, then destroys the GUI even on test failure. It resolves Dashboard as a sibling module or recursively within the parent container. Native Studio execution and screenshots are the root integration agent’s responsibility; this report does not claim they passed before that verification.

Verification completed locally: both `Dashboard.luau` and `DashboardProbe.luau` compile successfully with the pinned Luau 0.741 compiler (`luau-compile.exe --null`, exit 0). A separate read-only code review found and resolved two presentation issues: numerical-control assumptions now say “Same bars, execution rules and costs,” and the fast/slow legend uses separate colored labels. A compiler check does not verify native GUI rendering or event behavior; the Studio probe remains necessary.

Final Studio verification: the synthetic dashboard probe passed, including programmatic SPY/QQQ selection, callback routing, marker counts, missing-value handling, and the bounded 180-bar chart (718 descendants). The real dashboard was visually confirmed in the RoAlgo desktop window before the user requested MCP-only operation. Final controls use the desktop mouse event because `Activated` is documented for client execution. The MCP input tools accept Client mode only, so direct Edit-mode mouse delivery remains unverified; callback checks are not represented as physical click tests. The meta panel displays the evaluation start label instead of incorrectly describing a Unix timestamp as a score threshold.
