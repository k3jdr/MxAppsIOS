# MxPortMGR — Entity Relationship Diagram (schema `pmg`)

MxPortMGR keeps its illustrative market, samples and reports in Swift and My Portfolio in UserDefaults; in
security-master mode My Portfolio lives in MxDataHUB's `srm.portfolio` / `srm.portfolio_tax_lot` (see
[MxDataHUB's ERD](../../MxDataHUB/data-model/erd.md)). Schema `pmg` ([`ddl/install.sql`](ddl/install.sql)) is the
relational form of what the app holds, seeded from the app's own model, plus the engines' results. 50 tables.

Crow's-foot notation: `||` exactly one, `o|` zero or one, `|{` one or more, `o{` zero or more.

## 1. Overview

```mermaid
erDiagram
    SECTOR ||--o{ SECURITY : groups
    ASSET_CLASS ||--o{ SECURITY : groups
    SECURITY ||--o| BOND_TERMS : "has terms"
    SECURITY ||--o{ FUND_LOOK_THROUGH : "fund holds"
    BENCHMARK ||--|{ BENCHMARK_WEIGHT : weights
    SECURITY ||--o{ BENCHMARK_WEIGHT : "is weighted in"
    MARKET_MONTH ||--o{ SECURITY_MONTH_RETURN : "dates"
    BENCHMARK ||--o{ ACCOUNT : measures
    ACCOUNT ||--o{ HOLDING : holds
    HOLDING ||--o{ TAX_LOT : "splits into"
    REPORT_TIER ||--o{ MARKET_REPORT : ranks
    MARKET_REPORT ||--o{ REPORT_REACTION : "offers"
    REPORT_REACTION ||--o{ REACTION_MOVE : "moves money"
    ACCOUNT |o--o{ MARKET_REPORT : "is written for"
    ACCOUNT ||--o{ ENGINE_RUN : "is analysed by"
    ENGINE_RUN ||--o| OPTIMIZATION : "optimize / track"
    ENGINE_RUN ||--o| RISK_REPORT : "risk"
    ENGINE_RUN ||--o| ATTRIBUTION : "attribution"
    ENGINE_RUN ||--o| SIMULATION : "long run"
    MARKET_REPORT ||--o{ SIMULATION : "is simulated"
```

## 2. The illustrative market

```mermaid
erDiagram
    ASSET_CLASS {
        text asset_class PK "equity | bond | cash"
        text title "Stocks, Bonds, Cash"
    }
    SECTOR {
        text sector PK "11 equity sectors + Fixed Income, Cash, Fund"
        text sector_kind
    }
    SECURITY {
        text ticker PK "TICKER or TICKER:MIC for srm"
        text name
        text security_kind "company | bond_fund | bond | index_fund | cash | srm"
        text sector FK
        text asset_class FK
        float price
        float beta "market factor"
        float rate_beta "≈ −duration"
        float idio_vol
        float market_cap_bn
        float alpha "illustrative forecast"
        float yield
        float fee
        text source "illustrative | srm"
        bigint srm_security_id "srm.security"
    }
    BOND_TERMS {
        text ticker PK, FK
        text issuer_type
        float coupon
        date maturity
        text rating
    }
    FUND_LOOK_THROUGH {
        text fund_ticker PK, FK "MXTM, MXBD, MXTK"
        text member_ticker PK, FK
        float weight "members add up to 1"
    }
    BENCHMARK {
        text code PK "MXEQ, MX6040, MX3070, or srm code"
        text name
        text summary
        text source
    }
    BENCHMARK_WEIGHT {
        text code PK, FK
        text ticker PK, FK
        float weight
    }
    MARKET_MONTH {
        date month PK "2025-11 … 2026-10"
        float market_return
        float rate_change
    }
    SECURITY_MONTH_RETURN {
        text ticker PK, FK
        date month PK, FK
        float total_return
    }
    MODEL_PARAMETER {
        text name PK "risk_free, equity_premium, market_vol, ..."
        float value
    }

    ASSET_CLASS ||--o{ SECURITY : groups
    SECTOR ||--o{ SECURITY : groups
    SECURITY ||--o| BOND_TERMS : "has terms"
    SECURITY ||--o{ FUND_LOOK_THROUGH : "fund holds"
    SECURITY ||--o{ FUND_LOOK_THROUGH : "is held by fund"
    BENCHMARK ||--|{ BENCHMARK_WEIGHT : weights
    SECURITY ||--o{ BENCHMARK_WEIGHT : "is weighted in"
    MARKET_MONTH ||--o{ SECURITY_MONTH_RETURN : dates
    SECURITY ||--o{ SECURITY_MONTH_RETURN : returns
```

## 3. Accounts, holdings and tax lots

```mermaid
erDiagram
    ACCOUNT {
        text account_id PK "core-satellite, …, my-portfolio"
        text name
        text account_type "taxable | retirement | roth"
        text benchmark_code FK
        text style "active | passive | either"
        boolean is_sample
        text lesson
        text trading "buyAndHold | trader"
        text source "illustrative | srm"
        text srm_code "srm.portfolio.code"
    }
    ACCOUNT_LOOK_FOR {
        text account_id PK, FK
        smallint ordinal PK
        text text
    }
    HOLDING {
        text account_id PK, FK
        text ticker PK "not an FK: unknown securities are reported, not refused"
        float value
        float quantity
        boolean unpriced
    }
    TAX_LOT {
        text account_id PK, FK
        text ticker PK, FK
        date acquired PK
        float cost_basis PK
        float share "of the holding; lots add up to 1"
    }
    ACCOUNT_MISSING_RETURN {
        text account_id PK, FK
        text ticker PK, FK
        date from_month FK
    }
    BENCHMARK {
        text code PK
    }
    APP_SETTING {
        text key PK
        jsonb value
    }

    BENCHMARK ||--o{ ACCOUNT : measures
    ACCOUNT ||--o{ ACCOUNT_LOOK_FOR : "teaches"
    ACCOUNT ||--o{ HOLDING : holds
    HOLDING ||--o{ TAX_LOT : "splits into"
    ACCOUNT ||--o{ ACCOUNT_MISSING_RETURN : "lacks returns for"
```

## 4. Market reports and reactions

```mermaid
erDiagram
    REPORT_TIER {
        smallint tier PK "1 … 6"
        text title
        text summary
    }
    PRICE_DRIVER {
        text driver PK "growth, inflation, rates, profits, sentiment"
        text title
    }
    MARKET_REPORT {
        text report_id PK "jobs, cpi, fomc, …"
        text title
        text headline
        smallint tier FK
        text publisher
        text frequency
        smallint impact
        smallint top_five UK "1 … 5"
        float market_move
        float rate_move
        text single_ticker FK
        text suggested_sample FK
    }
    REPORT_TEXT {
        text report_id PK, FK
        text list PK "reading | key_metric | why_care | takeaway"
        smallint ordinal PK
        text text
    }
    REPORT_LINE {
        text report_id PK, FK
        smallint ordinal PK
        text label
        text value
        text expected
        text meaning
    }
    REPORT_TERM {
        text report_id PK, FK
        smallint ordinal PK
        text term
        text definition
    }
    REPORT_ASSET_MOVE {
        text report_id PK, FK
        smallint ordinal PK
        text asset
        text move
        text why
    }
    REPORT_DRIVER {
        text report_id PK, FK
        text driver PK, FK
    }
    REPORT_FACTOR_MOVE {
        text report_id PK, FK
        text factor PK "sector | company"
        text name PK
        float move
    }
    REPORT_CONTEXT_SERIES {
        text report_id PK, FK
        text title
        text unit
        text kind "line | bar"
        float reference
    }
    REPORT_CONTEXT_POINT {
        text report_id PK, FK
        smallint ordinal PK
        text label
        float value
    }
    REPORT_REACTION {
        text report_id PK, FK
        text reaction_id PK "sell-all, buy-dip, …"
        text title
        text summary
        text after "revert | permanent | rebalanceToPlan"
        float repeat_on_drawdown
    }
    REACTION_MOVE {
        text report_id PK, FK
        text reaction_id PK, FK
        smallint ordinal PK
        text from_sleeve FK
        text to_sleeve FK
        float fraction
    }
    SLEEVE {
        text sleeve PK "stocks | single | bonds | cash"
    }
    ACCOUNT {
        text account_id PK
    }
    SECURITY {
        text ticker PK
    }

    REPORT_TIER ||--o{ MARKET_REPORT : ranks
    MARKET_REPORT ||--o{ REPORT_TEXT : explains
    MARKET_REPORT ||--o{ REPORT_LINE : releases
    MARKET_REPORT ||--o{ REPORT_TERM : defines
    MARKET_REPORT ||--o{ REPORT_ASSET_MOVE : "moves markets"
    MARKET_REPORT ||--o{ REPORT_DRIVER : "moves drivers"
    PRICE_DRIVER ||--o{ REPORT_DRIVER : "is moved by"
    MARKET_REPORT ||--o{ REPORT_FACTOR_MOVE : "shocks factors"
    MARKET_REPORT ||--o| REPORT_CONTEXT_SERIES : "charts"
    REPORT_CONTEXT_SERIES ||--o{ REPORT_CONTEXT_POINT : plots
    MARKET_REPORT ||--o{ REPORT_REACTION : offers
    REPORT_REACTION ||--o{ REACTION_MOVE : "moves money"
    SLEEVE ||--o{ REACTION_MOVE : "from / to"
    ACCOUNT |o--o{ MARKET_REPORT : "is written for"
    SECURITY |o--o{ MARKET_REPORT : "is the company of"
```

## 5. Engine results

```mermaid
erDiagram
    ACCOUNT {
        text account_id PK
    }
    ENGINE_RUN {
        bigint run_id PK
        text account_id FK
        text analysis "active_optimization | index_tracking | risk | attribution | simulation"
        text engine "builtIn | services"
        text service_id "wms.layer3_service"
        text benchmark_code
        jsonb holdings
        float milliseconds
    }
    OPTIMIZATION {
        bigint run_id PK, FK
        float tracking_error_target "settings ..."
        int max_names
        text status "result ..."
        float tracking_error
        float information_ratio
        float active_share
        float turnover
        text recommendation "rebalance | rebalance_partially | hold | rerun_relaxed | escalate"
    }
    OPTIMIZATION_WEIGHT {
        bigint run_id PK, FK
        text ticker PK
        float weight
    }
    OPTIMIZATION_TRADE {
        bigint run_id PK, FK
        text ticker PK
        float from_weight
        float to_weight
        text route
    }
    OPTIMIZATION_CONSTRAINT {
        bigint run_id PK, FK
        smallint ordinal PK
        text text
    }
    OPTIMIZATION_SECTOR {
        bigint run_id PK, FK
        text sector PK, FK
        float active_weight
    }
    TAX_ESTIMATE {
        bigint run_id PK, FK
        text lot_order "fifo | hifo"
        float tax
    }
    TAX_ESTIMATE_LINE {
        bigint run_id PK, FK
        text ticker PK
        date acquired PK
        float sold
        float gain
        boolean short_term
    }
    RISK_REPORT {
        bigint run_id PK, FK
        float volatility
        float tracking_error
        float beta
        float var95_month
        float es95_month
    }
    RISK_CONTRIBUTION {
        bigint run_id PK, FK
        text basis PK "security | sector | active"
        text name PK
        float weight
        float share
    }
    ATTRIBUTION {
        bigint run_id PK, FK
        text method "brinson-fachler | brinson-hood-beebower"
        float portfolio_return
        float benchmark_return
        float allocation
        float selection
        float interaction
        float data_gap
        text recommendation "publish | review"
    }
    ATTRIBUTION_GROUP {
        bigint run_id PK, FK
        text group_name PK
        float allocation
        float selection
        float interaction
    }
    ATTRIBUTION_PERIOD {
        bigint run_id PK, FK
        date month PK
        float portfolio_return
        float benchmark_return
    }
    ATTRIBUTION_CONTRIBUTOR {
        bigint run_id PK, FK
        text rank_side PK "top | bottom"
        smallint ordinal PK
        text ticker
        float contribution
    }
    ATTRIBUTION_NOTE {
        bigint run_id PK, FK
        text kind PK "reason | assumption"
        smallint ordinal PK
        text text
    }
    SIMULATION {
        bigint run_id PK, FK
        text report_id FK
        smallint years
        int paths
        text scenario FK
        numeric seed
        float start_value
    }
    SIMULATION_OUTCOME {
        bigint run_id PK, FK
        text reaction_id PK "plan or a reaction of the report"
        text report_id FK
        float median_end
        float p10_end
        float p90_end
        float missed_best_days
        float ahead_of_plan
    }
    SIMULATION_PATH {
        bigint run_id PK, FK
        text reaction_id PK, FK
        int month PK
        float median
        float low
        float high
    }
    SIMULATION_MISSING_BEST {
        bigint run_id PK, FK
        smallint days PK
        float annual_return
    }

    ACCOUNT ||--o{ ENGINE_RUN : "is analysed by"
    ENGINE_RUN ||--o| OPTIMIZATION : "optimize / track"
    OPTIMIZATION ||--o{ OPTIMIZATION_WEIGHT : proposes
    OPTIMIZATION ||--o{ OPTIMIZATION_TRADE : trades
    OPTIMIZATION ||--o{ OPTIMIZATION_CONSTRAINT : "is bound by"
    OPTIMIZATION ||--o{ OPTIMIZATION_SECTOR : tilts
    OPTIMIZATION ||--o| TAX_ESTIMATE : "costs tax"
    TAX_ESTIMATE ||--o{ TAX_ESTIMATE_LINE : "sells lots"
    ENGINE_RUN ||--o| RISK_REPORT : risk
    RISK_REPORT ||--o{ RISK_CONTRIBUTION : "comes from"
    ENGINE_RUN ||--o| ATTRIBUTION : attribution
    ATTRIBUTION ||--o{ ATTRIBUTION_GROUP : "by sector"
    ATTRIBUTION ||--o{ ATTRIBUTION_PERIOD : "by month"
    ATTRIBUTION ||--o{ ATTRIBUTION_CONTRIBUTOR : "top and bottom"
    ATTRIBUTION ||--o{ ATTRIBUTION_NOTE : explains
    ENGINE_RUN ||--o| SIMULATION : "long run"
    SIMULATION ||--|{ SIMULATION_OUTCOME : "one per strategy"
    SIMULATION_OUTCOME ||--o{ SIMULATION_PATH : "month by month"
    SIMULATION ||--o{ SIMULATION_MISSING_BEST : "missing best days"
```

## Cross-application references

| From | To | How |
|---|---|---|
| `pmg.account.srm_code` | MxDataHUB `srm.portfolio.code` (with `srm.portfolio_tax_lot`) | by code; the srm rows are the record of truth, written by the accounts service (8774) |
| `pmg.security.srm_security_id` | `srm.security.security_id` | a cached copy, keyed `TICKER:MIC` when the ticker clashes with the illustrative universe |
| `pmg.benchmark` (source `srm`) | `srm.benchmark.code` | cached weights for a security-master benchmark |
| `pmg.attribution.srm_portfolio_code` | `srm.portfolio.code` | Attribution ▸ Source: a security-master portfolio (analytics `/attribution`) |
| `pmg.engine_run.service_id` | MxJobsWMS `wms.layer3_service.service_id` | portfolio-java, portfolio-cpp, analytics |
