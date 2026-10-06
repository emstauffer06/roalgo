# RoAlgo installation and verification

Completed October 5, 2026 (America/Los_Angeles).

The indicator is loaded in the RoAlgo Studio Edit DataModel, the original private place (ID redacted; this release uses PlaceId 0). Its current dashboard shows the completed SPY five-session run. The local plugin is installed at `%LOCALAPPDATA%/Roblox/Plugins/RoAlgoIndicator.rbxmx`. The bridge serves existing cached data on `127.0.0.1:47622`; it does not contact Alpaca or access credentials.

## What was verified

| Check | Evidence |
| --- | --- |
| Pure finance and learned entry filter | 16 Core and 7 Meta behavioral tests passed, including execution timing, costs, gap stops, ambiguity, and future-data exclusion. |
| Data bridge and package | 9 Node tests passed. |
| Native physics | Final Studio probe passed 19 checks over 126 bars and 1,512 verified native steps; zero corrupt steps and identical reset replay. |
| Dashboard | Studio probe passed rendering, callback routing, programmatic symbol/session selection, signal/fill markers, missing metrics, and the 180-bar chart bound. |
| Complete application | AppProbe passed target place, UI/controller presence, all 354 historical bars, native step coverage and saved export. |
| Replay | Completed 354 rows; saved path, returns and native step count remained unchanged. Replay displays recorded measurements. |
| Source consistency | All 9 Studio module sources and hashes matched the source tree. All manifest source hashes matched disk. |
| Local installation | Installed plugin SHA-256 matched the generated package exactly. |

The latest App, Dashboard and DashboardProbe files compiled with Luau 0.741. An independent review found no remaining P1/P2 issues in the finance/controller code after the partial-error export and label-availability fixes.

## Historical integration results

Both runs use five regular-market sessions ending December 31, 2024, including the December 24 early close. Each processed 354 completed five-minute candles and 4,248 verified native steps, with zero corrupt steps and zero failed bars. The strategy is long/flat, with one basis point of fee and one basis point of adverse slippage on each executed side.

| Symbol | Native net return | Native trades | Max drawdown | Numerical control return | Control trades |
| --- | ---: | ---: | ---: | ---: | ---: |
| SPY | −0.6922% | 15 | 0.7987% | −0.9537% | 19 |
| QQQ | −0.5451% | 13 | 0.9709% | −1.5016% | 18 |

These short tests validate integration, not a trading edge. Both lost money after the assumed costs. The optional entry filter remained **not trained** because the earlier training portion had fewer than 30 closed trades. Its fitting and leakage guards were tested separately. No model was tuned to make these displayed results profitable.

- Final SPY: `results/RoAlgo_SPY_1791200667556.json`, SHA-256 `ae16ebb00c3630440ad68df601852b19588def21b8881bddf1e0753de898a022`.
- QQQ: `results/RoAlgo_QQQ_1791199397782.json`, SHA-256 `d73fdc93eacf77aaf64e27d5d52a734abd91369e672bad22f101a2adf09ff415`. This precedes the final UI/controller selection fix; its financial and native engine modules match the final algorithm.
- Native probe: `results/RoAlgo_native_final_probe_20261005.json`.
- Installed plugin: SHA-256 `eb3b15701719da7164f9abbc463906f18ee9bbfed31dcc935331110e770a0454`.
- Package/source manifest: `build/manifest.json`.

## Use and verification limits

In the current RoAlgo window, select SPY or QQQ, choose 5, 20 or 60 sessions, then use **Run history**. **Replay** replays the stored chart; **View physics** reveals the three native spring channels. Start `Start-RoAlgo.ps1` when the local bridge is not running. The installed plugin is intended to load on the next RoAlgo place open; Studio was not restarted solely to test that startup path.

The dashboard was visually confirmed in the actual RoAlgo desktop window before the user requested MCP-only operation. Final controls bind `MouseButton1Click` with input enabled. Direct mouse delivery in Edit mode remains unverified because Roblox MCP input tools support Client mode only. Callback and controller checks are not physical-click tests. No Computer Use was used after the MCP-only instruction.

Nothing was published to Roblox or sent as a brokerage order. The earlier experiment and its data/results remain preserved.
