-- V034: MxPortMGR is renamed MxAcctMGR — the personal accounts app (banking and investments).
--
-- The values that name the app take the new name: the portfolios it maintains (managed_by 'MxPortMGR', and its sample
-- accounts' 'MxPortMGR samples') and the benchmarks it built (provider 'MxPortMGR'). Who saved a row (updated_by,
-- entered_by, ...) is history and stays as it was. The comments on the schema, its tables, views and columns that name
-- the app are rewritten. The apps and services read both names, so they work before and after this runs.

UPDATE srm.portfolio SET managed_by = 'MxAcctMGR' WHERE managed_by = 'MxPortMGR';
UPDATE srm.portfolio SET managed_by = 'MxAcctMGR samples' WHERE managed_by = 'MxPortMGR samples';
UPDATE srm.benchmark SET provider = 'MxAcctMGR' WHERE provider = 'MxPortMGR';

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT n.nspname, c.relname, c.relkind, a.attname, d.description
          FROM pg_description d
          JOIN pg_class c ON d.classoid = 'pg_class'::regclass AND c.oid = d.objoid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attribute a ON d.objsubid > 0 AND a.attrelid = c.oid AND a.attnum = d.objsubid
         WHERE n.nspname = 'srm' AND d.description LIKE '%MxPortMGR%'
    LOOP
        IF r.attname IS NULL THEN
            EXECUTE format('COMMENT ON %s %I.%I IS %L',
                           CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
                           r.nspname, r.relname, replace(r.description, 'MxPortMGR', 'MxAcctMGR'));
        ELSE
            EXECUTE format('COMMENT ON COLUMN %I.%I.%I IS %L', r.nspname, r.relname, r.attname,
                           replace(r.description, 'MxPortMGR', 'MxAcctMGR'));
        END IF;
    END LOOP;
    FOR r IN
        SELECT n.nspname, d.description
          FROM pg_description d
          JOIN pg_namespace n ON d.classoid = 'pg_namespace'::regclass AND n.oid = d.objoid
         WHERE n.nspname = 'srm' AND d.description LIKE '%MxPortMGR%'
    LOOP
        EXECUTE format('COMMENT ON SCHEMA %I IS %L', r.nspname, replace(r.description, 'MxPortMGR', 'MxAcctMGR'));
    END LOOP;
END $$;
