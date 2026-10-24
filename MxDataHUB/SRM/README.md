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
| Prices in dollars (V021) | FX series DEXUSUK (dollars per pound) and DEXCAUS (Canadian dollars per dollar) from FRED in `market_series` (family FX); `fx_to_usd(currency, date)`; `last_price` answers in dollars — a current USD listing, else the freshest listing converted at that day's rate, else the primary listing in its own currency — so a London line (fmp-symbols) is never valued in pounds as dollars by `portfolio_valuation`, the accounts views or MxDataHUB |
| Relations (V019) | `security_relation` (unit → share / warrant / right with quantity per unit; warrant / right → underlying share; room for exercise price and expiry) |
| Bonds (V018) | `bond_terms` (class treasury / agency / corporate / municipal, kind, issuer, coupon, frequency, floating, inflation-linked, callable, original issue / dated / maturity / first coupon dates, term, amount outstanding and offered, auctions, FRN spread, TIPS reference CPI); view `v_bond` (with CUSIP, ISIN, years to maturity, latest price). Corporate and agency bonds (FINRA TRACE) are planned: they need a FINRA API account |
| Fund families (V016) | `fund_profile` (a fund share class as its family lists it: family fund id, share class, mutual fund / ETF / money market, index, closed, style, category, expense ratio, inception, first and last seen); view `v_fund_family` (each fund with its latest NAV, first NAV date and NAV days — to check a load against the family's list) |
| Market series (V015) | `market_series` (VIX9D, VIX, VIX3M, VIX6M from Cboe; Treasury constant-maturity DGS1MO … DGS30 and the NBER recession indicator USREC from FRED), `market_series_value` (one value a day — open / high / low / close for the VIX family — or a month for USREC); view `v_market_series_summary` |
| Company fundamentals (V015) | `fundamental_watch` (the companies `fmp-fundamentals` keeps: MxPortMGR's Compute theme, 5 hyperscalers and 7 suppliers — add rows for more), `fundamental_quarter` (per symbol and quarter end: fiscal year / period, filing date, revenue, operating income, operating cash flow, capex as a positive amount, D&A, free cash flow; `security_id` from `us_security`) |
| Links (V014) | `security_link`: a link on a security's ticker or name (address, words, hover text plain and RTF, MxNoteONE title, updated at / by) — MxDataHUB's Securities and Holdings, MxPortMGR's Earnings by Day and My Holdings; `us_security(ticker)`: the current U.S. listing of a ticker spelled BRK.B, BRK-B or BRK/B |
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
| `earnings-symbols` | FMP `earnings-calendar` + `profile`, then OpenFIGI | Securities for the companies in FMP's earnings calendar (a week back to three weeks ahead, or `--since`) that the security master lacks — OTC shares of foreign companies, ADRs, small OTC banks, preferreds, warrants — from their FMP profile: name, type, listing (OTC → OTCM), ISIN, CUSIP, issuer with CIK, sector, market cap (not for preferreds, warrants and notes, whose FMP profile carries the issuer's); then composite / share-class / venue FIGIs from OpenFIGI for those securities. `--symbols` names them. MxPortMGR's Earnings by Day shows their names |
| `openfigi` | OpenFIGI mapping (by CUSIP, else ticker) | composite, share-class and exchange-level FIGIs; refines security type |
| `fmp-profiles` | FMP `profile` | ISIN, CUSIP, CIK, sector / industry, country, currency, market cap; then derives US ISINs from CUSIPs |
| `sec-submissions` | SEC submissions | SIC, state of incorporation, EIN, fiscal year end, former names |
| `gleif` | GLEIF ISIN→LEI file + LEI records API | LEI, legal form, entity status, legal / HQ country |
| `massive-prices` | Massive Flat Files (formerly Polygon.io; `us_stocks_sip/day_aggs_v1`, S3 at files.massive.com, keys in the Keychain `SRM-api` / `massive-s3-access`, `massive-s3-secret`) | **Every U.S. exchange-listed security's daily bar** (no OTC tickers: those come from `fmp-otc-prices`) — about 12,600 tickers a day in one ~320 KB file: open, high, low, close, volume (not adjusted). Matched to current U.S. listings in Massive's spelling, then SRM's (`ABRpD` → `ABR-PD`, `.WS` → `.W` / `-WT`, NYSE rights `r` → `.R`; one bar per listing a day, the exact spelling first); 99.8% match. Days since the last Massive price; `--since` (default 2 years, the plan's history) the first time. Runs first in Prices; FMP still prices benchmark and portfolio members with adjusted closes |
| `fmp-prices` | FMP `historical-price-eod/full` | EOD prices (default 2 years; incremental afterwards) |
| `fmp-otc-prices` | FMP `historical-price-eod/full` | **Every current OTC listing** (`fmp-prices --otc`): ADRs and the ordinary "F" lines of foreign companies, which Massive's day files don't carry and `earnings-symbols` creates without prices. Each listing gets its own prices (BAESF in dollars, not BAE's London line), two years the first time, then the days since its last FMP price; runs daily in Prices after `fmp-prices`. London / Toronto lines are refreshed by rerunning `fmp-symbols` |
| `nasdaq-prices` | Nasdaq.com quote API (free, no key) | EOD prices for the **stock and bond funds** (ETFs, ETNs, closed-end and mutual funds) held in portfolios and personal accounts, and for any benchmark or portfolio security without a price in the last 5 days (the fallback when `fmp-prices` can't run); `--funds` every active fund (~6,100, about 2 hours at one request a second), `--symbols`, `--all-securities`; closes, not dividend-adjusted |
| `vanguard-funds` | Vanguard's product list (the JSON behind investor.vanguard.com's *All products* page; free, no key) + Nasdaq.com | **Every Vanguard mutual fund** share class (267 on 2026-10-23: Investor, Admiral, Institutional, money market) as a `Mutual Fund` on MIC XXXX with ticker, CUSIP and ISIN; its profile in `fund_profile` (Vanguard fund id, share class, category, expense ratio, inception; ETFs too, when the listed universe has them); the day's **NAV** (source `VANGUARD`, one request for all funds); NAV history from Nasdaq.com from 2000 (`--since`) for new funds and after missed days. `--symbols` some funds, `--history` asks Nasdaq.com for every fund. Runs in Prices after `nasdaq-prices` |
| `trust-navs` | Your plan statements (`trusts.local.json`) + a proxy index fund | **Collective investment trusts** (401(k) "Trust Unit A" funds: no ticker, no public price feed, free or paid): each statement NAV, and every other day the latest earlier NAV × the proxy fund's return since then (source `PROXY`). Copy `trusts.example.json`; runs in Prices after `nasdaq-prices` |
| `mutual-funds` | Nasdaq.com fund network (free, no key) | Adds **mutual funds** (e.g. VTIFX) on demand — `--symbols VTIFX …` or `--search "fund name"` — as `Mutual Fund` securities on MIC XXXX, then loads their prices. The accounts service does the same when Add Securities finds no match. Not part of `load all` |
| `fmp-index-levels` | FMP | benchmark levels (^GSPC, ^DJI on the current plan) |
| `fmp-corporate-actions` | FMP calendars, symbol changes, delistings | dividends, splits, symbol changes, delistings; `--history` adds each security's full dividend / split history |
| `listed-derivatives` | the listed universe + FMP `profile` and `historical-price-eod` + Nasdaq.com | **Units, warrants, rights and tracking stocks** made complete: units named as units are typed Unit (NYSE's `.U` were Warrant / Right); `security_relation` links each unit to its share, warrant and right and each warrant / right to its share (from the ticker: Nasdaq base + W / WW / U / R, NYSE base.WS / .W / .U / .R / .RT, only when the share has the same issuer or name), with quantities from the name where stated ("one-half of one redeemable warrant"); missing issuers from the share; CUSIP (only when inside the ISIN and not the share's), ISIN and FMP sector — no market cap; FMP symbol (NYSE `.U` → `-UN`, `.R` → `-RI`, `.W` / `.WS` → `-WT`); end-of-day prices from FMP, then Nasdaq.com for any left without one. Exercise prices and expiries aren't in these sources. NYSE warrants have no prices in either source |
| `treasuries` | TreasuryDirect securities API + the Treasury's FedInvest prices (free, no key) | **Every outstanding U.S. Treasury** — bills, cash management bills, notes, bonds, TIPS, FRNs (470 on 2026-10-23) — as `Bond` securities of the U.S. Treasury on MIC XXXX under their CUSIP, with CUSIP and ISIN; terms in `bond_terms` (kind, coupon, frequency, original issue / dated / maturity dates, term, auctions, amount offered and, where TreasuryDirect gives it, outstanding, FRN spread, TIPS reference CPI); matured ones made inactive; end-of-day prices per 100 of par from FedInvest (source `FEDINVEST`) for each business day since the last, from `--since` (default 30 days) the first time, one request every 2 seconds |
| `cboe-vix` | Cboe daily history files (free, no key) | VIX9D, VIX, VIX3M, VIX6M open / high / low / close since each index began (VIX 1990); every file is the whole history, upserted so only new or revised days change; `--since` keeps only later days |
| `fred-yields` | FRED `fredgraph.csv` (free, no key) | Treasury constant-maturity yields DGS1MO … DGS30 (daily, from 1962), the FX rates DEXUSUK and DEXCAUS (daily, from 1971; V021) and USREC (monthly); after the first load only the last 60 days (FRED revises recent days; USREC the last 400), `--force` the whole history, `--since` from a date |
| `fmp-fundamentals` | FMP `cash-flow-statement` and `income-statement` (`period=quarter`) | quarterly revenue, operating income and cash flow, capex, D&A and free cash flow for `srm.fundamental_watch` (or `--symbols`): 40 quarters the first time, then the last 8 (restatements) unless `--force`; 2 calls a company |
| `portfolio-snapshots` (optional) | the security master | each portfolio's latest snapshot carried forward to the latest price date (`--as-of`, `--portfolios`): shares copied, weights drifted by adjusted-close returns; never changes an existing snapshot. Run it daily after `fmp-prices` to build portfolio weight history for attribution |
| `fmp-symbols` (optional) | FMP `profile` and `historical-price-eod/full`, then OpenFIGI | **Any security by its FMP symbol** (`--symbols JMAT.L JMPLY JMPLF`) — companies the universe loaders don't carry: listed abroad, or traded in the U.S. only over the counter without SEC filings. One issuer per company (by CIK, else name); the ordinary shares are one security with a listing per venue (the home market, e.g. LSE → XLON, added to `srm.exchange_code_map`; the OTC "F" line as a second listing, its stale FMP ISIN not recorded); an ADR is a security of its own with its ISIN and CUSIP. TICKER and FMP_SYMBOL per listing, sector, industry, description, market cap (dollar quotes only); two years of prices per listing (`--since`), London's pence stored as GBP. `--min-cap N` screens FMP instead: every actively traded OTC line of a company worth $N or more that srm lacks; `--home` adds each company's London / Toronto line (by ISIN, else name) — the only home markets the FMP plan prices (Amsterdam, Zurich, Paris, Frankfurt, Tokyo answer 402), so other companies get their OTC lines only. One issuer per company: the CIK any of its lines carries (a security on a name-only issuer moves to it). Runs 2026-10-24: Johnson Matthey (load 210); `--min-cap 10000000000 --home` (load 215): 533 OTC lines and 46 London / Toronto lines, 523 securities (268 ADRs, 245 ordinary), 287,465 prices — not in the daily refresh: rerun to update prices |
| `sample-portfolios` (optional) | the security master + FMP `historical-price-eod/full` | **MxPortMGR's sample accounts** (`SAMPLE_CORE_SATELLITE` … `SAMPLE_MISSING_DATA`, managed by "MxPortMGR samples"): real securities, tax lots costed at FMP's close on each purchase date (prices loaded back to the oldest lot first), cash, account type, approach and benchmark; and the blended benchmarks **BAL6040** / **BAL3070** (VTI / BND, provider MxPortMGR, month-end snapshots for two years; left out of the freshness checks). Rerunning rewrites them; a holding with no price is rejected (ACVA in the missing-data sample, on purpose) |

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
| FMP (this key) | **750 calls a minute** (plan upgraded from 300 on 2026-10-24; FMP answers 429 "Limit Reach … upgrade your plan" for any limit). The loaders share one budget of 600 a minute per process and back off 5–40 s on a 429; the accounts service uses the same key in its own process. Available: `profile`, `search-isin`, `search-cusip`, stock and ETF lists, EOD history (5,000 rows per call), dividends / splits and their calendars, symbol changes, delisted companies (first page), index history for ^GSPC and ^DJI, full per-symbol dividend / split history. **Not on the plan (402):** dividend / split calendar windows older than about 12 months, S&P 500 / Nasdaq / Dow constituents and their history, `etf/holdings`, `profile-bulk`, `batch-quote`, ^NDX / ^MID / ^SP600 history, later pages of delisted companies. Comma-separated symbols return nothing, so profiles are one call per symbol. |
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
