# wms DDL package

Creates schema `wms` in one transaction (PostgreSQL 15+, for `ON DELETE SET NULL (column)`):

```bash
cd MxJobsWMS/data-model/ddl
psql -v ON_ERROR_STOP=1 -h <host> -U postgres -d srm -1 -f install.sql
psql -v ON_ERROR_STOP=1 -h <host> -U postgres -d srm -1 -f load_samples.sql   # optional: the five sample jobspaces
```

`wms` does not depend on `srm`, so it can share MxDataHUB's database or have its own. Import and export any jobspace:

```sql
SELECT wms.import_jobspace(:'doc'::jsonb, '/path/to/My.jobspace');   -- psql: \set doc `cat My.jobspace`
SELECT jsonb_pretty(wms.export_jobspace('<jobspace_id>'));
SELECT * FROM wms.v_jobspace_problem;                               -- the Problems panel's checks
```

| File | Contents |
|---|---|
| `install.sql` | Version check, then the files below in order |
| `01_schema_and_codes.sql` | Schema, `touch_updated_at`, layers, step kinds, service use cases |
| `02_service_catalog.sql` | Layer 3 services, their use cases and endpoints, samples and the services each needs |
| `03_jobspace.sql` | Jobspaces, API subscriptions and headers, steps (with expected outcome and exception handling), arguments, required fields, value checks, links |
| `04_node_settings.sql` | The eight kind-specific settings tables and their lists |
| `05_run_history.sql` | Runs, step results, console log, prompts and answers |
| `06_routines_and_views.sql` | `import_jobspace`, `export_jobspace`, `v_job_link`, `v_jobspace_problem`, `v_jobspace_summary` |
| `10_seed.sql` | Layers, step kinds, use cases, the six Layer 3 services and 19 endpoints, the five samples (from `Shared/ServiceCatalog.swift`) |
| `load_samples.sql` | Imports `../../Samples/*.jobspace` tagged with their sample ids (re-runnable) |

**Verified (2026-10-18, PostgreSQL 18.6):** the five sample jobspaces and `startup.jobspace` import and export back
identical to the files (key-by-key comparison); `v_jobspace_problem` reports nothing on them and reports each rule on a
deliberately broken jobspace; settings rows for the wrong kind and links into another jobspace are refused.
