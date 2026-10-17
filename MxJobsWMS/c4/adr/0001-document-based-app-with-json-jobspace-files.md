# ADR-0001: A document-based app with JSON jobspace files

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxJobsWMS.app, *.jobspace

## Context

A workflow is something people version, share, review and copy between desks — like source code. Several workflows
are open at once (refresh, optimization, attribution). The definition must survive app upgrades.

## Decision

Make MxJobsWMS a **SwiftUI `DocumentGroup` app**: one window per **jobspace** file, `*.jobspace`, UTType
`com.k3jdr.mxjobswms.jobspace` conforming to JSON. The file is **pretty-printed JSON with sorted keys**,
`format: "mxjobspace"`, `formatVersion: 1`, holding subscriptions, nodes, links and run settings. **Decoding is
tolerant**: every property has a default when missing and links to unknown nodes are dropped; plain `.json` files
holding a jobspace open too.

## Consequences

- Standard File menu (New, Open, Open Recent, Save, Save As, Duplicate, Rename, Revert) and versions for free.
- Files diff cleanly in git (sorted keys, pretty printing) and can be shared — they contain no keys ([ADR-0004](0004-api-keys-in-keychain-never-in-jobspace.md)).
- New fields need defaults; a breaking format change would bump `formatVersion` and add a migration.
- Run results are not saved in the file (they live in the window's run engine).

## Evidence

`JobspaceDocument.swift`, `JobspaceModel.swift` (`init(from:)` with defaults), `Info.plist` (document type, exported UTType).
