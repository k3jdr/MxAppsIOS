# MxPortMGR

A portfolio-management IDE for macOS that **teaches**: it walks you through setting up an **actively managed** or a
**passive index** portfolio for personal accounts, explaining *why* each step — optimization, risk, tracking,
rebalancing, attribution — matters before showing the numbers, and lets you simulate what everyday reactions to market
news cost over the long run.

> **Educational only.** The companies, prices, reports and futures are illustrative — made up in the shape of real
> ones. Nothing in MxPortMGR is investment, tax or financial advice, a forecast, or a recommendation to buy or sell
> anything. The status bar says so on every screen.

Sixth app in the MXcodeIDE family, next to MxJobsWMS, MxDataHUB, MxDataSQL, MxNoteONE and MxFileMGR. It re-implements
MxDataHUB's portfolio optimization and attribution (which MxDataHUB hands to MxJobsWMS workflows and the Layer 3
services) as interactive, explained steps, and can run them through the same **Layer 3 services** in `../Services`.

## The window

One window (`MxPortMGR`, 1440 × 900 by default):

| Area | What it holds |
| --- | --- |
| **Sidebar — the guide** | Six groups: Start Here, Learn the Why, **My Portfolio** (6 steps, your own account), **Model Portfolio** (5 steps on a sample; Active or Passive index), Market Reports, Library. |
| **Quick Help** (bottom of the sidebar) | The shared MXcodeIDE Quick Help pane (`Shared/QuickHelp`): what's under the pointer — a metric, a column, a chart, a limit, a reaction — then what's selected (the account), then the screen. Its ⧉ button floats it in a window of its own; closing that window docks it again. |
| **Toolbar** | **Account** — the sample (or My Portfolio) every screen works on. **Engine** — *Built-in (Swift)* or *Layer 3 services*. |
| **Screen** | A title, a collapsible yellow **"Why this step"** lesson (remembered per screen), the step's controls and results, and **Back / Next** along the guide. |
| **Status bar** | The account, its type, value and benchmark; the last action (e.g. "Optimized with Built-in (Swift) in 134 ms"); the educational-use banner. |

Every control has a `.help` tooltip and a Quick Help entry (`.quickHelp` / `.quickHelpArea`), following the
convention of the other apps; glossary terms (tracking error, active share, information ratio, VaR, allocation /
selection / interaction, turnover, rebalance band, look-through, tax lot, Carino linking) use `.term(_:)`, which
gives both.

## Menus

| Menu | Items |
| --- | --- |
| **Guide** | Welcome ⌘0 · Choose Your Path · Learn the Why ▸ · My Portfolio steps 1–6 ⌥⌘1–⌥⌘6 · Model Portfolio steps 1–5 ⌘1–⌘5 and Model Type ▸ Active / Passive Index · Active Portfolio steps ⌘1–⌘5 · Passive Index Portfolio steps ⌥⌘1–⌥⌘5 · Sample Portfolios ⇧⌘L · Layer 3 Services ⌥⌘L |
| **Portfolio** | Account ▸ (every sample and My Portfolio) · Optimize (Active) ⌘R · Build Index Tracker (Passive) ⇧⌘R · Run Attribution ⇧⌘A · Engine ▸ · Copy Account to My Portfolio · Reset My Portfolio |
| **Reports** | Report Library ⌥⌘R · Morning Briefing ⌥⌘M · The Five Most Important (CPI, Jobs, FOMC, Earnings, ISM Manufacturing) ⌃⌘1–⌃⌘5 · one submenu per tier (Tier 1–6) with every report · Simulate the Long Run ⌘↩ |
| **View** | Quick Help ⌥⌘/ · Float / Dock Quick Help (shared `QuickHelpCommands`) · Previous Step ⌘[ · Next Step ⌘] |

## The guide

### Start Here and Learn the Why

* **Welcome** — what the app teaches and how to use it.
* **Choose Your Path** — four questions (edge after costs, tolerance for differing from the market, time, taxes) set
  against each approach, and a start button for each path with its own sample. It does not choose for you.
