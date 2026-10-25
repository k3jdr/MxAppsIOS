# Architecture Decision Records — MxDataHUB

Each record states the context, the decision, its consequences and the evidence in the code. They were written
**retrospectively** (2026-10-17) from the implementation, READMEs and git history; *Alternatives considered* lists
the options the design visibly avoids, not minutes of a meeting. New decisions get the next number and the same
template; a superseded record is kept and marked *Superseded by ADR-NNNN*.

| ADR | Decision | Status |
|---|---|---|
| [ADR-0001](0001-native-macos-app-in-swiftui.md) | A native macOS app in SwiftUI | Accepted |
| [ADR-0002](0002-postgresql-srm-schema-as-system-of-record.md) | PostgreSQL schema `srm` is the system of record, with rules in SQL | Accepted |
| [ADR-0003](0003-direct-database-access-with-single-statement-changes.md) | The app talks to PostgreSQL directly, one statement per change | Accepted |
| [ADR-0004](0004-python-loader-cli-with-versioned-migrations.md) | Loading and schema changes live in a Python CLI with versioned migrations | Accepted |
| [ADR-0005](0005-data-refresh-through-local-loader-service.md) | Data Refresh runs through a local loader service | Accepted |
| [ADR-0006](0006-secrets-in-keychain-never-in-repository.md) | Secrets live in the Keychain, environment or untracked config — never in the repository | Accepted |
| [ADR-0007](0007-identifiers-with-validity-ranges-in-the-database.md) | Identifiers are time-ranged and validated in the database | Accepted |
| [ADR-0008](0008-dated-snapshots-for-benchmarks-and-portfolios.md) | Benchmarks and portfolios are kept as dated weight snapshots | Accepted |
| [ADR-0009](0009-data-and-process-apps-linked-by-url-schemes.md) | Data (MxDataHUB) and processes (MxJobsMGR) are separate apps linked by URL schemes | Accepted |
| [ADR-0010](0010-shared-swift-sources-compiled-into-each-app.md) | Shared Swift sources are compiled into each app | Accepted |
| [ADR-0011](0011-app-sandbox-with-outgoing-network-only.md) | App Sandbox with outgoing network only | Accepted |
| [ADR-0012](0012-quick-help-panel-for-in-app-documentation.md) | In-app documentation through a shared Quick Help panel | Accepted |

Decisions shared with MxJobsMGR (0009 and 0010 here) are recorded in both apps' folders; see also
[MxJobsMGR ADRs](../../../MxJobsMGR/c4/adr/README.md).

## Template

```markdown
# ADR-NNNN: Title

- **Status:** Proposed | Accepted | Superseded by ADR-NNNN
- **Applies to:** …

## Context
## Decision
## Consequences
## Alternatives considered
## Evidence
```
