# ADR-0008: Decisions follow the `decisionContext` of versioned Layer 3 contracts

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Decision steps, Services/contracts

## Context

Layer 2 must choose the next step (rebalance, hold, …) from Layer 3 outcomes. Real LLM agents are not connected
yet, and the choice must be explainable and reproducible.

## Decision

Every Layer 3 outcome carries a **`decisionContext`** — `recommendation` (rebalance, rebalance_partially, hold,
rerun_relaxed, escalate), `confidence`, `alternatives`, `reason` — computed by documented rules in versioned
**contracts** (`mxjobs.optimization/1`, `mxjobs.risk/1`, …; a breaking change gets `/2` alongside). A **Decision**
step follows the context of its inputs **named in its Inputs list first, in that order, else the most confident**,
outputs `nextStep` with confidence, source and reason, and **escalates** when there is none.

## Consequences

- Deterministic, explainable decisions today; an LLM agent can later consume the same context.
- The Java and C++ engines must agree (`contracts/check_engines.py`).
- Recommendations are only as good as the rules in the contracts.

## Evidence

`RunEngine.swift` (`decision`), `Services/contracts/README.md` (decisionContext rules), `Services/contracts/*.schema.json`.