* **Why Optimize?** — two live demos: diversification (volatility of 1–36 equal-weighted companies falling to the
  market's floor) and the stock / bond trade-off (the risk–return line of every mix); then what an optimizer does
  with forecasts, a risk model and limits, and why limits matter ("error maximisation").
* **Why Attribution?** — a two-sector Brinson-Fachler demo with sliders: allocation, selection and interaction recomputed
  as you move the weights and returns.
* **Active vs Passive** — what fees compound to over 30 years (fee and pre-fee alpha sliders) and a comparison table.

### My Portfolio path

The clear path for your own account, in six steps. Every My Portfolio
step works on **My Portfolio** (the toolbar's Account picker is fixed to it), and a bar at the top of each step shows
the account and sets **My approach** — *Active* or *Passive index* — its account type, and **Start From a Sample**
(copy any sample's holdings, lots and benchmark) or reset to the three-fund starter.

**Add Securities…** (⇧⌘N, above the holdings table) opens a dialog listing every security in the illustrative
universe — the 36 companies, **individual bonds** (U.S. Treasury notes and bonds from 2028 to 2056, a TIPS, investment-
grade and high-yield corporates, a California general-obligation muni), the bond and index funds, and cash. Search by
ticker, name or issuer, filter by type and sector, and select one for its details (price or price per 100 face,
coupon, maturity, rating, yield, duration, beta, model volatility and expected return, and what kind of security it
is). Add it by dollar amount, shares or face value, optionally with a tax lot (cost basis and purchase date); adding a
security already held adds to the position and its lots. Each holding row has a trash button to remove it.

1. **My Holdings** — add, edit and remove holdings (shares, values, tax lots); asset mix; checks.
2. **My Benchmark** — choose the benchmark that matches your plan; sector and asset-mix comparison, overlap, active
   share, the names you hold in it and its 25 largest members.
3. **Risk Today** — your account's volatility, tracking error, beta, VaR and where the risk comes from.
4. **Optimize** (active) or **Build the Tracker** (passive).
5. **Trades & Taxes** (active) or **Rebalance Bands** (passive).
6. **Attribution** — read as an active or a passive account, by approach.

Steps 4 and 5 change name and screen with the approach (in the sidebar too). *Copy to My Portfolio* on a sample, the
Portfolio menu's *Copy Account to My Portfolio* and Choose Your Path's *Start My Portfolio* all lead here.

#### My Portfolio in the security master

The bar's **Data** switch chooses where My Portfolio lives:

* **Illustrative universe** — the made-up market the samples use, remembered on this Mac.
* **Security master (srm)** — real securities, prices and benchmarks in MxDataHUB's PostgreSQL database (`srm` on
  192.168.0.223), through the **accounts** Layer 3 service (`Services/accounts`, port 8774; start it with
  `python3 Services/mxservices.py start`). The account is an `srm.portfolio` with an account type, approach, cash
  balance and open **tax lots** (`srm.portfolio_tax_lot`, migration V011); every change is saved a moment later (or
  with **Save**), and the day's holdings snapshot is rewritten from the lots, so MxDataHUB ▸ Portfolios shows it (with
  a Tax Lots view and *Open in MxPortMGR*) and the analytics service can analyse it. **Account** names the code
  (default `MY_PORTFOLIO`); **Open** lists the personal accounts already there.

In security-master mode **Add Securities…** searches srm by ticker, name, ISIN or CUSIP (stocks, funds, bond funds)
across all 13,000-odd active securities, 200 at a time (*Show More*), largest companies first. Click any column header
(Ticker, Name, Type, Sector, Exchange, Price, As of, Market value) to sort by it — in the database, across every match —
and use the **filter row** like a spreadsheet's autofilter: ticker / name contains, Type, Sector and Exchange menus of
values with their counts (tick several), a price range, and with / without a price; a filtered column's title shows ⏷
and *Clear Filters* resets. Select a security for its sector, latest price and date, beta, market value and
identifiers, and add shares with a tax lot (cost and purchase date). Holdings without prices are valued at cost and flagged; **Load Prices** asks the srm-loader
service to load them (`srm.py load fmp-prices --symbols …`, which needs an FMP API key in SRM's configuration). The
benchmark is any benchmark loaded in srm (S&P 500, Nasdaq-100, Dow, S&P 400 / 600, custom); Risk, Optimize and Build
the Tracker use the analytics service's Ledoit-Wolf covariance from two years of srm prices (holdings without enough
price history and cash are left out and listed), and Attribution uses its `/attribution` for the account's code.
Securities whose tickers clash with the illustrative universe show as `TICKER:MIC` internally.

`mxportmgr://my-portfolio/CODE` (from MxDataHUB or MxJobsWMS ▸ Window ▸ Open MxPortMGR) opens My Portfolio on that
security-master account.

### Model Portfolio

The Active and Passive paths are one **Model Portfolio** section that works on the sample accounts. A bar at the top of
each step sets the **Model type** — *Active* or *Passive index* — and the **Sample**, and offers *Copy to My Portfolio*
(continuing at the same My Portfolio step). The sidebar's five steps follow the type:

| Step | Active | Passive index |
| --- | --- | --- |
| 1 | Portfolio & Benchmark | Portfolio & Index |
| 2 | Risk Today | Tracking Error & Drift |
| 3 | Optimize | Build the Tracker |
| 4 | Trades & Taxes | Rebalance Bands |
| 5 | Attribution | Attribution |

Switching the type keeps you on the same step; choosing My Portfolio as the account moves to the same My Portfolio step.

#### Active model type

1. **Portfolio & Benchmark** — value, holdings, look-through securities, weighted fee, unrealised gain; benchmark
   picker; *Check before you go on* (unknown or unpriced holdings, a single name over 20%, a sector more than twice
   the benchmark, asset classes the benchmark doesn't hold, idle cash, missing returns); look-through sector and
   asset-mix bars against the benchmark; the holdings table with tax lots (editable for My Portfolio).
2. **Risk Today** — volatility, tracking error, beta, one-month 95% VaR and expected shortfall in dollars, rate
   sensitivity; weight vs share of risk; risk by sector; what drives tracking error.
3. **Optimize** — tracking-error target (or risk aversion), largest position, largest active weight, sector band,
   turnover limit → decision (hold / rebalance / rebalance part of the way / relax a limit), tracking error,
   information ratio, forecast active return, active share, turnover, names, binding limits, largest changes and
   sector active weights.
4. **Trades & Taxes** — turnover, trading cost, realised long- and short-term gains, estimated tax; a *How far to go*
   slider (part of the way); the trade list (direct, through a fund, new); taxes by lot with FIFO or highest-cost-first
   and adjustable illustrative rates, tax-loss harvesting and wash-sale notes.
5. **Attribution** — account, benchmark and active return; allocation, selection, interaction by sector (bars and
   table) and month by month; top and bottom contributors; assumptions; *publish* or *review* with reasons.

#### Passive index model type

1. **Portfolio & Index** — the same screen, read for tracking.
2. **Tracking Error & Drift** — tracking error today and after a year untouched, month by month for the account and for
   a 20-name tracker set up today; the six names that drift most; why trackers drift.
3. **Build the Tracker** — names (3 to all), stratified or largest-weight selection, tracking-error budget → decision,
   the tracking-error-vs-names curve, sector gaps, *Three ways to be passive* (today's account, the N-name tracker,
   one index fund — with tracking error, fee, trades and the tax of switching), trades.
4. **Rebalance Bands** — ± points or ± 25% of target, trade back to the target or the band's edge; each class on its
   band; the stock share through the year; holding-level trades and their taxes.
5. **Attribution** — read as a check-up: for a passive account every effect should be close to zero.

### Market Reports

The hierarchy of reports portfolio managers, hedge funds, pension funds and mutual-fund managers watch — some move
markets within seconds, others shape positioning over weeks or months.

* **Report Library** — every report by tier as a card (publisher, schedule, key metrics, why PMs care, the price
  drivers it moves, typical impact), **If you had to pick five** (CPI, Nonfarm Payrolls, FOMC, earnings and guidance,
  ISM PMI — together they drive expectations for growth, inflation, interest rates and profits, the four primary
  determinants of asset prices), and a report × driver matrix.
* **Morning Briefing** — an illustrative morning's ten items: overnight markets, Treasury yield changes (with the
  2Y–10Y and 3M–10Y spreads), the economic calendar (consensus, prior, impact; each release opens its walkthrough),
  an economic surprise index, Fed funds futures probabilities, analyst upgrades and downgrades (fictional firms),
  earnings releases (marked "you hold"), weekly fund flows, credit spreads and the VIX — with what the selected
  account would be worth if it opened with the futures. Each panel says what it measures and how a long-term investor
  might use it.
* **Report Walkthrough** — one report at a time (the sidebar row shows which; the **Report** menu at the top of the
  page or the Reports menu picks another), in seven steps — **The Report** (with *About this report*), **Reading It**,
  **The Market's Move** (with a context chart: core CPI by month, ISM against its 50 line, auction tails, weekly
  flows…), **Your Account**, **Your Reaction**, **The Long Run**, **Takeaways**.

