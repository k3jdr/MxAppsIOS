# ADR-0001: A native macOS app in SwiftUI

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB (and its sibling MxJobsMGR)

## Context

The security master is used by one person or a small desk on Macs, alongside other native tools in the same
repository (MxDataSQL, MxFileMGR, MxNoteONE, MxJobsMGR). The screens are dense tables, charts and forms over a
PostgreSQL database on the local network. Users expect keyboard shortcuts, menus, multiple windows from the other
apps, Keychain integration and URL-scheme hand-offs between apps.

## Decision

Build MxDataHUB as a **native macOS app in Swift and SwiftUI** (Observation framework, `NavigationSplitView`,
SwiftUI `Table` and Charts), targeting macOS 26.6 with Swift 5 language mode and default `MainActor` isolation.

## Consequences

- Native menus (**Hub** ⌘1–⌘7, ⇧⌘K), Keychain, URL schemes and sandboxing come from the platform.
- One code style across the repository's apps; shared Swift sources compile into each ([ADR-0010](0010-shared-swift-sources-compiled-into-each-app.md)).
- macOS only: no browser or Windows access. Distribution is by signed app bundle, not a web deployment.
- Large result sets are bounded in the UI (search results are truncated; constituents and holdings are per snapshot).

## Alternatives considered

- *Web front end over an API* — would add a server tier for a single-user desktop workload ([ADR-0003](0003-direct-database-access-with-single-statement-changes.md)).
- *Cross-platform toolkit* — loses native table, menu and Keychain integration that the sibling apps already use.

## Evidence

`MxDataHUB/MxDataHUB/MxDataHUBApp.swift`, `ContentView.swift`; build settings `MACOSX_DEPLOYMENT_TARGET = 26.6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
