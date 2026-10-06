# Spring array replay restoration

**Goal:** Restore the user's already chosen eight-layer, front-to-back spring array as recorded-state playback, paused with a Play button and numeric node readouts.

**Architecture:** Three unsealed sidecar modules load the immutable completed archive, map its recorded endpoints to the original parallel lane schedule, and render anchored visual nodes. Existing capture, scoring, execution, source pins, and result files are unchanged. The old single-cluster replay is paused and reversibly hidden only after the array is ready.

**Tech stack:** Luau, Roblox MCP in Edit mode, existing local read-only results endpoint on47627, anchored visual Parts/Beams, CoreGui playback controls. This workspace is not a Git repository; changes are new files with explicit ownership.

## Scope and established design

- Restore eight X-spaced layers at800studs, each containing coupled24nodes and independent24nodes, matching the prior live array geometry.
- Every displayed recorded endpoint must come from the corresponding archived variant/bar. The common playback axis is reconstructed schedule tick1..5616, not captured wall-clock time.
- Warm-up and idle intermediate motion was not recorded: show dim rest nodes and an explicit caption, never fabricate captured motion.
- Preserve signed displacement readouts, free camera, and compact per-lane date/block labels. No large floating header card.
- No native stepping, forces, constraints, unanchored Parts, policy regeneration or trading. All files under results/ remain immutable.

## Tasks and interfaces

- [ ] Data mapping — SpringArrayReplayData.luau; owner spring_lane_review. Data.new(laneSeal,totalRows), append(chunk), finish(), sample(lane,tick), stats(). Store coupled/independent51-double vectors in compact buffers; reject invalid range/hex/nonfinite samples and inconsistent schedules. Test uneven warm-up, block boundaries, idle tails, coverage and malformed input.
- [ ] Renderer — SpringArrayReplayView.luau; owner spring_shutdown_fix. View.mount(workspace,descriptor,nativeConfig,options), updateLane(sample), stats(), destroy(). Sample provides phase/lane/blockId/rowIndex/label/t and recorded coupled/independent vectors. Expose one-time camera attributes; pool geometry and labels. Verify correct coordinate scaling,384nodes,680Beams, eight layers, no physical simulation instances and safe cleanup.
- [ ] Controller — SpringArrayReplay.luau; root owns HTTP loader, manifest/hash-chain checks, lifecycle and Play/Pause/seek/rate controls. Verify pinned manifest/lanes/chunks through existing server SHA256 checks; load incrementally. Hide old viewer only after successful mount; restore on exit. Start paused where all lanes have an initial recorded endpoint; no camera-follow loop.
- [ ] Install only the three new modules outside the sealed source tree using Roblox MCP. Compile sources first. Verify loading errors fail visibly and do not remove the old viewer.
- [ ] Studio acceptance: archived first/last sample mapping matches; Play advances actual node positions then Pause/seek restores; all384node readouts exist; eight layers are front-to-back; native capture stays absent; user can press Play; camera stays free. Capture screenshot and short frame timing, document limits and hashes.

Root cause: terminal release correctly removed completed native capture/display rigs, but the existing replay viewer renders only one24-node cluster. The user expected the array layout to persist. This change restores that presentation without rerunning or changing the completed experiment.

## Completion evidence

All tasks completed. Data9tests and renderer5tests passed; all3newmodules compiled. Independent controller review identified an error-path restoration issue, fixed by one shared failure handler for loading, seek, and playback. Studio loaded all94hash-checkedchunks and all36,402rows. Eight layers/384numeric nodes are installed, anchored, physics-free and paused at tick79. Playback test advanced435→483 and moved288nodes while unrecorded lanes stayed dim; zeroUIerrors. Meanframe16.6687ms (~60FPS), p9518.2471ms. Eleven protectedsourcepins unchanged. See `spring-live-launch-audit-20261005.md` for sourcehashes and full acceptance evidence. Current UI is CoreGui.RoAlgoSpringArrayReplayPanel with a bottom-left Play button.
