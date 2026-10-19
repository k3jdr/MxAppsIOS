# MxDataHUB — Logical Data Model

**Scope.** The security reference master (SRM) that MxDataHUB maintains in PostgreSQL schema `srm`: who issues
securities, what they are, where they trade, what they are called by every identifier scheme, what they cost, which
benchmarks hold them, and the portfolios and personal accounts built from them — each fact traceable to the source and
load that supplied it. Physical form: [`ddl/`](ddl/README.md); diagrams: [erd.md](erd.md).

## 1. Conventions

| Topic | Rule |
|---|---|
| Identity | Surrogate identity keys (`*_id`) for entities with no stable natural key (issuer, security, listing, benchmark, portfolio, load run); natural keys for code lists (ISO currency, country, MIC; identifier type; security type; scheme). Business codes (`benchmark.code`, `portfolio.code`, `data_source.code`) are unique and are what other apps use. |
| Time | **Validity ranges** `[valid_from, valid_to)` with `valid_to = 'infinity'` for current rows on facts that change and must keep history (listings, identifiers, classifications, benchmark membership). **Dated snapshots** (`as_of_date`) for facts reported as of a day (weights, holdings, market cap). **Event dates** for events (`ex_date`, `trade_date`, `price_date`). |
| No overlap | `EXCLUDE USING gist (… daterange(valid_from, valid_to) WITH &&)` enforces "one at a time" rules in the database, not in loaders. |
| Lineage | Every loaded fact carries `source_id` (mandatory where a source always exists) and `load_id` (nullable: manual entries have none). |
| Weights | Fractions (`0.0752` = 7.52 %), `numeric(14,10)`. Money `numeric(24,2)`; prices `numeric(20,6)`; quantities `numeric(24,6)`. |
| Validation | Identifier formats and check digits (ISIN, CUSIP, SEDOL, FIGI, LEI, CIK) are validated by IMMUTABLE functions used in `CHECK` constraints. |

## 2. Subject areas

| Area | Entities |
|---|---|
| A. Audit & lineage | Data Source, Load Run, Load Reject, Schema Version |
| B. Reference | Currency, Country, Exchange (MIC), Exchange Code Map, Identifier Type, Security Type, Classification Scheme |
| C. Legal entities | Issuer, Issuer Name History |
| D. Instruments | Security, Listing, Security Identifier, Classification Node, Security Classification |
| E. Market data | Price, Corporate Action, Security Market Data |
| F. Benchmarks | Benchmark, Benchmark Weight, Benchmark Constituent, Benchmark Level |
| G. Portfolios | Portfolio (model portfolio or personal account), Portfolio Holding, Portfolio Transaction, Portfolio Tax Lot |

## 3. Entities

### A. Audit & lineage

**Data Source** — an upstream feed (API or file) the loaders read, or a pseudo-source (`MANUAL` entered in the app,
`DERIVED` computed, `SNAPSHOT` carried forward).
Identifier: `source_id`; unique `code` (`^[A-Z0-9_]+$`). Attributes: name, url, licence note, plan note (what the
subscription serves and refuses). 12 seeded: MANUAL, DERIVED, ISO10383, ISO4217, SEC_EDGAR, NASDAQTRADER, OPENFIGI,
FMP, GLEIF, SSGA, NASDAQ_COM, SNAPSHOT.

**Load Run** — one execution of a loader. Identifier: `load_id`. Attributes: loader name, start / finish time, status
(`running`, `succeeded`, `partial`, `failed`), rows read / inserted / updated / rejected, API calls, parameters (JSON),
message. Rule: finish ≥ start. Opened by `begin_load(source, loader, params)`, closed by `finish_load(...)`.
Relationships: belongs to one Data Source; has many Load Rejects; is referenced by every fact it wrote.

**Load Reject** — a record a load could not apply (invalid identifier, conflict). Attributes: record key, reason,
payload (JSON). Deleted with its load run.

**Schema Version** (`srm_meta.schema_version`) — migrations applied: version, name, SHA-256 checksum, applied at/by.

### B. Reference

| Entity | Identifier | Key attributes | Notes |
|---|---|---|---|
| Currency | ISO 4217 code (`^[A-Z]{3}$`) | numeric code, name, minor units (0–4), active | |
| Country | ISO 3166 alpha-2 | name | |
| Exchange | ISO 10383 MIC (`^[A-Z0-9]{4}$`) | operating MIC, segment type (`OPRT`/`SGMT`), name, LEI, country, city, status, dates | An operating MIC groups its segments (XNAS → XNGS, XNMS, XNCM). |
| Exchange Code Map | (vendor, vendor code) | MIC (null for a composite), country, is composite | OpenFIGI `UW` → XNGS; OpenFIGI `US` = all US venues. |
| Identifier Type | `id_type` | scope (`security`, `listing`, `issuer`), regex pattern, has check digit, unique per security, sort order | ISIN, CUSIP, COMPOSITE_FIGI, SHARE_CLASS_FIGI (security); SEDOL, FIGI, TICKER, FMP_SYMBOL (listing). LEI and CIK are issuer attributes. |
| Security Type | name | asset class (`Equity`, `Fund`, `Fixed Income`, `Index`, `Cash`, `Derivative`, `Other`) | 16 seeded (Common Stock, ETF, Bond, …). |
| Classification Scheme | code | name, publishing source | FMP (sector / industry), SIC, SSGA. |

