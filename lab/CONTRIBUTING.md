# Lab implementation rules (read before editing anything under lab/ or tools/)

The authoritative design is docs/superpowers/plans/2026-10-04-roblox-physics-market-forecast.md (the plan).
Formulas, orders, dimensions, masks, split boundaries, exclusion reasons and budgets come from it verbatim.
When the plan and this file disagree on a numerical or protocol matter, the plan wins; this file records
how the code is organised.

## Layout

```text
lab/config/default.json     experiment settings (single source of truth)
lab/generated/              files written by Node generators; never hand-edit
lab/src/Types.luau          shared contracts (integration owner only)
lab/src/Config.luau         validated config (reads ../generated/ConfigData)
lab/src/Data/ Model/ Experiment/ Util/     pure Luau, shared by the CLI and Studio
lab/src/Physics/ UI/ Studio/ Main.server.luau   engine code (Studio only)
lab/cli/                    CLI-only orchestration (loads data via generated source loaders)
lab/tests/Test.luau         harness; lab/tests/Specs.luau registry; RunPure.luau CLI entry
lab/fixtures/               fixture modules (.luau) used by specs
tools/*.mjs                 Node generators, packaging, validation (Node 24, no npm packages)
```

## Pure-module rules

- No engine globals: game, script, workspace, Instance, Vector3, CFrame, Random, task, tick, os.time, os.date,
  HttpService. os.clock is allowed only for timing diagnostics.
- Require with relative require-by-string only: `require("./Sibling")`, `require("../Model/Ridge")`.
  The same tree is mirrored into Studio ModuleScripts, where these paths resolve identically. Use string
  literals in require calls.
- Randomness is injected: accept a Prng (Types.Prng) or a numeric matrix; never construct Random.
- Raise errors as `error("ModuleName: reason", 2)`. A failure is never converted into a numeric zero forecast.
- Use double-precision numbers. Do not round. Reject NaN/Inf where the plan says inputs must be finite.
- Freeze or copy anything stored from a caller (ledgers, models) so later caller mutation cannot change it.

## Tests

- Luau CLI: `luau lab/tests/RunPure.luau -a <SpecName>` (run from the
  project root). No filter runs every registered spec. Add `--codegen -O2` for speed on large data.
- Write the failing test first, observe the failure, then implement (the plan asks for this).
- Specs return a suite built with `Test.suite`/`Test.case` (see lab/tests/Harness.spec.luau).
- Node: `node --test tools/<name>.test.mjs`. The pre-existing suite at the project root must keep passing:
  `node --test download.test.mjs export-data.test.mjs download-supplement.test.mjs supplement-export.test.mjs prepare-supplement.test.mjs audit-supplement.test.mjs`
- Optional static check: `luau-analyze <files>`.

## Boundaries

- Never modify anything under data/, the existing root *.mjs collectors/exporters, README.md, SUPPLEMENT.md,
  or a separate MarkovJunior Luau port (not included). Never read, print or copy credential files; no network calls.
- Do not touch Roblox Studio (one integration owner drives it). Do not initialise Git.
- Only edit the files your task names. Other agents are working in this tree at the same time; preserve
  their changes and do not reformat files you do not own.
- Final-period outcomes are sealed: structural timestamp counts are allowed, but never compute or print
  target returns, errors or any performance figure for data on/after 2025-01-01T05:00:00Z (or for validation
  data), except on synthetic fixtures.
