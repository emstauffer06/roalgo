# Spring filming presentation — 2026-10-05

User requested the original trading chart and right panel, with only one visible replay toggle, plus motion on the large and small original showcase arrays.

## Installed presentation
- Sidecar controller: CoreGui.RoAlgoSpringArrayReplayControl.
- Selected layer defaults to 7; rate defaults to 6 schedule ticks/s.
- Original SpringLive viewer stays paused. Sidecar seeks it to the selected layer's exact recorded row and verifies panel RowIndex and chart Index receipts.
- Actual historical dates, actions, fills, prices and P&L are retained.
- Small original SpringReplayView is visible and follows the same selected row.
- Large display is an anchored clone named RoAlgoSpringArrayCompanion, with 48 saved-state nodes and numeric displacement labels. The original RoAlgoResearchPhysics is parked intact under ServerStorage.RoAlgoSpringArrayCompanionOriginal.
- Eight-layer array retains all 384 actual endpoint nodes. Each layer has its own historical block schedule, so different layers display different dates.
- During unsaved warm-up gaps: affected array layers dim at rest with x --, the selected chart/data hide, controls remain available, and small display is parked until an actual endpoint returns.
- Only visible replay wording: small Replay: on/off toggle in the right panel. Play/Pause, Prev/Next, layer, speed and timeline all route to the one sidecar clock.
- No camera locking or automatic framing on load; explicit frame command remains available.
- Cleanup restores prior UI properties and the original research model. Saved scientific modules and sealed results remain untouched.

## Validation
- Saved trading viewer regenerated all 36,402 rows / 94 chunks, zero row differences.
- Data 9 behavioral tests, array view 5 and presentation 5 passed. Companion worker ran 6 source fixtures; Studio acceptance independently verified geometry and motion.
- All five sidecar sources and launcher compiled with Luau 0.741.
- Six-second Studio sample at 6 ticks/s: 360 Heartbeats, mean 16.6673 ms, p95 18.0792 ms, maximum 20.0882 ms.
- 384 array nodes, 48 large companion nodes, 24 small nodes moved: 456 total. All three models had zero unanchored parts and zero constraints.
- Chart and panel matched row 2346 at tick156; old viewer playback remained off; both UI error counters zero.
- Large clone and selected array displacement comparisons: 0 mismatches at 0.001-stud tolerance.
- Warm-up gap and restoration tested; both GUI receipts returned to row2310/tick120.
- Visible-text scan found exactly one replay reference, the allowed toggle.
- MCP screenshots omit CoreGui overlays in this Studio; GUI Enabled, visibility, positions and row attributes were verified through MCP instead.

Evidence: evidence/spring-filming-acceptance-20261005.json

## Sources
- src/SpringArrayReplay.luau: synchronized clock, loading and lifecycle
- src/SpringArrayReplayData.luau: unchanged packed endpoint archive
- src/SpringArrayReplayView.luau: eight-layer rendering and concise captions
- src/SpringArrayPresentation.luau: reversible original-GUI adapter
- src/SpringArrayCompanionView.luau: safe large-array display clone
- Open-SpringArrayReplay-In-Studio.luau: restores saved viewer if closed, then opens presentation
