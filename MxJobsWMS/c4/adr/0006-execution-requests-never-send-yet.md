# ADR-0006: Execution Requests report what they would send — nothing is sent yet

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Run engine

## Context

Execution targets (order-management systems, publishing endpoints) are not integrated yet, and a design tool must be
safe to run against real data.

## Decision

An **Execution Request** step, even in *live* mode, **does not send**. It finishes with a **warning** and outputs
`sent: false`, the target, the mode (`dryRun`, `paper`, `live`) and the request it would have sent.

## Consequences

- Workflows can be run end to end against live data without side effects.
- The outcome report shows exactly what would be executed — reviewable evidence.
- Connecting a real target is a future decision (new ADR): authentication, idempotency, audit and the approval
  record must be designed then.

## Evidence

`RunEngine.swift` (`executeRequest`: "Not sent: execution connectors are not available yet").
