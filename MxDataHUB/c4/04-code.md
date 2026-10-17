# 04 · Code and data model (C4 level 4)

## Swift model

```mermaid
classDiagram
    direction LR
    class MxDataHUBApp {
        +store: SRMStore
        Hub menu, QuickHelpCommands
    }
    class SRMStore {
        <<Observable>>
        +section: SRMSection
        +status: ConnectionStatus
        +settings: ConnectionSettings
        +available: Bool?
        +results: [SecurityRow]
        +detail: SecurityDetail?
        +portfolios: [PortfolioRow]
        +holdings: [HoldingRow]
        +issues: [ValidationIssue]
        +activeWeights: [ActiveWeightRow]
        +benchmarks: [BenchmarkRow]
        +constituents: [ConstituentRow]
        +loads: [LoadRow]
        +coverage: [CoverageRow]
        +connect() async
        +switchDatabase(name) async
        +search() async
        +loadDetail() async
        +savePortfolio(...) async
        +newSnapshot(on) async
        +addHoldings(entries) async
        +normalizeWeights() async
        +copyBenchmark(id) async
        +buildBenchmark(...) async
        +loadAudit() async
    }
    class PostgresService {
        +connect(settings, password)$ PostgresService
        +rows(sql, binds) [[String?]]
        +databases() [String]
        +serverVersion() String
        +close()
    }
    class ConnectionSettings {
        <<nonisolated, Codable>>
        host, port, user, database
        sslMode: SSLMode
        savePasswordInKeychain
        keychainAccount
        +load()$ / save()
    }
    class SRMSection {
        <<enum>>
        connection, securities, portfolios,
        benchmarks, refresh, loads, services
    }
    class ConnectionStatus {
        <<enum>>
        disconnected, connecting,
        connected(serverVersion), failed(message)
    }
    class RefreshStore {
        <<Observable>>
        +categories: [RefreshCategory]
        +serviceUp: Bool?
        +dryRun: Bool
        +results: [RefreshResult]
        +load() async
        +refresh(id) async
        +refreshAll() async
    }
    class AppLink {
        <<shared enum>>
        sample(id, portfolio, benchmark)
        portfolio(code), benchmark(code)
        dataRefresh, services
        +url: URL
        +open() Bool
    }
    class ServiceCatalog {
        <<shared>>
        +all: [ServiceInfo]
        +isRunning(service)$ async Bool
        +probeAll()$ async
    }
    class Keychain {
        +password(for)$ String?
        +setPassword(_, for)$
    }

    MxDataHUBApp --> SRMStore
    SRMStore --> PostgresService
    SRMStore --> ConnectionSettings
    SRMStore --> SRMSection
    SRMStore --> ConnectionStatus
    SRMStore --> Keychain
    RefreshStore ..> ServiceCatalog : port of srm-loader
    SRMStore ..> AppLink : hand-offs (views)
```

`SRMStore` maps query results to small `Identifiable` row structs (`SecurityRow`, `IdentifierRow`, `ListingRow`,
`ActionRow`, `PricePoint`, `PortfolioRow`, `HoldingRow`, `ValidationIssue`, `ActiveWeightRow`, `ResolveMatch`,
`BenchmarkRow`, `ConstituentRow`, `SectorWeight`, `LoadRow`, `CoverageRow`, `SnapshotCoverageRow`, `SourceRow`) that
the screens show in SwiftUI `Table`s and charts. `PostgresService.rows` returns text cells, which the store parses.

## The `srm` schema (system of record)

Created by `SRM/srm.py migrate` from `SRM/migrations/V001…V010` (checksummed, applied in order).

