# pmg DDL package

Creates schema `pmg` with its seed data in one transaction (PostgreSQL 13+):

```bash
cd MxPortMGR/data-model/ddl
psql -v ON_ERROR_STOP=1 -h <host> -U postgres -d srm -1 -f install.sql
```

`pmg` does not depend on `srm` or `wms` (it names srm portfolios and Layer 3 services by code), so it can share
MxDataHUB's database or have its own.

| File | Contents |
|---|---|
| `install.sql` | Runs the files below in order |
| `01_schema_and_codes.sql` | Schema, `touch_updated_at`, asset classes, sectors, model parameters, sleeves, price drivers, report tiers, scenarios |
| `02_universe.sql` | Securities, bond terms, fund look-through, benchmarks and weights, market months and monthly returns |
| `03_accounts.sql` | Accounts, look-for notes, holdings, tax lots, missing returns, app settings |
| `04_reports_and_reactions.sql` | Market reports and their texts, lines, terms, moves, drivers, factor moves, context chart; reactions and their moves |
| `05_engine_results.sql` | Engine runs; optimizations (weights, trades, binding limits, sector tilts, tax estimates); risk reports; attribution; simulations |
| `06_views.sql` | Holdings, look-through, sector / asset-class vs benchmark, account summary, account checks, tax lots, report catalogue |
| `10_seed.sql` | **Generated** — 56 securities, 3 benchmarks, 12 months × 53 returns, 11 accounts with holdings and lots, 18 reports with 76 reactions |

`10_seed.sql` is produced from the app's own Swift model (including the drifted-tracker sample and the monthly
returns, which the app draws from seeded random numbers). After changing `Universe.swift`, `Samples.swift` or the
reports, regenerate it rather than editing it:

```bash
../tools/generate_seed.sh
```

**Verified (2026-10-18, PostgreSQL 18.6):** installs cleanly; benchmark weights and every holding's lots sum to 1;
`v_account_issue` reports the samples' teaching cases (OLDCO unknown, ROV unpriced, GMR missing returns, NWD at 48 %,
Technology 76 % vs 34 % in MXEQ, 45 % cash).
