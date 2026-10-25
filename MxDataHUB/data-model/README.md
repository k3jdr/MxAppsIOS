# MxDataHUB data model

The security reference master in PostgreSQL schema `srm`.

| Document | What it holds |
|---|---|
| [erd.md](erd.md) | Entity relationship diagrams (Mermaid): overview and four subject areas |
| [logical-data-model.md](logical-data-model.md) | Entities, attributes, identifiers, relationships, derived data and business rules |
| [ddl/](ddl/README.md) | PostgreSQL DDL package: builds schema `srm` from scratch, equivalent to migrations V001–V011 |

The migrations in [`../SRM/migrations`](../SRM/migrations) stay the way an existing database is upgraded
(`./srm.py migrate`); the DDL package is for a new database and as a single readable statement of the schema.
Related models: [MxJobsMGR](../../MxJobsMGR/data-model/README.md) (`wms`) and [MxAcctMGR](../../MxAcctMGR/data-model/README.md) (`pmg`).
