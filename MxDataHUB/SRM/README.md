# SRM — security reference master

A PostgreSQL securities master (schema `srm`) with loaders for free and subscribed data sources,
used by the MxDataHUB app (Securities, Portfolios, Benchmarks, Data Refresh, Load History; see [../README.md](../README.md)).

```
SRM/
  migrations/V001__foundation.sql ...   versioned schema (applied in order, checksummed)
  srm.py                                CLI: migrate, status, load
  srmlib/common.py                      config, secrets, rate-limited HTTP, load audit
  srmlib/model.py                       shared SQL helpers
  srmlib/loaders/*.py                   one module per source
```

## Quick start

```bash
cd MxDataHUB/SRM
./srm.py migrate          # create / upgrade schema srm on postgres@192.168.0.223/srm
./srm.py load all         # every loader, in dependency order (not the optional portfolio-snapshots)
./srm.py status           # migrations, row counts, identifier coverage, benchmarks, recent loads
```

Python 3.9+ with `psycopg2`; nothing else outside the standard library.
Connection: `--host --port --user --dbname`, or `SRM_PGHOST` etc., or `config.local.json`;
defaults `postgres@192.168.0.223:5432/srm`.

### Secrets (never in the repository)

Looked up in this order:

| Secret | Environment | Keychain (service / account) | `config.local.json` (untracked) |
|---|---|---|---|
| DB password | `PGPASSWORD` | `SRM-postgres` / `user@host/db` | `database.password`; libpq's `~/.pgpass` also works |
| OpenFIGI key | `OPENFIGI_API_KEY` | `SRM-api` / `openfigi` | `api_keys.openfigi` |
| FMP key | `FMP_API_KEY` | `SRM-api` / `fmp` | `api_keys.fmp` |
| SEC User-Agent | `SRM_SEC_USER_AGENT` | | `sec_user_agent` |

SEC EDGAR refuses requests (403) unless the User-Agent includes a contact e-mail, e.g.
`"Your Name you@example.com"`. API keys are redacted from URLs in logs and in `srm.load_run`.

```bash
security add-generic-password -U -s SRM-api -a fmp -w        # prompts for the key
security add-generic-password -U -s SRM-api -a openfigi -w
```

## Schema

| Area | Tables / functions |
|---|---|
| Audit | `data_source`, `load_run` (one row per loader run: counts, API calls, status), `load_reject`; `begin_load()`, `finish_load()` |
| Reference | `currency` (ISO 4217), `country`, `exchange` (ISO 10383 MICs), `exchange_code_map` (OpenFIGI / FMP / Nasdaq Trader / SEC codes → MIC) |
| Entities | `issuer` (LEI with ISO 17442 check, CIK, EIN, SIC, incorporation, GLEIF status / legal form), `issuer_name_history` |
| Securities | `security`, `security_type`, `listing` (security on a MIC under a ticker, with validity; one ticker per venue at a time) |
| Identifiers | `identifier_type`, `security_identifier` — ISIN, CUSIP, SEDOL, FIGI, composite FIGI, share-class FIGI, ticker, FMP symbol, each valid over `[valid_from, valid_to)` with source and load. Two exclusion constraints: a value points to one security at a time, and a security has one current value per type (and venue). A CHECK validates every value's format and check digit. |
| Classification | `classification_scheme`, `classification_node` (sector → industry), `security_classification` (with history) |
| Market data | `price` (EOD per listing and source), `security_market_data` (market cap, shares, beta), `corporate_action` (dividends, splits, symbol changes, delistings) |
| Benchmarks | `benchmark`, `benchmark_weight` (dated snapshots, one per load), `benchmark_constituent` (membership over time, rebuilt from all snapshots), `benchmark_level` |
| Portfolios | `portfolio`, `portfolio_holding` (dated snapshots; shares and/or target weight; `load_id` and `drifted_from` when carried forward by `portfolio-snapshots`), `portfolio_transaction` |
| Personal accounts (V011) | `portfolio.account_type` (taxable / retirement / roth; NULL for model portfolios), `approach` (active / passive), `managed_by` (e.g. MxPortMGR), `cash_balance`; `portfolio_tax_lot` (open lots: security, purchase date, shares, total cost) |
| Views | `v_security` (current identifiers pivoted), `v_identifier_coverage`, `v_benchmark_summary`, `v_load_history`, `v_snapshot_coverage` (weight history per benchmark and portfolio), `v_portfolio_tax_lot` (lots valued: price, market value, unrealised gain, long-term), `v_personal_account` (accounts with lots, value and cost) |

