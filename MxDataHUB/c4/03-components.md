# 03 · Components of MxDataHUB.app (C4 level 3)

The app is one window (`Window("MxDataHUB")`) with a sidebar of seven screens. State is held in one observable
store; screens are thin SwiftUI views over it. Code shared with MxJobsMGR is compiled in from `../Shared`.

```mermaid
C4Component
    title Components — MxDataHUB.app

    Container_Boundary(app, "MxDataHUB.app") {
        Component(shell, "App shell", "MxDataHUBApp, ContentView, StatusBar", "Window, sidebar, Hub menu (⌘1–⌘7, Connect ⇧⌘K), Database drop-down, launch arguments, mxdatahub:// routing")
        Component(screens, "Security master screens", "ConnectionView, SRMSecuritiesView, SRMPortfoliosView, SRMBenchmarksView, SRMLoadsView", "Search and detail, portfolio and holdings maintenance, benchmarks, load history; their dialogs")
        Component(refresh, "Data Refresh", "DataRefreshView, RefreshStore", "Categories, freshness, Refresh / Refresh All / Preview only via the srm-loader service")
        Component(svcwf, "Services & Workflows", "ServicesWorkflowsView, PortfolioWorkflowsMenu", "Layer 3 services and the MxJobsMGR sample workflows for the selected portfolio")
        Component(store, "SRMStore", "@Observable class", "Connection state, selections, row models and every SQL query and change")
        Component(pgsvc, "PostgresService", "PostgresNIO client", "Connect with ConnectionSettings and SSL mode; rows(sql, binds) with text parameters; databases; server version")
        Component(keychain, "Keychain", "Security framework", "Password per user@host:port/database")
        Component(help, "HubQuickHelp", "QuickHelp items", "What Quick Help says for each screen, selection and control")
        Component(shared, "Shared (../Shared)", "AppLinks, ServiceCatalog, ServicesView, QuickHelp", "URL hand-offs, service and sample catalog with health checks, services and samples views, the Quick Help panel")
    }

    ContainerDb(db, "SRM schema", "PostgreSQL")
    Container(loader, "srm-loader", "Python HTTP 8770")
    Container(others, "Other Layer 3 services", "HTTP 8765–8772")
    System_Ext(wms, "MxJobsMGR.app")
    System_Ext(kc, "Login Keychain")

    Rel(shell, screens, "Shows the selected screen")
    Rel(shell, refresh, "Shows")
    Rel(shell, svcwf, "Shows")
    Rel(screens, store, "Binds to state, calls async actions")
    Rel(store, pgsvc, "SQL with text binds")
    Rel(pgsvc, db, "PostgreSQL protocol")
    Rel(store, keychain, "Save / load password")
    Rel(keychain, kc, "SecItem API")
    Rel(refresh, loader, "GET /categories, POST /refresh/{id}")
    Rel(svcwf, shared, "ServicesView, SampleGalleryView")
    Rel(shared, others, "GET /health")
    Rel(svcwf, wms, "AppLink.sample(...).open()")
    Rel(screens, help, "quickHelp modifiers")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Components

| Component | Files | Responsibility | Notes |
|---|---|---|---|
| **App shell** | `MxDataHUBApp.swift`, `ContentView.swift` | The single window and its **Hub** menu; sidebar of `SRMSection`s; shows *Not Connected* or *No Security Master Here* instead of a screen when needed; the toolbar **Database** drop-down; the status bar; `onOpenURL` for `mxdatahub://`; launch arguments (`-autoConnect`, `-section`, `-query`, `-servicesTab`, connection fields; `PGPASSWORD` in Debug). | DB Connection, Data Refresh and Services & Workflows work without a database connection. |
| **Security master screens** | `ConnectionView`, `SRMSecuritiesView`, `SRMPortfoliosView` (+ `PortfolioDialog`, `AddHoldingDialog`, `PasteHoldingsDialog`), `SRMBenchmarksView` (+ `BuildBenchmarkDialog`, `BenchmarkAvailabilitySheet`), `SRMLoadsView` | Presentation and input; no SQL. | See the [UI screen catalog](ui-screen-catalog.md). |
| **Data Refresh** | `DataRefreshView.swift` (`RefreshStore`, `RefreshCategory`, `RefreshResult`) | Its own small store: loads `/categories`, runs `/refresh/{id}` one at a time, *Refresh All* stops at the first failure and skips optional categories; *Preview only* sends `X-SRM-Dry-Run: 1`. | Independent of the database connection — the service has its own. |
| **Services & Workflows** | `ServicesWorkflowsView.swift` | Segmented *Workflows* / *Layer 3 Services*; opens a sample in MxJobsMGR for the portfolio selected in Portfolios (and its benchmark). `PortfolioWorkflowsMenu` is the Portfolios screen's **Workflows** menu. | Uses `ServicesView` and `SampleGalleryView` from `../Shared`. |
| **SRMStore** | `SRMStore.swift` | The app's model: connection status and settings, the selections of every screen, row types (`SecurityRow`, `HoldingRow`, `BenchmarkRow`, `LoadRow`, …) and every query. Async actions: `connect`, `switchDatabase`, `search`, `loadDetail`, `savePortfolio`, `newSnapshot`, `addHoldings`, `normalizeWeights`, `copyBenchmark`, `buildBenchmark`, `loadAudit`, … | One store for one window; errors surface as `errorMessage` (an alert) or a failed connection status. |
| **PostgresService** | `PostgresService.swift` | Owns the PostgresNIO connection. `rows(_:_:)` runs SQL with **text binds** (`$1…`) and returns text cells; `databases()`, `serverVersion()`. `ConnectionSettings` (host, port, user, database, SSL mode, *save password*) persist in `UserDefaults`. `DatabaseError.from` turns driver errors into readable messages. | Parameterised SQL only — values are never interpolated. |
| **Keychain** | `Keychain.swift` | Generic password per `MxDataHUB: user@host:port/database`. | Debug builds can also take `PGPASSWORD`. |
| **HubQuickHelp** | `HubQuickHelp.swift` | Text for the shared Quick Help panel: screens, why a screen is empty, the selection, each control. | Panel docks at the bottom of the sidebar. |
| **Shared** | `../Shared/AppLinks.swift`, `ServiceCatalog.swift`, `ServicesView.swift`, `QuickHelp/QuickHelp.swift` | Compiled into both apps (file-system synchronized group). `AppLink` builds and parses `mxjobsmgr://` / `mxdatahub://` URLs; `ServiceCatalog` lists the five services, their use cases, endpoints and the five samples, and checks `GET /health`. | [ADR-0010](adr/0010-shared-swift-sources-compiled-into-each-app.md) |

## Dependencies and rules

- Views never talk to PostgreSQL or HTTP directly; they call `SRMStore` (database) or `RefreshStore` (srm-loader).
- All Swift types default to `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); value types that cross to
  background work are `nonisolated` and `Sendable` (`ConnectionSettings`, `DatabaseError`, the shared catalog types).
- No component writes more than one SQL statement per user action: there are no client-side transactions
  ([ADR-0003](adr/0003-direct-database-access-with-single-statement-changes.md)).
