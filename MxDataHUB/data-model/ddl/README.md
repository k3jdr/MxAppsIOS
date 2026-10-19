# srm DDL package

Builds MxDataHUB's security reference master (schema `srm`) in an empty database, in one transaction:

```bash
cd MxDataHUB/data-model/ddl
psql -v ON_ERROR_STOP=1 -h <host> -U postgres -d srm -1 -f install.sql
```

Needs PostgreSQL 13+ with the `btree_gist` extension (contrib); `pg_trgm` is used when available. The installer
refuses to run where `srm` already has tables — upgrade an existing database with `../../SRM/srm.py migrate`.

| File | Contents |
|---|---|
| `install.sql` | Runs the files below in order |
| `01_schema.sql` | Schema `srm`, extensions, `srm_meta.schema_version` |
| `02_identifier_functions.sql` | ISIN / CUSIP / SEDOL / FIGI / LEI / CIK validation and conversion, `touch_updated_at` |
| `03_reference_and_audit.sql` | Data sources, load runs and rejects; currency, country, exchange (MIC), vendor exchange codes; identifier types, security types, classification schemes |
| `04_issuers_securities.sql` | Issuers, securities, listings, identifier cross-reference with history, classifications, name-search indexes |
| `05_market_data.sql` | Corporate actions, prices, market cap / shares |
| `06_benchmarks.sql` | Benchmarks, weight snapshots, membership, levels |
| `07_portfolios.sql` | Portfolios and personal accounts, holdings snapshots, transactions, tax lots |
| `08_routines.sql` | Load audit, `set_identifier`, `resolve_identifier`, `last_price`, benchmark snapshots and custom benchmarks, portfolio valuation / checks / active weights, `add_holding`, `sync_holdings_from_lots` |
| `09_views.sql` | `v_security`, coverage, load history, benchmark summary, snapshot coverage, tax lots, personal accounts |
| `10_seed.sql` | Sources (with plan notes), US country / currency / MICs, vendor code maps, identifier and security types, schemes, the five benchmark definitions |
| `99_register_migrations.sql` | Records V001–V011 with their SHA-256 checksums so `srm.py migrate` continues from V012 |

**Verified (2026-10-18, PostgreSQL 18.6):** a database built with this package and one built by applying
V001–V011 give identical `pg_dump --schema-only -n srm` output and identical seed rows, and `./srm.py migrate`
reports the package-built database as up to date. When a V012 migration is added, apply it with `srm.py` and update
this package to match (re-run the comparison).
