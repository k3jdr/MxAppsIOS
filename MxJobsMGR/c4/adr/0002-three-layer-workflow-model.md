# ADR-0002: Workflows are three-layer swim-lane diagrams

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Jobspace model, canvas, run engine, validation

## Context

Desk processes mix people (who trigger and approve), judgement (agents that prepare and decide) and mechanics
(data reads and computations). Mixing them in one flat flowchart hides who is accountable for what and where data
comes from.

## Decision

Model every jobspace in **three layers**, each a swim lane with its own node kinds:

| Layer | Node kinds |
|---|---|
| **1 · Business Operations** | Refresh Trigger, Assemble Instructions, User Approval, Execution Request, Outcome Report |
| **2 · Agentic Operations** | Agent Task, Aggregate Results, Decision |
| **3 · Data Reads** | API Data Read, Python Script, Normalize Data |

Nodes stay in their lane. Links **down** the layers are **calls**, links **up** carry **results** (drawn dashed),
links within a layer are flow. The run engine orders steps by these semantics; the Validator warns when a link
skips the agent layer.

## Consequences

- The diagram reads as an operating model: accountability (L1), preparation and decision (L2), data (L3).
- Run order follows from the links without a separate scheduling language.
- Some processes need a Layer 2 pass-through step even when no judgement is involved.
- The draw.io export maps each layer to a swimlane ([ADR-0015](0015-diagram-export-as-png-and-drawio-svg.md)).

## Evidence

`JobspaceModel.swift` (`Layer`, `NodeKind`), `DiagramCanvas.swift`, `RunEngine.swift` header, `Validation.swift`, README *The three layers*.
