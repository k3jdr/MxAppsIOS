# MxDataHUB — Entity Relationship Diagram (schema `srm`)

The security reference master as built by migrations V001–V011 (and by [`ddl/install.sql`](ddl/install.sql)).
28 tables, shown as one overview and four subject areas. Crow's-foot notation: `||` exactly one, `o|` zero or one,
`|{` one or more, `o{` zero or more. Every loaded fact also points to `data_source` (who supplied it) and, optionally,
`load_run` (which load wrote it); those audit links are drawn only in the Audit diagram to keep the others readable.

## 1. Overview

```mermaid
erDiagram
    ISSUER |o--o{ SECURITY : issues
    SECURITY_TYPE ||--o{ SECURITY : classifies
    SECURITY ||--o{ LISTING : "trades as"
    EXCHANGE ||--o{ LISTING : hosts
    SECURITY ||--o{ SECURITY_IDENTIFIER : "is known by"
    IDENTIFIER_TYPE ||--o{ SECURITY_IDENTIFIER : types
    SECURITY ||--o{ SECURITY_CLASSIFICATION : "is classified"
    CLASSIFICATION_NODE ||--o{ SECURITY_CLASSIFICATION : "applies to"
    LISTING ||--o{ PRICE : "is priced"
    SECURITY ||--o{ CORPORATE_ACTION : undergoes
    SECURITY ||--o{ SECURITY_MARKET_DATA : "has cap and shares"
    BENCHMARK ||--o{ BENCHMARK_WEIGHT : "snapshots"
    SECURITY ||--o{ BENCHMARK_WEIGHT : "is weighted in"
    BENCHMARK ||--o{ BENCHMARK_CONSTITUENT : "has members"
    BENCHMARK ||--o{ BENCHMARK_LEVEL : "has levels"
    BENCHMARK |o--o{ PORTFOLIO : "measures"
    PORTFOLIO ||--o{ PORTFOLIO_HOLDING : "snapshots"
    PORTFOLIO ||--o{ PORTFOLIO_TRANSACTION : records
    PORTFOLIO ||--o{ PORTFOLIO_TAX_LOT : "holds lots"
    SECURITY ||--o{ PORTFOLIO_HOLDING : "is held"
    SECURITY ||--o{ PORTFOLIO_TAX_LOT : "is bought"
    DATA_SOURCE ||--o{ LOAD_RUN : "is loaded by"
```

## 2. Reference data and audit trail

```mermaid
erDiagram
    DATA_SOURCE {
        smallint source_id PK
        text code UK "MANUAL, FMP, OPENFIGI, SEC_EDGAR, ..."
        text name
        text url
        text licence_note
        text plan_note "what the subscription serves"
    }
    LOAD_RUN {
        bigint load_id PK
        smallint source_id FK
        text loader
        timestamptz started_at
        timestamptz finished_at
        text status "running | succeeded | partial | failed"
        int rows_read
        int rows_inserted
        int rows_updated
        int rows_rejected
        int api_calls
        jsonb parameters
    }
    LOAD_REJECT {
        bigint reject_id PK
        bigint load_id FK
        text record_key
        text reason
        jsonb payload
    }
    CURRENCY {
        char3 currency_code PK "ISO 4217"
        char3 numeric_code
        text name
        smallint minor_units
        boolean is_active
        smallint source_id FK
    }
    COUNTRY {
        char2 country_code PK "ISO 3166"
        text name
    }
    EXCHANGE {
        char4 mic PK "ISO 10383"
        char4 operating_mic
        text segment_type "OPRT | SGMT"
        text name
        char20 lei
        char2 country_code FK
        text status
        smallint source_id FK
    }
    EXCHANGE_CODE_MAP {
        text source_code PK "OPENFIGI, FMP, NASDAQTRADER, SEC"
        text vendor_code PK
        char4 mic FK "NULL for a composite"
        boolean is_composite
    }
    IDENTIFIER_TYPE {
        text id_type PK "ISIN, CUSIP, SEDOL, FIGI, ..."
        text scope "security | listing | issuer"
        text pattern
        boolean has_check_digit
        boolean unique_per_security
    }
    SECURITY_TYPE {
        text security_type PK
        text asset_class "Equity, Fund, Fixed Income, ..."
    }
    CLASSIFICATION_SCHEME {
        text scheme_code PK "FMP, SIC, SSGA"
        text name
        smallint source_id FK
    }
    SCHEMA_VERSION {
        int version PK "srm_meta: applied migrations"
        text name
        text checksum "SHA-256 of the file"
        timestamptz applied_at
    }

    DATA_SOURCE ||--o{ LOAD_RUN : "is loaded by"
    LOAD_RUN ||--o{ LOAD_REJECT : rejects
    COUNTRY |o--o{ EXCHANGE : "is home to"
    EXCHANGE |o--o{ EXCHANGE_CODE_MAP : "is coded as"
    DATA_SOURCE |o--o{ CURRENCY : supplies
    DATA_SOURCE |o--o{ EXCHANGE : supplies
    DATA_SOURCE |o--o{ CLASSIFICATION_SCHEME : publishes
```