### C. Legal entities

**Issuer** — the legal entity that issues securities. Identifier: `issuer_id`; alternate keys LEI (ISO 17442, MOD 97-10
check) and CIK (10 digits, non-zero), each optional and unique. Attributes: name (non-blank), EIN, entity type, legal
form (ISO 20275), entity status, legal and HQ country, incorporation, SIC code / description, fiscal year end,
website, LEI and SEC refresh times. One issuer → zero or many Securities.

**Issuer Name History** — former names (issuer, name) with optional validity and source.

### D. Instruments

**Security** — an instrument at share-class level: one per ISIN / share-class FIGI. Identifier: `security_id`.
Attributes: name, security type, share class, currency, country of risk, primary MIC, active flag and inactive date,
description, the load that created it. Optional issuer (funds and indexes may have none).

**Listing** — a security traded on a venue under a ticker over a period. Identifier: `listing_id`. Attributes: MIC,
ticker (`^[A-Z0-9./\-^=]{1,20}$`), trading currency, primary flag, round lot, validity.
Rules: a (MIC, ticker) names one security at a time (exclusion); at most one current primary listing per security.

**Security Identifier** — every identifier value a source reported for a security (and, for listing-scoped types, a
listing / venue), with validity. Identifier: `xref_id`. Attributes: type, value, MIC, validity, source, load,
first / last seen. Rules:
1. the value passes its type's format and check digit (`identifier_is_valid`);
2. a value points to one security at a time (per venue for listing-scoped types);
3. a security has one current value per type (per venue);
4. maintained only through `set_identifier(...)`, which closes the previous value, reassigns tickers that moved, and
   reports conflicts instead of overwriting (`unchanged`, `inserted`, `changed`, `moved`, `conflict:<id>`, `invalid`).

**Classification Node** — a node of a scheme's hierarchy (Sector → Industry). Identifier: `node_id`; unique (scheme,
code). Attributes: name, level (≥ 1), level name, parent node.

**Security Classification** — a security's node at one level of one scheme, over a validity range; one node per
(security, scheme, level) at a time.

### E. Market data

**Price** — end-of-day prices of a listing from a source. Identifier: (listing, date, source). Attributes: open,
high, low, close (required, ≥ 0), adjusted close, volume (≥ 0), VWAP, currency, load. Rule: high ≥ low. The "last
price" of a security prefers its primary listing (`last_price(security, as_of)`).

**Corporate Action** — an event on a security: cash or stock dividend, split, symbol or name change, delisting,
merger, spin-off, other. Identifier: `action_id`; unique (security, type, ex-date, source). Attributes: ex / record /
pay / declared dates, amount and split-adjusted amount per share, currency, frequency, split ratio (new for old,
both > 0 for a split), old / new value, details (JSON).

**Security Market Data** — market cap, shares outstanding and beta of a security as reported by a source on a date.

### F. Benchmarks

**Benchmark** — an index or custom benchmark. Identifier: `benchmark_id`; unique code (`SP500`, `NDX`, `DJIA`,
`SP400`, `SP600`, custom). Attributes: name, provider (`MxDataHUB` for custom ones the app built), level symbol
(`^GSPC`), weighting method (`cap`, `modified_cap`, `price`, `equal`, `custom`), currency, constituent source, proxy
flag and note (weights taken from a tracking ETF), parent benchmark (for custom ones), description.

**Benchmark Weight** — a dated snapshot: all rows of a benchmark with the same date. Identifier: (benchmark, date,
security). Attributes: weight (0–1), shares, market value, source, load.

**Benchmark Constituent** — membership over time, derived: rebuilt from all of the benchmark's snapshots by
`apply_benchmark_snapshot` (a security is a member from the first snapshot of each run of consecutive snapshots that
hold it until the next snapshot without it). No overlapping ranges per (benchmark, security).

**Benchmark Level** — daily index level (OHLC) from a source.

### G. Portfolios

**Portfolio** — a model portfolio, or a **personal account** when `account_type` is set. Identifier: `portfolio_id`;
unique code (`^[A-Za-z0-9_\-]{1,40}$`). Attributes: name, base currency (default USD), benchmark (optional, set null
if the benchmark is deleted), inception date, description; personal accounts add account type (`taxable`,
`retirement`, `roth`), approach (`active`, `passive`), managing app (`MxPortMGR`), cash balance (≥ 0).

