# ADR-0007: Per-layer run modes for rehearsal and debugging

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Run settings, run engine, run bar

## Context

Designers need to try a workflow without services running, without network, without approvals, or one layer at a
time; operators need to step through and inspect.

## Decision

Save **run settings in the jobspace**: Layer 1 *Interactive / Auto-approve / Skip*; Layer 2 *Run / Skip*; Layer 3
*Live / Mock / Skip*; breakpoints on or off; stop on error; delay between steps. A skipped step passes its inputs
through. **Mock** generates data that passes the step's checks without network or Python. Debugging: breakpoints
(⌘\), **Step** (F6), **Pause**, **Continue** (⌃⌘Y), **Stop** (⌘.), run console with log and step outputs.

## Consequences

- Samples open safely (SRM Daily Refresh and the template on Mock; portfolio samples on Live with services).
- Mocks prove wiring, not data quality; a Live run is still needed.
- Run settings travel with the file, so a shared jobspace opens in the mode its author intended.

## Evidence

`JobspaceModel.swift` (`RunSettings`, `OperationsAction`, `AgentsAction`, `DataAction`), `RunEngine.swift` (`mockOutput`, `skipReason`, `checkpoint`), `RunViews.swift`.
