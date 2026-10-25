-- MxJobsMGR · wms DDL package · installer
--
-- Creates schema wms in one transaction (PostgreSQL 15 or later):
--
--   psql -v ON_ERROR_STOP=1 -d srm -1 -f install.sql
--
-- wms is independent of MxDataHUB's srm schema (runs name srm portfolios and benchmarks by code
-- only), so it can share srm's database or have its own. It refuses to run where wms has tables.
-- Optional: load the sample jobspaces with load_samples.sql (needs psql's \set and pg_read_file
-- rights, or use the import function from a client).

\set ON_ERROR_STOP on

DO $$
BEGIN
    IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION 'wms needs PostgreSQL 15 or later (ON DELETE SET NULL (column)); this is %', version();
    END IF;
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'wms') THEN
        RAISE EXCEPTION 'schema wms already has tables';
    END IF;
END $$;

\ir 01_schema_and_codes.sql
\ir 02_service_catalog.sql
\ir 03_jobspace.sql
\ir 04_node_settings.sql
\ir 05_run_history.sql
\ir 06_routines_and_views.sql
\ir 10_seed.sql
