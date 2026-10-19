-- MxPortMGR · pmg DDL package · installer
--
-- Creates schema pmg with the illustrative market, the sample accounts and the market reports,
-- in one transaction (PostgreSQL 13 or later):
--
--   psql -v ON_ERROR_STOP=1 -d srm -1 -f install.sql
--
-- pmg does not depend on srm or wms: My Portfolio in security-master mode names its srm.portfolio
-- by code, and engine runs name their Layer 3 service by id. It refuses to run where pmg has tables.

\set ON_ERROR_STOP on

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pmg') THEN
        RAISE EXCEPTION 'schema pmg already has tables';
    END IF;
END $$;

\ir 01_schema_and_codes.sql
\ir 02_universe.sql
\ir 03_accounts.sql
\ir 04_reports_and_reactions.sql
\ir 05_engine_results.sql
\ir 06_views.sql
\ir 10_seed.sql
