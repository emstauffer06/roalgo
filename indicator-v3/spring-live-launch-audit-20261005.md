# Spring live launch audit — 2026-10-05

Task: finish an internal handover note (not included), verify the previously untested multi-lane driver, then start the forward run inside RoAlgo Studio. No forward run has started as of this initial audit.

## Contract provenance

The plan remains SHA-256 `11c7f75de45ae7eafd889d2be1d1277a88b57599459d46f634b88100ec2333bc`.
The live contract at receipt was SHA-256 `e1f64a238085839cc83319cea5c26742d03dc718844f1b4fe81be8453d25f525`. The current pre-run contract is `d13e4c060134d3bc3c545b1a3bfa534a22bd51d4b2ca16bf27250a210d339250`, following the visual-only L21 clarification below.

The previous handover left the contract hash record at `d130e24a18d29157d47ff28e9927943f29a94dd8f2abf45bdf89937635d33c68`. The source was the previous session's transcript (not included).

At 2026-10-05T18:59:13.510Z, an Edit replaced L9's port 47625 wording with default port 47627 and an explanation that another project's bridge occupied 47625. At 18:59:20.737Z, a second operation replaced three remaining endpoint descriptions: `binds 127.0.0.1:47625`, `pages from :47625`, and `via the :47625 data server`, all with 47627. Reversing exactly these four recorded changes in the current UTF-8 file reconstructs the previously recorded D130E24A hash exactly. Therefore the unrecorded contract change is fully accounted for as a port correction. The new hash is appended to the existing hash record before any run. Trading rules, fitting, data, and lane protocol were not changed by that correction.

## Pre-install backup

- Backup: `backups/pre-live-lanes-20261005-130159/` (complete build tree and actual installed plugin).
- Installed plugin: `%LOCALAPPDATA%/Roblox/Plugins/RoAlgoMarketLab.rbxmx`.
- Original and copied plugin SHA-256 both `bdfc36170d31e589ccc52f84d300fc027b7f86964e00d0f4edb9e57bc8e1a714`.
- A source-tree install does not replace this plugin file. The permanent toolbar rebuild was not requested.

## Audit findings and required pre-run repairs

An independent read-only audit of the new driver found that terminal manifests could be sealed before a yielding physics producer stopped; capture cleanup did not clear the cached active registry through a supported terminal control; and a waiting consumer could return a row after a producer fault. Repair these orchestration issues and test them before native execution. Keep all decision/feature/calibration/native-configuration modules frozen.

The target eight-lane layout spans about 40,463.5 studs in depth. L21 requires checking its actual draw distance before forward data, so the probe needs a retained inspection mode with explicit safe cleanup. Select and record the fixed lane count before the run using measured probe and viewport evidence.

Implementation deliberately emits completed records chronologically before an entire block has finished. This differs from L19's literal block-completion wording; record that disclosure with the run. It must not change inputs, mechanics, warm-up boundaries, or chronological decision order.

## Protected source pins before repair

| Module | SHA-256 |
|---|---|
| SpringState | bf7cd0a8b76f3bf36836b91cda735fa6a0632bcee90f37095b2c2956973602e0 |
| SpringSignals | 2d6c65a6d32e3eac4b3bdaa9a7cd6bc02640d409b49805712d44d9bcd356426c |
| SpringPolicy | 4dc7adcdee61c3321ae931732173a171457f9c97c0e83dc024e8d51c9a1d3119 |
| Execution | 24d03c162bfd4a3c9e3e39ce0178a08af74d4b30212930f737ce9acf3ff6ffc3 |
| SpringStudy | 38aa94db338dccd8c3eb973ebb187c94259b04fa9345bc568267d61835d87654 |
| VerifiedStepper | 1ee4c13cac93f1dafea47c0f5d8a595558a0a03d14decb357fef36eb14a31fa4 |
| Learning | c2a7bfe24829602d8db055412446ff8d2be6b1ff5650bcd4ff13bdebf7933984 |
| Features | a40d1c42f51fa77eab027522ae760ddc34ea4ea75fa84eefff267381dd22efb9 |
| Regime | 5b8ac36eac95fb2e9f7c100c89202bbe9267f24ff0787fafbdf8bbe35bdb0d4f |
| SpringFrozenV1 | 23f34988d72073ed55e7b0f7c7375a79089948fad8e5f259c2611e00b43c5bc0 |
| SpringLiveCapture | 15a5673d287756ca2969d17e5e8e798c726949257a941a46d3a995960098dae1 |

