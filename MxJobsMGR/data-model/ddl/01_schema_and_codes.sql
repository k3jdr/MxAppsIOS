-- MxJobsMGR · wms DDL package · 01 schema and code lists
--
-- Schema wms holds MxJobsMGR jobspaces (the three-layer workflow diagrams saved today as
-- *.jobspace JSON), their API subscriptions (never the keys: those stay in the login Keychain),
-- the Layer 3 service catalog and sample library both apps describe, and run history.
-- gen_random_uuid() is built in from PostgreSQL 13; ON DELETE SET NULL (column) needs 15+.

CREATE SCHEMA IF NOT EXISTS wms;
COMMENT ON SCHEMA wms IS 'MxJobsMGR: jobspaces (three-layer workflows), subscriptions, Layer 3 service catalog, samples and run history';

-- updated_at maintenance
CREATE FUNCTION wms.touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- The three swim lanes. Links pointing down the layers are calls; links pointing up carry results.
CREATE TABLE wms.layer (
    layer    smallint PRIMARY KEY CHECK (layer BETWEEN 1 AND 3),
    code     text NOT NULL UNIQUE,
    title    text NOT NULL,
    subtitle text NOT NULL
);
COMMENT ON TABLE wms.layer IS 'Swim lanes: 1 Business Operations, 2 Agentic Operations, 3 Data Reads';

-- Node kinds (NodeKind in JobspaceModel.swift). spec names the kind-specific settings table.
CREATE TABLE wms.node_kind (
    kind    text PRIMARY KEY,
    layer   smallint NOT NULL REFERENCES wms.layer,
    title   text NOT NULL,
    summary text NOT NULL,
    symbol  text NOT NULL,              -- SF Symbol shown on the canvas
    spec    text CHECK (spec IN ('schedule', 'agent', 'approval', 'execution', 'report', 'api_call', 'script', 'transform')),
    sort_order smallint NOT NULL,
    UNIQUE (kind, layer)
);
COMMENT ON TABLE wms.node_kind IS 'Step kinds per layer and the settings table each one uses';

-- Layer 3 use cases (ServiceUseCase in Shared/ServiceCatalog.swift).
CREATE TABLE wms.service_use_case (
    use_case    text PRIMARY KEY,
    title       text NOT NULL,
    when_to_use text NOT NULL,
    sort_order  smallint NOT NULL
);
