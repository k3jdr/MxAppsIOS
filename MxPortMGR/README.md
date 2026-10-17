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
| **Sidebar — the guide** | Six groups: Start Here, Learn the Why, Active Portfolio (5 steps), Passive Index Portfolio (5 steps), Market Reports, Library. |
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
| **Guide** | Welcome ⌘0 · Choose Your Path · Learn the Why ▸ · Active Portfolio steps ⌘1–⌘5 · Passive Index Portfolio steps ⌥⌘1–⌥⌘5 · Sample Portfolios ⇧⌘L · Layer 3 Services ⌥⌘L |
| **Portfolio** | Account ▸ (every sample and My Portfolio) · Optimize (Active) ⌘R · Build Index Tracker (Passive) ⇧⌘R · Run Attribution ⇧⌘A · Engine ▸ · Copy Account to My Portfolio · Reset My Portfolio |
| **Reports** | Jobs Report ⌥⌘J · Earnings Report ⌥⌘E · Yield Curve Report ⌥⌘Y · Simulate the Long Run ⌘↩ |
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

### Active Portfolio path

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

### Passive Index Portfolio path

1. **Portfolio & Index** — the same screen, read for tracking.
2. **Tracking Error & Drift** — tracking error today and after a year untouched, month by month for the account and for
   a 20-name tracker set up today; the six names that drift most; why trackers drift.
3. **Build the Tracker** — names (3 to all), stratified or largest-weight selection, tracking-error budget → decision,
   the tracking-error-vs-names curve, sector gaps, *Three ways to be passive* (today's account, the N-name tracker,
   one index fund — with tracking error, fee, trades and the tax of switching), trades.
4. **Rebalance Bands** — ± points or ± 25% of target, trade back to the target or the band's edge; each class on its
   band; the stock share through the year; holding-level trades and their taxes.
5. **Attribution** — read as a check-up: for a passive account every effect should be close to zero.

### Market Reports walkthroughs

Each walkthrough has seven steps — **The Report**, **Reading It**, **The Market's Move**, **Your Account**,
**Your Reaction**, **The Long Run**, **Takeaways**:

| Walkthrough | The report (illustrative) | Written for | Reactions to simulate |
| --- | --- | --- | --- |
| **Jobs Report** | Payrolls +48,000 vs +150,000 expected, unemployment 4.6%, downward revisions, slower wages; stocks −2.4%, yields down, bonds up | Cash-Heavy | Sell all stocks and buy back later · sell half · rotate into bonds for good · buy the dip · react to every scary headline |
| **Earnings Report** | Northwind Devices (fictional) misses revenue, EPS and margin, cuts guidance; −18% after hours; the index −2.6% because NWD is ~13% of it | Concentrated Employer Stock | Sell the company and buy the index · sell, wait in cash, buy back · double down · sell all stocks |
| **Yield Curve Report** | 10-year 4.55% (+0.28), 30-year 4.95%, a bear steepener, with an inverted curve for comparison; long bonds −4.6%, REITs and utilities −3% | Retiree Income | Sell the bonds and sit in cash · sell stocks before the recession · chase the higher yields · react to every scary headline |

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

Launch arguments for demos and tests: `-screen activeOptimize` (any `Screen` case), `-sample employer-stock` (a sample
id), and for a walkthrough `-reportStep 5 -reaction sell-all` (step 5 runs the simulation). `-quickHelpVisible NO`
hides Quick Help.

## Files

| File | Contents |
| --- | --- |
| `MxPortMGRApp.swift` | The window and the Guide, Portfolio and Reports menus |
| `ContentView.swift` | Sidebar guide with Quick Help docked, toolbar pickers, status bar, launch arguments |
| `PortStore.swift` | Screens, the selected account, settings, results, walkthrough state, tax-lot estimates |
| `Universe.swift`, `Portfolio.swift`, `Samples.swift` | The illustrative market, accounts and checks, the samples |
| `Optimizer.swift`, `Attribution.swift`, `ServiceClient.swift` | Built-in engines and the Layer 3 service client |
| `BehaviorLab.swift`, `MarketReports.swift` | The long-horizon simulator and the three report walkthroughs |
| `LearnViews.swift`, `PathViews.swift`, `PassiveViews.swift`, `ReportView.swift`, `SamplesView.swift` | The screens |
| `Components.swift`, `PortQuickHelp.swift` | Lesson cards, tiles, bars, step footer; Quick Help text and glossary |