## Initial runtime state

At 13:01 local: the RoAlgo place is in Edit mode; market App is idle/complete; the 2024 spring showcase is paused at row 50. No live-lane or live-physics container and no live controller exist. The lane module is not installed. Bridge 47624 is the expected schema-3 project bridge; 47627 is free.

## Execution ledger

- Contract hash provenance: verified; appended record.
- Backup: made; plugin byte hash verified. All six build files have identical paths and SHA-256 values in the backup.
- Raw-data server: started hidden at loopback 47627; health reports RoAlgo Spring Live / roalgo-spring-live-server-1. Manifest pins match 36,402 bars, 72 pages, 469 sessions, 2,268 capture lead-in rows, and forward start 2,269.
- Unchanged Luau suites: SpringLiveCapture 22, SpringLiveSession 20, SpringLaneLayout 41, SpringBlockSchedule 23, SpringFeaturesPass 22 checks passed (128 total).
- Node baseline: `node --test` run separately for spring-live-data, spring-v2-copies, SpringLiveSession, spring-features-pass, and run-spring-indicator; all five returned exit 0. An initial combined invocation hit the 60-second harness timeout; rerunning independently with a longer harness deadline completed. These are offline tests, not production showcase results.
- Lifecycle repairs: independently reviewed; 39 SpringLive tests, 15 lane lifecycle tests and 15 pinned-copy tests passed. Studio installed this source tree and successfully reloaded the frozen saved App readout. SpringLive SHA-256 `0a8b4f0f91435b0db7a259708f8337cb330b6c967591cff676b59472b4dd6902`; first repaired lane driver SHA-256 `b08f51897fa95c5ae068edd4b69edf733c4d314e05554771218a17c53040d757`.
- Probe attempt 1: eight lanes, requested 20 timed zero-drive bars, retained inspection enabled. Refused at layout planning before native stepping because lane 4's swept box z[-1537.75,3071.75] overlapped the existing research rig's excluded zone z[-896.75,896.75]. No forward run or result was created. The default footprint-plus-512 spacing was insufficient for the existing scene; a spacing correction is being prepared under L16, preserving the origin, Z-only centered offsets, native modules, and protected rig.
- Post-refusal Studio check: no lane container, no live controller, zero active single-lane captures; releaseProbe returned false because failure cleanup had already completed. Protected source audit verified all eleven pins above unchanged. No result directory or sealed attempt exists yet.
- Placement fix: select the smallest valid two-stud spacing using bounded forbidden intervals, then verify through unchanged SpringLaneLayout. Eight lanes need 13,060 studs; seven would need 6,530. All 21 lifecycle/placement tests and 41 unchanged layout tests passed, with independent review. Driver at this stage: `42e5e36c97890ba8c2f471fcf500f74ae72b0f7e60b16cf1dc2e7c393de362ce`.
- Probe attempt 2: eight lanes, 20 timed zero-drive bars after construction warm-up, 386 explicitly stepped parts. 6.416574900002161 seconds; 3.1169276929960354 bars/second/lane; 240 verified timed steps; 385 waited frames; zero corrupt steps; zero isolation movement/missing parts. The native pinned stepper recorded 36 dropped **requests**, retried under its existing three-frame loss protocol; no verified step was missing. This preserves the frozen stepper behavior, including its retry accounting.
- Draw inspection: native bounds span approximately 96,029.5 studs. Raw 1.5-stud nodes are too small to read in that overview. Temporary enlarged, body-adorned markers made all eight native lane pairs visible from camera (-31000,2500,3328) looking at (-144.25,1280,3328); capture `SpringLaneProbe8_MarkerOverview`. These temporary markers include two metronome markers that will be removed with the probe; production display excludes metronomes.
- User correction: “why is it spanning that way, I thought it was gonna infront of each other not to the side”. The original description incorrectly called Z “depth”; native grids lie in Y–Z, so Z translation is lateral. To preserve native numerical coordinates while correcting the requested presentation, L21 now explicitly specifies an X-stacked translated live view. No trading, fitting, data, warm-up, or native stepping rule changed. The revised hash was appended before any forward run.
- Native display preview: 384 sphere adornments and 680 Beams translated by ((laneIndex-4.5)*800, 0, -nativeLaneOffsetZ), attached to actual bodies through new visual-only attachments. No native BasePart, constraint, force, mass, or original attachment reference was changed. All 384 native body bases had exactly zero rotation error after the probe. Remote body adornments and Beams rendered successfully in the stacked view from (-6500,2500,-1000) looking at (0,1280,3328); capture `SpringLane8_FrontBackPreview`. Production integration and a repeat timed probe are pending.
- Final native probe (attempt 3): final installed driver `94d9e84b7ed70c2826e65927b3cb5d2e9030a37171847e9e97acb89295962ae3`, display `3ee1cf3147b50d86db17e8733573d88d466f0b152da35f6efc9b7baef0b00aad`. Eight lanes, 386 stepped parts, 384 display bodies, 680 Beams. Twenty timed bars took 6.416231800001697 seconds (3.117094366820524 bars/second/lane); 240 verified timed steps, 385 waited frames, 36 cumulative retried dropped requests, zero corrupt steps, zero outside movement/missing parts. The display invariant audit confirmed no physical instances, unchanged original attachment references and runner list, unchanged mount physics, and zero source basis rotation error. Full evidence: `evidence/spring-live-probe8-final-display-20261005.json`.
- Final visual check (attempt 4): recreated the identical retained probe for one timed bar because the previous screenshot was obscured by the legacy App dashboard. No source changes. Twelve timed verified steps, zero corrupt steps and zero isolation movement. After an intermittent blank viewport, the installed front-to-back display rendered successfully; the temporary red anchored visibility diagnostic was removed before probe cleanup. Capture `SpringLane8_AcceptedFrontBackStack` records the accepted view. The camera remains free; no following/locking loop exists.
- Native probe / layout inspection / fixed lane choice: complete. **N=8 is fixed before the forward run**, using the final probe above. Native lanes remain Z-spaced by 13,060; translated live display layers are X-spaced by 800. Display mount and removal invariants passed in actual Studio.
- Launch requested: `live_lanes8_1791232619`, controller `CoreGui.RoAlgoSpringLiveControl`, background setup with the default mandatory preflight enabled and no override. Initial phase `data`, running/busy true. Camera framing is disabled for launch (`frame=false`) to preserve the user's freely chosen view.
- Studio preflight: **passed without override**. Rows 1..78: numeric maximum absolute difference 0, independent 0, coupled 1.1920928955078126e-7, against native tolerance 0.002 and numeric tolerance 0. Both module and controller gates passed; allowedToFail=false.
- Native run: running; observed 369 decided lead-in rows with no reported warning/error. `plan.json` and `lanes.json` have been sealed under `results/spring-live/live_lanes8_1791232619/`. The 2025–2026 decision segment begins at 2269; no completed performance claim yet.
- Additional user request during the run: numerical values on the display nodes. A separate read-only display overlay is being prepared; the sealed computational/display modules above will not be replaced or edited during this attempt. Values will read native X displacement from the pinned zero-X rest coordinate.
- Numeric node overlay: installed during the active run at approximately decided row 3,299, outside the sealed source tree at `ServerStorage.RoAlgoSpringDisplayExtras.SpringLaneReadouts`. Source `src/SpringLaneReadouts.luau`, SHA-256 `9b21134c7f6e4cd6bd66b1ce7b831d910d350b9b116d3fc8b6086158f74c75bb`. All 384 nodes display signed native X displacement from zero-X rest in studs, to three decimal places, at 10 Hz. It reuses the existing translated display attachments, reads body positions, and writes only label text; it never writes native physical properties. Compilation, six formatting checks, independent review, runtime status, and a Studio screenshot confirmed it working. Camera remains free.
- Full feature pass: all 36,402 bars / 469 sessions computed inside Studio in 3.8182439000011072 seconds. Digest matches the offline test reference exactly: `sfp1-hex:36402:8b1dffdb7cf50c5280e454969d511fd377b775edb1da9b34b78ce4e2a764c787`. The offline digest supplied a check, not production features.
- L20 lead-in reproducibility: completed all 2,268 rows with no missing/invalid rows or index/reset/timestamp mismatch and exact drive inputs. Overall status **differs**: numeric maximum absolute state difference 1.1774000388542483e-6 exceeds the strict zero tolerance; coupled 1.0097728055935562e-6 and independent 2.962350845336914e-5 are within native tolerance 0.002. First numeric exceedance at row 391. Detailed decision rows differ on 659 of 2,268 rows, but **zero rows have a different action or ledger**. This is a small state/readout difference under block warm-up, not a bit-exact reproduction; disclose alongside final results. No retuning or capture restart was performed. Full evidence: `evidence/spring-live-leadin-reproducibility-20261005.json`.
- Continuation snapshot at about 2026-10-05 13:44 local (20:44 UTC): run `live_lanes8_1791232619` remains running/busy, 6,377 decided bars and 16 sealed chunks, no returned error/warning. Node overlay has 384 labels and 1,402 refresh samples. Chunk 0016 covers rows 5,779..6,168; isolation check passed (zero movement/missing parts), zero corrupt steps, zero step/barrier failures, zero off-axis or saturation observations. Retried dropped requests are recorded by the frozen stepper (1,605 at this chunk) and must remain in final accounting. Forward performance remains incomplete; no edge or P&L conclusion yet.

