-- V054: database roles for the Layer 3 services (Services/mxservices.py: srm-loader, analytics, accounts), the same
-- three the PC's server has, so the services stop connecting as the owner. Migrations (srm.py migrate) stay with
-- the owner, postgres, from config.local.json.
--
--  * srm_reader (NOLOGIN): connects to this database and reads schema srm (every table, view and sequence) and
--    srm_meta's migration history.
--  * srm_writer (NOLOGIN, a member of srm_reader): also inserts, updates and deletes srm's rows and draws from its
--    sequences. No DDL, no TRUNCATE, nothing in srm_admin.
--  * srm_app (LOGIN, a member of srm_writer): the services' user (mxservices.py sets SRM_PGUSER=srm_app). Created
--    with no password: this Mac's server trusts connections from 127.0.0.1 and ::1; where the server asks for one,
--    give the role a password there and keep it in the Keychain (service SRM-postgres, account srm_app@host/srm).
--  * Tables and sequences later migrations create in srm (as postgres) get the same grants by default.

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'srm_reader') THEN
        CREATE ROLE srm_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'srm_writer') THEN
        CREATE ROLE srm_writer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'srm_app') THEN
        CREATE ROLE srm_app LOGIN;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO srm_reader', current_database());
END $$;

GRANT srm_reader TO srm_writer;
GRANT srm_writer TO srm_app;

GRANT USAGE ON SCHEMA srm, srm_meta TO srm_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA srm, srm_meta TO srm_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA srm TO srm_reader;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA srm TO srm_writer;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA srm TO srm_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA srm GRANT SELECT ON TABLES TO srm_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA srm GRANT INSERT, UPDATE, DELETE ON TABLES TO srm_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA srm GRANT SELECT ON SEQUENCES TO srm_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA srm GRANT USAGE ON SEQUENCES TO srm_writer;
