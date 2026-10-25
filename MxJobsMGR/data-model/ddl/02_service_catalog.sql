-- MxJobsMGR · wms DDL package · 02 Layer 3 service catalog and sample library
--
-- The services in ../Services (ServiceCatalog.all) and the sample jobspaces (SampleInfo.all),
-- which MxDataHUB ▸ Services & Workflows and MxJobsMGR ▸ Layer 3 Services both show.

CREATE TABLE wms.layer3_service (
    service_id        text PRIMARY KEY CHECK (service_id ~ '^[a-z0-9][a-z0-9-]*$'),
    name              text NOT NULL,
    language          text NOT NULL CHECK (language IN ('Python', 'Java', 'C++', 'Swift', 'Other')),
    port              integer NOT NULL UNIQUE CHECK (port BETWEEN 1 AND 65535),
    purpose           text NOT NULL,
    why_this_language text NOT NULL,
    folder            text NOT NULL,      -- under MxAppsIOS/Services
    develop_in        text NOT NULL DEFAULT ''
);
COMMENT ON TABLE wms.layer3_service IS 'A local Layer 3 service (http://127.0.0.1:<port>) the workflows call';

CREATE TABLE wms.layer3_service_use (
    service_id text NOT NULL REFERENCES wms.layer3_service ON DELETE CASCADE,
    use_case   text NOT NULL REFERENCES wms.service_use_case,
    ordinal    smallint NOT NULL,
    PRIMARY KEY (service_id, use_case)
);

CREATE TABLE wms.service_endpoint (
    service_id text NOT NULL REFERENCES wms.layer3_service ON DELETE CASCADE,
    method     text NOT NULL CHECK (method IN ('GET', 'POST', 'PUT', 'DELETE')),
    path       text NOT NULL CHECK (path LIKE '/%'),
    summary    text NOT NULL,
    contract   text,                      -- versioned contract in Services/contracts, e.g. mxjobs.risk/1
    ordinal    smallint NOT NULL,
    PRIMARY KEY (service_id, method, path)
);
COMMENT ON TABLE wms.service_endpoint IS 'An endpoint of a Layer 3 service and the contract its body follows';

CREATE TABLE wms.sample (
    sample_id       text PRIMARY KEY CHECK (sample_id ~ '^[a-z0-9][a-z0-9-]*$'),
    title           text NOT NULL,
    area            text NOT NULL CHECK (area IN ('Data', 'Active', 'Passive', 'Analytics', 'Templates')),
    summary         text NOT NULL,
    file_name       text NOT NULL UNIQUE,  -- MxJobsMGR/Samples/<file>.jobspace
    takes_portfolio boolean NOT NULL,      -- opened from MxDataHUB with ?portfolio=&benchmark=
    sort_order      smallint NOT NULL
);
COMMENT ON TABLE wms.sample IS 'A sample workflow (File ▸ New from Sample…), opened by mxjobsmgr://sample/<id>';

CREATE TABLE wms.sample_service (
    sample_id  text NOT NULL REFERENCES wms.sample ON DELETE CASCADE,
    service_id text NOT NULL REFERENCES wms.layer3_service,
    ordinal    smallint NOT NULL,
    PRIMARY KEY (sample_id, service_id)
);
COMMENT ON TABLE wms.sample_service IS 'Services a sample needs running on Live';
