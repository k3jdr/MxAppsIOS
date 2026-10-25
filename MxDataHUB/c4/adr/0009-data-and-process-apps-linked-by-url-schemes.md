# ADR-0009: Data (MxDataHUB) and processes (MxJobsMGR) are separate apps linked by URL schemes

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB, MxJobsMGR, Shared/AppLinks.swift

## Context

The security master screens originally lived in MxDataSQL (a general PostgreSQL utility). Workflow design and
execution — scheduling, approvals, agents, Layer 3 calls — is a different job with a different document model
(jobspace files) and different users' moments (operations vs analysis).

## Decision

Split responsibilities: **MxDataHUB keeps the data** (securities, benchmarks, portfolios, data freshness);
**MxJobsMGR runs the processes** (repeatable, scheduled, approved workflows). Link them with **URL schemes**
defined once in `Shared/AppLinks.swift`:

- `mxjobsmgr://sample/<id>?portfolio=CODE&benchmark=CODE` — Portfolios ▸ Workflows (Optimize, Track, Attribution),
  Benchmarks ▸ Track…, Data Refresh ▸ Automate in MxJobsMGR…, Services & Workflows ▸ Open in MxJobsMGR.
- `mxdatahub://portfolio/<CODE>`, `benchmark/<CODE>`, `data-refresh`, `services` — MxJobsMGR ▸ Window ▸ Open MxDataHUB.

## Consequences

- Each app stays focused; each can be used alone.
- Hand-offs carry only identifiers (codes); each app reads current data itself, so nothing goes stale in transit.
- Both apps must be installed for hand-offs; the app reports "MxJobsMGR is not installed in Applications" otherwise.
- The URL format is a contract between the apps: change it in `AppLinks.swift` and release both together.

## Evidence

`Shared/AppLinks.swift`, `ContentView.swift` (`onOpenURL`), `ServicesWorkflowsView.swift`, `Info.plist` (`CFBundleURLSchemes`), commit `8f94edd` (shared Layer 3 services and hand-offs).
