# MxPortMGR — Logical Data Model

**Scope.** What MxPortMGR, the teaching portfolio IDE, works with: an **illustrative market** (36 fictional companies,
bond funds, individual bonds, cash and look-through index funds, three benchmarks, a year of monthly history), the
**accounts** it teaches on (ten samples and My Portfolio) with their holdings and tax lots, the **market reports**
and the **reactions** the Behaviour Lab simulates, and the **results** of its engines — active optimization, index
tracking, risk, attribution and long-run simulation.

Today the market, samples and reports are Swift constants, My Portfolio is JSON in UserDefaults, and results live in
memory. My Portfolio in *security-master mode* is already in PostgreSQL as an `srm.portfolio` with
`srm.portfolio_tax_lot` (MxDataHUB V011), written through the accounts service — this model refers to it by code and
does not duplicate it as a record of truth. Physical form: [`ddl/`](ddl/README.md) (seeded from the app's own model
by `tools/generate_seed.sh`); diagrams: [erd.md](erd.md).

> Educational only: the companies, prices, forecasts and releases are illustrative, not market data or advice.

## 1. Conventions

| Topic | Rule |
|---|---|
| Identity | Natural keys as the app uses them: ticker, benchmark code, account id (`core-satellite`, `my-portfolio`), report id (`cpi`), reaction id within its report. Engine runs get a surrogate `run_id`. |
| Numbers | `double precision` — the app computes in `Double`; weights, returns and rates are fractions (0.05 = 5 %), money in dollars. |
| Tickers in holdings | Not foreign keys on purpose: an account may hold a security nobody knows (the *Missing & Messy Data* sample's OLDCO), which the checks report rather than the database refusing. Universe tables (benchmark weights, look-through, returns) do use FKs. |
| Security-master data | Securities and benchmarks brought in from srm are cached with `source = 'srm'` and their srm key; a ticker that clashes with the illustrative universe is keyed `TICKER:MIC`. |
| Results | Each engine run is an `engine_run` (what, which engine, when, the holdings it saw as JSON) with a 1:1 result entity per analysis, enforced by `(run_id, analysis)`. |

## 2. Subject areas

| Area | Entities |
|---|---|
| A. Code lists | Asset Class, Sector, Model Parameter, Sleeve, Price Driver, Report Tier, Scenario |
| B. Illustrative market | Security, Bond Terms, Fund Look-Through, Benchmark, Benchmark Weight, Market Month, Security Month Return |
| C. Accounts | Account, Account Look-For, Holding, Tax Lot, Account Missing Return, App Setting |
| D. Market reports | Market Report, Report Text, Report Line, Report Term, Report Asset Move, Report Driver, Report Factor Move, Report Context Series / Point, Report Reaction, Reaction Move |
| E. Engine results | Engine Run; Optimization (+ Weight, Trade, Constraint, Sector, Tax Estimate, Tax Estimate Line); Risk Report (+ Contribution); Attribution (+ Group, Period, Contributor, Note); Simulation (+ Outcome, Path, Missing Best) |

## 3. Entities

### A. Code lists

| Entity | Values |
|---|---|
| Asset Class | equity (Stocks), bond (Bonds), cash (Cash) |
| Sector | Technology, Health Care, Financials, Consumer Discretionary, Consumer Staples, Industrials, Energy, Utilities, Real Estate, Materials, Communication Services (equity); Fixed Income; Cash; Fund, Diversified Fund; Unclassified, Unknown |
| Model Parameter | risk-free 3 %, equity premium 5 %, market vol 16 %, sector vol 7 %, rate vol 0.9 % |
| Sleeve | stocks, single (one company), bonds, cash — what reactions move money between |
| Price Driver | growth, inflation, rates, profits, sentiment |
| Report Tier | 1 market-moving economic · 2 growth · 3 corporate · 4 positioning · 5 fixed income · 6 industry |
| Scenario | random, fastCrash (2020-like), longBear (2007–09-like), bothFall (2022-like) |

### B. Illustrative market

**Security** — identifier: ticker. Attributes: name; kind (`company`, `bond_fund`, `bond`, `index_fund`, `cash`, `srm`);
sector; asset class; price (per share, or per 100 face for a bond); factor exposures — beta (market), rate beta
(≈ −duration), own volatility; market cap ($bn, for cap weights); illustrative alpha forecast; yield; fee (expense
ratio). For srm securities: security_id, plain ticker, price date, security type.

**Bond Terms** (0..1 per security) — issuer type, coupon, maturity, rating (`AA+`, `BBB-`, …) for individual bonds.

**Fund Look-Through** — what an index fund holds: (fund, member, weight), weights summing to 1. MXTM holds the 36
companies at cap weight, MXBD five bond funds, MXTK the technology companies.

**Benchmark** — code (`MXEQ`, `MX6040`, `MX3070`, or a cached srm code), name, summary, source. **Benchmark Weight** —
(benchmark, base security, weight), summing to 1.

**Market Month** — the twelve months attribution explains (2025-11 … 2026-10) with the market return and change in
yields. **Security Month Return** — each base security's return in each month (factor model + seeded noise).

### C. Accounts

**Account** — identifier: account id. Attributes: name; account type (`taxable`, `retirement`, `roth`); benchmark;
style (`active`, `passive`, `either`); sample flag; lesson (the edge case it teaches) and ordered **Look-For** notes;
trading pattern (`buyAndHold`, `trader` — how holdings change through the attribution year); symbol; source
(`illustrative`, `srm`) and srm code. Rules: an srm account has an srm code and is not a sample.

**Holding** — (account, ticker): market value, shares when known, unpriced flag (stale or missing price).
Weight = value / account total (derived).

**Tax Lot** — (account, ticker, acquired, cost): share of the holding's value (lots of a holding sum to 1) and cost
basis in dollars. Long-term when held over 365 days (derived).

**Account Missing Return** — a base security with no returns from a month on (attribution reports a data gap and
says *review*).

**App Setting** — per-Mac preferences (screen, sample, approaches, collapsed lessons, data source, srm account code).

### D. Market reports

**Market Report** — identifier: report id (`jobs`, `cpi`, `ppi`, `fomc`, `gdp`, `ism-manufacturing`, …, `energy`).
Attributes: title, symbol, source line, headline, tier, publisher, frequency, typical impact (1–3), rank among the
"five most important" (unique, 1–5), the day's market move and rate move, the company it is about (corporate reports),
the sample account the walkthrough is written for.
Owns: ordered **Report Text** lists (reading guide, key metrics, why PMs care, takeaways), **Report Lines** (figure,
as released, expected, what it means), **Terms**, **Asset Moves** (what each market did and why), **Drivers** it
moves, **Factor Moves** (sector and company shocks applied through the factor model to any account), an optional
**Context Series** with points (line or bar, reference line).

**Report Reaction** — (report, reaction id): title, symbol, summary, what happens after (`revert` after the lab's
months, `permanent`, `rebalanceToPlan` at the yearly rebalance), optional repeat-on-drawdown threshold. Reaction ids
recur across reports (`every-time`, `sell-single`) with report-specific wording, so the report is part of the key.
**Reaction Move** — ordered (from sleeve, to sleeve, fraction). *Stay with the plan* has no moves and is not stored as
a reaction (it is every simulation's baseline, `reaction_id = 'plan'`).

### E. Engine results

**Engine Run** — account, analysis (`active_optimization`, `index_tracking`, `risk`, `attribution`, `simulation`),
engine (`builtIn` Swift or `services` — then the Layer 3 service id), benchmark, holdings seen (JSON), time taken.

**Optimization** — settings (active: largest position, largest active weight, sector band, tracking-error target,
risk aversion, turnover limit; tracking: max names, `stratified` / `largest` selection, tracking-error budget,
turnover) and outcome (status, tracking error now and after, forecast active return, information ratio, active
share, turnover, names, λ, method, benchmark covered) with the **decision** (`rebalance`, `rebalance_partially`,
`hold`, `rerun_relaxed`, `escalate`) and reason. Children: proposed **Weights**, **Trades** (from → to, route
`direct` / `fund` / `new`), binding **Constraints**, sector **active weights**, and a **Tax Estimate** (lot order
FIFO / highest-cost-first, how far to go, rates, tax, funds traded through) with **Lines** per lot sold (gain or
harvestable loss, short- or long-term).

**Risk Report** — volatility (account, benchmark), tracking error, beta, one-month 95 % VaR and expected shortfall,
expected return, rate sensitivity, diversification ratio, concentration; **Contributions** by security, sector and to
active risk (weight, share of risk).

**Attribution** — method (`brinson-fachler`, `brinson-hood-beebower`), data source (sample, or a security-master
portfolio by code), account / benchmark return, allocation, selection, interaction, residual, data gap,
recommendation (`publish` / `review`), highlight; **Groups** (by sector), **Periods** (by month), top / bottom
**Contributors**, **Notes** (reasons for review, assumptions).

**Simulation** — the report, years (10 / 20 / 30), futures (100 / 300 / 1,000), months out, trading-cost rate,
taxable flag and long- / short-term rates, scenario, seed, starting value. **Outcomes** — one per strategy (the plan
and each reaction): median, 10th and 90th percentile ending value, annual return, median taxes and costs, tracking
error vs the plan, missed best days, share of futures ahead of the plan, median worst drop, trades; each with a
monthly **Path** (median, low, high). **Missing Best** — annualised stock return when the best N days are missed.

## 4. Relationships (cardinality)

| Parent | Child | Cardinality | Delete rule |
|---|---|---|---|
| Sector, Asset Class | Security | 1 : 0..n | restrict |
| Security | Bond Terms | 1 : 0..1 | cascade |
| Security (fund) | Fund Look-Through | 1 : 0..n | cascade |
| Benchmark | Benchmark Weight | 1 : 1..n | cascade |
| Market Month × Security | Security Month Return | n : m | cascade from security |
| Benchmark | Account | 1 : 0..n | restrict |
| Account | Look-For, Holding, Missing Return, Engine Run | 1 : 0..n | cascade |
| Holding | Tax Lot | 1 : 0..n | cascade |
| Report Tier | Market Report | 1 : 0..n | restrict |
| Account | Market Report (suggested sample) | 0..1 : 0..n | restrict |
| Market Report | texts, lines, terms, moves, drivers, factor moves, context, reactions | 1 : 0..n | cascade |
| Report Reaction | Reaction Move | 1 : 0..n | cascade |
| Engine Run | Optimization / Risk Report / Attribution / Simulation | 1 : 0..1 (by analysis) | cascade |
| Market Report | Simulation | 1 : 0..n | restrict |
| Simulation | Outcome | 1 : 1..n | cascade |
| Report Reaction | Simulation Outcome | 0..1 : 0..n (null for the plan) | restrict |

## 5. Derived data (views)

| View | Gives |
|---|---|
| `v_holding` | Holdings with weight, cost basis (lots, else value), sector, asset class, fee, unknown flag |
| `v_look_through` | Weights over base securities with funds replaced by their members (unknown tickers left out) |
| `v_account_sector`, `v_account_asset_class` | Look-through sector and asset-class weights beside the benchmark's |
| `v_account_summary` | Value, cost, unrealised gain, weighted fee, holdings, active share |
| `v_account_issue` | The checks under the holdings (§6) |
| `v_tax_lot`, `v_tax_lot_mismatch` | Lots with value, gain and holding period; holdings whose lots don't sum to 1 |
| `v_report_catalogue` | Reports with tier, drivers and number of reactions |

## 6. Business rules (Portfolio checks, `v_account_issue`)

| Level | Rule |
|---|---|
| error | A holding the market doesn't know (left out of every calculation). |
| error | A holding without a current price (its value, and every weight, may be wrong). |
| warning | A single company over 20 % of the account. |
| warning | A sector over 15 % and more than twice the benchmark's weight (look-through). |
| warning | Over 5 % in asset classes the benchmark doesn't hold (pure active risk against it). |
| warning | Months of missing returns (attribution says *review*). |
| note | Over 10 % in cash. |

Other rules: lots of a holding sum to 1; a security-master account's record of truth is `srm.portfolio` /
`srm.portfolio_tax_lot`; trade-list taxes apply only to taxable accounts; a passive account's attribution effects
should all be close to zero (the check-up reading).
