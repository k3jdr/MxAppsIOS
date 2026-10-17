# ADR-0004: Loading and schema changes live in a Python CLI with versioned migrations

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** srm.py, SRM schema

## Context

The security master is filled from eight free or subscribed sources with different formats, rate limits and plans
(ISO MIC CSV, ISO 4217 XML, Nasdaq Trader files, SEC JSON, SSGA SPDR XLSX, Nasdaq.com, OpenFIGI, FMP, GLEIF). Loads
must be repeatable, auditable and runnable from a terminal or a scheduler.

## Decision

A Python 3.9+ CLI, **`SRM/srm.py`** (`migrate`, `load <loader>|all`, `status`), with **one module per source**
under `srmlib/loaders/`, shared rate-limited HTTP, secrets lookup and load audit in `srmlib/common.py`. Schema
changes are **versioned, checksummed migrations** (`V001…V010`, applied in order; applied files must not change).
Every write is an **upsert**, so any loader can be re-run; every run is recorded in `srm.load_run` (with rejects in
`load_reject`). `load all` runs the loaders in dependency order; `portfolio-snapshots` is optional.

## Consequences

- Python's data libraries and quick iteration suit messy sources; psycopg2 is the only non-standard dependency.
- Re-runnable, audited loads: Load History shows them; the srm-loader service reads them for freshness.
- The app cannot run the CLI itself (sandbox) — hence [ADR-0005](0005-data-refresh-through-local-loader-service.md).
- Migration files are immutable once applied; renames (e.g. MxDataSRM → MxDataHUB) leave old wording in applied migrations.

## Evidence

`SRM/srm.py`, `SRM/srmlib/`, `SRM/migrations/`, `SRM/README.md` (Loaders, Source limits).
