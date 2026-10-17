# ADR-0007: Identifiers are time-ranged and validated in the database

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** SRM schema

## Context

Securities are known by many identifiers (ISIN, CUSIP, SEDOL, FIGI, composite and share-class FIGI, tickers per
venue, FMP symbols, CIK, LEI). They change over time (ticker changes, re-listings), sources disagree, and bad check
digits are common in free data.

## Decision

Store identifiers in `srm.security_identifier` with **`[valid_from, valid_to)` ranges**, source and load. Two
**`EXCLUDE` constraints** guarantee that a value points to one security at a time and that a security has one
current value per type (and venue). A **`CHECK` with `identifier_is_valid`** validates format and check digits.
`set_identifier` is an idempotent upsert that keeps history and reports `unchanged`, `inserted`, `changed`,
`moved`, `conflict:<id>` or `invalid`; `resolve_identifier` answers "which security is this, as of a date".

## Consequences

- Point-in-time correctness for holdings and benchmarks; conflicts surface as data instead of silent overwrites.
- Search in the app accepts any identifier and `TICKER:MIC` / `TICKER US` forms.
- Needs the `btree_gist` extension; loaders must handle `conflict` and `invalid` outcomes (recorded as rejects).

## Evidence

`SRM/migrations/V002__identifier_validation.sql`, `V003__issuers_securities_listings.sql`, `V004__xref_functions_prices_actions.sql`.