Functions:

- Validation: `isin_is_valid`, `cusip_is_valid`, `sedol_is_valid`, `figi_is_valid`, `lei_is_valid`,
  `identifier_is_valid(type, value)`, `detect_identifier_type`; conversions `isin_from_cusip`, `cusip_from_isin`.
- `set_identifier(security, type, value, source, ...)` — idempotent upsert that keeps history
  (`unchanged` / `inserted` / `changed` / `moved` / `conflict:<id>` / `invalid`).
- `resolve_identifier(text, type, as_of)` — any identifier, `TICKER:MIC`, `TICKER US`, CIK or LEI → securities, best first.
- `last_price`, `benchmark_weights(benchmark, as_of)`, `apply_benchmark_snapshot` (procedure: rebuilds the benchmark's
  membership ranges from all its snapshots, so loading a date twice or out of order keeps them right),
  `build_benchmark(code, name, parent, 'equal'|'cap', sector, as_of)`.
- `add_holding(portfolio, date, identifier, shares, weight, type)`, `portfolio_positions` (from transactions),
  `portfolio_valuation`, `portfolio_validate`, `portfolio_active_weights`.
- `sync_holdings_from_lots(portfolio, as_of)` — rewrites a personal account's holdings snapshot on `as_of` from its
  open tax lots (total shares, average cost), so valuation, the analytics service and `portfolio-snapshots` see it
  like any other portfolio. MxPortMGR's My Portfolio is kept this way through the accounts service
  (`Services/accounts`).

## Loaders

`./srm.py load <name>`; `all` runs them in this order, except the optional `portfolio-snapshots`. Every run is
recorded in `srm.load_run`; all writes are upserts, so loaders can be re-run at any time.