## Continue without disturbing the active run

Use Roblox MCP in RoAlgo Edit mode, Studio `<studio-instance>`, the RoAlgo place. Read `game.CoreGui.RoAlgoSpringLiveControl:Invoke("status")` and `:Invoke("reproducibility")`. Numeric overlay status is `game.CoreGui.RoAlgoSpringReadoutControl:Invoke("status")`; its `destroy` action removes labels only. Do not reinstall or mutate sealed modules, start Play, stop/restart the data server, move native rigs, or call `stop` just to inspect. The user's camera is free and should stay where they put it.

Results are write-once files under `results/spring-live/live_lanes8_1791232619/`; the completion manifest is still pending at the snapshot above. After completion, report all seven variants and the frozen coupled-positive-after-costs-and-better-than-EMA criterion, plus coupled-versus-zero action differences and the L20 disclosure. Do not infer final performance from partial data. Terminal `release` is the supported cleanup action; never delete an active capture container manually.

## Completion — 2026-10-05 14:17:41 PDT

**Run complete.** All 36,402 rows are decided and saved in 94 chunks, with zero unsaved rows. The final manifest ended at 2026-10-05T21:17:41.465Z after 2,442.27 seconds (40 minutes 42 seconds). Studio status independently reports `phase=complete`, `running=false`, `busy=false`, and zero UI errors. Producer/stepping have stopped, shutdown is joined, and the rigs remain retained. The two-minute monitoring heartbeat was paused after completion; no geometry cleanup or replay was started.

