# ADR-0009: Every step declares its expected outcome and its exception policy

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Jobspace model, run engine, API and Python runners

## Context

Market-data sources fail in many ways (rate limits, partial data, plan limits). A workflow must say what success
looks like and what to do otherwise, step by step, rather than fail as a whole.

## Decision

Each node has an **Expected Outcome** — output name, success HTTP status (default `200-299`), required JSON
fields, **value checks** `path op value` (`==`, `!=`, `<`, `<=`, `>`, `>=`, `contains`, `exists`; numeric when both
sides are numbers; values may use `{{argument}}`) — and an **Exception Policy** — `retry` (max retries, delay,
exponential backoff), `skip`, `useFallback`, `escalateToUser` (Retry / Skip / Abort), `abortRun`, timeout, notify.
A step after a failed, rejected or cancelled step is skipped.

## Consequences

- Behaviour under failure is part of the design and visible in the inspector and the diagram.
- The same checks apply to live runs, Test Call and Python steps; mocks generate passing values.
- Defaults (retry ×2, 5 s, backoff, 30 s timeout) suit HTTP sources; long loads need larger timeouts.

## Evidence

`JobspaceModel.swift` (`ExpectedOutcome`, `ValueAssertion`, `ExceptionPolicy`), `RunEngine.swift` (`attempt`, `handleFailure`), `ApiTester.swift`.
