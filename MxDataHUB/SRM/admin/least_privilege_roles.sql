-- Least-privilege roles for the security master, so the loaders, the Layer 3 services and the apps stop signing in
-- as the superuser postgres (who can read every database and run programs on the server: COPY ... FROM PROGRAM).
--
--   srm_reader  NOLOGIN  reads every table and view in schema srm, and the migration list in srm_meta
--   srm_writer  NOLOGIN  srm_reader, and inserts, updates and deletes rows in srm; it cannot create, alter, drop or
--                        truncate anything
--   srm_app     LOGIN    a srm_writer: srm.py's loaders, srm-loader, accounts, analytics, MxDataHUB, MxAcctMGR (through
--                        the accounts service), MxJobsMGR's service steps
--
-- postgres keeps owning schema srm and runs the migrations (srm.py --user postgres migrate); what later migrations
-- create gets the same grants (ALTER DEFAULT PRIVILEGES). spending_web keeps its own narrow grants. Only roles that
-- are granted CONNECT may connect to the database any more; the notices name any login role that loses it.
-- Functions keep PostgreSQL's default EXECUTE for everyone; none is SECURITY DEFINER.
--
-- There is no password in this file. Run it as postgres on the database PC, then give srm_app its password with
-- psql's \password, which sends it already hashed (never into a log or history):
--
--   "D:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U postgres -d srm -f least_privilege_roles.sql
--   "D:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U postgres -d srm -c "\password srm_app"
--
-- Then switch the clients (README.md, "Database roles"). Running it again is safe: it creates what is missing and
-- repeats the grants. It never changes a password.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'srm_reader') THEN
        CREATE ROLE srm_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'srm_writer') THEN
        CREATE ROLE srm_writer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'srm_app') THEN
        CREATE ROLE srm_app LOGIN;      -- no password: it cannot sign in until \password srm_app
    END IF;
END $$;

-- However the roles were made before: no superuser powers, ever.
ALTER ROLE srm_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE srm_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE srm_app LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
DO $$
BEGIN
    IF NOT pg_has_role('srm_writer', 'srm_reader', 'MEMBER') THEN
        GRANT srm_reader TO srm_writer;
    END IF;
    IF NOT pg_has_role('srm_app', 'srm_writer', 'MEMBER') THEN
        GRANT srm_writer TO srm_app;
    END IF;
END $$;

-- Reading: the schema, every table and view, the sequences' values; srm.py status's migration list.
GRANT USAGE ON SCHEMA srm TO srm_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA srm TO srm_reader;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA srm TO srm_reader;
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_namespace WHERE nspname = 'srm_meta') THEN
        GRANT USAGE ON SCHEMA srm_meta TO srm_reader;
        GRANT SELECT ON ALL TABLES IN SCHEMA srm_meta TO srm_reader;
    END IF;
END $$;

-- Writing rows (no TRUNCATE, no CREATE on the schema), and new ids from the sequences.
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA srm TO srm_writer;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA srm TO srm_writer;

-- The same for whatever later migrations create, whoever owns srm's objects now (postgres, normally).
DO $$
DECLARE
    owner name;
BEGIN
    FOR owner IN SELECT 'postgres'::name
                 UNION
                 SELECT pg_get_userbyid(c.relowner) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'srm'
    LOOP
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA srm GRANT SELECT ON TABLES TO srm_reader', owner);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA srm GRANT SELECT ON SEQUENCES TO srm_reader', owner);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA srm GRANT INSERT, UPDATE, DELETE ON TABLES TO srm_writer', owner);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA srm GRANT USAGE ON SEQUENCES TO srm_writer', owner);
    END LOOP;
END $$;

-- Connecting: only these roles (superusers always can), not every role on the server.
DO $$
DECLARE
    r record;
BEGIN
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO srm_reader', current_database());
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'spending_web') THEN
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO spending_web', current_database());
    END IF;
    FOR r IN SELECT rolname FROM pg_roles
              WHERE rolcanlogin AND NOT rolsuper AND rolname !~ '^pg_'
                AND NOT has_database_privilege(oid, current_database(), 'CONNECT')
    LOOP
        RAISE NOTICE 'Role % can no longer connect to %; if it should: GRANT CONNECT ON DATABASE % TO %;',
            r.rolname, current_database(), current_database(), r.rolname;
    END LOOP;
END $$;

COMMIT;

-- What srm_app may do now. Expected: t, t, f, f, f, 0.
SELECT has_schema_privilege('srm_app', 'srm', 'USAGE')            AS uses_srm,
       has_table_privilege('srm_app', 'srm.load_run', 'INSERT')    AS writes_rows,
       has_table_privilege('srm_app', 'srm.load_run', 'TRUNCATE')  AS truncates,
       has_schema_privilege('srm_app', 'srm', 'CREATE')            AS creates_tables,
       (SELECT rolsuper FROM pg_roles WHERE rolname = 'srm_app')   AS superuser,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'srm' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND NOT has_table_privilege('srm_app', c.oid, 'SELECT')) AS tables_it_cannot_read;