| Loader | Source | What it loads |
|---|---|---|
| `reference` | ISO 20022 (MIC CSV), SIX (ISO 4217 XML) | 2,889 MICs, 149 countries, 177 currencies |
| `nasdaqtrader` | Nasdaq Trader symbol directory | US listed universe (~13,250 securities): listings, tickers, ETF flag; closes listings that left the files |
| `sec-tickers` | SEC `company_tickers_exchange.json` | issuers with CIK, linked to listed securities (`--include-otc` adds OTC names) |
| `ssga` | State Street SPDR daily holdings | S&P 500 (SPY), Dow (DIA), S&P 400 (MDY), S&P 600 (SPSM): members, weights, shares, CUSIP, SEDOL |
| `nasdaq100` | Nasdaq.com | Nasdaq-100 members and market caps |
| `openfigi` | OpenFIGI mapping (by CUSIP, else ticker) | composite, share-class and exchange-level FIGIs; refines security type |
| `fmp-profiles` | FMP `profile` | ISIN, CUSIP, CIK, sector / industry, country, currency, market cap; then derives US ISINs from CUSIPs |
| `sec-submissions` | SEC submissions | SIC, state of incorporation, EIN, fiscal year end, former names |
| `gleif` | GLEIF ISIN→LEI file + LEI records API | LEI, legal form, entity status, legal / HQ country |
| `fmp-prices` | FMP `historical-price-eod/full` | EOD prices (default 2 years; incremental afterwards) |
| `nasdaq-prices` | Nasdaq.com quote API (free, no key) | EOD prices for the **stock and bond funds** (ETFs, ETNs, closed-end and mutual funds) held in portfolios and personal accounts, and for any benchmark or portfolio security without a price in the last 5 days (the fallback when `fmp-prices` can't run); `--funds` every active fund (~6,100, about 2 hours at one request a second), `--symbols`, `--all-securities`; closes, not dividend-adjusted |
| `trust-navs` | Your plan statements (`trusts.local.json`) + a proxy index fund | **Collective investment trusts** (401(k) "Trust Unit A" funds: no ticker, no public price feed, free or paid): each statement NAV, and every other day the latest earlier NAV × the proxy fund's return since then (source `PROXY`). Copy `trusts.example.json`; runs in Prices after `nasdaq-prices` |
| `mutual-funds` | Nasdaq.com fund network (free, no key) | Adds **mutual funds** (e.g. VTIFX) on demand — `--symbols VTIFX …` or `--search "fund name"` — as `Mutual Fund` securities on MIC XXXX, then loads their prices. The accounts service does the same when Add Securities finds no match. Not part of `load all` |
| `fmp-index-levels` | FMP | benchmark levels (^GSPC, ^DJI on the current plan) |
| `fmp-corporate-actions` | FMP calendars, symbol changes, delistings | dividends, splits, symbol changes, delistings; `--history` adds each security's full dividend / split history |
| `portfolio-snapshots` (optional) | the security master | each portfolio's latest snapshot carried forward to the latest price date (`--as-of`, `--portfolios`): shares copied, weights drifted by adjusted-close returns; never changes an existing snapshot. Run it daily after `fmp-prices` to build portfolio weight history for attribution |

The per-symbol loaders (FMP, SEC submissions) work on securities that are in a benchmark or a portfolio;
`--symbols` picks others, `--all-securities` takes every active security (about 13,000 calls, roughly an hour
at 250 calls/minute), `--max N` caps the calls, `--force` refreshes recent rows.

### Logging

`-v` (verbose) also prints what each step does: the connection (and where the password came from, never the
password), downloads and cache hits, rate-limit waits, retries, every reject, identifier results per source, a
load's parameters and time, and a failing loader's full traceback. `-vv` (trace) also prints every HTTP request
with its status, size and time, and every SQL statement with its time. Give it before or after the command
(`./srm.py -v load ssga`, `./srm.py load fmp-prices -vv`), or set `SRM_VERBOSITY=1`. Detail lines are tagged
`[debug]` or `[trace]`; MxDataHUB's Data Refresh ▸ Log detail sets it for the refreshes it starts.

## Source limits (probed 2026-10-16)

| Source | Limit / availability |
|---|---|
| Nasdaq.com quote API | Free, no key: about two years of daily history per request for stocks, ETFs, closed-end funds (`assetclass=stocks` / `etf`) and mutual funds; closes only (no adjusted close); no dividend history for funds not listed on Nasdaq. Unofficial public endpoint: loaded politely at one request a second. |
| FMP (this key) | Available: `profile`, `search-isin`, `search-cusip`, stock and ETF lists, EOD history (5,000 rows per call), dividends / splits and their calendars, symbol changes, delisted companies (first page), index history for ^GSPC and ^DJI, full per-symbol dividend / split history. **Not on the plan (402):** dividend / split calendar windows older than about 12 months, S&P 500 / Nasdaq / Dow constituents and their history, `etf/holdings`, `profile-bulk`, `batch-quote`, ^NDX / ^MID / ^SP600 history, later pages of delisted companies. Comma-separated symbols return nothing, so profiles are one call per symbol. |
| OpenFIGI (this key) | 250 mapping requests per minute, 100 jobs per request. No ISIN lookup by design; mapping uses CUSIP or ticker. Preferreds, warrants and units often return "No identifier found". |
| SEC EDGAR | ≤ 10 requests/second; User-Agent with contact e-mail required. |
| GLEIF | Open data (CC0). ISIN→LEI file published daily; API 60 requests/minute. |
| SSGA SPDR files | Free daily holdings; current date only (history builds up one snapshot per load). |
| Nasdaq.com | Free Nasdaq-100 list with market caps; no official weights. |

## Benchmarks

| Benchmark | Built from | Notes |
|---|---|---|
| S&P 500 | SPY holdings | ETF weights as a proxy for index weights (full replication); level ^GSPC |
| Dow Jones Industrial Average | DIA holdings | price-weighted; level ^DJI |
| S&P MidCap 400, SmallCap 600 | MDY, SPSM holdings | no levels on the FMP plan |
| Nasdaq-100 | Nasdaq.com list | official members; plain market-cap weights, not Nasdaq's modified-cap weights; no ^NDX levels on the plan |
| Custom | `build_benchmark` | equal or cap weighted, optionally one sector, from any loaded benchmark |

Not buildable with these sources: official S&P / Dow Jones / Nasdaq weights (licensed; FMP constituent endpoints are not on the plan),
Russell indexes (licensed; iShares files were blocked when probed), MSCI / FTSE / STOXX (licensed, and the loaded universe is US),
and constituent history before the first load.
