# ADR-0015: Diagrams export as PNG and draw.io SVG

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** DiagramExport

## Context

Workflows are discussed in documents, slides and wikis, and sometimes edited by people without the app.

## Decision

Export the whole diagram as **PNG (2×)** and as **`*.drawio.svg`**: an SVG any viewer displays that also carries the
diagram as **draw.io XML** — each layer a swimlane holding its nodes, links as connectors, results going up dashed —
so draw.io / diagrams.net opens it for editing. Available from File ▸ Export Diagram and the canvas's context menu.

## Consequences

- Diagrams can be embedded and edited outside the app (e.g. `MxJobsWMS/*.drawio.svg` in the repository).
- Edits made in draw.io do not flow back into the jobspace.

## Evidence

`DiagramExport.swift`, `MxJobsWMSApp.swift` (Export commands), `DiagramCanvas.swift` (context menu).
