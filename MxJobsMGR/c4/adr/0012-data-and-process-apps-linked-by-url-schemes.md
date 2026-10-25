# ADR-0012: Data (MxDataHUB) and processes (MxJobsMGR) are separate apps linked by URL schemes

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxJobsMGR, MxDataHUB, Shared/AppLinks.swift

*Shared decision; also recorded as [MxDataHUB ADR-0009](../../../MxDataHUB/c4/adr/0009-data-and-process-apps-linked-by-url-schemes.md).*

## Context

The security master (MxDataHUB) and the workflows over it (MxJobsMGR) have different users' moments and document
models. Users still need to go from a portfolio to its workflows and back.

## Decision

Keep them as **separate apps** and hand off with **URL schemes** defined in `Shared/AppLinks.swift`:
`mxjobsmgr://sample/<id>?portfolio=CODE&benchmark=CODE` opens a new jobspace from a sample, set to that portfolio
and benchmark (`AppDelegate.application(_:open:)` → `PendingSample.open`); **Window ▸ Open MxDataHUB** opens
`mxdatahub://data-refresh` (also `portfolio/<CODE>`, `benchmark/<CODE>`, `services`).

## Consequences

- Each app is usable alone; links carry only codes, so each app reads current data itself.
- The URL format is a contract: change it in one place and release both apps together.
- If MxDataHUB is not installed, Open MxDataHUB opens its GitHub page instead.

## Evidence

`Shared/AppLinks.swift`, `SampleLibrary.swift`, `MxJobsMGRApp.swift`, `Info.plist` (`CFBundleURLSchemes`).
