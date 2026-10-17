# ADR-0002: PostgreSQL schema `srm` is the system of record, with rules in SQL

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** SRM database, MxDataHUB, srm.py, analytics service

## Context

Three kinds of writers and readers touch the security master: the app (interactive changes), the Python loaders
(bulk upserts from many sources) and the analytics service (optimization inputs, attribution). Identifier rules are
subtle — check digits, validity periods, one security per value at a time — and must hold no matter who writes.

## Decision

Keep all SRM data in one **PostgreSQL schema `srm`**, and put the rules **in the database**: `CHECK` constraints
calling `identifier_is_valid`, `EXCLUDE` constraints on validity ranges (btree_gist), and SQL functions and
procedures for the operations every client needs — `resolve_identifier`, `set_identifier`, `add_holding`,
`benchmark_weights`, `apply_benchmark_snapshot`, `build_benchmark`, `portfolio_valuation`, `portfolio_validate`,
`portfolio_active_weights`, `last_price`. Views (`v_security`, `v_identifier_coverage`, `v_benchmark_summary`,
`v_load_history`, `v_snapshot_coverage`) give stable read shapes.

## Consequences

- The app, the loaders and the analytics service get identical answers (e.g. the same identifier resolution).
- The app stays thin: it calls functions and views rather than re-implementing rules in Swift.
- Business logic is split between SQL and Python/Swift; SQL functions need their own tests and migrations.
- Ties the system to PostgreSQL features (range types, `EXCLUDE`, PL/pgSQL).

## Alternatives considered

- *Rules in the app* — would not protect against the loaders; duplicated in Python.
- *A service layer owning the rules* — an extra process for a single-user system ([ADR-0003](0003-direct-database-access-with-single-statement-changes.md)).

## Evidence

`SRM/migrations/V001…V010`, `SRM/README.md` (Schema, Functions), `SRMStore.swift` (calls to `srm.*`).
