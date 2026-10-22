# MxDataHUB

A macOS app (SwiftUI) for the **security reference master** (SRM): securities and their identifiers,
portfolios and benchmarks, kept in PostgreSQL (schema `srm`) and loaded from free and subscribed data
sources by the Python tools in [`SRM/`](SRM/README.md).

Open `MxDataHUB.xcodeproj` in Xcode, then Run. The PostgresNIO Swift package is fetched automatically.

The database side is created and filled from the command line:

```bash
cd MxDataHUB/SRM
./srm.py migrate      # create / upgrade schema srm
./srm.py load all     # load reference data, securities, identifiers, benchmarks, prices, corporate actions
./srm.py status       # migrations, row counts, identifier coverage, recent loads
```

See [SRM/README.md](SRM/README.md) for the schema, the loaders, where the API keys live and each source's limits.

## MxDataHUB, MxJobsWMS and the Layer 3 services

- **MxDataHUB** (this app) keeps the data: securities, benchmarks, portfolios, and each category of market data.
- **MxJobsWMS** runs the processes over that data: scheduled, checked and approved workflows — the daily refresh,
  active optimization, passive index tracking, attribution.
- **`../Services/`** holds the Layer 3 tools both apps use (Python loaders and analytics, a Java active optimizer,
  a C++ index-tracking and risk engine). Start them with `python3 ../Services/mxservices.py start`; see
  [Services/README.md](../Services/README.md).

Hand-offs: **Portfolios ▸ Workflows** opens Optimize (active), Track (passive) or Attribution in MxJobsWMS for the
selected portfolio and its benchmark; **Benchmarks ▸ Track…** opens an index-tracking workflow for the benchmark;
**Data Refresh ▸ Automate in MxJobsWMS…** opens the SRM Daily Refresh workflow. MxJobsWMS links back with
`mxdatahub://portfolio/<CODE>`, `mxdatahub://benchmark/<CODE>`, `mxdatahub://data-refresh`, `mxdatahub://services`.

## Screens

One window with a sidebar (⌘1 – ⌘7, also in the **Hub** menu):

| Screen | What it does |
|--------|--------------|
| **DB Connection** | Host, port, user, database, password, SSL mode (`disable` / `prefer` / `require`, no certificate verification, like libpq). The fields are remembered by the app; with **Save password in Keychain** the password is kept in the login Keychain under `MxDataHUB: user@host:port/database`. **Connect** (⇧⌘K) also checks that the database has the `srm` schema. While connected, a **Database** drop-down in the toolbar reconnects to another database on the same server with the same user and password. |
| **Securities** | Search by name or any identifier (ISIN, CUSIP, SEDOL, FIGI, composite / share-class FIGI, ticker, `TICKER:MIC`, CIK, LEI), filtered by type, benchmark membership and active status. The panel on the right shows the price chart, every identifier with its validity dates and source, the issuer (LEI, CIK, SIC, incorporation), listings, sector / industry, benchmark weights and corporate actions. |
| **Portfolios** | **New…** / **Edit…** (code, name, base currency, benchmark). Holdings are kept in dated snapshots (**Holdings on**; **New Snapshot…** copies the latest earlier one). **Add Holding…** takes any identifier, shows the securities it matches as you type, and takes shares or a weight in percent; **Paste Holdings…** takes one `identifier [type] shares|weight%` per line. **Copy Benchmark** fills the snapshot with a benchmark's weights; **Normalize Weights** scales target weights to 100%. The snapshot is valued with the latest prices and checked (weights add up to 100%, prices present and recent, inactive or short positions); **vs Benchmark** shows portfolio, benchmark and active weights and the active share. A **personal account** (V011 — e.g. MxPortMGR's My Portfolio) shows its account type, approach, cash and the app that maintains it, a **Tax Lots** view (shares, purchase date, cost, value, unrealised gain, short- or long-term) and **Open in MxPortMGR** (`mxportmgr://my-portfolio/CODE`). MxPortMGR rewrites such an account's holdings from its lots whenever it saves, so edit its lots there. |
| **Benchmarks** | Members, weights and shares, weights by sector, and the index level. **Build Custom…** makes an equal- or market-cap-weighted benchmark from another benchmark's members, optionally one sector. **Availability…** lists which benchmarks the data sources can and cannot supply, and why. |
| **Data Refresh** | Every category of market data — reference data, listed universe & issuers, benchmark constituents, identifiers & issuer data, prices & index levels, corporate actions — with its state (fresh, due, stale, failed), data date, last load, cadence and loaders, and **Refresh** (that category's `srm.py` loaders, in order) or **Refresh All** (every category except the optional Portfolio snapshots, stopping at a failure). **Preview only** shows the commands without loading. *Prices & index levels* runs `fmp-prices` (needs an FMP API key), then `nasdaq-prices` (Nasdaq.com, free, no key: the stock and bond funds held and any security left without a recent price — it runs even when FMP fails) and `fmp-index-levels`; `srm.py load nasdaq-prices --funds` backfills every fund once. Runs through the SRM loader service (`../Services/srm-loader`, 127.0.0.1:8770), so it works without connecting the app to the database. **Log detail** (Normal, Verbose `-v`, Trace `-vv`) sets how much `srm.py` prints for the refreshes started here. **Activity**, on the right, streams what the loaders print as they run (the service's `GET /log`), whoever started them — this window, another, or MxJobsWMS. Its status strip always says what is happening: RUNNING with the refresh, its current loader, a bar by loaders finished, the latest line and the time so far; afterwards the last refresh's outcome (green, orange or red) with **Show Its Lines**; else Idle. The running category is highlighted, and Refresh All shows which category it is on. In the log each refresh opens with a START line and closes with an END line and a rule, and each loader starts (▶) and finishes (✓ ✗ !) with status, time and rows, warnings, errors and detail (DBG) lines marked; filter by run, level (Info hides the detail lines) or text, and follow new lines. It is a read-only text view: drag across lines (or ⌘A) and ⌘C or **Copy** to copy them tab-separated, ⌘F to find; **Copy** with nothing selected copies every line shown. An error from the service (or, app-wide, from the database) shows in a small dialog whose text can be selected, with **Copy** for all of it (`ErrorDialog.swift`). **Automate in MxJobsWMS…** opens the scheduled, approved version. |
| **Load History** | Identifier coverage, the data sources with their plan limits, snapshot history (dated weight snapshots per benchmark and portfolio: count, first and last date, months, longest gap), and the load audit trail (`srm.load_run`). |
| **Services & Workflows** | **Workflows**: the MxJobsWMS sample workflows with the services each needs and whether they run; **Open in MxJobsWMS** opens one for the portfolio selected in Portfolios. **Layer 3 Services**: each service's state, language and why, use cases and when to use them, endpoints, start command and project folder, and how to choose a language for a new tool. |

