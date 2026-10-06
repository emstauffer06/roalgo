# v3 physics and causal-feature implementation evidence

Local implementation verified 2026-10-05. Native validation is pending root-owned Roblox Studio execution; numerical measurements below are not native physics results.

The exact drive order is trend, immediateReturn, rangeActivity, volume, qqqMinusSpy, iwmMinusSpy, tltReturn, xlkMinusSpy, xlfMinusSpy, xleMinusSpy, targetDailyReturn, regimeStress. Relative hourly inputs require both completed legs covering exactly the same hourly interval. Hourly context is unavailable when later than the decision end, prematurely available before its hour completes, or more than 7,200 seconds old. Daily context requires a prior day. The ETF volume channel refers to the observed ETF only.

The original 33 raw coordinates retain their order; three sector returns, five relative returns, three sector-missing flags and five relative-missing flags produce 49 raw coordinates. The 48 memory coordinates are lag1, lag3, EWMA alpha .5, EWMA alpha .05 for each normalized drive, in drive order. EWMAs include the current completed observation; lags contain prior observations only. Memory starts at zero and resets with an intraday gap; overnight carry is retained.

Configurations accept 24/48 nodes, grouped/grid topology and diverse/balanced response. Configuration IDs include all three options, for example grouped48-diverse. Each of three response banks contains four financial groups and two/four replicas per group. Fixed signed projections have L1 norm 1 and identify their dominant +.72 coefficient. Remaining coefficients are signed .12/.08/.08. Group labels describe actual projected inputs. Spring coefficients remain nonnegative; a graph connection is an experimental passive coupling, not a claim about permanent market-correlation sign. Grouped graphs connect representatives between adjacent financial groups; grids connect adjacent columns. Both include adjacent-bank links.

The dynamic state schema is N normalized positions, N normalized velocities, three bank energies (Fast, Medium, Slow), then xMean/vMean for Tape, EquityRelative, SectorBond, ParticipationRegime: 59 coordinates at 24 nodes and 107 at 48. Names are stored with every state. Native x/v are measured from Roblox bodies; bank energies, group means and node forces are derived from those readings and fixed physical coefficients. Numerical x/v explicitly identify the RK4 comparator as their origin.

All geometry remains full size: 256-stud spacing, 64-stud displacement normalization, 224-stud rails, 512-stud axial anchors. Both native rigs use the same cached rest geometry and measured mass. Node count drives readout indices, reset arrays, drive arrays, inventories and numerical integration. The camera distance and center use configured bounds. Floating node labels show bank, group and dominant mixed input, with complete fixed signed projections in attributes; MaxDistance=0 and opaque text/card settings preserve non-fading labels. No motion-writing capture path was added.

## Local verification

Meaningful red tests were observed before feature/mechanics production edits: the new feature test failed on the old 33/8 schema, and the mechanics test failed because the old projector rejected twelve inputs. Both then passed against the new implementation.

Commands run from indicator-v3 with Luau 0.741:

- `luau tests/Features.spec.luau`: PASS; 49 raw, 12 drives, 48 memory, signs, missing legs, hourly stale/future timestamps, lag1/lag3, matching hourly intervals, gap reset and previous daily/HMM causality cases.
- `luau tests/Mechanics.spec.luau`: PASS; passive force formula and damping, zero equilibrium, direction, bank timescales, disconnected control, exact reset replay, sign symmetry, boundedness, release, finite validation, all eight architecture combinations, signed fixed projections, graph endpoints/rest geometry, dynamic names. Sustained 48-node repeatability and release cover 420 bars/5,040 numerical intervals.
- `luau tests/MechanicsMetrics.luau`: PASS; default 24-node numerical first-bar coupling difference 0.010234040027785274; maximum normalized position after 1,001 held bars 1.1026141278821655; release energy ratio after 120 zero-drive bars 1.5283773452013838e-18; 37 edges. Coupled scale residual 0.004897157132592145 versus independent 0 for the declared amplitude check.
- `luau-compile --null src/Features.luau src/Mechanics.luau src/Engine.luau src/PhysicsView.luau tests/Features.spec.luau tests/Mechanics.spec.luau tests/EngineProbe.luau tests/LayoutProbe.luau tests/MechanicsMetrics.luau`: PASS.

VerifiedStepper remains byte-identical to v2 (SHA256 checked locally). The pre-existing comment describing 48 values was intentionally left untouched; actual runner interfaces consume rig-provided arrays generically.

## Native work outstanding

Root should run `EngineProbe.run(workspace,{nodeCount=24})` and independently `{nodeCount=48}` in Studio Edit mode. Each performs exactly 12 bars / 144 expected verified intervals, covering equilibrium, positive direction, response order, disconnected control, reset replay, release, schema agreement, native/numerical deviation, all world-X rails, non-saturation, an unrelated unstepped sentinel, exact inventories and cleanup. Expected moving bodies including metronomes: 50 and 98. Expected coupling spring counts: 37 and 77. Probe reports native failure instead of substituting numerical state.

`LayoutProbe.run(workspace,{nodeCount=24|48})` additionally compares full-size wide/showcase geometry and 6 bars per layout, with a midpoint reset. The native display and complete end-to-end study are root-owned verification. No native pass, market advantage, 48-node advantage or untouched holdout is claimed by this report.