```mermaid
erDiagram
    data_source ||--o{ load_run : "records runs of"
    load_run ||--o{ load_reject : "rejects"
    country ||--o{ exchange : "hosts"
    exchange ||--o{ exchange_code_map : "aliases"
    issuer ||--o{ issuer_name_history : "was named"
    issuer ||--o{ security : "issues"
    security_type ||--o{ security : "types"
    security ||--o{ listing : "listed as"
    exchange ||--o{ listing : "venue of"
    security ||--o{ security_identifier : "identified by"
    identifier_type ||--o{ security_identifier : "kind"
    listing |o--o{ security_identifier : "venue-level ids"
    classification_scheme ||--o{ classification_node : "contains"
    classification_node |o--o{ classification_node : "parent of"
    security ||--o{ security_classification : "classified"
    classification_node ||--o{ security_classification : "node"
    listing ||--o{ price : "EOD prices"
    security ||--o{ security_market_data : "cap, shares, beta"
    security ||--o{ corporate_action : "dividends, splits, ..."
    benchmark |o--o{ benchmark : "custom built from"
    benchmark ||--o{ benchmark_weight : "dated snapshots"
    benchmark ||--o{ benchmark_constituent : "membership ranges"
    benchmark ||--o{ benchmark_level : "index level"
    security ||--o{ benchmark_weight : "member"
    benchmark |o--o{ portfolio : "measured against"
    portfolio ||--o{ portfolio_holding : "dated snapshots"
    security ||--o{ portfolio_holding : "held"
    portfolio ||--o{ portfolio_transaction : "trades"
    currency ||--o{ security : "trades in"

    security {
        bigint security_id PK
        bigint issuer_id FK
        text name
        text security_type FK
        char currency_code FK
        boolean is_active
        date inactive_date
    }
    security_identifier {
        bigint xref_id PK
        bigint security_id FK
        bigint listing_id FK
        text id_type FK
        text id_value "CHECK identifier_is_valid"
        char mic
        date valid_from
        date valid_to "EXCLUDE overlapping ranges"
        bigint load_id FK
    }
    benchmark_weight {
        int benchmark_id FK
        date as_of_date
        bigint security_id FK
        numeric weight
        numeric shares
        numeric market_value
        bigint load_id FK
    }
    portfolio_holding {
        int portfolio_id FK
        date as_of_date
        bigint security_id FK
        numeric quantity
        numeric weight
        numeric cost_price
        text input_identifier
        bigint load_id FK "set by portfolio-snapshots"
        date drifted_from
    }
    load_run {
        bigint load_id PK
        smallint source_id FK
        text loader
        timestamptz started_at
        timestamptz finished_at
        text status
        int rows_read
        int rows_inserted
        int rows_updated
        int rows_rejected
        int api_calls
        jsonb parameters
    }
```

### SQL functions the app relies on

| Function | Used by | What it guarantees |
|---|---|---|
| `resolve_identifier(text, type, as_of)` | Securities search, Add Holding | Any identifier (ISIN, CUSIP, SEDOL, FIGI, ticker, `TICKER:MIC`, `TICKER US`, CIK, LEI) → securities, best match first, as of a date |
| `add_holding(portfolio, date, identifier, shares, weight, type)` | Add / Paste Holdings | Resolves and inserts in one statement |
| `benchmark_weights(benchmark, as_of)` | Benchmarks, Copy Benchmark, vs Benchmark | The snapshot in force on a date |
| `build_benchmark(code, name, parent, 'equal'\|'cap', sector, as_of)` | Build Custom… | Creates a custom benchmark from another's members |
| `portfolio_valuation`, `portfolio_validate`, `portfolio_active_weights` | Portfolios | Market value with latest prices; checks (weights sum to 100 %, prices present and recent, inactive or short positions); active weights and active share |
| `last_price` | Securities, Portfolios | Latest EOD price for a listing |

Rules enforced in the database rather than the app (see [ADR-0002](adr/0002-postgresql-srm-schema-as-system-of-record.md)
and [ADR-0007](adr/0007-identifiers-with-validity-ranges-in-the-database.md)): identifier format and check digits
(`CHECK`), one security per identifier value at a time and one current value per security and type (`EXCLUDE`
constraints on validity ranges), benchmark membership rebuilt from all snapshots (`apply_benchmark_snapshot`).
