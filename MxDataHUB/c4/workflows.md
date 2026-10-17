# Workflows — MxDataHUB

User and data workflows, from what the code does. Sequence diagrams name the real components, endpoints and SQL
objects.

1. [Connect and check the security master](#1-connect-and-check-the-security-master)
2. [Look up a security](#2-look-up-a-security)
3. [Maintain a portfolio](#3-maintain-a-portfolio)
4. [Build a custom benchmark](#4-build-a-custom-benchmark)
5. [Refresh a data category](#5-refresh-a-data-category)
6. [Loader dependency order](#6-loader-dependency-order)
7. [Hand a portfolio to MxJobsWMS and back](#7-hand-a-portfolio-to-mxjobswms-and-back)
8. [Daily data operations](#8-daily-data-operations)
9. [Weight history for attribution](#9-weight-history-for-attribution)

## 1. Connect and check the security master

```mermaid
sequenceDiagram
    actor U as Analyst
    participant V as ConnectionView
    participant S as SRMStore
    participant K as Keychain
    participant P as PostgresService
    participant DB as PostgreSQL

    U->>V: Connect (⇧⌘K)
    V->>S: connect()
    S->>P: connect(settings, password)
    P->>DB: startup, TLS per SSL mode
    DB-->>P: ready
    S->>P: serverVersion()
    S->>S: save fields (UserDefaults)
    opt Save password in Keychain
        S->>K: setPassword(user@host:port/database)
    end
    S->>P: databases()
    S->>DB: SELECT to_regclass('srm.security') IS NOT NULL
    alt schema srm present
        S->>DB: security types, benchmarks, portfolios
        S-->>V: connected, screens available
    else no schema
        S-->>V: "No Security Master Here" (choose another database or run srm.py migrate)
    end
```

Switching the toolbar **Database** reconnects with the same user and password; on failure it reconnects to the
previous database and shows the error.

## 2. Look up a security

```mermaid
sequenceDiagram
    actor U as Analyst
    participant V as SRMSecuritiesView
    participant S as SRMStore
    participant DB as PostgreSQL (srm)

    U->>V: type "US0378331005" or "AAPL:XNAS", filters
    V->>S: search()
    S->>DB: resolve_identifier(text, type, as_of) / v_security, filters (type, benchmark, active)
    DB-->>S: up to 1,001 rows
    S-->>V: results (truncated note above 1,000)
    U->>V: select a row
    V->>S: loadDetail()
    par detail queries
        S->>DB: identifiers with validity (security_identifier)
        S->>DB: issuer, listings, classification, market data
        S->>DB: prices (chart), benchmark_weights, corporate_action (40)
    end
    S-->>V: SecurityDetail
```

## 3. Maintain a portfolio

```mermaid
flowchart TD
    A([New… portfolio<br/>code, name, currency, benchmark]) --> B[Pick snapshot date<br/>Holdings on]
    B --> C{Snapshot exists?}
    C -- no --> D[New Snapshot…<br/>copies latest earlier snapshot]
    C -- yes --> E[Edit holdings]
    D --> E
    E --> F[Add Holding…<br/>identifier, live matches,<br/>shares or weight %]
    E --> G[Paste Holdings…<br/>identifier type shares or weight%<br/>one line each]
    E --> H[Copy Benchmark<br/>fills snapshot with weights]
    E --> I[Remove]
    F & G & H & I --> J[Normalize Weights<br/>target weights to 100%]
    J --> K[Valuation and checks<br/>portfolio_valuation, portfolio_validate]
    K --> L{Issues?}
    L -- yes --> E
    L -- no --> M[vs Benchmark<br/>portfolio_active_weights, active share]
    M --> N{Next}
    N -- Workflows menu --> O((MxJobsWMS: Optimize,<br/>Track or Attribution))
    N -- done --> P([Snapshot kept as history])
```

Each box that changes data is **one SQL statement** (`INSERT`/`UPDATE`/`DELETE` or `srm.add_holding`); *Paste
Holdings* runs `add_holding` per line and lists the lines that failed.

## 4. Build a custom benchmark

```mermaid
sequenceDiagram
    actor U as Analyst
    participant V as BuildBenchmarkDialog
    participant S as SRMStore
    participant DB as PostgreSQL (srm)

    U->>V: Code, Name, Members of (parent), Weighting (equal or cap), Sector
    V->>S: buildBenchmark(code, name, parent, method, sector)
    S->>DB: SELECT srm.build_benchmark(code, name, parent, method, sector, as_of)
    DB->>DB: insert benchmark and dated benchmark_weight snapshot
    DB-->>S: new benchmark
    S->>S: refreshBenchmarks(), select it
    S-->>V: close dialog, show members, sectors
```

## 5. Refresh a data category

```mermaid
sequenceDiagram
    actor U as Data steward
    participant V as DataRefreshView (RefreshStore)
    participant L as srm-loader :8770
    participant C as srm.py
    participant DB as PostgreSQL (srm)
    participant X as Data sources

    V->>L: GET /categories
    L->>DB: v_load_history (last runs, data dates)
    L-->>V: categories with state fresh, due, stale or failed
    U->>V: Refresh "Prices & index levels" (or Refresh All)
    V->>L: POST /refresh/prices  [X-SRM-Dry-Run: 1 if Preview only]
    loop each loader of the category, in order
        alt dry run
            L-->>L: report the srm.py command only
        else run
            L->>C: srm.py load fmp-prices ...
            C->>DB: begin_load()
            C->>X: HTTPS, rate limited, keys from env, Keychain or config
            X-->>C: data
            C->>DB: upserts, rejects
            C->>DB: finish_load(counts, status)
        end
    end
    L-->>V: per-loader status, seconds, command, totals, output tail
    V->>L: GET /categories (new freshness)
    Note over V: Refresh All runs the non-optional categories in order and stops at the first failure
```

When the service does not answer, the screen shows **SRM Loader Service Not Running** with the start command and
*Check Again*.

## 6. Loader dependency order

```mermaid
flowchart LR
    subgraph ref[Reference data]
        r1[reference<br/>MICs, countries, currencies]
    end
    subgraph uni[Listed universe & issuers]
        u1[nasdaqtrader] --> u2[sec-tickers]
    end
    subgraph con[Benchmark constituents]
        c1[ssga<br/>SPY DIA MDY SPSM] --> c2[nasdaq100]
    end
    subgraph ids[Identifiers & issuer data]
        i1[openfigi] --> i2[fmp-profiles] --> i3[sec-submissions] --> i4[gleif]
    end
    subgraph px[Prices & index levels]
        p1[fmp-prices] --> p2[fmp-index-levels]
    end
    subgraph ca[Corporate actions]
        a1[fmp-corporate-actions]
    end
    subgraph opt[Portfolio snapshots - optional]
        o1[portfolio-snapshots]
    end
    ref --> uni --> con --> ids --> px --> ca
    px -.-> opt
```

`srm.py load all` runs the same order and skips `portfolio-snapshots`.

## 7. Hand a portfolio to MxJobsWMS and back

```mermaid
sequenceDiagram
    actor U as Portfolio manager
    participant H as MxDataHUB (Portfolios)
    participant OS as macOS Launch Services
    participant W as MxJobsWMS
    participant J as Jobspace window

    U->>H: Workflows ▸ Optimize — active vs SP500
    H->>H: AppLink.sample(active-optimization, DEMO_GROWTH, SP500).url
    H->>OS: open mxjobswms://sample/active-optimization?portfolio=DEMO_GROWTH&benchmark=SP500
    OS->>W: application(_:open:)
    W->>W: Jobspace.fromSample(id, portfolio, benchmark)
    W->>J: new document with the sample
    U->>J: run, approve, review outcome
    U->>W: Window ▸ Open MxDataHUB
    W->>OS: open mxdatahub://data-refresh (or portfolio/CODE, benchmark/CODE)
    OS->>H: onOpenURL → select screen and item
```

## 8. Daily data operations

```mermaid
flowchart TD
    start([Business day close]) --> auto{Automated?}
    auto -- "yes: MxJobsWMS SRM Daily Refresh<br/>weekdays 18:30 New York" --> wms[MxJobsWMS runs the 12 loaders<br/>via srm-loader /load, then /status]
    wms --> review[Data quality analyst agent<br/>builds report and follow-ups]
    review --> approve{Data steward approves?}
    approve -- yes --> backfill[Run approved backfills<br/>dry run]
    approve -- no --> stop([Investigate])
    auto -- "no: on demand" --> hub[MxDataHUB Data Refresh<br/>Refresh a category or Refresh All]
    hub --> check[Check states: fresh / due / stale / failed]
    backfill --> check
    check --> audit[Load History: loads, coverage, snapshot history]
    audit --> done([Data ready for portfolios,<br/>benchmarks and workflows])
```

## 9. Weight history for attribution

```mermaid
flowchart LR
    ssga[ssga / nasdaq100 loads<br/>one dated snapshot per load] --> bw[(benchmark_weight)]
    bw --> apply[apply_benchmark_snapshot<br/>rebuild membership ranges] --> bc[(benchmark_constituent)]
    ui[Portfolios: New Snapshot,<br/>Add / Paste Holdings] --> ph[(portfolio_holding)]
    ps[portfolio-snapshots loader<br/>carry forward, drift by returns] --> ph
    bw --> cov[v_snapshot_coverage<br/>Load History]
    ph --> cov
    bw --> attr[analytics /attribution<br/>monthly weights: latest snapshot on or before month start]
    ph --> attr
    attr --> wf((MxJobsWMS Performance &<br/>Risk Attribution))
```
