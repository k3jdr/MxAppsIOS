-- MxJobsWMS · wms DDL package · load the sample jobspaces (optional)
--
-- Run from this folder (the paths are relative to it), after install.sql:
--
--   psql -v ON_ERROR_STOP=1 -d srm -1 -f load_samples.sql
--
-- Each sample is imported once, tagged with its sample_id; run again to replace them.

\set ON_ERROR_STOP on

\set doc `cat ../../Samples/SRMDailyRefresh.jobspace`
SELECT wms.import_jobspace(:'doc'::jsonb, 'MxJobsWMS/Samples/SRMDailyRefresh.jobspace', 'srm-daily-refresh',
                           (SELECT jobspace_id FROM wms.jobspace WHERE sample_id = 'srm-daily-refresh' LIMIT 1));
\set doc `cat ../../Samples/ActivePortfolioOptimization.jobspace`
SELECT wms.import_jobspace(:'doc'::jsonb, 'MxJobsWMS/Samples/ActivePortfolioOptimization.jobspace', 'active-optimization',
                           (SELECT jobspace_id FROM wms.jobspace WHERE sample_id = 'active-optimization' LIMIT 1));
\set doc `cat ../../Samples/PassiveIndexTracking.jobspace`
SELECT wms.import_jobspace(:'doc'::jsonb, 'MxJobsWMS/Samples/PassiveIndexTracking.jobspace', 'passive-tracking',
                           (SELECT jobspace_id FROM wms.jobspace WHERE sample_id = 'passive-tracking' LIMIT 1));
\set doc `cat ../../Samples/PerformanceAttribution.jobspace`
SELECT wms.import_jobspace(:'doc'::jsonb, 'MxJobsWMS/Samples/PerformanceAttribution.jobspace', 'attribution',
                           (SELECT jobspace_id FROM wms.jobspace WHERE sample_id = 'attribution' LIMIT 1));
\set doc `cat ../../Samples/DailyMarketRefresh.jobspace`
SELECT wms.import_jobspace(:'doc'::jsonb, 'MxJobsWMS/Samples/DailyMarketRefresh.jobspace', 'market-refresh',
                           (SELECT jobspace_id FROM wms.jobspace WHERE sample_id = 'market-refresh' LIMIT 1));