Every change the app makes is one SQL statement, committed on its own.

Launch arguments for testing: `-autoConnect YES` connects with the saved password, `-section Portfolios`
(or `"Data Refresh"`, `"Services & Workflows"`) opens a screen, `-servicesTab Services` shows the services list,
and `-query AAPL` searches Securities; the connection fields can be given as `-host`,
`-port`, `-user`, `-database` and `-sslMode`; `-srmLoaderPort 8790` points Data Refresh at a test instance of the
SRM loader service. Debug builds also take the password from `PGPASSWORD`.

The window's minimum (1280 × 720 points) is the widest sidebar plus the widest screen (Data Refresh). Each screen's
panes sit in `SplitPanes`, not `HSplitView`: drag the divider; the width is remembered per screen.

## Quick Help

**View ▸ Quick Help** (⌥⌘/) shows a panel at the bottom of the sidebar, as in MxNoteONE, telling what's under the
pointer in a sentence or two, with its shortcut: a screen in the sidebar, a button, the search, the results,
holdings, active weights or constituents table, a Data Refresh category, a Load History panel. Over nothing it can
describe, it tells about what's selected (a security, portfolio or benchmark) and then the screen — including why a
screen is empty (not connected, no `srm` schema). **View ▸ Float Quick Help** (or the panel's float button) puts it
in a small window of its own; closing that window docks it again. Both choices are remembered.

## Source layout

| File | Purpose |
|------|---------|
| `MxDataHUBApp.swift` | The window and the **Hub** menu |
| `ContentView.swift` | Sidebar, screens, Database drop-down, status bar, launch arguments |
| `ConnectionView.swift` | DB Connection screen |
| `PostgresService.swift` | Connection settings and the PostgresNIO connection |
| `Keychain.swift` | Passwords in the login Keychain |
| `SRMStore.swift` | Connection state, row types and every query |
| `SRMSecuritiesView.swift`, `SRMPortfoliosView.swift`, `SRMBenchmarksView.swift`, `SRMLoadsView.swift` | The screens and their dialogs |
| `DataRefreshView.swift` | Data Refresh: categories, freshness, refresh through the SRM loader service, and the Activity console |
| `SplitPanes.swift` | Two panes with a divider to drag, used by every screen instead of `HSplitView` |
| `ServicesWorkflowsView.swift` | Services & Workflows, and the Workflows menu of Portfolios |
| `HubQuickHelp.swift` | What Quick Help says about each screen, the selection and the controls |
| `Info.plist` | The `mxdatahub` URL scheme (merged into the generated Info.plist) |
| `../Shared/` | Compiled into both apps: `ServiceCatalog.swift` (services, use cases, samples), `ServicesView.swift` (the services and workflows views), `AppLinks.swift` (the `mxdatahub://` / `mxjobswms://` hand-offs), `QuickHelp/` (the Quick Help panel, also in MxDataSQL) |
| `Formatting.swift` | Number formatting shared by the screens |
| `SRM/` | PostgreSQL migrations and the Python loaders |

The SRM screens and `SRM/` were moved here from MxDataSQL, which is again a general PostgreSQL utility.