**Portfolio Holding** — a dated holdings snapshot row. Identifier: (portfolio, date, security). Attributes: quantity
and / or target weight (at least one; weight −1…1 allows shorts), cost price, what the user typed and how it resolved,
note; `load_id` and `drifted_from` when carried forward by the `portfolio-snapshots` loader (drifted_from < date).

**Portfolio Transaction** — a dated cash or position event. Identifier: `txn_id`. Types: BUY, SELL, DIVIDEND, SPLIT,
DEPOSIT, WITHDRAWAL, FEE, TRANSFER_IN, TRANSFER_OUT. Rules: security required for security events; quantity > 0
for buys, sells and transfers; price required for buys and sells; settle ≥ trade date; fees ≥ 0.

**Portfolio Tax Lot** — an open lot of a personal account: security, acquired date, quantity (> 0), total cost
(≥ 0). Selling a whole lot deletes it; part of a lot lowers its quantity and cost in proportion.
`sync_holdings_from_lots(portfolio, date)` rewrites that day's holdings from the lots.

## 4. Relationships (cardinality)

| Parent | Child | Cardinality | Delete rule |
|---|---|---|---|
| Data Source | Load Run | 1 : 0..n | restrict |
| Load Run | Load Reject | 1 : 0..n | cascade |
| Load Run | every loaded fact | 0..1 : 0..n | restrict |
| Country | Exchange | 0..1 : 0..n | restrict |
| Exchange | Exchange Code Map | 0..1 : 0..n | restrict (deferrable) |
| Issuer | Security | 0..1 : 0..n | restrict |
| Issuer | Issuer Name History | 1 : 0..n | cascade |
| Security Type | Security | 1 : 0..n | restrict |
| Security | Listing, Security Identifier, Security Classification, Corporate Action, Security Market Data | 1 : 0..n | cascade |
| Exchange | Listing | 1 : 0..n | restrict |
| Listing | Price | 1 : 0..n | cascade |
| Listing | Security Identifier (listing-scoped) | 0..1 : 0..n | cascade |
| Identifier Type | Security Identifier | 1 : 0..n | restrict |
| Classification Scheme | Classification Node | 1 : 0..n | restrict |
| Classification Node | Classification Node (parent) | 0..1 : 0..n | restrict |
| Benchmark | Benchmark (parent) | 0..1 : 0..n | restrict |
| Benchmark | Weight, Constituent, Level | 1 : 0..n | cascade |
| Security | Benchmark Weight, Constituent, Portfolio Holding, Tax Lot | 1 : 0..n | restrict |
| Benchmark | Portfolio | 0..1 : 0..n | set null |
| Portfolio | Holding, Transaction, Tax Lot | 1 : 0..n | cascade |

## 5. Derived data (views and functions)

| Object | Gives |
|---|---|
| `v_security` | One row per security with its current ticker / MIC, ISIN, CUSIP, SEDOL, FIGIs, FMP symbol, issuer (LEI, CIK, SIC), FMP sector / industry |
| `v_identifier_coverage` | Securities carrying each identifier type now, with the sources |
| `v_load_history` | Load runs with source code and duration |
| `v_benchmark_summary` | Each benchmark's latest snapshot: members, weight sum, snapshots, last level |
| `v_snapshot_coverage` | Weight history per benchmark and portfolio: snapshots, first / last date, months, longest gap, drifted snapshots |
| `v_portfolio_tax_lot` | Lots valued at the latest price: market value, unrealised gain, long-term flag |
| `v_personal_account` | Personal accounts: lots, securities, invested value, cost |
| `resolve_identifier(value)` | Securities matching any identifier (`TICKER:MIC`, `TICKER US`, CIK and LEI via the issuer), best first |
| `portfolio_valuation`, `portfolio_validate`, `portfolio_active_weights`, `portfolio_positions` | Valued holdings, checks (weights ≠ 100 %, missing / stale prices, inactive, shorts), active weights vs a benchmark, positions from transactions |
| `build_benchmark(code, name, parent, method, sector)` | A custom equal- or cap-weighted benchmark from another's members |

## 6. Business rules summary

1. An identifier value identifies one security at a time; a security has one current value per identifier type
   (per venue for listing-scoped types). History is never overwritten — values are closed and new ones opened.
2. A ticker names one security on one venue at a time; a security has at most one current primary listing.
3. Benchmark membership is derived from weight snapshots and rebuilt whenever a snapshot is written.
4. Target weights of a holdings snapshot should add up to 100 % (checked, not enforced, so drafts can be saved).
5. A personal account's holdings are derived from its tax lots; edit the lots (MxPortMGR), not the holdings.
6. Every change made from the app is one SQL statement, committed on its own (ADR 0003).
