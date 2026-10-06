# StepPhysics capability findings (Task 3 gate), measured 2026-10-05

Studio 0.741.19.7411056, Windows 11, RoAlgo (a private Team Create place) and a local .rbxlx place.
All numbers below were measured in this workspace; evidence code is `lab/src/Studio/StepStudy.luau` and
`lab/src/Studio/SteppingProbe.luau`.

## What the plan assumed

The plan (section 4) assumed `workspace:StepPhysics(1/60, parts)` advances the simulation synchronously, so
twelve calls complete twelve steps before the readout.

## What the engine does here

| Observation | Evidence |
|---|---|
| A call returns before anything moves; the step is applied on a later frame. | 12 back-to-back calls: 0 steps visible immediately, in MCP, plugin-load and plugin-request contexts, in Team Create and in a local file. |
| Bursts lose steps. | Bursts of 5/12/24 calls completed 4/11/21.5 steps. |
| About one request in eight is dropped, never applied late. | One call per frame for 200 frames: zero-increment frames at 5, 13, 21, ... (every 8th); 176 of 200 completed; nothing arrived after stopping. |
| A burst leaves queued time that can surface later as a fractional step. | A 12-call burst followed by single calls produced a 1.5-dt step. |
| A fast free-falling part gets fractional increments from adaptive timestepping. | 1-stud part: 1.5 dt at ~50 studs/s, 1.25 dt at ~146 and ~199 studs/s, identical with or without other bodies; 0.5-stud part: already at ~36 studs/s; none when the part is re-launched every 12 steps. |
| `WorldModel:StepPhysics` does not move parts in a WorldModel under Workspace. | 12 calls, 30 frames: no motion. A WorldModel parented to CoreGui and stepped from MCP context coincided with a Studio crash (once); not retried. |
| Background (unfocused) Studio windows run Heartbeat at ~7-12 Hz; a foreground window at ~48-72 Hz. | Heartbeat counts over 3 s. |

## Protocol adopted (ExplicitRunner, verified deferred stepping)

- Two 8-stud free-falling metronome parts ride in every `StepPhysics(1/60, parts)` call with all moving
  reservoir parts. Their velocity change measures exactly how many dt-steps the engine applied.
- Exactly one request is outstanding. The next is issued only after both metronomes show exactly +1 step.
- A request with no increment one frame later was dropped and is re-issued (late arrivals were never seen;
  one would show as a +2 increment and be caught).
- Metronomes are re-launched every 12 completed steps (max ~39 studs/s), far from the adaptive-rate regime.
- Any non-unit or disagreeing increment raises `CORRUPT_STEP`; `PhysicsJob` replays the whole segment from its
  reset. Batches contain whole segments only, so no exported state is ever replaced.
- Never burst; never call StepPhysics outside this protocol in the lab place.

This keeps every plan invariant: Roblox's native solver integrates every step, dt = 1/60 exactly, 12 completed
steps per observation, 60 settle steps per segment, all moving parts in every call. The deviation is only that
steps are applied one per frame and confirmed, instead of synchronously.

## Measured with the adopted protocol (plugin context, RoAlgo)

- 600/600 and 600/600 confirmed steps exactly one dt on both metronomes (two runs), 0 disagreements.
- Probe: 24-node reservoir, 200 bars + 40 repeat bars: 3,120 steps, 3,566 requests (446 dropped and re-issued),
  0 corrupt steps, 4.05 bars/s including resets (~63 steps/s at ~72 frames/s).
- Soft reset then the same 20 inputs: maximum absolute state difference 0 (bit-identical).
- One-node probe: driven X 0.859 after 60 steps (static target 0.6, zeta 0.25 overshoot), off-axis drift 0,
  energy proxy 3.97 -> 0.0125 over 10 s free decay. Two-node probe: undriven neighbour moved 0.036 studs.
- Studio Physics.spec: 4/4 passed in the plugin context.

## Limits that remain

- Adaptive timestepping may integrate different assemblies at different internal rates; the metronomes prove
  the request applied one dt, not the internal sub-step schedule of each reservoir assembly. Repeatability
  and rebuild comparisons (Task 3) bound the consequence empirically.
- Throughput depends on Studio's frame rate; keep the lab window in the foreground during long runs.
