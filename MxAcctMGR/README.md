# MxAcctMGR

A portfolio-management IDE for macOS that **teaches**: it walks you through setting up an **actively managed** or a
**passive index** portfolio for personal accounts, explaining *why* each step — optimization, risk, tracking,
rebalancing, attribution — matters before showing the numbers, and lets you simulate what everyday reactions to market
news cost over the long run.

> **Educational only.** Every security, price, benchmark and account — My Portfolio and the samples — is real data
> from the security master (MxDataHUB's `srm` schema), with risk estimated from real daily prices by the analytics
> service; the earnings screens show real companies' reports as Nasdaq.com and FMP publish them. The report
> walkthroughs and the Morning Briefing's market panels are scenarios — made-up numbers in the shape of real releases,
> labelled as such — and a walkthrough about one company uses the account's own stock with invented numbers. Nothing in
> MxAcctMGR is investment, tax or financial advice, a forecast, or a recommendation to buy or sell anything. The
> status bar says so on every screen.

Sixth app in the MxAppsIOS family, next to MxJobsMGR, MxDataHUB, MxDataSQL, MxNoteONE and MxFileMGR. It re-implements
MxDataHUB's portfolio optimization and attribution (which MxDataHUB hands to MxJobsMGR workflows and the Layer 3
services) as interactive, explained steps, and can run them through the same **Layer 3 services** in `../Services`.

**Renamed from MxPortMGR** (10/25/26): the personal accounts app — Banking as well as Investments — so it is named for
accounts. Folder, Xcode project, target, product, bundle identifier (`com.k3jdr.MxAcctMGR`) and link scheme
(`mxacctmgr://`; `mxportmgr://` links saved before still open it) all changed. Target accounts' passwords and user keys
saved under the old name move to the new Keychain service the first time they are read. The security master's values
naming the app (`managed_by`, a benchmark's `provider`) are renamed by migration V034, and the apps and services read
both names until it runs. The app's window and display preferences start fresh (macOS keeps each app's own); everything
else — portfolios, registers, target accounts, links, notes — is in the security master. Commits before the rename say
"MxPortMGR:".

## The window

One window (`MxAcctMGR`, 1440 × 900 by default):

