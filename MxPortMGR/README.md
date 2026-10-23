# MxPortMGR

A portfolio-management IDE for macOS that **teaches**: it walks you through setting up an **actively managed** or a
**passive index** portfolio for personal accounts, explaining *why* each step — optimization, risk, tracking,
rebalancing, attribution — matters before showing the numbers, and lets you simulate what everyday reactions to market
news cost over the long run.

> **Educational only.** The companies, prices, reports and futures are illustrative — made up in the shape of real
> ones — except on the earnings screens (Market Reports ▸ Earnings Calendar and Earnings by Day), which show real
> companies' reports as Nasdaq.com and FMP publish them, and in My Portfolio from the security master. Nothing in
> MxPortMGR is investment, tax or financial advice, a forecast, or a recommendation to buy or sell anything. The
> status bar says so on every screen.

Sixth app in the MXcodeIDE family, next to MxJobsWMS, MxDataHUB, MxDataSQL, MxNoteONE and MxFileMGR. It re-implements
MxDataHUB's portfolio optimization and attribution (which MxDataHUB hands to MxJobsWMS workflows and the Layer 3
services) as interactive, explained steps, and can run them through the same **Layer 3 services** in `../Services`.

## The window

One window (`MxPortMGR`, 1440 × 900 by default):

| Area | What it holds |
| --- | --- |
| **Sidebar — the guide** | Five groups: Start Here, **My Portfolio** (6 steps, your own account), Market Reports, Learn the Why, Library. |
| **Quick Help** (bottom of the sidebar) | The shared MXcodeIDE Quick Help pane (`Shared/QuickHelp`): what's under the pointer — a metric, a column, a chart, a limit, a reaction — then what's selected (the account), then the screen. Its ⧉ button floats it in a window of its own; closing that window docks it again. |
| **Toolbar** | **‹ ›** beside the title — **Back** and **Forward** through the places you've visited, as in a browser and in MxNoteONE (hold either for the places before or after; see *Back and Forward* below). **Account** — the sample (or My Portfolio) the report walkthroughs and the Morning Briefing work on; the My Portfolio steps always use My Portfolio. **Engine** — *Built-in (Swift)* or *Layer 3 services*. |
| **Screen** | A title, a collapsible yellow **"Why this step"** lesson (remembered per screen), the step's controls and results, and **Previous / Next** step along the guide. |
| **Status bar** | The account, its type, value and benchmark; the last action (e.g. "Optimized with Built-in (Swift) in 134 ms"); the educational-use banner. |

Every control has a `.help` tooltip and a Quick Help entry (`.quickHelp` / `.quickHelpArea`), following the
convention of the other apps; glossary terms (tracking error, active share, information ratio, VaR, allocation /
selection / interaction, turnover, rebalance band, look-through, tax lot, Carino linking) use `.term(_:)`, which
gives both.

**Selecting and copying.** The screens' text can be selected and copied (⌘C), as in a document: lessons, figures,
captions, cards and the walkthroughs. Sections that are mostly reading are each one text, so a drag selects across
all their lines: every lesson (Why this step, What this walkthrough shows), and in the walkthroughs About this report,
The real report (its titles still open the source), How to read it, Terms and Takeaways, and Attribution's
Assumptions (`Shared/Copy/SelectableText.swift`, shared with MxDataHUB). Elsewhere each piece of text is selected on
its own — SwiftUI doesn't select across several — so to take more than one at a time:

