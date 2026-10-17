# ADR-0017: In-app documentation through a shared Quick Help panel

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxJobsWMS (also MxDataHUB, MxDataSQL, MxFileMGR, MxNoteONE)

## Context

The editor has many specialised parts (three lanes, handles, breakpoints, run modes, value checks, auth styles).

## Decision

Use the shared **Quick Help** panel, docked at the bottom of the palette or floating (⌥⌘/), fed by
`JobsQuickHelp.swift`: what is under the pointer (a palette step or service, a step and its last run and problems,
a handle, a lane, run-bar controls, console, approvals waiting, inspector sections, subscription fields), then the
selection, then the jobspace. The floating panel follows the Layer 3 Services, New from Sample and Adding API Keys
windows.

## Consequences

- Help stays next to the code; consistent across the repository's apps.

## Evidence

`JobsQuickHelp.swift`, `ContentView.swift` (`quickHelpDock`), `Shared/QuickHelp/QuickHelp.swift`.