| Area | What it holds |
| --- | --- |
| **Sidebar — the guide** | Four groups, each collapsible: **Banking** (Checking Accounts — the shared check register, cleared by PNC downloads, each entry's target a target account with its last four digits, a note on hover and its link; Expense Ledgers — funded ledgers of purpose spending (a Mac and its software, a home office build-out), each item on a budget line, with the transfers that fund it; Target Accounts — where the registers' money goes to or comes from, each with its details, its funding sources and a link of its own; Secure Accounts — the products and services you hold an account with, their subscriptions' payment and renewal); **Investments** (6 steps on your own account, My Portfolio); Knowledge Library (reports, earnings, CBOE Volatility Index (VIX), Compute Hyperscalers Tracking, the Why lessons and the sample portfolios); Reporting (Spending Analysis — why the family's spending changed and the children's forward curve; SRM Table, Layer 3 Services); right-click any page for a link of its own with hover text. Welcome and Choose Your Path are in the Guide menu. |
| **Quick Help** (bottom of the sidebar) | The shared MxAppsIOS Quick Help pane (`Shared/QuickHelp`): what's under the pointer — a metric, a column, a chart, a limit, a reaction — then what's selected (the account), then the screen. Its ⧉ button floats it in a window of its own; closing that window docks it again. |
| **Toolbar** | **‹ ›** beside the title — **Back** and **Forward** through the places you've visited, as in a browser and in MxNoteONE (hold either for the places before or after; see *Back and Forward* below). **Account** — the sample (or My Portfolio) the report walkthroughs and the Morning Briefing work on; the Investments steps always use My Portfolio. **Engine** — *Layer 3 services* (the default) or *Built-in (Swift)*. |
| **Screen** | A title, a collapsible yellow **"Why this step"** lesson (remembered per screen), the step's controls and results, and **Previous / Next** step along the guide. Settings sets the headings' fonts and how much of the teaching shows. |
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
| **MxAcctMGR** | **Settings…** ⌘, — **Text**: a font name, size and style for each kind of text that takes room — **Headings** (page titles, page introductions, headings, subheadings, names, figures) and **Numbers and Tables** (registers and tables, whose rows follow their text's height; the earnings calendar, whose day cells shrink or grow with it; IDs and codes; calculation results) — each section with **Step Down** / **Step Up** (every kind a point smaller or larger) and **Restore Defaults**; **Banking**: what the checking register's New entry starts with (kind — Debit at first —, check number, date); **Guidance**: the instruction level — **Full** (everything), **Brief** (no "Why this step" lessons) or **Minimal** (also no line under the titles, and the lesson-only pages — Welcome, Choose Your Path, Why Optimize?, Why Attribution?, Active vs Passive — leave the sidebar, the Guide menu and Previous / Next Step) |
| **Edit** | (the standard items) · **Copy Page Text** ⌥⇧⌘C — the whole page as text · **Link…** ⌘K — add or edit the link on the selected company (Earnings by Day) or holding (My Holdings): its symbol, or its name when the pointer rests there |
| **Go** | **Back** ⌘[ · **Forward** ⌘] · **History** ▸ (the places before and after, the current one ticked) · Previous Step ⌥⌘↑ · Next Step ⌥⌘↓ (along the guide) |
| **Guide** | Welcome ⌘0 · Choose Your Path · Investments steps 1–6 ⌥⌘1–⌥⌘6 · Learn the Why ▸ · Spending Analysis · SRM Table · Sample Portfolios ⇧⌘L · Layer 3 Services ⌥⌘L |
| **Portfolio** | Account ▸ (every sample and My Portfolio) · Optimize My Portfolio / Build My Index Tracker ⌘R (step 4, by My approach) · Run Attribution ⇧⌘A · Engine ▸ · Copy Account to My Portfolio · Reset My Portfolio |
| **Reports** | Report Library ⌥⌘R · Morning Briefing ⌥⌘M · Earnings Calendar ⌥⌘E · Earnings Today ⇧⌥⌘E · CBOE Volatility Index (VIX) ⌥⌘V · The Five Most Important (CPI, Jobs, FOMC, Earnings, ISM Manufacturing) ⌃⌘1–⌃⌘5 · one submenu per tier (Tier 1–6) with every report, and Compute Hyperscalers Tracking ⌥⌘U in Tier 6 below Semiconductor Sales · Simulate the Long Run ⌘↩ |
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

### Investments path

The clear path for your own account, in six steps (the sidebar's **Investments** section, called My Portfolio before 2026-10-25). Every
Investments step works on **My Portfolio** (the toolbar's Account picker is fixed to it), and a bar at the top of each step shows
the account and sets **My approach** — *Active* or *Passive index* — its account type, and **Start From a Sample**
(copy any sample's holdings, lots and benchmark) or reset to the account as saved in the security master.

**Add Securities…** (⇧⌘N, above the holdings table) searches the security master (see *My Portfolio in the security
master* below). Each holding row has a trash button to remove it.

1. **My Holdings** — add, edit and remove holdings (shares, values, tax lots); value, look-through securities,
   weighted fee, unrealised gain; asset mix; *Check before you go on* (unknown or unpriced holdings, a single name over
   20%, a sector more than twice the benchmark, asset classes the benchmark doesn't hold, idle cash, missing returns).
   The ticker and the name of each holding can carry a link (⌘K; see *Links on symbols and names*).
   **Edit Holding…** (double-click a row, its pencil or context menu) edits a holding's tax lots — purchase date, shares and total cost of each; add or remove lots — or the cash; kept when the portfolio is saved.
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

My Portfolio lives in the security master — real securities, prices and benchmarks in MxDataHUB's PostgreSQL
database (`srm` on 192.168.0.223) — through the **accounts** Layer 3 service (`Services/accounts`, port 8774; start it
with `python3 Services/mxservices.py start`). If the service or the database can't be reached, a banner says so, with
*Try Again* and a link to Library ▸ Layer 3 Services; nothing is made up in its place. The account is an `srm.portfolio` with an account type, approach, cash
balance and open **tax lots** (`srm.portfolio_tax_lot`, migration V011), and the day's holdings snapshot is rewritten
from the lots when it is saved, so MxDataHUB ▸ Portfolios shows it (with a Tax Lots view and *Open in MxAcctMGR*) and
the analytics service can analyse it.

**One portfolio open at a time, like a document** (`PortfolioFile.swift`, `PortfolioSheets.swift`, migration V022):

| File menu | |
| --- | --- |
| **New Portfolio…** ⌘N | a code, name, account type, approach and benchmark; no holdings or a copy of a sample's; created in the security master and opened |
| **Open Portfolio…** ⌘O | the personal accounts in the security master — value, version, when and by whom last saved (samples and closed portfolios on request) |
| **Open Recent** | the last eight opened |
| **Close Portfolio** | The Investments steps then ask to open or create one |
| **Save** ⌘S | holdings, lots, cash, benchmark, approach and **preferences** as the portfolio's next version |
| **Revert to Saved** | drop the unsaved changes and read the saved version again |
| **Duplicate Portfolio…** | a new portfolio (new code and name) from the saved version — lots, cash, benchmark, preferences — then opened |
| **Rename Portfolio…** | the name; the code stays (MxDataHUB and `mxacctmgr://` links use it) |
| **Import Holdings…** ⇧⌘I | a CSV with a header line — Ticker (or Symbol), Shares (or Quantity), optionally Cost and Acquired (yyyy-mm-dd or m/d/yyyy), e.g. a custodian's export — resolved against the security master (`POST /securities/resolve`), previewed, then added to the holdings or replacing them |
| **Export Portfolio** | the saved version as JSON (account, lots, preferences, decisions) or CSV (tax lots) |

**Portfolio ▸ Decisions…** (⌥⌘D, or *Decisions…* in the bar): what was decided for the portfolio and why — date,
category (allocation, benchmark, approach, limits, taxes, trade, cash, other), the reasoning and the portfolio's
version at the time — kept in `srm.portfolio_decision` (V023). Append-only: a change of mind is a new decision. Each
saved version also records what changed (*Holdings: 2 added, 1 changed; Benchmark: SP500 → POLICY_GROWTH*).

**Portfolio ▸ Policy Benchmarks…** (or *Policy Benchmarks…* under the benchmark in step 2): a benchmark that is your
plan — index funds or ETFs standing in for asset classes (VTI, VXUS, BND …), the weights you aim for, and the date each
mix took effect. Saving it writes the mixes to `srm.benchmark_policy` and has the srm-loader service write its
month-end snapshots for two years (`policy-benchmarks`, in the activity log), each from the mix in force that month,
so attribution measures a 2025 change of plan correctly; *Use for This Portfolio* makes it the open portfolio's
benchmark.

Edits wait for Save (the bar shows *Edited*, with what changed in its tooltip). Each save names the version it was
made from and is refused when the portfolio was saved elsewhere since it was opened (*Not saved: … changed
elsewhere* — keep editing or revert). Every saved version is kept whole in `srm.portfolio_version`. The preferences —
the optimizer's limits, the tracker's names and budget, tax rates, lot order, rebalance band, attribution method —
are saved with the portfolio (`srm.portfolio.settings`) and come back when it is opened, on any Mac. Leaving a
portfolio with unsaved changes — opening or creating another, closing it, quitting — first asks to **Save**,
**Discard Changes** or **Cancel**, listing what is unsaved. While there are unsaved holdings, Risk Today and Optimize
send the analytics service the holdings on screen (its securities and the benchmark, the weights from the app) rather
than the saved portfolio.

**Add Securities…** searches srm by ticker, name, ISIN or CUSIP (stocks, funds, bond funds)
across all 16,000-odd active securities, 200 at a time (*Show More*), largest companies first. While it reads, the
toolbar and the empty table say which step is running and for how long — finding the securities with their latest
price and market value, then counting the values for the filter menus (after the rows show) — and list the steps done
with their times. Tickers and names carry their links, the same rows as on the Securities page and in MxDataHUB:
a click opens one, the hover card has *Edit Link…*, the row's context menu adds, edits or opens one, and Edit ▸
Link… (⌘K) works on the selected row while the dialog is open (see *Links on symbols and names*). Click any column header
(Ticker, Name, Type, Sector, Exchange, Price, As of, Market value) to sort by it — in the database, across every match —
and use the **filter row** like a spreadsheet's autofilter: ticker / name contains, Type, Sector and Exchange menus of
values with their counts (tick several), a price range, and with / without a price; a filtered column's title shows ⏷
and *Clear Filters* resets. Select a security for its sector, latest price and date, beta, market value and
identifiers, and add shares with a tax lot (cost and purchase date). Holdings without prices are valued at cost and flagged; **Load Prices** asks the srm-loader
service to load them (`srm.py load nasdaq-prices --symbols …` — Nasdaq.com's free quote API, no key needed). The
benchmark is any benchmark loaded in srm (S&P 500, Nasdaq-100, Dow, S&P 400 / 600, custom); Risk, Optimize and Build
the Tracker use the analytics service's Ledoit-Wolf covariance from two years of srm prices (holdings without enough
price history and cash are left out and listed), and Attribution uses its `/attribution` for the account's code.
Each security's market beta (against VTI), rate beta (against daily changes in the 10-year Treasury yield; ≈ −duration
for a bond fund), volatility and momentum alpha come from the same `/inputs`, and the risk-free rate is the latest
3-month Treasury yield; the equity premium (5%) is the one assumption, and the screens say so. A fund's fee is its
expense ratio from the security master (Vanguard funds; other families' show none). A ticker two securities share
shows as `TICKER:MIC` internally.

`mxacctmgr://my-portfolio/CODE` (from MxDataHUB or MxJobsMGR ▸ Window ▸ Open MxAcctMGR) opens My Portfolio on that
security-master account.

### Knowledge Library

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
* **Morning Briefing** — ten panels: an illustrative morning's overnight markets, Treasury yield changes (with the
  2Y–10Y and 3M–10Y spreads), the economic calendar (consensus, prior, impact; each release opens its walkthrough),
  an economic surprise index, Fed funds futures probabilities, weekly fund flows, credit spreads and the VIX; today's
  **real** earnings releases (the six largest from Earnings by Day, marked "you hold"); an analyst-ratings panel that
  says no source is loaded yet — with what the selected account would be worth if it opened with the futures (each
  holding's real market and rate betas). Each panel says what it measures and how a long-term investor
  might use it. Its earnings panel links to today's real list (Earnings by Day).
* **Earnings Calendar** — real earnings reports by **month** or **week** (◀ ▶ and Today step through them), weeks Sunday to Saturday as on a
  U.S. calendar. A month
  cell shows the number of U.S.-listed companies reporting, for past days a bar and count of how many beat (green),
  were in line (grey) or missed (red) the consensus EPS, and the largest names — coloured by result, or with a
  sunrise / moon for before the open / after the close — with the companies you hold first. The week view lists each
  day's 16 largest reports with the actual EPS (coloured) or the consensus. Under the grid, **This month / This
  week**: reports listed, the share that beat on EPS and on revenue, how many are still to come, and the largest
  reports still to come and already reported. Click a day (or a company) to open it in Earnings by Day.
* **Earnings by Day** — every company reporting on the day picked (date field, ◀ ▶ weekdays, Today): symbol, company,
  before the open / after the close, market cap, number of estimates, consensus and actual EPS with the surprise,
  revenue estimate, actual and surprise. Tiles count the companies, the timing, EPS and revenue beats and misses
  (or, for an upcoming day, how many have a consensus and the revenue expected) and the ones in your account. Filter
  by symbol or name, time of day, *Also FMP-only listings* (OTC, foreign and preferred-share symbols only FMP lists — named, with market cap where it applies, from the security master once `srm.py load earnings-symbols` has added them)
  and *Only my holdings*; sort by any column. Selecting a company shows this report in detail (Nasdaq.com's range of
  estimates and four-week revisions, FMP's figures where they differ, a year earlier), an EPS chart of its last
  twelve reports and the next one against the estimate, its recent revenue surprises, and Nasdaq.com's last four
  surprises. *You hold* marks (a briefcase) need My Portfolio in the security master, whose tickers are real.
* **CBOE Volatility Index (VIX)** (⌥⌘V) — the Cboe Volatility Index, real data: the latest close and change, its regime (calm under 15,
  normal 15–20, elevated 20–30, stress 30–40, panic 40 and over), the share of closes since 1990 below it, the 52-week
  range, the long-run average and median, and the S&P 500 move it implies (±VIX/√12 a month, ±VIX/16 a day). Its
  history (1M, 6M, 1Y, 5Y, since 1990) with the regimes shaded; the term structure (VIX9D, VIX, VIX3M, VIX6M) and what
  an upward or inverted curve means; and every spike above 35 since 1990 — when it began, its peak, and the trading days
  until the VIX closed under 20 again (a table that copies). The lesson: fear peaks near market lows and passes, so the
  VIX explains swings rather than timing a plan. Data: Cboe's daily history files (cdn.cboe.com, no key) — the
  security master's copy (`srm.py load cboe-vix`, through the accounts service's `GET /market/series`) when it has the
  last few trading days, else Cboe itself — read at most hourly and kept in the app's Caches folder for when neither
  can be reached. The Morning Briefing's illustrative
  VIX panel and the Report Library's morning reading link to it.
* **Compute Hyperscalers Tracking** (⌥⌘U) — AI compute as an asset theme, followed through what the hyperscalers spend to build it, with
  real reported figures: Microsoft, Alphabet, Amazon, Meta and Oracle's quarterly capex — combined for the latest
  calendar quarter all have reported and against a year earlier, over the last four quarters, and as a share of their
  operating cash flow and revenue — in a stacked chart by calendar quarter (3, 5 or 10 years); a table company by
  company (latest quarter and its growth, last four quarters, capex / revenue, capex / cash flow, depreciation, free
  cash flow; copyable); capital intensity over time; **where the money goes** — the revenue and growth of Nvidia,
  Broadcom, AMD, Micron, Arista, Vertiv and Equinix; and **your exposure**, the share of My Portfolio (in the security
  master) held in these companies directly. The lesson: capex is the suppliers' revenue, building ahead of demand has
  happened before (fibre around 2000), and an index fund already holds the theme. Data: FMP's quarterly cash-flow and
  income statements through the accounts service (`GET /fundamentals/quarters`), which keeps them 12 hours: the
  security master's copy (`srm.py load fmp-fundamentals`) when it was loaded in the last 14 days, else FMP itself.

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
  yields, Freddie Mac mortgage rates), and for the earnings reports MxAcctMGR's own Earnings by Day and Earnings
  Calendar. The addresses (`ReportSources.swift`) were checked in a browser on 2026-10-22; OPEC's monthly report is
  left out because its site puts up a bot check.

  The **Yield Curve Report** adds the real curve below *The real report* (`YieldCurve.swift`), over several time
  frames: today's yields (3-month, 2-, 10- and 30-year, each with its change in a year) and slopes (10Y − 2Y,
  10Y − 3M) with how long the curve has been inverted or not; **the curve, then and now** — 1-month to 30-year today
  against 1 month, 1 year, 5 and 10 years before (tick which); **the slope over time** and **yields over time** for
  1, 5, 10 or 25 years or since 1977, with NBER recessions shaded; and **every inversion since 1981** (10-year below
  the 3-month) with the recession that began within three years and how many months later — or "none yet", as after
  the longest, which began in 2022 (a table that copies). Data: the Treasury's daily constant-maturity yields and the
  NBER recession months from FRED (free CSV, no key) — the security master's copy (`srm.py load fred-yields`, through
  the accounts service) when it is current, else FRED itself — read at most hourly and kept in the app's Caches folder.

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

The day's move is a market move, a change in the 10-year yield, sector moves and one company's move; it lands on
the account through each holding's real market and rate betas and its sector. The single-company reports (Earnings,
Earnings Revisions, Semiconductors, Bank Earnings, EIA Petroleum) name no company of their own: theirs is the
account's largest stock in the report's sector (or its largest stock), named in the text with the numbers marked
hypothetical; an account with no single stock gets only the sector and market move. **The Long Run** runs the **Behaviour Lab**: every reaction and *Stay with the plan* on the
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
  security without a ticker has none, but any address works. *Remove Link* takes it off.
* **Links to your notes in MxNoteONE**: right-click a page, paragraph, section or notebook in MxNoteONE ▸ *Copy Link
  to …*, then in the Link dialog press **Use the Link Copied in MxNoteONE** (it shows when MxNoteONE's link is on the
  clipboard) — or paste the `mxnoteone://…` address. The title copied with it (the page's, section's or paragraph's) is
  kept with the link, since MxAcctMGR can't read MxNoteONE's notebooks: the hover card shows it, with a page, paragraph,
  pin, section or notebook symbol, and "Click to open in MxNoteONE". Clicking opens MxNoteONE there; MxNoteONE opens
  `mxnoteone://` links from other apps from the version released with this (older ones don't, and MxAcctMGR then says
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
BRK.B, BRK-B and BRK/B alike). Links stay on this Mac for tickers the security master doesn't list; a link saved while the accounts service can't be reached is kept here too, and goes to
the security master the next time it answers (the dialog says where each link is kept). Links made on this Mac before
are sent there the same way, unless the security master already has one for that ticker or name.

### Checking register (Banking ▸ Checking Accounts)

The register's bar has **Hide entries before** a date (or **Recent** ▸ the last 7, 30 or 90 days, this month, this
year) and **Rows**: how many of the register's rows show at once (6–40, 22 at first; the rest scroll inside it). Fewer
rows leave room for the rest of the page, so it needs less scrolling. The same **Rows** control sits above the Credit Card
Accounts register and its Statements, the Expense Ledgers register, and the Target Accounts and Secure Accounts
tables: one choice for all of them, remembered — changing it in one table changes every one. Rows are as tall as Settings ▸ Text ▸ Registers
and tables makes them. Its columns: Line, Date, Num, Target, Payment, Deposit, ✓ (cleared) and Balance; an entry's
category and memo are in *Edit Entry…* (double-click) and in *Copy Entry*. The **New entry** line above it takes
the date, the kind (or check number), the target and the amount; picking a known target fills in its usual amount and
files the entry under the target's category. It starts as a **Debit** with no check number, on the date of the entry
entered before; its gear button opens **Settings ▸ Banking**, where the kind, the check number (empty or the register's
next) and the date (the entry before's or today) it starts with are set.

### Importing a card download (Banking ▸ Credit Card Accounts ▸ Import File…)

Download the card's activity from the card company — Chase: Spreadsheet (CSV) or Quicken (QFX / OFX); Discover
(*All Available* reaches back two years) and Capital One: CSV — and pick it with **Import File…** above the card's
register. Before anything is saved, a sheet shows what the file holds for the card (`POST /cards/accounts/<code>/import`
with `preview`): what it is (Discover CSV …) and its dates; how many lines are new and how many were read already —
by a download that overlapped it, or from the card's other format (a Chase CSV and a QFX of the same weeks); the new
lines by kind (charges, credits, payments, fees, interest) and how much they change the balance owed; and every line,
or only the new ones. It warns of new lines dated before the register starts (*Edit… ▸ Register starts* and *Owed
then* set where the balance begins), of card-company categories with no expense account, and of a CSV from another
card company than the card's. A file that names another card (Chase's *Chase1234_Activity…* file names, Capital One's
Card No., a QFX's account) is refused — pick that card — and so is a file that isn't a card download.

**Import *N* New Lines** saves the file in the card's drop folder (`src-cards/<CODE>/`) and runs `srm.py load
card-downloads` through srm-loader (it shows in the shared activity log): each line is read once and posts to the
register — matching a charge entered by hand, else as a new entry with its target and category — and the card's
payments link to the checking entries that paid them once *Paid from checking as* is set.

### Removing a card (Banking ▸ Credit Card Accounts ▸ Remove…)

**Remove…** beside Edit… first asks, in a sheet, with what removing the card would clean up (`GET
/cards/accounts/<code>/removal`): its register entries (and how many were entered here rather than downloaded), the
lines read from the card company's downloads, the statements entered, and the downloads in its drop folder — and what
stays: its checking target and the checking entries that paid it, the expense-ledger entries naming its charges (both
unlinked), the target accounts its charges were filed to, and the activity log. **Cancel** is the default; **Remove
*card*** takes it away (`DELETE /cards/accounts/<code>?confirm=<code>`), which can't be undone. Its drop folder is moved
to `src-cards/_removed/<CODE>-<date-time>/`, not deleted, where card-downloads doesn't read it.

### Removing expense ledger entries (Banking ▸ Expense Ledgers ▸ Register)

Right-click an entry for **Void** (it stays on record, struck through and out of the balance; **Restore** brings it
back) or select one or several and choose **Delete Entry…** / **Delete N Entries…** (or press Delete) to remove them
for good after a confirmation that names them and their total. Deleting is all or none, and refused when someone changed
one of them since the register was loaded. A card charge or check an entry was linked to stays in its register; the
entry's spending tag and any Year-End Tax move of it go with it, and assets or training records that named it keep no
entry.

### Target accounts (Banking ▸ Target Accounts)

A target account is where a register entry's money goes to or comes from — a utility, a card, a brokerage, a person
(`srm.payee`; called External Accounts before 2026-10-25). The page lists them all in one table (the *Show inactive
and closed* box adds those): name (as its link when it has one, with its status when not active), category,
**Funding** (a checkbook mark when the Checking register pays it, a card when the card registers do), *This year*
(this calendar year's payments), *Total paid* (every payment in all registers and years — a card target last paid in
2025 shows nothing this year but its total here) and *Last paid*. Each column header's button sorts and filters it, as in Excel (the registers' own: values
to tick, text contains, number and date ranges), and *Clear Sort & Filters* above the table puts it back. Above the
table: *New Target Account…*, *Add from Card Registers…* and *New Category…*.

**Add from Card Registers…** lists the targets credit card entries carry without a target account, as the card company
names them (`GET /cards/targets`), with their entries, total, last date and kinds. The merchants (charges, credits)
start ticked; the card company's own lines (payments, interest, fees, adjustments) don't. Adding makes each ticked one
a target account that the card registers offer (a recipient of credit card payments), in the category its entries
mostly have, and links those entries to it (`POST /cards/targets`); a card line with the same name later is filed to
it too, as card lines find their target by name. A name a target account already has just gains the card source.

The rows aren't edited in place. Right-clicking anywhere on a row (its words aren't selectable text, so the menu is
the same on every column) offers:

* **Edit Target Account Name…** — renames it; Save closes the dialog. Names are unique whatever their case (the
  security master's index on the lower-cased name): the dialog says when another account has the name and won't save
  it, and the accounts service refuses one taken since. The registers show the new name for every entry with it.
* **Edit Target Details…** — the account's details, in this order: *Nickname*, *Description*, *Status*,
  *Identifier*; the *Next payment* (date, amount); *Logon URL*, *User name*, *Password*, *User keys*; *User notes*;
  *Address 1*, *Address 2*, *City*, *State*, *Zip code*, *Phone number*; and its **Funding sources**. The account's
  name, bank, last four digits, category, usual amount and bank names stay as they are (the service keeps what a save
  doesn't send).
* **Add Link to … / Edit Link on …** (the Link dialog, below) and *Open Link*.

**New Target Account…** takes every detail of it: *Account name*, *Nickname* (the registers' target lists show it
beside the name), *Description*, *Status* (active; inactive or closed — kept with their entries, offered by no
register), *Identifier* (your account or customer number with them), *Bank / company*, *Last four digits*, *Category*,
*Usual amount*; the *Next payment* (date and amount, shown on the target's hover in the registers); *Logon URL* (open
it from there), *User name*, *Password* and *User keys* (security answers, recovery codes, PINs; hidden until *Show the
password and user keys*, each with a copy button); *User notes* (the note shown on hover in the registers) and the
bank's names for it; *Address 1*, *Address 2*, *City*, *State*, *Zip code*, *Phone number*; and its **Funding
sources**.

* **Funding sources** decide which registers offer it as a target: *Recipient of checking account payments* (the
  Checking Accounts register's target list) and *Recipient of credit card payments* (the card registers'); either,
  both, or neither (offered nowhere). Existing accounts started with the sources they had been paid from (V033), both
  when not paid yet. A name typed in a register that isn't a target account becomes one with that register's source;
  a target account a register names (typed, or a bank line accepted) gains that register's source.
* **The password and user keys** are kept in this Mac's Keychain (service `com.k3jdr.MxAcctMGR.target-accounts`, one
  item each per account), never in the security master: other Macs, and others using the registers, don't see them,
  and they don't move to another Mac (the app can't use iCloud Keychain without a provisioning profile). Everything
  else is in the security master with the account (V033), shared like the registers.

### Links on sidebar pages

Right-click a page in the sidebar for *Add Link to … / Edit Link on …*, *Open Link* and *Remove Link*: the same Link
dialog as for securities and target accounts (Text to display, Address — a web page, an email address or a page in
MxNoteONE — and formatted Hover text). Kept on this Mac with MxAcctMGR's preferences, one per page: the pointer resting
on the page's row shows its hover card, and the row's link mark opens it; a click on the row still opens the page.

### Links on target accounts

A target account can carry a link the same way, made with the same **Link** dialog
and shown with the same hover card: *Text to display* (the account's name unless you change it), *Address* (a web
page, an email address, or a page in MxNoteONE — *Use the Link Copied in MxNoteONE*; the account's logon page is
offered when it has one), and formatted **hover text** with links of its own, with a *Hover card preview* and *Remove
Link*. Open it from a Checking or card register entry's target (the link button that shows on hover, or the row's
context menu, *Add Link to … / Edit Link on …*), from a Target Accounts row's context menu, or *Edit Link…* on the
hover card.

The link belongs to the target account, so it shows wherever the account is a target: its name is shown as the link
in the Checking Accounts register's Target column, the card registers' and the Target Accounts table. A click opens
it; resting the pointer on it shows the hover card. It is kept in the security master (`srm.payee_link`, V032) through
the accounts service (`PUT` / `DELETE /payees/<id>/link`), apart from the account's own details, so saving a link
never conflicts with someone editing them. A change made on one screen shows on the others (each loads again after a
save; the Checking register also every 30 seconds). The target's note (the pencil) stays as it was: with a link, it
shows on the last four digits and the note mark, and the link's hover text on its words.

### Secure accounts (Banking ▸ Secure Accounts)

Modeled on Target Accounts: the products and services you hold an account with — software, data services, APIs —
kept in the security master (`srm.secure_account`, V035; the accounts service's `/secure-accounts`). Each has:

* **Product**: its name (unique whatever its case), a description and its **product key** (a license key).
* **Service**: its web address (*Open the Service Page* from the row's menu), its API (base URL or endpoint), its
  **service key** (an API key) and its status — active, inactive or closed (*Show inactive and closed* lists those).
* **Owner** (your user account): your user name and **password**.
* **Subscription**: the last payment (date, amount) and the renewal — its date, its amount, and whether it
  **auto-renews**, you **renew** it by hand, or you **decline** it and let it lapse — kept in *Edit Service
  Details*. *Renewing* above the table adds up the renewal amounts not declined.

The product key, service key and password are kept in this Mac's Keychain (service `com.k3jdr.MxAcctMGR.secure-accounts`),
never in the security master: other Macs don't see them; the editor masks them unless *Show the keys and password* is
on, and each has a copy button. The **Service Product Table** lists each one's product, status, service, user name and
**Keys** (which of its service key, product key and password the Keychain holds),
read-only with Excel-style sorting and filters on every column; right-click a row for *Edit Service Name…* (refused
when another service has the name, whatever its case; Save closes it) or *Edit Service Details…* (also a double-click).
*New Secure Account…* adds one.

**API keys for MxJobsMGR.** A service key is also an API key: each of MxJobsMGR's API subscriptions names a secure
account and its calls send that account's service key, so Secure Accounts is the one place API keys are entered and
changed (MxJobsMGR has no key entry of its own). The keys are saved trusting both apps (`Shared/SharedKeys.swift`: each
by bundle id and signing certificate, MxJobsMGR as installed in /Applications), so MxJobsMGR reads them without a
password prompt. MxJobsMGR's API Subscriptions opens `mxacctmgr://secure-accounts/<id>` (*Open in MxAcctMGR*: that
account's Edit Service Details) or `mxacctmgr://secure-accounts/new?name=…&api=…&url=…` (*New in MxAcctMGR…*: New
Secure Account filled in with the subscription's name, base URL and documentation, or the account of that name if
there is one). Its *Move Keys to Secure Accounts* moved the keys it used to keep itself into the secure accounts of
the subscriptions' names, making the missing ones through the accounts service (ADR-0018 in `MxJobsMGR/c4/adr`).

**Import Passwords and Keys…** reads a credentials worksheet from the workbook **open in Microsoft Excel** (Apple
Events: macOS asks once whether MxAcctMGR may control Excel; an encrypted workbook can't be read from its file, and no
CSV with passwords in plain text is made). Columns: A user ID, B password, C account description, D notes, E keys. Each
row names a secure account as the accounts were seeded from it (2026-10-25, 101 from `.sync-up.xlsx` ▸ Creds): a web
address without its scheme and `www.` (the address becoming the service URL), a license key or `(PIN …)` taken out of
the description, the user ID when there's no description, and " 2", " 3" … after a name already taken. The row's
password goes to the Keychain as the account's password; column E, else the license key or PIN, as its product key; a
user ID that is a token (an API key's id) as its service key, never its user name. Notes fill an empty description
(optional). Accounts not found are made. The preview shows names and which secrets each row has — never a secret.

### Learn the Why

* **Why Optimize?** — two live demos: diversification (volatility of 1–36 equal-weighted companies falling to the
  market's floor) and the stock / bond trade-off (the risk–return line of every mix); then what an optimizer does
  with forecasts, a risk model and limits, and why limits matter ("error maximisation").
* **Why Attribution?** — a two-sector Brinson-Fachler demo with sliders: allocation, selection and interaction recomputed
  as you move the weights and returns.
* **Active vs Passive** — what fees compound to over 30 years (fee and pre-fee alpha sliders) and a comparison table.

## Spending Analysis (Reporting ▸ Spending Analysis)

Household spending attribution: performance attribution for the family's spending. It explains why spending changed
from one year to the next and forecasts what the children's ages bring. Everything is kept in the security master
(V037) through the accounts service (`/spending/…`, `Services/accounts/spending.py`).

* **Two dimensions on every dollar.** The spending is every entry of the check register in an expense account, the
  credit cards' charges and credits, and the expense ledgers' items that aren't already a card or check entry
  (`srm.v_spending_entry`). Each gets a **spending category** (Food, Housing, Transportation, Education, Activities,
  Technology, Healthcare, Clothing, Travel, Other) and a **primary driver** (Inflation, Family Growth, New Activity,
  Lifecycle Transition, Preference Change, Lifestyle & Hobbies — V045, One-Time Event, Taxes — V044), and optionally a
  family member. They come from **rules**:
  an expense account's (V037 seeds the categories from the expense accounts' names); overriding it, a **statement
  text** rule (V042: every entry whose payee, statement name or description contains the text, ignoring case — the
  longest text wins when several match); and overriding both, a target account's. A **tag** on a single entry
  overrides them all, and can name an event ("Philmont 2026"). Rules are set on *Rules*; tags on *Entries*
  (double-click, or select several and right-click). The *Entries* context menu also opens the rule for an entry's
  target account, statement text or expense account, and **Change Expense Account…** files the selected card and
  check entries under another expense account (NJM INSURANCE from Subscriptions & Services to Insurance). With *Also
  file future charges under it* (on at first), their target account is filed under it too; entries with no target
  account get one (named in the sheet, found or made) that carries their statement names, so the next card and
  checking downloads post to it, under that expense account. Expense-ledger entries take their budget line's expense
  account and don't change.
* **What Amazon charges bought.** An Amazon charge reads only "AMAZON MKTPL*BD9ZG3640". Once Amazon's order export is
  read (Sources ▸ Amazon Orders), each charge matched to its order shows what was bought: the *Bought* column of the
  entries tables (Entries and the Deep Dive; "Kids' Swim Goggles, 3 Pack and 1 more", every item with its cost and the
  order number on hover, and on the Payee's hover), the Tag Entry sheet, and the Deep Dive's Largest This Year. The
  search finds entries by an item's name. The context menu opens the order on amazon.com (you sign in there). A credit
  matched to a return shows the item refunded. The Bought words are a link to the order: hover shows the items and
  whether Amazon's Transactions list or the export (by amount and date) matched it; *Edit Link…* on the card looks
  the charge up again, *Remove Link* (or *Take Amazon Orders Off*) takes its orders off for good — the export doesn't
  match it again.
* **Look Up Amazon Orders…** (Entries, right-click selected Amazon charges; `AmazonLookup.swift`): finds what they
  bought on amazon.com without waiting for an export. It opens its own window with Amazon's pages in it (WebKit); you
  sign in there yourself, the first time and whenever Amazon asks — MxAcctMGR never sees, types or keeps the password,
  and leaves sign-in, two-step and robot checks to you (the lookup waits up to ten minutes, the page yours meanwhile;
  while it reads, the page is the lookup's). It reads Your Payments ▸ Transactions, which pairs each card charge with
  its orders (the same amount and sign within 4 days, the closest first, the card's name breaking ties) — older
  charges further down, by its Next page button or, on the newer list, its Show more button or the bottom of the page
  (when nothing more comes, *Steps* lists the page's controls); for charges not there, Your Orders for their year
  (`timeFilter=year-…`: otherwise Amazon shows only the past 3 months; an order whose total is the charge, placed up
  to 30 days before it) — the **Digital Orders** tab for **Prime Video** rentals, purchases and channels, Kindle books
  and other digital charges (D01-… orders, placed within 5 days); then each order's page for its items (a video's
  title; a channel's renewal by its item title), unless the security master has them. One page every 3 seconds, at
  most 40 Transactions pages, 30 Your Orders pages a year (back to a month before the charges; the year before too for
  a January charge) and 25 orders a run. The window lists the
  charges and the orders found (*Steps* shows each page read). **One order at a time:** each charge's row takes an
  order number typed or pasted (several, comma-separated, or an order page's link) — *Attach* reads only that order's
  page (none when the security master has it) and attaches it in place of what the charge had — and *This Order*
  attaches the order the window shows (*Your Orders* and *Digital Orders* open the lists to find it). *Attach an Amazon Order…* in the
  Entries menu opens the window that way, without the full lookup. Amazon's card offers on order pages aren't items. The results attach as the export's do (`POST /spending/amazon/attach`); an export read later
  replaces what an order's page gave and narrows the charge to its shipment. *Sign Out of Amazon* clears amazon.com's
  cookies from the window. Amazon's Conditions of Use don't allow robots: it runs only when you ask, at your own risk,
  and may stop working when Amazon changes its pages (its scripts read the pages' words, not their layout, to last
  longer).
* **Rules.** *Expense Account Rules*: one row per expense account. **New Expense Account…** adds one (Home Office,
  Studio) with, if you pick them, its spending category and driver; right-click an expense account for **Edit Expense
  Account…** (name, description) or **Remove Expense Account…**: one in use (card and checking entries, target accounts,
  expense-ledger lines, the card companies' categories mapped to it) moves all of it to the expense account you choose
  first, and its own spending rule goes. Names are unique, ignoring case. *Target Account Rules*: the target accounts with a
  rule first (bold, ✕ removes it), then every target account with spending in either year, most spent this year first;
  *Only rules* hides the rest. Picking a category, driver or member on a row gives it a rule. Only entries linked to a
  target account (the check register, Chase) have one — Discover's charges and the expense-ledger lines carry only the
  statement's words — so *Statement Text Rules* covers those: *Add Statement Text Rule…* (the sheet shows what the
  text matches as you type), ✎ to change a rule's text, ✕ to remove it, and *Largest statement names no rule reaches*
  with *Add Rule…* for each. Every row shows both years' spending. Target account and statement text names carry
  links as Banking's target accounts do (the Link dialog: Text to display, Address, Hover text): right-click a name
  for *Add Link…* / *Edit Link…*, *Open Link*, and its rule; a linked name opens on a click and shows its hover card,
  and an unlinked one shows its details (bank, last four digits, category, notes, what its rule says) or what the text
  matches. A target account's link is the one Banking shows (`srm.payee_link`); a statement text's is kept with its
  rule (`srm.spending_rule_link`, V043). A family member can be picked once the family is
  set up on *Family & Lifecycle*.
* **Overview (the attribution).** For each category, `change = inflation + usage + lifecycle + behavior + one-time + taxes`. Inflation is
  the earlier year's spending times the category's CPI change, plus whatever spending tagged Inflation grew beyond it.
  Each other driver's effect is what its spending grew beyond inflation: Family Growth and New Activity (and spending
  with no driver) count as usage, Lifecycle Transition as lifecycle, Preference Change and Lifestyle & Hobbies as behavior, One-Time Event as
  one-time, Taxes as taxes (its own effect: a Taxes column, bar and, once something is tagged Taxes, tile). The effects
  add up to the change exactly. The **Key Metrics** table gives each category's earlier and
  current spending, change, growth %, and each effect's share of the change, with a reading: unavoidable (prices or
  age), habit change, one-time, taxes, or more of the same. Charts: a waterfall from last year to this year, each category's
  change by effect, and this year's spending by category and driver.
* **Deep Dive.** Take one category apart: right-click (or double-click) its bar or its name in *This Year by
  Category and Driver* or *What Changed Each Category*, or click its name in Key Metrics. The **Deep Dive** tab (with
  a category picker and a way back to the Overview) shows:
  - its earlier and current spending with each effect and the CPI change, as tiles and a waterfall;
  - its spending month by month in both years;
  - **By Driver**: each driver's spending in both years and what it grew beyond prices, adding up to the change with
    the price change on last year's spending;
  - **How Entries Got Here**: which expense-account, statement-text and target-account rules and entry tags put its
    entries in it,
    each with the rule's category, driver and member, both years' spending and *Rule…* to change it;
  - **Where It Went**: by expense account, with the target accounts whose spending changed most;
  - the ten largest entries this year, and spending by family member;
  - its lifecycle triggers and what they bring each child in the next ten years;
  - its entries, to tag. The entries tables (here and on Entries) keep their column widths, order and shown columns
    across reloads and launches: drag a header's edge to widen Payee.
* **Sources.** A strip above every tab names the sources included and how fresh they are: the newest spending date,
  when the card and checking downloads were last read, the last Amazon order read, and the CPI's latest month. It turns orange when a register's
  newest spending is more than 14 days old or the CPI more than 75. Its *Sources…* button opens the **Sources** tab,
  which shows:
  - **Time Window:** the two periods' dates, year to date or whole years, how partial registers are treated, and the
    CPI months compared.
  - **Spending Sources:** each checking account, credit card and expense ledger, with a checkbox that includes it or
    leaves it out. The choice is kept in the security master (`srm.spending_source`, V038), shared by every Mac, with
    who changed it and when. For each source:
    - where its data comes from: the loader (`pnc-bank`, `card-downloads`), its drop folders (`bank_accounts.local.json`
      / `card_accounts.local.json`, else `src-bank`, `src-cards`) and the downloads there for the account, newest first,
      with their dates and sizes; or, for a ledger, entries made by hand;
    - the tables its data lands in (`srm.card_line` → `srm.card_txn` → `srm.v_spending_entry`), with its lines' dates;
    - its last import (the `srm.load_run` that wrote its newest lines);
    - its register: entries, dates, how many came from downloads, the last edit;
    - its spending in both periods.

    A checking account none of whose entries is in an expense account says that none of it counts as spending (card
    payments and transfers aren't).
  - **Amazon Orders** (V046): where Amazon's order export comes from — amazon.com ▸ Account ▸ Request Your Data ▸
    Your Orders; Amazon e-mails a link to a zip — its drop folder (`amazon_orders.local.json`, else `src-amazon`) and
    the exports there; the tables it lands in (`srm.amazon_order` → shipments, items → `srm.amazon_match` →
    `srm.v_amazon_charge`); its last load; the orders' dates, orange when Amazon charges came after the export's last
    order (a newer export is due); and how many of the period's Amazon charges it matched. **Import Export…** picks the
    zip (or a `Retail.OrderHistory` CSV), saves it in the drop folder and runs `amazon-orders` through srm-loader;
    **Read Again** runs it again (new card charges then find their orders). *Not matched* lists the period's Amazon
    charges no order matched and the shipments no charge paid (another card, a gift card), each order opening on
    amazon.com.
  - **SRM Tables in the Aggregation:** every table and view the analysis reads, with what it gives the analysis, its
    rows, its newest data and its last change.
  - **Last Loads:** the latest `pnc-bank`, `card-downloads`, `amazon-orders` and `fred-yields` runs.
* **Admin.** The expense accounts, and guidance and tools for the two relationships the analysis rests on (MxAcctMGR
  only, not the family page):
  - **Expense Accounts**: every expense account with its description, its rule (category · driver · family member;
    orange when it has none) and this year's spending and entries, with **Edit…** (name, description), **Rule…** and
    **Remove…** on each and **New Expense Account…**, the same sheets as the Rules tab's;
  - **Driver & Category**: a category is what the money bought (its CPI decides the inflation part), a driver why the
    spending changed (it decides the effect); they are independent, and each comes from the first of the entry's tag,
    its target account's rule, a statement text rule and its expense account's rule. A table says what each driver
    counts as. **This Year: Category × Driver** shows this year's spending in both, spending with no driver or category
    in orange; a click on a cell lists what put its entries there (category from, driver from) with *Rule…* to change
    it, and its largest entries.
  - **Target Accounts & Expense Ledgers**: a target account is who was paid, an expense ledger what it was for; one
    purchase can be both a card charge and a ledger entry. Linked (Add from Card Charges, or *Link*), it counts once,
    as the charge; unlinked, the ledger entry is spending of its own and the purchase counts twice while the ledger is
    in the analysis. **Counted Twice** lists the ledger entries that match an unlinked card charge or check (the same
    amount within a week), with the nearest match (or a choice of up to three), *Link* and *Link All…*. Void and
    Restore a ledger entry to undo its link.
* **Year-End Tax.** A tax year's tax-applicable expenses, tax payments, real estate taxes, refunds and tax savings
  account, built from **tax items** (V040). A tax item is a target account (Peco, H Federal Taxes …), an
  expense-ledger line (Home Office Desk Buildout) or a name the card companies use (TURBOTAX). V040 seeds them from
  the target accounts there are. Most of these payments are checking entries with no expense account, so they aren't
  spending: the report reads the registers for them directly. The tab shows:
  - the expenses by category, each with what it cost and its deductible share (type a percent, e.g. 15% of
    utilities for a home office) and the deductible amount;
  - estimated and local tax payments by jurisdiction and quarter. Estimated payments follow their quarter: January
    counts as Q4 of the year before. *Move…* puts a payment in another year or quarter, e.g. an April payment that
    settles last year's return;
  - real estate taxes; refunds, each counted toward the year before the one it arrives in; and the tax savings
    account, set aside against taken out;
  - a warning when a register the items draw on starts after January 1 (PNC Checking starts 12/26/2025, so 2025 is
    incomplete).

  *Copy Summary* copies the year as text. *Export CSV…* saves every payment, then each item's totals, the payments by
  quarter and the summary, for whoever prepares the return. *Tax Items* adds, edits and removes items.
* **Send Family Link.** The menu beside the tabs opens Mail (**Email…**) or Messages (**Message…**) with the family
  page's link and a short note, addressed to the email and phone saved under **Link and Recipients…**. The link is
  kept in this Mac's Keychain because it carries the page's key; it is the same link through every release and
  changes only when John changes it on the PC. With no link saved, Email… and Message… open Link and Recipients first.
* **The family's web page and Feedback.** The same page, read-only, is on the home network for the rest of the
  family (`Services/spending-web` on K3JDR-DSKTOP-11; see its README for the link and how it is kept private). Notes
  sent from it (💬 on a section, ⚑ on a purchase, *Suggest a change* on a rule) come to the **Feedback** tab. The tab
  name counts the new ones. Each note shows:
  - who sent it and when, what it is about and where on the page it came from;
  - for a purchase, its date, payee, amount and category at the time, and the change she suggests.

  Set its status (New, Seen, Planned, Done, Not planned) and a reply, then Save: the page shows both under her
  *My Notes*. The page can also change an entry's category or driver, and a lifecycle trigger's category or kind
  (V041). Each change applies at once and is listed here as *A change on the family page*, saying what it was before;
  **Undo** puts it back. *Tag Entry…* tags the purchase a note is about, and *Deep Dive* opens its category.
* **Layout.** The tabs are a row of buttons, each as wide as its name. When the window is too narrow for the page, the page scrolls sideways from its left edge instead of growing under the sidebar (`StepPage(scrollsHorizontally:)`, available to any page). The year controls and the Entries filters wrap to a second line when narrow.
* **Periods.** A year against the year before, year to date by default (January 1 to today's date in both).
  *Only registers covering both years* leaves out a register whose entries start after the earlier year does, so
  its whole spending isn't counted as growth (the TECH_2026 ledger starts in December 2025).
* **Inflation.** It comes from FRED's CPI-U series in the security master (`market_series` family INFLATION, loaded by
  `srm.py load fred-yields`): food, shelter, transportation, tuition and childcare, recreation, information
  technology, medical care, apparel, airline fares, and all items for Other. A category's change is its months in
  this period over the same months a year earlier. With no values for those months, the category's assumed rate is
  used, marked with `*`. *Family & Lifecycle* sets each category's series and assumption.
* **Family Spending Forward Curve.** The family members are kept with their birth years. A child's age in a year is
  the year less the birth year. Each **lifecycle trigger** (V037 seeds them; edit them on *Family & Lifecycle*) costs
  its yearly amount in today's dollars in each year a child is of age for it, and a replacement costs it once every
  few years. The seeded triggers: school by stage, tutors 14–16, SAT/ACT prep 16, applications 17, college 18–21;
  club sports 10–12, scouts 11–17 with a high-adventure trip every other year 13–15; a phone from 12 every 3 years,
  electronics 12–14, a laptop from 13 every 4, a tablet from 8 every 5; driver's ed 15, insurance and a car 16–18;
  college visits 16–17. With *Grow with inflation* on, costs grow by their category's CPI change, except peak events,
  which distance and participation drive. The chart stacks ten years by child or by category. *Waves Ahead* lists the
  years whose costs rise most and what starts in them, the three-to-five-year ones first. *Year by Year* gives each
  child's cost and age. *Child Lifecycle Model* draws the triggers by age with each child's age today.

## SRM Table (Reporting ▸ SRM Table)

MxDataHUB's Securities page in MxAcctMGR: the security master's securities, searched by name or any identifier
(ticker, ISIN, CUSIP, SEDOL, FIGI, CIK, LEI — current or past), filtered by **Type**, **In** (a benchmark's members
on its latest date, the benchmarks by name: the S&P and Nasdaq indexes, and the 401(k) plan's Vanguard Institutional Total Stock Market, Total Bond Market and Total International Stock Market Index and Vanguard Total International Bond Index from `vanguard-holdings`, whose international stocks and non-Treasury bonds are priced at each month-end from Vanguard's holdings: their Price and As of are that valuation in dollars, their Ticker the ISIN) and **Active only**, and by any column from its header (sort, the column's values with their
counts, or a condition — numbers and dates compared as such), a thousand at a time with Previous / Next. Like Add
Securities, the table shows Ticker, Name, Type, Sector, MIC, **Price**, **As of** and **Market value**, priced
securities first and the largest first; the identifiers are in the details. Select several rows with ⌘-click or ⇧-click (⌘A for the page): ⌘C, or the context menu's *Copy N Rows*, copies them under the column titles, tab-separated for a spreadsheet; the status line counts the selection and the details show the last row clicked. Selecting one shows its last year of closes, its
identifiers with their dates and sources (a table that copies), then its issuer and security facts, listings,
classification, benchmark membership and corporate actions as one selectable text. Links on tickers and names are the
same rows as MxDataHUB's (`Shared/Links`): ⌘K, the row's context menu, or a hover card's Edit Link…. MxAcctMGR reads
the database through the accounts service (`POST /securities/browse`, `/securities/browse/values`,
`GET /securities/<id>/detail`, `GET /security-types`), which runs MxDataHUB's queries; the two panes use the shared
`SplitPanes` (`Shared/SplitPanes.swift`).

## Sample portfolios (Library ▸ Sample Portfolios)

Each sample is an edge case, and an account in the security master: `srm.py load sample-portfolios` (MxDataHUB/SRM,
run through the srm-loader service so it shows in Data Refresh ▸ Activity) writes them with real securities, tax lots
costed at the real close on each purchase date, cash and a benchmark, managed by "MxAcctMGR samples". The app reads
them through the accounts service like My Portfolio and keeps only each one's lesson (`Samples.swift`). *Use* makes
it the account of the report walkthroughs and the Morning Briefing; *Copy to My Portfolio* (or My Portfolio's *Start
From a Sample*) copies its holdings, lots and benchmark into My Portfolio to work through the six steps.

| Sample (code) | Account | Benchmark | Edge case |
| --- | --- | --- | --- |
| Core & Satellite (`SAMPLE_CORE_SATELLITE`) | Retirement | SP500 | The ordinary active case: a total-market fund plus eight S&P 500 names |
| Concentrated Employer Stock (`SAMPLE_EMPLOYER_STOCK`) | Taxable | SP500 | Nearly half in MSFT, low-basis lots from years back plus a short-term lot |
| Sector-Heavy Technology (`SAMPLE_TECH_HEAVY`) | Taxable | SP500 | Most of the account in technology through a fund and overlapping names |
| Retiree Income (`SAMPLE_INCOME`) | Retirement | BAL3070 | Mostly bond funds plus rate-sensitive dividend stocks |
| Cash-Heavy, Waiting to Invest (`SAMPLE_CASH_HEAVY`) | Taxable | BAL6040 | 45% cash kept back "for the dip" |
| High-Turnover Trader (`SAMPLE_TRADER`) | Taxable | SP500 | Every lot under a year old |
| Direct-Index Tracker, Drifted (`SAMPLE_DRIFTED_TRACKER`) | Taxable | SP500 | The 22 largest S&P 500 names at their 2024-10-21 index weights, never rebalanced |
| Tax-Lot Harvesting Case (`SAMPLE_TAX_LOTS`) | Taxable | BAL6040 | Lots at large gains and at losses; FIFO vs highest-cost-first; harvesting |
| 60/40 Outside Its Band (`SAMPLE_6040_DRIFT`) | Retirement | BAL6040 | Drifted past 70/30 after a rally |
| Missing & Messy Data (`SAMPLE_MISSING_DATA`) | Taxable | SP500 | A delisted security with no price (ACVA), a unit with a short history (ALUB.U) |
| My Portfolio (`MY_PORTFOLIO`) | yours | yours | Editable; *Copy to My Portfolio* starts it from any sample |

**BAL6040** and **BAL3070** are blended benchmarks the same loader writes (VTI / BND at 60/40 and 30/70, month-end
snapshots for two years). Attribution needs history: the samples have one holdings snapshot (the day they were
loaded), and the S&P 500's weights in the security master start in October 2026, so a year's attribution uses today's
weights throughout and says *review*.

## Engines — built-in and Layer 3 services

The toolbar's Engine starts at *Layer 3 services*; *Built-in (Swift)* runs without them. The built-in engines follow the Layer 3 contracts (`../Services/contracts/README.md`) so their answers match:

| Step | Built-in (`Optimizer.swift`, `Attribution.swift`) | Layer 3 service (Engine ▸ Layer 3 services) |
| --- | --- | --- |
| Optimize | Active mean-variance vs the benchmark, box + sector-band penalty, λ by bisection to the tracking-error target, FISTA | **portfolio-java** `POST /optimize/active` (127.0.0.1:8766), inputs sent inline |
| Build the Tracker | Minimum tracking error with ≤ N names (stratified selection exactly as portfolio-cpp's) | **portfolio-cpp** `POST /optimize/tracking` (127.0.0.1:8767), inputs sent inline |
| Risk | Volatility, VaR / ES, tracking error, beta, risk contributions (portfolio-cpp's `/risk` formulas) | — |
| Attribution | — | **analytics** `POST /attribution` (127.0.0.1:8772) for the account's code (or another security-master portfolio, e.g. `DEMO_GROWTH`): monthly Brinson-Fachler / Brinson-Hood-Beebower by sector (funds by their family's style, cash as its own group earning the 3-month Treasury yield), Carino-linked, data gaps → *review* |
| Risk inputs | — | **analytics** `POST /inputs`: Ledoit-Wolf covariance, betas, rate betas, momentum alpha, risk-free rate |

The built-in active optimizer matches portfolio-java to the published weight precision, and the built-in tracker
matches portfolio-cpp's tracking error. Start the services with
`python3 Services/mxservices.py start`; **Library ▸ Layer 3 Services** is the shared `ServicesView` (what each
service is for, whether it runs, how to start it). Failures (a service not running, the security-master database not
reachable) are shown as alerts with a link to that screen.

## Build and run

```bash
cd MxAcctMGR
xcodebuild -project MxAcctMGR.xcodeproj -scheme MxAcctMGR -configuration Debug build
```

File-system-synchronized Xcode project (team QC4VX47BJ8, bundle id `com.k3jdr.MxAcctMGR`, macOS 26.6,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), compiling `MxAcctMGR/` and `../Shared` (Quick Help, the Layer 3
service catalog and view). Sandboxed with outgoing network connections (for the services on 127.0.0.1 and Nasdaq.com's earnings calendar). The Debug
configuration is compiled with `-O`: the optimizers and the simulator are numeric loops that are ~75× slower
unoptimised.

Launch arguments for demos and tests: `-srmAccount CODE` (My Portfolio's security-master account), `-addSecurities YES` (open Add Securities), `-screen myImprove` (any `Screen` case), `-sample SAMPLE_EMPLOYER_STOCK` (a sample's
code), and for a walkthrough `-screen reportWalkthrough -report cpi -reportStep 5 -reaction sell-all` (step 5 runs the simulation; report ids: jobs, cpi, ppi, fomc, gdp, ism-manufacturing, ism-services, retail-sales, earnings, revisions, cot, fund-flows, auctions, yield-curve, semiconductors, banks, housing, energy). `-quickHelpVisible NO`
hides Quick Help. Earnings screens: `-screen earningsDay -earningsDate 2026-10-20 -earningsSymbol META` (the day, and a company selected) and `-screen earningsCalendar -earningsMode Week` (the calendar shows `-earningsDate`'s month or week); `-holding VTI` selects a holding in My Holdings. Debug builds only:
`-linkEdit symbol` (or `name`) opens the Link dialog for the selected company or holding, and `-linkHoverTest ID`
(e.g. `META|symbol`) shows a linked cell's hover card as if the pointer rested on it, and
`-linkPasteboard NAME` makes the dialog look for a copied MxNoteONE link on that named pasteboard (not the clipboard), and `-addSecurities YES -addLinkEdit META|name` opens the Link dialog for that row of Add Securities. `-screen cards -cardAccount DISCOVER -cardImportFile PATH` opens Import File… with that file picked (an unsandboxed test build reads it: `ENABLE_APP_SANDBOX=NO`), and `-cardRemove YES` opens Remove… (test it on a scratch database, with `SRM_CARD_ACCOUNTS` naming a card_accounts file whose drop folder is a scratch one).

## Files

| File | Contents |
| --- | --- |
| `MxAcctMGRApp.swift` | The window and the Guide, Portfolio and Reports menus, and Edit ▸ Link… |
| `ContentView.swift` | Sidebar guide with Quick Help docked, toolbar pickers, status bar, launch arguments |
| `Navigation.swift` | Back and Forward: the places visited, the toolbar's ‹ ›, the Go menu, ⌃← ⌃→ and a mouse's side buttons |
| `PortStore.swift` | Screens, the selected account, settings, results, walkthrough state, tax-lot estimates |
| `Universe.swift`, `Portfolio.swift`, `Samples.swift` | Security, benchmark and the lookups into the registry; accounts and checks; the samples' lessons |
| `HoldingEditor.swift` | Edit Holding: a holding's tax lots (date, shares, cost) or the cash |
| `PortfolioTransfer.swift` | Import Holdings (CSV), Export Portfolio (JSON / CSV), Duplicate and Rename |
| `PortfolioFile.swift`, `PortfolioSheets.swift` | One portfolio open at a time: preferences, unsaved-change checks, New / Open / Recent / Close / Save / Revert, the quit check; the Open Portfolio, New Portfolio, Decisions, Duplicate, Rename, Import and Policy Benchmarks sheets |
| `SRMData.swift` | Security-master securities and benchmarks registry (with the analytics service's risk numbers), the accounts-service client, analytics inputs |
| `AddSecuritiesSheet.swift` | Add Securities: search the security master |
| `Optimizer.swift`, `Attribution.swift`, `ServiceClient.swift` | The built-in optimizers, the attribution result, and the Layer 3 service client |
| `BehaviorLab.swift`, `MarketReports.swift`, `ReportLibrary.swift` | The long-horizon simulator; the report model, tiers and drivers with the jobs, earnings and yield-curve reports; the other fifteen reports and the shared reactions |
| `ReportsHubViews.swift` | Report Library and Morning Briefing |
| `ReportNotes.swift` | Your notes on reports: kept on this Mac; the report's name in the matrix, its context menu and hover card; the Notes dialog |
| `ReportSources.swift` | Each report's official sources: latest release, release schedule, history or live data |
| `Earnings.swift`, `EarningsViews.swift` | Real earnings: the Nasdaq.com and FMP (accounts service) clients, merging by symbol, the day files kept on this Mac, the store; Earnings Calendar (month, week) and Earnings by Day with the company detail |
| `TargetAccounts.swift` | Target accounts: their funding sources, the password and user keys in this Mac's Keychain (`TargetSecrets`), the editor (New Target Account, a row's Edit Target Details) and Edit Target Account Name |
| `TargetAccountLinks.swift` | Links on target accounts: the link as the service sends it, the Link dialog's target and its save (with the shared `../Shared/Links/LinkSheet.swift`: linked words, their hover card and the Link dialog for links that aren't on a security) |
| `SecurityLinkTargets.swift` | Links on symbols and names: Earnings by Day's and My Holdings' securities, and the accounts service as where links are kept. The rest is shared with MxDataHUB in `../Shared/Links`: the link store, linked cell, Link dialog and its pages about a security (`SecurityLinks.swift`); the hover card, also the reports' (`LinkHover.swift`); the hover text and its editor (`LinkTips.swift`), after MxNoteONE's |
| `LearnViews.swift`, `PathViews.swift`, `PassiveViews.swift`, `ReportView.swift`, `SamplesView.swift` | The screens: Start Here and Learn the Why; the Investments steps (PassiveViews: Build the Tracker and Rebalance Bands); the report walkthrough; the samples |
| `SpendingExpenseAccounts.swift` | Spending Analysis ▸ Rules: New Expense Account… and Edit Expense Account… (with a new one's spending rule), and Remove Expense Account… with what files under it and where it moves |
| `SpendingAdminView.swift` | Spending Analysis ▸ Admin: the Expense Accounts list with Edit…, Rule… and Remove…, the Driver & Category guide with the Category × Driver table and its cells' origins, and the Target Accounts & Expense Ledgers guide with the Counted Twice finder and its links |
| `SpendingModel.swift`, `SpendingViews.swift` | Spending Analysis: the categories, drivers, family, rules, lifecycle triggers and entries as the accounts service sends them, the attribution and forward-curve engine, and the client; the page with its sources strip, its Overview (attribution), Deep Dive, Forward Curve, Year-End Tax, Entries, Rules, Family & Lifecycle, Sources and Feedback tabs, the tax item and move sheets, Send Family Link (FamilyLink: the link in the Keychain, Mail and Messages), its sheets, and the charts' Deep Dive menu |
| `Components.swift`, `PortQuickHelp.swift` | Lesson cards, tiles, bars, step footer; Quick Help text and glossary |