| Tier | Report | The illustrative release | Written for |
| --- | --- | --- | --- |
| 1 | **Jobs Report** (#2 of the five) | Payrolls +48,000 vs +150,000, unemployment 4.6%, downward revisions | Cash-Heavy |
| 1 | **CPI Inflation Report** (#1) | Core +0.5% m/m, 3.4% y/y; 2-year yield +0.20; growth stocks −4% | Sector-Heavy Technology |
| 1 | **PPI Producer Prices** | Final demand +0.7%; margin pressure; producers up, users down | Core & Satellite |
| 1 | **FOMC Decision & Projections** (#3) | Hold, but the dot plot shows one cut instead of three; dollar up | 60/40 Outside Its Band |
| 2 | **GDP Report** | 0.8% annualised; consumers and business investment cool | Core & Satellite |
| 2 | **ISM Manufacturing PMI** (#5) | 46.8, a sixth month below 50; cyclicals −2.5% | Core & Satellite |
| 2 | **ISM Services PMI** | 56.4, a two-year high — a *good-news* case: stocks up, yields up | 60/40 Outside Its Band |
| 2 | **Retail Sales** | −0.9%, control group −0.6%; discretionary −3% | Missing & Messy Data |
| 3 | **Earnings Report** (#4) | Northwind Devices misses and cuts guidance; −18% | Concentrated Employer Stock |
| 3 | **Earnings Revisions** | Four weeks of upward revisions to Helix Software (FactSet / Bloomberg / Visible Alpha / Refinitiv-style data) | Sector-Heavy Technology |
| 4 | **CFTC Commitments of Traders** | Record speculative long in equity futures, record short in Treasuries — a crowded trade | 60/40 Outside Its Band |
| 4 | **Fund Flow Report** | −$24bn from stock funds, +$41bn into money-market funds (EPFR / Morningstar / Lipper-style) | Core & Satellite |
| 5 | **Treasury Auction Results** | Weak 10-year auction: 3.2bp tail, low bid-to-cover; long yields +0.12 | Retiree Income |
| 5 | **Yield Curve Report** | 10-year +0.28 in a bear steepener, with an inverted curve for comparison | Retiree Income |
| 6 | **Semiconductor Sales** (Technology) | Chip sales −6%, cloud capex cut; Qubitron −9% | Sector-Heavy Technology |
| 6 | **Bank Earnings & Credit** (Financials) | Higher loan-loss provisions, card charge-offs at a 10-year high | Core & Satellite |
| 6 | **Housing Starts & Home Sales** (Housing) | Starts −11%, permits at a five-year low, mortgage rates near 7% | Retiree Income |
| 6 | **EIA Petroleum Status** (Energy) | 9.6m-barrel crude build, OPEC+ adds output; oil −6% | Retiree Income |

Reactions to simulate include selling all stocks and buying back later, selling half, rotating into bonds, buying the
dip, reacting to every scary headline, going all in on good news, taking profits, selling bonds for cash, chasing
yields, betting against or following the crowd, and — for the single-company reports — selling the stock into the
index, doubling down, buying more of a winner, or selling and buying back later.

The day's move is expressed in the factor model (market, rates, sectors, one company), so it lands on any account
through its own holdings. **The Long Run** runs the **Behaviour Lab**: every reaction and *Stay with the plan* on the
*same* simulated futures (100 / 300 / 1,000 futures of 10 / 20 / 30 years). Stocks follow a GARCH(1,1) daily model
with fat tails, so calm and stormy stretches alternate and the best days cluster near the worst; bonds and a single
stock are tied to it; optional stress futures are shaped like **2020** (fast crash and recovery), **2007–09** (long bear
market) and **2022** (stocks and bonds fall together). Every trade pays a spread; in a taxable account sales realise
gains at short- or long-term rates by holding period, losses carry forward. The results: median, bad (10th) and good
(90th percentile) ending values, how often the reaction beat the plan, **missed best days**, **taxes**, **trading
costs**, **tracking error** against the plan, worst drop, and how much missing the best 5 / 10 / 20 / 30 days costs.
It reports honestly when a reaction helps (selling a concentrated position into the index usually does; buying the dip
sometimes does) — and that you can't know in advance which future you're in.

## Sample portfolios (Library ▸ Sample Portfolios)

| Sample | Account | Benchmark | Edge case |
| --- | --- | --- | --- |
| Core & Satellite (active) | Retirement | MXEQ | The ordinary active case: 70% index fund plus eight conviction names |
| Concentrated Employer Stock | Taxable | MXEQ | 48% in one company, low-basis lots from 2012 plus a short-term lot |
| Sector-Heavy Technology | Taxable | MXEQ | Over 60% technology through overlapping funds and names (only visible by look-through) |
| Retiree Income (bond-heavy) | Retirement | MX3070 | 66% bonds plus rate-sensitive dividend stocks |
| Cash-Heavy, Waiting to Invest | Taxable | MX6040 | 45% cash kept back "for the dip" |
| High-Turnover Trader | Taxable | MXEQ | Holdings replaced every month; every lot short-term |
| Direct-Index Tracker, Drifted | Taxable | MXEQ | 22 of 36 names bought at index weights two years ago, never rebalanced |
| Tax-Lot Harvesting Case | Taxable | MX6040 | Lots at large gains and at losses; FIFO vs highest-cost-first; harvesting |
| 60/40 Outside Its Band | Retirement | MX6040 | Drifted to 71/29 after a rally |
| Missing & Messy Data | Taxable | MXEQ | An unknown security, a stale price, months of missing returns (attribution says *review*) |
| My Portfolio | yours | yours | Editable; *Copy to My Portfolio* starts it from any sample; remembered between launches |

**The illustrative market** (`Universe.swift`): 36 fictional companies in eleven sectors, six bond funds (short,
aggregate, long Treasury, inflation-protected, corporate, municipal), cash, and three index funds held by look-through
(MXTM total market, MXBD total bond, MXTK technology). Covariance from market, sector and interest-rate factors plus
each company's own risk; illustrative alpha forecasts; three cap-weighted benchmarks — **MXEQ** (MX Equity Market 36),
**MX6040** (balanced 60/40), **MX3070** (income 30/70). Attribution uses twelve months of illustrative returns
(2025-11 to 2026-10, with a spring sell-off and recovery).

## Engines — built-in and Layer 3 services

The built-in engines follow the Layer 3 contracts (`../Services/contracts/README.md`) so their answers match:

| Step | Built-in (`Optimizer.swift`, `Attribution.swift`) | Layer 3 service (Engine ▸ Layer 3 services) |
| --- | --- | --- |
| Optimize | Active mean-variance vs the benchmark, box + sector-band penalty, λ by bisection to the tracking-error target, FISTA | **portfolio-java** `POST /optimize/active` (127.0.0.1:8766), inputs sent inline |
| Build the Tracker | Minimum tracking error with ≤ N names (stratified selection exactly as portfolio-cpp's) | **portfolio-cpp** `POST /optimize/tracking` (127.0.0.1:8767), inputs sent inline |
| Risk | Volatility, VaR / ES, tracking error, beta, risk contributions (portfolio-cpp's `/risk` formulas) | — |
| Attribution | Monthly sector Brinson-Fachler / Brinson-Hood-Beebower, Carino-linked, data gaps → *review* | **analytics** `POST /attribution` (127.0.0.1:8772): the sample's monthly returns and start-of-month weights sent inline, checked against the built-in result; or a real **security-master portfolio** by code (MxDataHUB ▸ Portfolios, e.g. `DEMO_GROWTH`) — Attribution ▸ Source |

On the samples the built-in active optimizer matches portfolio-java to the published weight precision, and the
built-in tracker matches portfolio-cpp's tracking error, and built-in attribution matches the analytics service's
returns, effects (total, by sector, by month) and weights to its 6-decimal rounding on every sample and both methods —
the status line says so (or by how much they differ) after each services run. Start the services with
`python3 Services/mxservices.py start`; **Library ▸ Layer 3 Services** is the shared `ServicesView` (what each
service is for, whether it runs, how to start it). Failures (a service not running, the security-master database not
reachable) are shown as alerts with a link to that screen.

## Build and run

```bash
cd MxPortMGR
xcodebuild -project MxPortMGR.xcodeproj -scheme MxPortMGR -configuration Debug build
```

File-system-synchronized Xcode project (team QC4VX47BJ8, bundle id `com.k3jdr.MxPortMGR`, macOS 26.6,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), compiling `MxPortMGR/` and `../Shared` (Quick Help, the Layer 3
service catalog and view). Sandboxed with outgoing network connections (for the services on 127.0.0.1). The Debug
configuration is compiled with `-O`: the optimizers and the simulator are numeric loops that are ~75× slower
unoptimised.

Launch arguments for demos and tests: `-mySource srm -srmAccount CODE` (My Portfolio from the security master), `-addSecurities YES` (open Add Securities), `-screen activeOptimize` (any `Screen` case), `-sample employer-stock` (a sample
id), and for a walkthrough `-screen reportWalkthrough -report cpi -reportStep 5 -reaction sell-all` (step 5 runs the simulation; report ids: jobs, cpi, ppi, fomc, gdp, ism-manufacturing, ism-services, retail-sales, earnings, revisions, cot, fund-flows, auctions, yield-curve, semiconductors, banks, housing, energy). `-quickHelpVisible NO`
hides Quick Help.

## Files

| File | Contents |
| --- | --- |
| `MxPortMGRApp.swift` | The window and the Guide, Portfolio and Reports menus |
| `ContentView.swift` | Sidebar guide with Quick Help docked, toolbar pickers, status bar, launch arguments |
| `PortStore.swift` | Screens, the selected account, settings, results, walkthrough state, tax-lot estimates |
| `Universe.swift`, `Portfolio.swift`, `Samples.swift` | The illustrative market, accounts and checks, the samples |
| `SRMData.swift` | Security-master securities and benchmarks registry, the accounts-service client, analytics inputs for srm accounts |
| `AddSecuritiesSheet.swift` | Add Securities: illustrative universe or security master |
| `Optimizer.swift`, `Attribution.swift`, `ServiceClient.swift` | Built-in engines and the Layer 3 service client |
| `BehaviorLab.swift`, `MarketReports.swift`, `ReportLibrary.swift` | The long-horizon simulator; the report model, tiers and drivers with the jobs, earnings and yield-curve reports; the other fifteen reports and the shared reactions |
| `ReportsHubViews.swift` | Report Library and Morning Briefing |
| `LearnViews.swift`, `PathViews.swift`, `PassiveViews.swift`, `ReportView.swift`, `SamplesView.swift` | The screens |
| `Components.swift`, `PortQuickHelp.swift` | Lesson cards, tiles, bars, step footer; Quick Help text and glossary |
