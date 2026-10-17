# ADR-0008: Benchmarks and portfolios are kept as dated weight snapshots

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** SRM schema, MxDataHUB Portfolios and Benchmarks, analytics service

## Context

Official index weights are licensed and not on the available plans; free ETF files (SSGA SPDR, Nasdaq.com) give
only the current date. Attribution needs monthly weight history for both the benchmark and the portfolio.

## Decision

- Store **benchmark weights as dated snapshots** (`benchmark_weight`, one per load), rebuild membership ranges
  from all snapshots (`apply_benchmark_snapshot`), and use **ETF holdings as proxies** for index weights (SPY, DIA,
  MDY, SPSM; Nasdaq-100 market caps), marked *PROXY* in the app.
- Store **portfolio holdings as dated snapshots** (`portfolio_holding` by `as_of_date`). *New Snapshot…* copies the
  latest earlier one; the optional `portfolio-snapshots` loader carries the latest snapshot forward to the latest
  price date, drifting weights by returns (`load_id`, `drifted_from`), never changing an existing snapshot.
- Show the history in **Load History ▸ Snapshot history** (`v_snapshot_coverage`: count, first and last date, months, longest gap).

## Consequences

- History accumulates from the first load onward; earlier months fall back to the nearest snapshot and are flagged
  `review` in attribution.
- Custom benchmarks (`build_benchmark`, equal or cap weighted, optionally one sector) reuse the same tables.
- Proxy weights differ from official index weights; the Availability… sheet explains what cannot be built.

## Evidence

`SRM/migrations/V005__benchmarks_portfolios.sql`, `V010__benchmark_portfolio_history.sql`, `SRMBenchmarksView.swift`, `SRMPortfoliosView.swift`, `SRMLoadsView.swift`, `Services/README.md` (Weight history).