Byte verification checked every manifest-listed chunk SHA-256, the plan-file SHA-256, sequence/run identity, contiguous row ranges, per-chunk row counts, and final chain hash. All checks passed. Manifest SHA-256: `d2210c5b218c227d5b4854dc79484480149fc78813b162d100c44edb78e5f4d2`. Chunks total 158,655,861 bytes. Evidence: `evidence/spring-live-final-verification-20261005.json`.

Native execution completed exactly 436,824 decided-row steps. Shared stepping: 5,616 global bars, 67,392 verified steps; 77,019 requests minus 9,627 retried drops equals 67,392. There were zero corrupt steps, step failures, barrier failures, or delayed completions. All 97 isolation checks across 50 protected parts found zero movement or missing parts. Maximum displacement 114.73822021484375 studs; zero off-axis or saturation observations. An independent read-only audit reconciled every lane's completed blocks and the decided/warm-up/idle counts. Monitored Studio CPU samples were about 4.7–8.3% of total 24-logical-processor capacity and resident memory about 2.2–2.6 GiB. An isolated frame hitch did not persist in the next timing sample; no sustained overload or native corruption was observed.

### Frozen forward-test result

The 34,134 forward rows follow the 2,268-row lead-in. These are simulated outcomes under the predeclared execution/cost model, not broker trades.

| Variant | Net return after costs | Completed trades |
|---|---:|---:|
| Coupled native | -56.0863% | 1,588 |
| Independent native | -57.4481% | 1,648 |
| Numerical springs | -54.1102% | 1,582 |
| EMA baseline | -67.0882% | 2,179 |
| Zero state | 0% | 0 |
| Frozen state | 0% | 0 |
| No trade | 0% | 0 |

**The predeclared edge criterion failed:** coupled beat EMA but did not beat no-trade or achieve a positive return. Coupled maximum drawdown was 56.3817%. Physics dependence was verified on historical inputs: 1,968 coupled physics actions versus zero for the zero-state input, 1,968 intent/emitted-action differences, and 2,074 final differences over 34,134 forward rows. That establishes dependence of decisions on measured state; it does not establish predictive value or a useful trading edge.

