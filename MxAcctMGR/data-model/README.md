# MxAcctMGR data model

The illustrative market, the teaching accounts with their tax lots, the market reports and reactions, and the engines'
results, as PostgreSQL schema `pmg`. MxAcctMGR itself keeps these in Swift and UserDefaults; a My Portfolio in the
security master is already MxDataHUB's `srm.portfolio` / `srm.portfolio_tax_lot`.

| Document | What it holds |
|---|---|
| [erd.md](erd.md) | Entity relationship diagrams (Mermaid): overview, market, accounts, reports, engine results |
| [logical-data-model.md](logical-data-model.md) | Entities, attributes, keys, relationships, views and the Portfolio checks |
| [ddl/](ddl/README.md) | PostgreSQL DDL package for schema `pmg`, seeded from the app's own model |
| [tools/](tools/) | `generate_seed.sh` — rebuilds `ddl/10_seed.sql` by compiling the app's model files with `main.swift` |

Related models: [MxDataHUB](../../MxDataHUB/data-model/README.md) (`srm`) and [MxJobsMGR](../../MxJobsMGR/data-model/README.md) (`wms`).
