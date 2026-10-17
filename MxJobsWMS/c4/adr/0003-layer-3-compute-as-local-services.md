# ADR-0003: Layer 3 computation runs as local HTTP services, in the language that fits

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Services/, MxJobsWMS API Data Read steps, MxDataHUB

## Context

The workflows need data loading and statistics (pandas/numpy-style work), long-lived rule-heavy portfolio construction,
and numerically heavy tracking and risk. The app is sandboxed and should not embed numerical libraries or credentials.

## Decision

Run Layer 3 tools as **small HTTP services on 127.0.0.1**, outside the sandbox, each in the language that fits:

| Service | Language | Port | Why |
|---|---|---|---|
| srm-loader | Python | 8770 | Data loading, database work |
| analytics | Python | 8772 | Statistics: covariance (Ledoit-Wolf), momentum alpha, Brinson-Fachler attribution |
| portfolio-java | Java 17 | 8766 | Active optimization with many constraints; typed, unit-tested (20 JUnit tests) |
| portfolio-cpp | C++ | 8767 | Index tracking and risk in tight numeric loops (52 checks) |
| market-sample | Python | 8765 | Template for wrapping a new source |

Every service answers `GET /health` and `GET /describe`. MxJobsWMS calls them through **Local service**
subscriptions; `Services/mxservices.py` starts, stops and checks them (optionally as launchd agents). Both apps show
them from the built-in `ServiceCatalog`.

## Consequences

- Each tool uses its natural ecosystem and IDE; the app stays dependency-free.
- Services can be tested and called on their own (`curl`, unit tests, `check_engines.py`).
- Operations: services must be running; the app shows their state and the start command.
- Loopback only; no authentication beyond an optional bearer token.

## Evidence

`Services/README.md`, `Services/mxservices.py`, `Shared/ServiceCatalog.swift`, sample subscriptions (`Samples/*.jobspace`).
