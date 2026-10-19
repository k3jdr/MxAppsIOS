-- MxDataHUB · srm DDL package · 01 schema, extensions, migration registry
--
-- The security reference master lives in schema srm. srm_meta.schema_version is the table
-- MxDataHUB/SRM/srm.py migrate keeps; 99_register_migrations.sql fills it so that a database
-- built from this package is "up to date" for the migration runner.

CREATE SCHEMA IF NOT EXISTS srm;
COMMENT ON SCHEMA srm IS 'Security reference master: issuers, securities, listings, identifiers, prices, benchmarks, portfolios';

-- btree_gist is needed for the no-overlap (EXCLUDE) constraints on validity ranges.
-- pg_trgm speeds up name search; optional (search falls back to ILIKE without it).
CREATE EXTENSION IF NOT EXISTS btree_gist;
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_trgm not available (%); name search will not use trigram indexes', SQLERRM;
END $$;

CREATE SCHEMA IF NOT EXISTS srm_meta;
CREATE TABLE IF NOT EXISTS srm_meta.schema_version (
    version    integer PRIMARY KEY,
    name       text NOT NULL,
    checksum   text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by text NOT NULL DEFAULT current_user
);
