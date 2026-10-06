# Compact showcase layout — 2026-10-05

The default layout now stacks Independent below Coupled. Each complete rig retains its original internal geometry, orientation, spring coefficients, mass, rails and forces. Independent moves from an offset of `(0, 0, 2816)` to `(0, -768, 0)` relative to Coupled. Centers are 768 studs apart; the nearest rows are 256 studs apart. `layout="wide"` remains available for verification.

The RoAlgo Edit scene was rebuilt with correct cached rest positions. All 48 node poses relative to their guides, linear/angular velocities and applied drive forces were restored for presentation. Measured pose and velocity restoration error was zero. The camera targets the combined rigs and the dashboard is collapsed for showcasing. PhysicsView attachments follow the rigs.

This presentation engine has fresh counters and numeric state. It is not a continuation of the historical capture. App.start accepts a validated idle engine for this handover; every new Run still creates a fresh engine. The existing completed historical result remains loaded and unchanged.

## Verification

- Native LayoutProbe: 14 checks passed. Each layout ran the same 24 eight-input bars, with resets on bars 1 and 13, totaling 288 verified native intervals per layout.
- Maximum difference across all 51 readouts: coupled `4.872788478271772e-8`, independent `0`, numeric `0`; tolerance `0.002`.
- Exact mechanics configuration, internal geometry and inventory matched. No corrupt steps, saturation or off-axis observations.
- Luau compilation passed for Engine, App and LayoutProbe. App lifecycle regression checks: 9 passed. Package tests: 8 passed.
- Camera projection check placed all rig part centers inside the viewport, with none behind the camera. The MCP screenshot returned a blank world layer, so screenshot appearance was not independently verified.

Native evidence: `results/RoAlgoV2_layout_1791207635380.json`, SHA256 `00952e3b5ce8fec6da8194f2537895689482eab27a1399df2affdaf779506f14`.

Unchanged historical result: `results/RoAlgoV2_SPY_1791205420530.json`, SHA256 `bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828`. Its original source hashes and native counters remain historical provenance; they describe the previous wide layout.

Updated plugin artifact SHA256: `ce6b8a742bd10627857135ff0f43eb29605e6d81e15fd7f601f3aa7ef97fad3b`. Previous installed plugin preserved at `build/RoAlgoResearch.before-showcase.rbxmx`, SHA256 `e8532c483c14be843b09b1bb8f5d354e439882a250963e366149a39f15362c82`. The previous Studio source folder was retained as `ServerStorage.RoAlgoResearch_backup_showcase_1791207538167`.
