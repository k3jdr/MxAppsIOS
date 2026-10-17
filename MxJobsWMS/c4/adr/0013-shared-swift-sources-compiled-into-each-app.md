# ADR-0013: Shared Swift sources are compiled into each app

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxJobsWMS, MxDataHUB (and MxDataSQL, MxFileMGR for Quick Help)

*Shared decision; also recorded as [MxDataHUB ADR-0010](../../../MxDataHUB/c4/adr/0010-shared-swift-sources-compiled-into-each-app.md).*

## Context

Both apps show the same services, samples and Quick Help, and must agree on the hand-off URLs.

## Decision

Keep shared code in `MXcodeIDE/Shared` (`AppLinks.swift`, `ServiceCatalog.swift`, `ServicesView.swift`,
`QuickHelp/`) and compile it into each app through a **file-system synchronized group**, not a package or framework.
Shared views take closures for app-specific behaviour (e.g. MxJobsWMS passes *Add Step* into `ServicesView`).

## Consequences

- One source of truth without versioning overhead; release the apps that use a changed file together.

## Evidence

`MxJobsWMS.xcodeproj/project.pbxproj`, `MxJobsWMSApp.swift` (`ServicesView(serviceActions:…)`).