## 3. Issuers, securities, listings and identifiers

```mermaid
erDiagram
    ISSUER {
        bigint issuer_id PK
        text name
        char20 lei UK "ISO 17442, check digits"
        char10 cik UK "SEC"
        text ein
        text entity_status
        char2 country_code
        char4 sic_code
        text incorporation
    }
    ISSUER_NAME_HISTORY {
        bigint issuer_id PK, FK
        text name PK
        date valid_from
        date valid_to
        smallint source_id FK
    }
    SECURITY {
        bigint security_id PK
        bigint issuer_id FK
        text name
        text security_type FK
        text share_class
        char3 currency_code FK
        char2 country_code
        char4 primary_mic FK
        boolean is_active
        date inactive_date
        bigint created_load_id FK
    }
    LISTING {
        bigint listing_id PK
        bigint security_id FK
        char4 mic FK
        text ticker "one security per MIC+ticker at a time"
        char3 currency_code FK
        boolean is_primary "one current primary per security"
        date valid_from
        date valid_to
    }
    SECURITY_IDENTIFIER {
        bigint xref_id PK
        bigint security_id FK
        bigint listing_id FK "listing-scoped types"
        text id_type FK
        text id_value "format and check digit validated"
        char4 mic FK
        date valid_from
        date valid_to
        smallint source_id FK
        bigint load_id FK
    }
    CLASSIFICATION_SCHEME {
        text scheme_code PK
    }
    CLASSIFICATION_NODE {
        int node_id PK
        text scheme_code FK
        text code "UK with scheme"
        text name
        smallint level "1 Sector, 2 Industry"
        int parent_id FK
    }
    SECURITY_CLASSIFICATION {
        bigint security_id PK, FK
        text scheme_code PK, FK
        smallint level PK
        date valid_from PK
        int node_id FK
        date valid_to
    }
    IDENTIFIER_TYPE {
        text id_type PK
    }
    SECURITY_TYPE {
        text security_type PK
    }
    EXCHANGE {
        char4 mic PK
    }

    ISSUER ||--o{ ISSUER_NAME_HISTORY : "was named"
    ISSUER |o--o{ SECURITY : issues
    SECURITY_TYPE ||--o{ SECURITY : classifies
    EXCHANGE |o--o{ SECURITY : "is primary venue of"
    SECURITY ||--o{ LISTING : "trades as"
    EXCHANGE ||--o{ LISTING : hosts
    SECURITY ||--o{ SECURITY_IDENTIFIER : "is known by"
    LISTING |o--o{ SECURITY_IDENTIFIER : "carries"
    IDENTIFIER_TYPE ||--o{ SECURITY_IDENTIFIER : types
    EXCHANGE |o--o{ SECURITY_IDENTIFIER : "scopes"
    CLASSIFICATION_SCHEME ||--o{ CLASSIFICATION_NODE : defines
    CLASSIFICATION_NODE |o--o{ CLASSIFICATION_NODE : "is parent of"
    CLASSIFICATION_NODE ||--o{ SECURITY_CLASSIFICATION : "applies to"
    CLASSIFICATION_SCHEME ||--o{ SECURITY_CLASSIFICATION : "within"
    SECURITY ||--o{ SECURITY_CLASSIFICATION : "is classified"
```

## 4. Market data and benchmarks

