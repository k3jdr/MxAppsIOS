-- MxDataHUB · srm DDL package · installer
--
-- Builds schema srm (security reference master) in an empty database, in one transaction:
--
--   psql -v ON_ERROR_STOP=1 -d srm -1 -f install.sql
--
-- Equivalent to MxDataHUB/SRM/migrations V001–V011 applied in order (see README.md); it also
-- records those versions in srm_meta.schema_version so ./srm.py migrate continues from V012.
-- It refuses to run where srm already has tables: upgrade an existing database with srm.py.

\set ON_ERROR_STOP on

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'srm') THEN
        RAISE EXCEPTION 'schema srm already has tables; upgrade it with ./srm.py migrate instead of this package';
    END IF;
END $$;

\ir 01_schema.sql
\ir 02_identifier_functions.sql
\ir 03_reference_and_audit.sql
\ir 04_issuers_securities.sql
\ir 05_market_data.sql
\ir 06_benchmarks.sql
\ir 07_portfolios.sql
\ir 08_routines.sql
\ir 09_views.sql
\ir 10_seed.sql
\ir 99_register_migrations.sql
