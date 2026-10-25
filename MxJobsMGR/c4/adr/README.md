# Architecture Decision Records — MxJobsMGR

Each record states the context, the decision, its consequences and the evidence in the code. They were written
**retrospectively** (2026-10-17) from the implementation, READMEs and git history. New decisions get the next number
and the same template; a superseded record is kept and marked *Superseded by ADR-NNNN*.

| ADR | Decision | Status |
|---|---|---|
| [ADR-0001](0001-document-based-app-with-json-jobspace-files.md) | A document-based app with JSON jobspace files | Accepted |
| [ADR-0002](0002-three-layer-workflow-model.md) | Workflows are three-layer swim-lane diagrams | Accepted |
| [ADR-0003](0003-layer-3-compute-as-local-services.md) | Layer 3 computation runs as local HTTP services, in the language that fits | Accepted |
| [ADR-0004](0004-api-keys-in-keychain-never-in-jobspace.md) | API keys live in the Keychain, never in a jobspace | Accepted |
| [ADR-0005](0005-human-approval-before-execution.md) | A human approves before anything is executed | Accepted |
| [ADR-0006](0006-execution-requests-never-send-yet.md) | Execution Requests report what they would send — nothing is sent yet | Accepted |
| [ADR-0007](0007-per-layer-run-modes-for-rehearsal.md) | Per-layer run modes for rehearsal and debugging | Accepted |
| [ADR-0008](0008-decisions-follow-decision-context-contracts.md) | Decisions follow the `decisionContext` of versioned Layer 3 contracts | Accepted |
| [ADR-0009](0009-expected-outcomes-and-exception-policies-per-step.md) | Every step declares its expected outcome and its exception policy | Accepted |
| [ADR-0010](0010-data-along-links-by-templates-large-data-stays-in-services.md) | Data flows along links by templates; large data stays in the services | Accepted |
| [ADR-0011](0011-python-steps-run-in-the-sandbox-with-consent.md) | Python Script steps run inside the sandbox, with consent; services are preferred | Accepted |
| [ADR-0012](0012-data-and-process-apps-linked-by-url-schemes.md) | Data (MxDataHUB) and processes (MxJobsMGR) are separate apps linked by URL schemes | Accepted |
| [ADR-0013](0013-shared-swift-sources-compiled-into-each-app.md) | Shared Swift sources are compiled into each app | Accepted |
| [ADR-0014](0014-sandbox-with-user-selected-files-and-bookmarks.md) | Sandboxed, with user-selected files and security-scoped bookmarks | Accepted |
| [ADR-0015](0015-diagram-export-as-png-and-drawio-svg.md) | Diagrams export as PNG and draw.io SVG | Accepted |
| [ADR-0016](0016-agents-simulated-until-a-model-is-connected.md) | Layer 2 agents are simulated until a model is connected | Accepted |
| [ADR-0017](0017-quick-help-panel-for-in-app-documentation.md) | In-app documentation through a shared Quick Help panel | Accepted |

ADR-0012 and ADR-0013 are shared with MxDataHUB; see also [MxDataHUB ADRs](../../../MxDataHUB/c4/adr/README.md).

## Open questions for future ADRs

- Connecting execution targets (order management, publishing): authentication, idempotency, audit ([ADR-0006](0006-execution-requests-never-send-yet.md)).
- Connecting a model to Layer 2 agents: provider, prompts, evaluation, cost ([ADR-0016](0016-agents-simulated-until-a-model-is-connected.md)).
- Unattended scheduling of triggers (today schedules are recorded; runs start from the app).
- Persisting run results and an audit trail of approvals.

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
