-- MxPortMGR · pmg DDL package · 01 schema and code lists
--
-- Schema pmg holds what MxPortMGR keeps today in Swift (the illustrative universe, the sample
-- accounts, the market reports and reactions) and in UserDefaults (My Portfolio), plus the
-- results of its engines (optimizations, risk, attribution, long-run simulations).
-- A My Portfolio kept in the security master stays in srm.portfolio / srm.portfolio_tax_lot
-- (MxDataHUB, V011); pmg.account names it by srm_code. Educational data only — none of the
-- illustrative companies, prices or forecasts are real.

CREATE SCHEMA IF NOT EXISTS pmg;
COMMENT ON SCHEMA pmg IS 'MxPortMGR: illustrative market, accounts and tax lots, market reports, reactions and engine results';

CREATE FUNCTION pmg.touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TABLE pmg.asset_class (
    asset_class text PRIMARY KEY CHECK (asset_class IN ('equity', 'bond', 'cash')),
    title       text NOT NULL UNIQUE,      -- Stocks, Bonds, Cash
    sort_order  smallint NOT NULL
);

-- The eleven equity sectors plus the pseudo-sectors the app uses for bonds, cash and funds.
CREATE TABLE pmg.sector (
    sector      text PRIMARY KEY,
    sector_kind text NOT NULL CHECK (sector_kind IN ('equity', 'fixed_income', 'cash', 'fund', 'other')),
    sort_order  smallint NOT NULL
);

-- Parameters of the illustrative factor model (Universe.swift).
CREATE TABLE pmg.model_parameter (
    name        text PRIMARY KEY,
    value       double precision NOT NULL,
    description text NOT NULL
);

-- The four sleeves the Behaviour Lab moves money between.
CREATE TABLE pmg.sleeve (
    sleeve     text PRIMARY KEY CHECK (sleeve IN ('stocks', 'single', 'bonds', 'cash')),
    title      text NOT NULL,
    sort_order smallint NOT NULL
);

-- The four primary determinants of asset prices a report moves (plus sentiment).
CREATE TABLE pmg.price_driver (
    driver     text PRIMARY KEY,
    title      text NOT NULL UNIQUE,
    symbol     text NOT NULL,
    sort_order smallint NOT NULL
);

CREATE TABLE pmg.report_tier (
    tier    smallint PRIMARY KEY CHECK (tier BETWEEN 1 AND 6),
    title   text NOT NULL,
    summary text NOT NULL
);

-- Futures the simulator draws: random, or shaped like a past episode.
CREATE TABLE pmg.scenario (
    scenario   text PRIMARY KEY CHECK (scenario IN ('random', 'fastCrash', 'longBear', 'bothFall')),
    title      text NOT NULL,
    detail     text NOT NULL,
    sort_order smallint NOT NULL
);
