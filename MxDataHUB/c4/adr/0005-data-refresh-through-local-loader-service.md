# ADR-0005: Data Refresh runs through a local loader service

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB.app (Data Refresh), Services/srm-loader

## Context

Users want to see how fresh each category of market data is and refresh it from the app. The loaders are Python
(`srm.py`) that need the database password, API keys and file access; the app is sandboxed with outgoing network
only, so it cannot start Python or read the loaders' configuration. The same loaders must also run unattended in
MxJobsWMS's SRM Daily Refresh workflow.

## Decision

Wrap `srm.py` in the **srm-loader** HTTP service (`Services/srm-loader`, Python, **127.0.0.1:8770**). It groups
loaders into **categories** (reference, universe, constituents, identifiers, prices, corporate actions, optional
portfolio snapshots), computes their state (fresh, due, stale, failed) from `srm.v_load_history`, and runs them
**one at a time**: `GET /categories`, `POST /refresh/{category}`, `POST /load/{loader}`, `GET /status`. The header
`X-SRM-Dry-Run: 1` returns the commands without running them. MxDataHUB's Data Refresh screen and MxJobsWMS's
SRM Daily Refresh sample both call it.

## Consequences

- Data Refresh works **without** the app's database connection — the service uses srm.py's own configuration.
- One implementation of "what to load, in which order" for both the interactive refresh and the scheduled workflow.
- The service must be started (`Services/mxservices.py start` or launchd agents); the screen explains this when it is down.
- Long loads hold an HTTP request open (the app waits up to 3 hours); the service serialises loads.
- Listening on loopback only, and accepting only srm.py's own loaders and options, limits what a caller can run.

## Alternatives considered

- *Run srm.py from the app* — impossible in the sandbox without giving up the sandbox.
- *A database-side job queue* — more infrastructure; MxJobsWMS already provides scheduling and approval.

## Evidence

`DataRefreshView.swift` (`RefreshStore`), `Services/srm-loader/srm_service.py` (`CATEGORIES`, endpoints), `Services/README.md`.
