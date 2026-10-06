# Spring filming telemetry and eased display — 2026-10-05

This update supersedes the control/label portions of spring-filming-presentation-20261005.md.

- Only Run/Pause and layer selection remain in the right panel. Replay toggle, previous/next, timeline and speed selection are removed from the visible panel.
- The filming clock is fixed at six schedule ticks per second; the rate command rejects other values.
- S&P 500 · SPY · 2025–2026 TEST DATA is prominent, with readable historical dates.
- CONFIDENCE preserves the original signed signal index; it is labeled as a signal index, not a probability.
- Contribution/policy/action/fill/evidence/comparison text is replaced by telemetry for coupled and independent spring states: displaced-node count (explicit >1-stud threshold), signed mean/RMS/peak x, speeds, bank means, coupling stretch and coupled-versus-independent displacement difference.
- Physical displacement is D*x; speed is abs(D*omega_i*v_i). Coupling stretch uses endpoint distance minus the configured free length, including prestretch. No force or CPU-load figures are invented.
- New SpringPresentationMotion eases all three anchored displays between saved endpoints over one-sixth second. Seeks, lane switches, gaps and block transitions snap. Pausing finishes the current endpoint. It does not alter saved states, signal computation or chart decisions.
- Numeric telemetry changes at the endpoint observation; geometry eases toward it over up to167ms.

Validation: seven presentation and seven motion test groups passed; changed sources and launcher compiled. In Studio, all456 movable nodes were under the smoother, and a tracked node moved on349 of361 sampled Heartbeats over six seconds. Mean frame time16.666ms, p95 25.848ms, maximum29.396ms. Both UI error counters zero, only Run and Layer buttons visible, no clipped telemetry labels, chart/panel/selected layer all row2346. Paused geometry matched reported mean/RMS displacement within0.000011studs and active count exactly. Original viewer's independent clock remained paused.

Evidence: evidence/spring-telemetry-filming-20261005.json. Sealed run files and scientific modules remain unchanged. Original protected research rig remains parked while its inert visual copy is displayed, and is restored on exit.
