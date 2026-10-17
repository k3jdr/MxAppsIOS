# ADR-0012: In-app documentation through a shared Quick Help panel

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB (also MxJobsWMS, MxDataSQL, MxFileMGR, MxNoteONE)

## Context

The screens are dense and domain-specific (identifier types, proxy benchmarks, freshness states, snapshots).
Tooltips are too short and a separate manual goes out of date.

## Decision

Use the shared **Quick Help** panel (`Shared/QuickHelp`), docked at the bottom of the sidebar or floating
(View ▸ Quick Help ⌥⌘/). Views declare what they are with `.quickHelp(title, detail, shortcut:)`,
`.quickHelpArea(item)` and `.quickHelpScreen(name, item, selection:)`; `HubQuickHelp.swift` holds the app's text,
including why a screen is empty (not connected, no `srm` schema).

## Consequences

- Help is next to the code it describes and is reviewed with it.
- Consistent behaviour across the repository's apps; one implementation to maintain.
- Text must be kept accurate as screens change (it is code, so code review catches it).

## Evidence

`HubQuickHelp.swift`, `ContentView.swift` (`quickHelpDock`, `quickHelpScreen`), `Shared/QuickHelp/QuickHelp.swift`.
