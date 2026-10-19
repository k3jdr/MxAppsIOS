-- MxDataHUB · srm DDL package · 99 register the migrations this package is equivalent to
--
-- The package builds the same schema as MxDataHUB/SRM/migrations V001–V011. Recording them here
-- with the files' SHA-256 checksums lets `./srm.py migrate` treat the database as up to date and
-- apply only V012 onward. If a later migration is added, apply it with srm.py, not by editing
-- this package.

INSERT INTO srm_meta.schema_version (version, name, checksum) VALUES
    ( 1, 'foundation', '5fe7673838d72d1be94b3514c70ef94400a75965c90649e85f6bbd71f94e4794'),
    ( 2, 'identifier_validation', 'd4bed1a86d182d4dbe676c9beb1b767619358f21b85b606eff53ddcde8d7d859'),
    ( 3, 'issuers_securities_listings', '9c273256ddb85462b64abdee4f0adc4933f4f7fd0f2618ab9f61db31f57847c3'),
    ( 4, 'xref_functions_prices_actions', 'd66b03a9a1fbc187b94604649a943e99631e5a39d51772b2105e19d70358d788'),
    ( 5, 'benchmarks_portfolios', '2afaf0ff659cf493632663f91f0dccae01dc34d7299a761b24c5bffdbf8f9926'),
    ( 6, 'views_and_benchmark_seed', 'bd311cf8d2b15946a7b0fd1e52a731c36eaed953ebb33a04fdaf43d49f6530af'),
    ( 7, 'fmp_calendar_note', '46e4e120bea6ad78294c856fd89857d89614d2e2537d66ff64e7f88769f2d157'),
    ( 8, 'fmp_calendar_note_fix', 'fa42de41f98e3609586718ff410038796837a1ba618280a4c155d0f96539a16e'),
    ( 9, 'mxdatahub_app', 'a24f4479977706d6b6ac1a87cdf50da26a1bfc9367b864b646d3e2237fc5a41f'),
    (10, 'benchmark_portfolio_history', '94b0631953bf508efe0c4b27d24530a29320064a2997afa9ce8ca1c1e89cdb10'),
    (11, 'personal_accounts_tax_lots', 'df1a477490b5d047e0673fc86b3bacbd0e4356a7ccee2c11c670dd93db1ce836');
