# ADR-0016: Layer 2 agents are simulated until a model is connected

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Agent Task, Aggregate Results, Decision

## Context

The design calls for agents (an LLM or other engine) that prepare data points and decide. Model integration — keys,
prompts, cost, evaluation — is not in place yet, but workflows must run end to end now.

## Decision

**Agent Task** and **Aggregate Results** pass their inputs on (the configured model is noted as "not connected
yet"); **Decision** applies the deterministic `decisionContext` rules ([ADR-0008](0008-decisions-follow-decision-context-contracts.md)).
Agent settings (model, instructions, inputs, output format) are kept in the jobspace for when a model is connected.

## Consequences

- Workflows are runnable and testable today with predictable results.
- The agent configuration format is already part of the file, so connecting a model later is additive.
- Until then, Layer 2 adds no reasoning beyond the contracts' rules.

## Evidence

`RunEngine.swift` (`agentTask`, `aggregate`, `decision`), `JobspaceModel.swift` (`AgentSpec`).
