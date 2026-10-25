# MxJobsMGR data model

Jobspaces (three-layer workflows), their subscriptions and steps, run history, and the Layer 3 service catalog, as
PostgreSQL schema `wms`. MxJobsMGR itself still saves `*.jobspace` JSON files; this model is their relational form
and the place to keep run history, with import / export functions that round-trip the files.

| Document | What it holds |
|---|---|
| [erd.md](erd.md) | Entity relationship diagrams (Mermaid): overview, design, step settings, catalog and runs |
| [logical-data-model.md](logical-data-model.md) | Entities, attributes, keys, relationships, the Problems rules, and the JSON ↔ table mapping |
| [ddl/](ddl/README.md) | PostgreSQL DDL package for schema `wms` |

Related models: [MxDataHUB](../../MxDataHUB/data-model/README.md) (`srm`) and [MxAcctMGR](../../MxAcctMGR/data-model/README.md) (`pmg`).