**L20 disclosure:** lead-in reproduction still reports `differs`/`pass=false`; 659 of 2,268 detailed rows differ from the original continuous capture, with zero action/ledger differences. Native state differences are within tolerance; the strict zero numeric tolerance failed at row 391. This is separate from the clean native execution and successful file integrity checks. The manifest criterion's generic note says interim, but the manifest status, final row counts, closed file chain, and stopped producer establish that this attempt is complete.

The existing replay path uses exact archived bar-end state vectors and does not rerun native physics. It requires this final manifest. The current viewer shows one selected 24-node variant; smooth transitions or an eight-layer replay are additional presentation work. Intermediate substeps, warm-up/idle motion, and wall-clock lane animation are not recorded.

## User-requested playback opened

After completion, the owner requested a replay with a Play button. Reused the completed in-memory recorded session through its existing controller; no cold reload or state regeneration was needed. Invoked the supported terminal `release` to remove the native capture rigs and translated display; recorded rows and replay UI remain available. The sidecar readout cleanup follows display destruction. Selected coupled versus zero, sought to row 2,269 (forward-test start), and left the viewer paused at six rows per second. Reframed the camera once from the replay model's saved view/focus attributes; no camera-follow loop.

Verification: Play advanced the cursor to 2,274 and updated the rendered row, then Pause and seek restored 2,269. The Play button is visible/enabled, UI errors remain zero, all replay parts are anchored, native lane container is absent, and physics running is false. Screenshot capture `SpringReplay_Paused_PlayReady_20261005`. Controller phase remains `complete` while its controls replay recorded rows; this is expected for the reused in-memory session.

## Array replay correction

The owner asked where the array was: the single-cluster viewer did not preserve the expected eight-layer layout. Added three unsealed sidecar modules and installed them under `ServerStorage.RoAlgoSpringArrayReplayExtras`, without changing captured data, calibration, native sources, or results. Eleven protected source pins were rechecked and unchanged.

- `src/SpringArrayReplayData.luau` SHA-256 `ce4ed4b1a64e00431f7a67dabf71025ac108b443d15b6ac1c11637b194dbac02`: validated schedule mapping and exact recorded vectors in29,704,032bytes of packed buffers.
- `src/SpringArrayReplayView.luau` SHA-256 `cf574aa5498a9f80430129bd77b4d8f436ff2a4f61f000b92f8a28dc7d8aea75`: eight layers800studs apart onX, each paired coupled/independent grid;384nodes,680Beams,392anchorednoncollidingParts,384numericreadouts.
- `src/SpringArrayReplay.luau` SHA-256 `f4b1e2520448b674cc3e379835ca539a3aebe56e2312857b377c5f3b97607a57`: hash-checked archive loading and separate Play/Pause/Prev/Next/Restart/speed/timeline controls. No simulation or decision regeneration.

New control: `CoreGui.RoAlgoSpringArrayReplayControl`; commands `status`, `play`, `pause`, `seek` (schedule tick), `rate` (ticks/second), `frame` (one-time), and `exit`. The array was left paused at tick 79, the first tick where all eight lanes have recorded states. The timeline spans **5,616 reconstructed schedule ticks**; it is not recorded wall-clock animation. Every lane displays its own block/time. Warm-up and idle motion was not archived and is displayed at dim rest with explicit captions/unknown readouts. No interpolated motion is presented as capture evidence.

The previous single-cluster viewer is paused and reversibly hidden; Close restores it. `Open-SpringArrayReplay-In-Studio.luau` opens the array for later use. No other project's Studio or protected research model was changed. Camera framing happened once; user camera movement stays free.

Verification: Data9tests, renderer5behaviorchecks, compilation of all3modules, and independent integration review passed. All94chunks loaded, covering36,402rows; every GET enforced its manifest/receipt SHA-256, with continuous chain/range verification. Studio counted384nodeParts,384readouts,680Beams,392anchoredParts, zero constraints and zero unanchoredParts. Play advanced tick435→483 and moved288nodes (other lanes were in unrecorded phases); Pause/seek restored79. No UI errors, native capture absent, native runningfalse. Two-second playback frame sample: mean16.6687ms (~60FPS), p9518.2471ms, max31.2963ms. Capture `SpringArrayReplay_EightLayers_Paused` confirms the array and labels visible. Follow-up checks should use the new array controller rather than the old single-cluster control.