- **Edit ▸ Copy Page Text** (⌥⇧⌘C) copies the whole page — every section, card and grid, also what is scrolled out of
  sight — laid out as on screen: things side by side tab-separated (a grid's columns, a metric row), cards one after
  another, a blank line between blocks. The Report Library's drivers grid comes out as a table with ✓ per driver and
  the impact (low / medium / high).
- **Copy Section** — right-click a section (a titled box, a lesson) away from its text — copies just that section.
- **Tables** — click a row to select it (⇧ / ⌘ for several, ⌘A for all), then **⌘C** (Edit ▸ Copy) or the row's
  context menu, *Copy Row*, copies them as tab-separated columns under the columns' titles, which paste into Numbers or
  Excel as a table: My Holdings, Earnings by Day, Add Securities, Trades and By sector.

Buttons drawn as cards or headings stay buttons: a click on their words presses them (their words are in the copied
page). The page and section text is read through accessibility (`Shared/Copy/PageText.swift`); table rows through
`Shared/Copy/TableCopy.swift`, shared with MxDataHUB.

## Menus

| Menu | Items |
| --- | --- |
| **Edit** | (the standard items) · **Copy Page Text** ⌥⇧⌘C — the whole page as text · **Link…** ⌘K — add or edit the link on the selected company (Earnings by Day) or holding (My Holdings): its symbol, or its name when the pointer rests there |
| **Go** | **Back** ⌘[ · **Forward** ⌘] · **History** ▸ (the places before and after, the current one ticked) · Previous Step ⌥⌘↑ · Next Step ⌥⌘↓ (along the guide) |
| **Guide** | Welcome ⌘0 · Choose Your Path · My Portfolio steps 1–6 ⌥⌘1–⌥⌘6 · Learn the Why ▸ · Sample Portfolios ⇧⌘L · Layer 3 Services ⌥⌘L |
| **Portfolio** | Account ▸ (every sample and My Portfolio) · Optimize My Portfolio / Build My Index Tracker ⌘R (step 4, by My approach) · Run Attribution ⇧⌘A · Engine ▸ · Copy Account to My Portfolio · Reset My Portfolio |
| **Reports** | Report Library ⌥⌘R · Morning Briefing ⌥⌘M · Earnings Calendar ⌥⌘E · Earnings Today ⇧⌥⌘E · VIX ⌥⌘V · Compute — Hyperscaler Capex ⌥⌘U · The Five Most Important (CPI, Jobs, FOMC, Earnings, ISM Manufacturing) ⌃⌘1–⌃⌘5 · one submenu per tier (Tier 1–6) with every report · Simulate the Long Run ⌘↩ |
| **View** | Quick Help ⌥⌘/ · Float / Dock Quick Help (shared `QuickHelpCommands`) |

### Back and Forward

As in a browser, Finder and MxNoteONE, every place you go joins a history: a screen, the report a walkthrough shows,
or the day Earnings by Day shows. Going somewhere new after going back drops the places ahead, as a browser does.

* **Back**: the toolbar's **‹**, Go ▸ Back, **⌘[**, **⌃←**, or a mouse's back button.
* **Forward**: the toolbar's **›**, Go ▸ Forward, **⌘]**, **⌃→**, or a mouse's forward button.
* **Several places at once**: hold ‹ or › for the places before or after (up to 15), or use Go ▸ History.

macOS gives ⌃← and ⌃→ to Mission Control ("Move left / right a space") until they are turned off in System Settings ▸
Keyboard ▸ Keyboard Shortcuts… ▸ Mission Control; ⌘[ and ⌘] always work. ⌃← and ⌃→ are left to text while you type.
The guide's own order is **Previous Step ⌥⌘↑** and **Next Step ⌥⌘↓** (they used to be ⌘[ and ⌘]), and the buttons at
the foot of each step.

## The guide

### Start Here

* **Welcome** — what the app teaches and how to use it.
* **Choose Your Path** — four questions (edge after costs, tolerance for differing from the market, time, taxes) set
  against each approach, and *Start My Portfolio*. It does not choose for you.

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

1. **My Holdings** — add, edit and remove holdings (shares, values, tax lots); value, look-through securities,
   weighted fee, unrealised gain; asset mix; *Check before you go on* (unknown or unpriced holdings, a single name over
   20%, a sector more than twice the benchmark, asset classes the benchmark doesn't hold, idle cash, missing returns).
   The ticker and the name of each holding can carry a link (⌘K; see *Links on symbols and names*).
2. **My Benchmark** — choose the benchmark that matches your plan; sector and asset-mix comparison, overlap, active
   share, the names you hold in it and its 25 largest members.
3. **Risk Today** — volatility, tracking error, beta, one-month 95% VaR and expected shortfall in dollars, rate
   sensitivity; weight vs share of risk; risk by sector; what drives tracking error.
4. **Optimize** (active) — tracking-error target (or risk aversion), largest position, largest active weight, sector
   band, turnover limit → decision (hold / rebalance / rebalance part of the way / relax a limit), tracking error,
   information ratio, forecast active return, active share, turnover, names, binding limits, largest changes and sector
   active weights. **Build the Tracker** (passive) — names (3 to all), stratified or largest-weight selection,
   tracking-error budget → decision, the tracking-error-vs-names curve, sector gaps, *Three ways to be passive* (today's
   account, the N-name tracker, one index fund — with tracking error, fee, trades and the tax of switching), trades.
5. **Trades & Taxes** (active) — turnover, trading cost, realised long- and short-term gains, estimated tax; a *How far
   to go* slider (part of the way); the trade list (direct, through a fund, new); taxes by lot with FIFO or
   highest-cost-first and adjustable illustrative rates, tax-loss harvesting and wash-sale notes. **Rebalance Bands**
   (passive) — ± points or ± 25% of target, trade back to the target or the band's edge; each class on its band; the
   stock share through the year; holding-level trades and their taxes.
6. **Attribution** — account, benchmark and active return; allocation, selection, interaction by sector (bars and
   table) and month by month; top and bottom contributors; assumptions; *publish* or *review* with reasons. Read as a
   check-up for a passive account: every effect should be close to zero.

Steps 4 and 5 change name and screen with the approach (in the sidebar too). *Copy to My Portfolio* on a sample, the
Portfolio menu's *Copy Account to My Portfolio*, *Start From a Sample* and Choose Your Path's *Start My Portfolio* all
lead here: learning on a sample means copying it into My Portfolio. (The separate Model Portfolio section, with its
Tracking Error & Drift screen, was retired on 2026-10-22.)

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
service to load them (`srm.py load nasdaq-prices --symbols …` — Nasdaq.com's free quote API, no key needed). The
benchmark is any benchmark loaded in srm (S&P 500, Nasdaq-100, Dow, S&P 400 / 600, custom); Risk, Optimize and Build
the Tracker use the analytics service's Ledoit-Wolf covariance from two years of srm prices (holdings without enough
price history and cash are left out and listed), and Attribution uses its `/attribution` for the account's code.
Securities whose tickers clash with the illustrative universe show as `TICKER:MIC` internally.

`mxportmgr://my-portfolio/CODE` (from MxDataHUB or MxJobsWMS ▸ Window ▸ Open MxPortMGR) opens My Portfolio on that
security-master account.

### Market Reports

The hierarchy of reports portfolio managers, hedge funds, pension funds and mutual-fund managers watch — some move
markets within seconds, others shape positioning over weeks or months.

* **Report Library** — every report by tier as a card (publisher, schedule, key metrics, why PMs care, the price
  drivers it moves, typical impact), **If you had to pick five** (CPI, Nonfarm Payrolls, FOMC, earnings and guidance,
  ISM PMI — together they drive expectations for growth, inflation, interest rates and profits, the four primary
  determinants of asset prices), and a report × driver matrix. Each card links to the **real report** at its
  publisher (the latest release: BLS, the Federal Reserve, BEA, ISM, the Census Bureau, CFTC, ICI, TreasuryDirect…).
  In the matrix (*Which drivers each report moves*) a report's name opens its walkthrough, and **your own notes** go
  on it:
  * **Right-click** a report's name: *Add Notes…* / *Edit Notes…*, *Open Walkthrough*, *Open Official Source* and
    *Copy Official Source Address*. The **Notes** dialog takes formatted text, written as a link's hover text is (B I U S,
    size, colour, ⌘B ⌘I ⌘U): what to watch, how you read the report, links to your own pages (the link button or ⌘K;
    typed addresses become links, `mxnoteone://…` pages in MxNoteONE too). It has a *Hover card preview* and *Remove
    Notes*. Return starts a new line. A link in the notes takes words of its own (*Text to display*), as links in a
    link's hover text do.
  * **Resting the pointer** on the name for 0.6 s shows its **hover card**, as a link's does: your notes with their
    links and when you last changed them, then the report's publisher and schedule, the drivers it moves and its
    impact, its official source (a click opens it), and **Edit Notes…** and **Open Walkthrough**.
  * A speech-bubble mark follows the name of a report with notes. Notes are kept on this Mac (`reportNotes`).
* **Morning Briefing** — an illustrative morning's ten items: overnight markets, Treasury yield changes (with the
  2Y–10Y and 3M–10Y spreads), the economic calendar (consensus, prior, impact; each release opens its walkthrough),
  an economic surprise index, Fed funds futures probabilities, analyst upgrades and downgrades (fictional firms),
  earnings releases (marked "you hold"), weekly fund flows, credit spreads and the VIX — with what the selected
  account would be worth if it opened with the futures. Each panel says what it measures and how a long-term investor
  might use it. Its earnings panel links to today's real list (Earnings by Day).