```mermaid
erDiagram
    SECURITY {
        bigint security_id PK
    }
    LISTING {
        bigint listing_id PK
        bigint security_id FK
    }
    PRICE {
        bigint listing_id PK, FK
        date price_date PK
        smallint source_id PK, FK
        numeric open
        numeric high
        numeric low
        numeric close
        numeric adj_close
        bigint volume
        char3 currency_code FK
        bigint load_id FK
    }
    CORPORATE_ACTION {
        bigint action_id PK
        bigint security_id FK "UK with type, ex_date, source"
        text action_type "CASH_DIVIDEND, SPLIT, SYMBOL_CHANGE, ..."
        date ex_date
        date pay_date
        numeric amount
        numeric ratio_new
        numeric ratio_old
        smallint source_id FK
    }
    SECURITY_MARKET_DATA {
        bigint security_id PK, FK
        date as_of_date PK
        smallint source_id PK, FK
        numeric market_cap
        numeric shares_outstanding
        numeric beta
    }
    BENCHMARK {
        int benchmark_id PK
        text code UK "SP500, NDX, DJIA, ..."
        text name
        text provider
        text index_symbol "^GSPC"
        text weighting_method "cap | modified_cap | price | equal | custom"
        boolean is_proxy "weights from a tracking ETF"
        int parent_benchmark_id FK "custom benchmarks"
    }
    BENCHMARK_WEIGHT {
        int benchmark_id PK, FK
        date as_of_date PK "one snapshot per date"
        bigint security_id PK, FK
        numeric weight "fraction 0..1"
        numeric shares
        smallint source_id FK
    }
    BENCHMARK_CONSTITUENT {
        int benchmark_id PK, FK
        bigint security_id PK, FK
        date valid_from PK
        date valid_to "rebuilt from all snapshots"
    }
    BENCHMARK_LEVEL {
        int benchmark_id PK, FK
        date level_date PK
        smallint source_id PK, FK
        numeric close
    }

    SECURITY ||--o{ LISTING : "trades as"
    LISTING ||--o{ PRICE : "is priced"
    SECURITY ||--o{ CORPORATE_ACTION : undergoes
    SECURITY ||--o{ SECURITY_MARKET_DATA : "has cap and shares"
    BENCHMARK |o--o{ BENCHMARK : "is parent of"
    BENCHMARK ||--o{ BENCHMARK_WEIGHT : snapshots
    SECURITY ||--o{ BENCHMARK_WEIGHT : "is weighted in"
    BENCHMARK ||--o{ BENCHMARK_CONSTITUENT : "has members"
    SECURITY ||--o{ BENCHMARK_CONSTITUENT : "is member of"
    BENCHMARK ||--o{ BENCHMARK_LEVEL : "has levels"
```

## 5. Portfolios and personal accounts

```mermaid
erDiagram
    PORTFOLIO {
        int portfolio_id PK
        text code UK "DEMO_GROWTH, MY_PORTFOLIO, ..."
        text name
        char3 base_currency FK
        int benchmark_id FK
        date inception_date
        text account_type "taxable | retirement | roth; NULL = model portfolio"
        text approach "active | passive"
        text managed_by "MxAcctMGR"
        numeric cash_balance
    }
    PORTFOLIO_HOLDING {
        int portfolio_id PK, FK
        date as_of_date PK "one snapshot per date"
        bigint security_id PK, FK
        numeric quantity
        numeric weight "target, fraction"
        numeric cost_price
        text input_identifier "what the user typed"
        text input_type
        bigint load_id FK "carried forward by portfolio-snapshots"
        date drifted_from
    }
    PORTFOLIO_TRANSACTION {
        bigint txn_id PK
        int portfolio_id FK
        bigint security_id FK
        text txn_type "BUY, SELL, DIVIDEND, SPLIT, DEPOSIT, ..."
        date trade_date
        date settle_date
        numeric quantity
        numeric price
        numeric amount
        numeric fees
    }
    PORTFOLIO_TAX_LOT {
        bigint lot_id PK
        int portfolio_id FK
        bigint security_id FK
        date acquired_date
        numeric quantity
        numeric cost_basis
    }
    BENCHMARK {
        int benchmark_id PK
    }
    SECURITY {
        bigint security_id PK
    }
    CURRENCY {
        char3 currency_code PK
    }

    BENCHMARK |o--o{ PORTFOLIO : measures
    CURRENCY ||--o{ PORTFOLIO : "is base of"
    PORTFOLIO ||--o{ PORTFOLIO_HOLDING : snapshots
    PORTFOLIO ||--o{ PORTFOLIO_TRANSACTION : records
    PORTFOLIO ||--o{ PORTFOLIO_TAX_LOT : "holds lots"
    SECURITY ||--o{ PORTFOLIO_HOLDING : "is held"
    SECURITY |o--o{ PORTFOLIO_TRANSACTION : "is traded"
    SECURITY ||--o{ PORTFOLIO_TAX_LOT : "is bought"
```

`srm.sync_holdings_from_lots` writes a personal account's holdings snapshot for a day from its open tax lots (one
row per security: total shares, average cost), so every tool that reads holdings sees personal accounts as ordinary
portfolios.

## Cross-application references


| From                                                      | To                                          | How                                                           |
| ----------------------------------------------------------- | --------------------------------------------- | --------------------------------------------------------------- |
| MxAcctMGR `pmg.account.srm_code`                          | `srm.portfolio.code`                        | by code (no FK; `pmg` installs without `srm`)                 |
| MxAcctMGR `pmg.security.srm_security_id`                  | `srm.security.security_id`                  | cached copy of a security-master security                     |
| MxJobsMGR `wms.job_run.portfolio_code` / `benchmark_code` | `srm.portfolio.code` / `srm.benchmark.code` | by code, from `mxjobsmgr://sample/<id>?portfolio=&benchmark=` |
| accounts service (8774)                                   | `srm.portfolio`, `srm.portfolio_tax_lot`    | writes MxAcctMGR's My Portfolio                               |
