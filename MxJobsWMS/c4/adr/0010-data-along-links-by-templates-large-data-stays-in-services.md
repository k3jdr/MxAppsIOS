# ADR-0010: Data flows along links by templates; large data stays in the services

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** API Data Read steps, Layer 3 services

## Context

Steps need values produced upstream (an inputs id, weights, a date). Covariance matrices for hundreds of securities
are megabytes and should not pass through the app or the jobspace.

## Decision

A step's path, parameters, headers and body may use **templates**: `{{argument}}`, `{{today}}`, `{{yesterday}}`,
`{{in:output.path}}` (insert a value from a linked step's output) and `{{json:output.path}}` (insert it as JSON).
For large data the services **pass references**: analytics `POST /inputs` returns an `inputsUrl` that the Java and
C++ endpoints fetch themselves (`"inputsUrl": "{{in:optInputs.inputsUrl}}"`).

## Consequences

- Workflows stay small and readable; the heavy data never leaves the loopback services.
- Templates are strings: a wrong path shows up at run time (Test Call uses the last run's outputs to try them).
- Services must keep inputs available for the duration of a run.

## Evidence

`ApiTester.swift` (`substitute`, `fillInputs`), `Services/README.md`, the Active, Passive and Attribution samples.