* **Earnings Calendar** — real earnings reports by **month** or **week** (◀ ▶ and Today step through them). A month
  cell shows the number of U.S.-listed companies reporting, for past days a bar and count of how many beat (green),
  were in line (grey) or missed (red) the consensus EPS, and the largest names — coloured by result, or with a
  sunrise / moon for before the open / after the close — with the companies you hold first. The week view lists each
  weekday's 16 largest reports with the actual EPS (coloured) or the consensus. Under the grid, **This month / This
  week**: reports listed, the share that beat on EPS and on revenue, how many are still to come, and the largest
  reports still to come and already reported. Click a day (or a company) to open it in Earnings by Day.
* **Earnings by Day** — every company reporting on the day picked (date field, ◀ ▶ weekdays, Today): symbol, company,
  before the open / after the close, market cap, number of estimates, consensus and actual EPS with the surprise,
  revenue estimate, actual and surprise. Tiles count the companies, the timing, EPS and revenue beats and misses
  (or, for an upcoming day, how many have a consensus and the revenue expected) and the ones in your account. Filter
  by symbol or name, time of day, *Also FMP-only listings* (OTC, foreign and preferred-share symbols only FMP lists)
  and *Only my holdings*; sort by any column. Selecting a company shows this report in detail (Nasdaq.com's range of
  estimates and four-week revisions, FMP's figures where they differ, a year earlier), an EPS chart of its last
  twelve reports and the next one against the estimate, its recent revenue surprises, and Nasdaq.com's last four
  surprises. *You hold* marks (a briefcase) need My Portfolio in the security master, whose tickers are real.
* **VIX** (⌥⌘V) — the Cboe Volatility Index, real data: the latest close and change, its regime (calm under 15,
  normal 15–20, elevated 20–30, stress 30–40, panic 40 and over), the share of closes since 1990 below it, the 52-week
  range, the long-run average and median, and the S&P 500 move it implies (±VIX/√12 a month, ±VIX/16 a day). Its
  history (1M, 6M, 1Y, 5Y, since 1990) with the regimes shaded; the term structure (VIX9D, VIX, VIX3M, VIX6M) and what
  an upward or inverted curve means; and every spike above 35 since 1990 — when it began, its peak, and the trading days
  until the VIX closed under 20 again (a table that copies). The lesson: fear peaks near market lows and passes, so the
  VIX explains swings rather than timing a plan. Data: Cboe's daily history files (cdn.cboe.com, no key), read at
  most hourly and kept in the app's Caches folder for when Cboe can't be reached. The Morning Briefing's illustrative
  VIX panel and the Report Library's morning reading link to it.
* **Compute** (⌥⌘U) — AI compute as an asset theme, followed through what the hyperscalers spend to build it, with
  real reported figures: Microsoft, Alphabet, Amazon, Meta and Oracle's quarterly capex — combined for the latest
  calendar quarter all have reported and against a year earlier, over the last four quarters, and as a share of their
  operating cash flow and revenue — in a stacked chart by calendar quarter (3, 5 or 10 years); a table company by
  company (latest quarter and its growth, last four quarters, capex / revenue, capex / cash flow, depreciation, free
  cash flow; copyable); capital intensity over time; **where the money goes** — the revenue and growth of Nvidia,
  Broadcom, AMD, Micron, Arista, Vertiv and Equinix; and **your exposure**, the share of My Portfolio (in the security
  master) held in these companies directly. The lesson: capex is the suppliers' revenue, building ahead of demand has
  happened before (fibre around 2000), and an index fund already holds the theme. Data: FMP's quarterly cash-flow and
  income statements through the accounts service (`GET /fundamentals/quarters`), which keeps them 12 hours.

#### Earnings sources and their limits

| Piece | Source | Limits |
| --- | --- | --- |
| The day's companies, time of day, market cap, consensus EPS (Zacks) and number of estimates, actual EPS and % surprise | **Nasdaq.com earnings calendar** (`api.nasdaq.com/api/calendar/earnings?date=`), called directly by the app — free, no key | U.S.-listed companies only (up to about 600 on the busiest days); schedules a few weeks ahead (none in January 2027 when probed on 2026-10-22); history back years (2015 probed). Past listings drop the time of day and keep only companies with a result; results appear a day or so after the report. Market cap is today's, also on past days. No revenue. An unofficial public API: fetched three days at a time, and each listing is kept on this Mac |
| Revenue estimate and actual, FMP's own EPS, OTC / foreign / preferred listings | **FMP earnings calendar** (`stable/earnings-calendar`) through the **accounts** service (`GET /earnings/calendar`, port 8774), which holds SRM's FMP key | The plan reaches back **12 months** (before that FMP answers 402) and several months ahead; at most 4,000 rows a call (the service fetches a week at a time); no company names or times. FMP's EPS can differ from Nasdaq.com's (another consensus, GAAP for some companies), so the app compares each source's estimate with its own actual: FMP's pair is shown (ᶠ) only where Nasdaq.com has no result yet |
| Company history | FMP `stable/earnings?symbol=` (accounts service `GET /earnings/history`); Nasdaq.com `company/{symbol}/earnings-surprise` and `analyst/{symbol}/earnings-forecast` | FMP: every report back decades, with revenue. Nasdaq.com: the last four quarters' surprises; this and the next quarters' consensus, high, low, number of estimates and the last four weeks' revisions |

Without the accounts service the screens still work from Nasdaq.com, with a note that revenue needs the service.
Each day's listings are kept in the app's container (`Application Support/Earnings/YYYY-MM-DD.json`): past days open
at once, a listing is fetched again until three days after its date (FMP's: a week), and when a later listing drops
the time of day the time from an earlier one is kept (marked ↺) — so times survive for days this Mac saw beforehand.
* **Report Walkthrough** — one report at a time (the sidebar row shows which; the **Report** menu at the top of the
  page or the Reports menu picks another), in seven steps — **The Report** (with *About this report*), **Reading It**,
  **The Market's Move** (with a context chart: core CPI by month, ISM against its 50 line, auction tails, weekly
  flows…), **Your Account**, **Your Reaction**, **The Long Run**, **Takeaways**. The walkthroughs teach with
  illustrative numbers; **The Report**'s *The real report* box links to the actual one: the publisher's latest
  release, its release schedule, and its history (FRED for the economic series) or live data (CME FedWatch, Treasury
  yields, Freddie Mac mortgage rates), and for the earnings reports MxPortMGR's own Earnings by Day and Earnings
  Calendar. The addresses (`ReportSources.swift`) were checked in a browser on 2026-10-22; OPEC's monthly report is
  left out because its site puts up a bot check.

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

### Links on symbols and names

In **Earnings by Day** (the Symbol and Company columns) and **My Holdings** (Ticker and Name), any symbol or name can
carry a link, made and shown the way MxNoteONE does it (its `LinkHover.swift`, `LinkTips.swift` and Link dialog, ported
into `../Shared/Links` — shared with MxDataHUB's Securities and Portfolio Holdings tables):

* **⌘K** (Edit ▸ Link…) on a selected row — or the row's context menu, *Add Link to Symbol… / Company…* — opens the
  **Link** dialog (**Edit Link** when there is one): *Link on* Symbol or Company (Ticker or Name; ⌘K takes the column the
  pointer rests on), *Text to display* (the symbol or name unless you change it), *Address* (a web address — https://
  is added — or an email address), and **hover text**: formatted text (B I U S, size, colour, ⌘B ⌘I ⌘U) that can hold
  links of its own, with a *Hover card preview*. The link button (or ⌘K in the hover text) asks, as MxNoteONE's Link
  dialog does, for the link's **Text to display** and its *Address*: on selected words, on a link (to change its words
  or address, or *Remove Link*), or on an address typed in the text (to show words of your own in its place; empty shows
  the address itself). The hover card shows the words; the pointer resting on them shows the address. In place of
  MxNoteONE's list of notebook pages it offers pages about the security: Nasdaq.com's quote and earnings pages (or the
  ETF / fund page), SEC EDGAR filings, Yahoo Finance, and a web search for the company's investor relations. A made-up
  security of the illustrative market has none, but any address works. *Remove Link* takes it off.
* **Links to your notes in MxNoteONE**: right-click a page, paragraph, section or notebook in MxNoteONE ▸ *Copy Link
  to …*, then in the Link dialog press **Use the Link Copied in MxNoteONE** (it shows when MxNoteONE's link is on the
  clipboard) — or paste the `mxnoteone://…` address. The title copied with it (the page's, section's or paragraph's) is
  kept with the link, since MxPortMGR can't read MxNoteONE's notebooks: the hover card shows it, with a page, paragraph,
  pin, section or notebook symbol, and "Click to open in MxNoteONE". Clicking opens MxNoteONE there; MxNoteONE opens
  `mxnoteone://` links from other apps from the version released with this (older ones don't, and MxPortMGR then says
  that no app opens the link). Hover text can hold MxNoteONE links too.
* A linked symbol or name is shown as a link; **a click opens it** (in the default browser, or in MxNoteONE).
* **Resting the pointer** on it for 0.6 s shows the **hover card** (in the key window): the hover text with its links
  (a click opens one), where the link goes (site and address), the link's words, "Click to open in …", and **Edit
  Link…**, **Copy** and **Remove Link**. It closes when the pointer leaves the link and the card, or on a click or key
  press elsewhere.

A link belongs to the security and the column, not the table or the app: it is kept in the **security master**
(`srm.security_link`, migration V014) through the accounts service (`/links`), so it shows in Earnings by Day, in My
Holdings (My Portfolio from the security master) and in **MxDataHUB** (Securities, Portfolios ▸ Holdings), and a link
made there shows here. A company in Earnings by Day is found by its ticker's current U.S. listing (`srm.us_security`:
BRK.B, BRK-B and BRK/B alike). Links stay on this Mac for the illustrative market's made-up securities and for tickers
the security master doesn't list; a link saved while the accounts service can't be reached is kept here too, and goes to
the security master the next time it answers (the dialog says where each link is kept). Links made on this Mac before
are sent there the same way, unless the security master already has one for that ticker or name.

### Learn the Why

* **Why Optimize?** — two live demos: diversification (volatility of 1–36 equal-weighted companies falling to the
  market's floor) and the stock / bond trade-off (the risk–return line of every mix); then what an optimizer does
  with forecasts, a risk model and limits, and why limits matter ("error maximisation").
* **Why Attribution?** — a two-sector Brinson-Fachler demo with sliders: allocation, selection and interaction recomputed
  as you move the weights and returns.
* **Active vs Passive** — what fees compound to over 30 years (fee and pre-fee alpha sliders) and a comparison table.

## Sample portfolios (Library ▸ Sample Portfolios)

Each sample is an edge case. *Use* makes it the account of the report walkthroughs and the Morning Briefing; *Copy to
My Portfolio* (or My Portfolio's *Start From a Sample*) makes an editable copy to work through the six steps.


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
service catalog and view). Sandboxed with outgoing network connections (for the services on 127.0.0.1 and Nasdaq.com's earnings calendar). The Debug
configuration is compiled with `-O`: the optimizers and the simulator are numeric loops that are ~75× slower
unoptimised.

Launch arguments for demos and tests: `-mySource srm -srmAccount CODE` (My Portfolio from the security master), `-addSecurities YES` (open Add Securities), `-screen myImprove` (any `Screen` case), `-sample employer-stock` (a sample
id), and for a walkthrough `-screen reportWalkthrough -report cpi -reportStep 5 -reaction sell-all` (step 5 runs the simulation; report ids: jobs, cpi, ppi, fomc, gdp, ism-manufacturing, ism-services, retail-sales, earnings, revisions, cot, fund-flows, auctions, yield-curve, semiconductors, banks, housing, energy). `-quickHelpVisible NO`
hides Quick Help. Earnings screens: `-screen earningsDay -earningsDate 2026-10-20 -earningsSymbol META` (the day, and a company selected) and `-screen earningsCalendar -earningsMode Week` (the calendar shows `-earningsDate`'s month or week); `-holding MXTM` selects a holding in My Holdings. Debug builds only:
`-linkEdit symbol` (or `name`) opens the Link dialog for the selected company or holding, and `-linkHoverTest ID`
(e.g. `META|symbol`, `mx:MXTM|name`) shows a linked cell's hover card as if the pointer rested on it, and
`-linkPasteboard NAME` makes the dialog look for a copied MxNoteONE link on that named pasteboard (not the clipboard).

## Files

| File | Contents |
| --- | --- |
| `MxPortMGRApp.swift` | The window and the Guide, Portfolio and Reports menus, and Edit ▸ Link… |
| `ContentView.swift` | Sidebar guide with Quick Help docked, toolbar pickers, status bar, launch arguments |
| `Navigation.swift` | Back and Forward: the places visited, the toolbar's ‹ ›, the Go menu, ⌃← ⌃→ and a mouse's side buttons |
| `PortStore.swift` | Screens, the selected account, settings, results, walkthrough state, tax-lot estimates |
| `Universe.swift`, `Portfolio.swift`, `Samples.swift` | The illustrative market, accounts and checks, the samples |
| `SRMData.swift` | Security-master securities and benchmarks registry, the accounts-service client, analytics inputs for srm accounts |
| `AddSecuritiesSheet.swift` | Add Securities: illustrative universe or security master |
| `Optimizer.swift`, `Attribution.swift`, `ServiceClient.swift` | Built-in engines and the Layer 3 service client |
| `BehaviorLab.swift`, `MarketReports.swift`, `ReportLibrary.swift` | The long-horizon simulator; the report model, tiers and drivers with the jobs, earnings and yield-curve reports; the other fifteen reports and the shared reactions |
| `ReportsHubViews.swift` | Report Library and Morning Briefing |
| `ReportNotes.swift` | Your notes on reports: kept on this Mac; the report's name in the matrix, its context menu and hover card; the Notes dialog |
| `ReportSources.swift` | Each report's official sources: latest release, release schedule, history or live data |
| `Earnings.swift`, `EarningsViews.swift` | Real earnings: the Nasdaq.com and FMP (accounts service) clients, merging by symbol, the day files kept on this Mac, the store; Earnings Calendar (month, week) and Earnings by Day with the company detail |
| `SecurityLinkTargets.swift` | Links on symbols and names: Earnings by Day's and My Holdings' securities, and the accounts service as where links are kept. The rest is shared with MxDataHUB in `../Shared/Links`: the link store, linked cell, Link dialog and its pages about a security (`SecurityLinks.swift`); the hover card, also the reports' (`LinkHover.swift`); the hover text and its editor (`LinkTips.swift`), after MxNoteONE's |
| `LearnViews.swift`, `PathViews.swift`, `PassiveViews.swift`, `ReportView.swift`, `SamplesView.swift` | The screens: Start Here and Learn the Why; My Portfolio's steps (PassiveViews: Build the Tracker and Rebalance Bands); the report walkthrough; the samples |
| `Components.swift`, `PortQuickHelp.swift` | Lesson cards, tiles, bars, step footer; Quick Help text and glossary |
