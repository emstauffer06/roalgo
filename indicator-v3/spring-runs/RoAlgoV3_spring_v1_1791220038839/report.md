# Spring indicator run RoAlgoV3_spring_v1_1791220038839

Protocol `spring-consensus-v1`. Status: **complete**. Created 2026-10-05T17:07:24.931Z.
This run executed **zero new native steps** (newNativeSteps = 0); it read previously captured v2 states only.

> Placeholder report written by the runner. Phase 2 (SpringStudy) extends it with paired comparisons,
> setup/action counts, risk/cost breakdowns and the evidence verdict. Market evidence: development only, no fresh holdout.

## Result files (write-once)

Single file; logical sha256 `56dd3aec0acfadb4f2c246d4ab28fa826511f2519ead0405eeb92ce06b3f8713`.

| File | Bytes | SHA-256 |
|---|---:|---|
| RoAlgoV3_spring_v1_1791220038839.json | 8871677 | `3fdcd3b57e0b9224117169c24a23ee8724efbfc968b7811f06a682f2bd0a5d6d` |

## Verified inputs (unchanged before and after writing)

| Input | Bytes | SHA-256 |
|---|---:|---|
| RoAlgoV2_SPY_1791205420530.json | 27497819 | `bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828` |
| RoAlgoV2_SPY_1791205420530_states_0001.json | 16841444 | `d75e3a65a34750e2e54bf394a6d3ac5c1eae63810a1724e911bac2b80640b74a` |
| RoAlgoV2_SPY_1791205420530_states_0002.json | 16840676 | `7ef24f376cdc10d6784ade62d2a61e104d7f063d85a631aa61d9f8a34f4a69f5` |
| RoAlgoV2_SPY_1791205420530_states_0003.json | 16852473 | `55c352c0a752ce6c58713030463c3543a557e7a4d62f4d8ee4e472a5d932cab0` |
| RoAlgoV2_SPY_1791205420530_states_0004.json | 16824329 | `b79751d37ba5c6cc193983437e4e63c2b155cfcf4f910386042a50a7235b7ca3` |
| RoAlgoV2_SPY_1791205420530_states_0005.json | 7255854 | `109aab90b951a60623db3c683dff06dba0e1a293dd2954d420fe1db243bdfa76` |
| RoAlgoV2_SPY_1791205420530_source.json | 122578 | `ecbee1e2e639acd7e9b51d0b81a0d9541e24cc1ec23fdc4e033a2860a16dee58` |

Capture source recorded from manifest.sourceHashes (D15); on-disk indicator-v2 src is not hashed as capture source.

## Luau modules executed

| Module | SHA-256 |
|---|---|
| src/Execution.luau | `24d03c162bfd4a3c9e3e39ce0178a08af74d4b30212930f737ce9acf3ff6ffc3` |
| src/SpringPolicy.luau | `4dc7adcdee61c3321ae931732173a171457f9c97c0e83dc024e8d51c9a1d3119` |
| src/SpringSignals.luau | `2d6c65a6d32e3eac4b3bdaa9a7cd6bc02640d409b49805712d44d9bcd356426c` |
| src/SpringState.luau | `bf7cd0a8b76f3bf36836b91cda735fa6a0632bcee90f37095b2c2956973602e0` |
| src/SpringStudy.luau | `38aa94db338dccd8c3eb973ebb187c94259b04fa9345bc568267d61835d87654` |

Luau 0.741 (`bbf4bec2470efbb722afaa2803b5ffc47fbf9bc84653c807e176f8b5dc3891ec`), interpreted; no --codegen flags (D19), default optimisation as in the spec runs.
Data modules: 36 (11770681 bytes); minimised records sha256 `9d5b94f3a9879880a235a8947f7613df0f40a136979a8595f501c650745e0c2a`.
Omitted fields: bar contexts, minute, n, v, vwap; feature contextMissing, drive, names, raw, regime, t; state banks, energy, nodes.
