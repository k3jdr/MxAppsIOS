-- MxJobsMGR · wms DDL package · 03 jobspaces, subscriptions, steps and links
--
-- One row per *.jobspace document. The documents' own ids (UUIDs of steps, links, subscriptions,
-- arguments, ...) are unique only inside a document — Save As and New from Sample keep them — so
-- every child is keyed by (jobspace_id, its id) or (parent key, ordinal), and the composite
-- foreign keys keep each link, step and subscription reference inside its own jobspace.
-- ordinal is the position in the document's array, so a file exports in its own order.

CREATE TABLE wms.jobspace (
    jobspace_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name           text NOT NULL DEFAULT 'Untitled Jobspace' CHECK (btrim(name) <> ''),
    description    text NOT NULL DEFAULT '',
    format_version integer NOT NULL DEFAULT 1 CHECK (format_version >= 1),
    sample_id      text REFERENCES wms.sample ON DELETE SET NULL,   -- created from a sample
    file_path      text,                                            -- where the document was last saved
    -- Run settings (RunSettings): what a run does with each layer.
    run_operations text NOT NULL DEFAULT 'interactive' CHECK (run_operations IN ('interactive', 'autoApprove', 'skip')),
    run_agents     text NOT NULL DEFAULT 'run'         CHECK (run_agents IN ('run', 'skip')),
    run_data       text NOT NULL DEFAULT 'mock'        CHECK (run_data IN ('live', 'mock', 'skip')),
    breakpoints_enabled boolean NOT NULL DEFAULT true,
    stop_on_error  boolean NOT NULL DEFAULT true,
    step_delay     double precision NOT NULL DEFAULT 0.4 CHECK (step_delay >= 0),   -- seconds between steps
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobspace_sample_idx ON wms.jobspace (sample_id);
CREATE TRIGGER jobspace_touch BEFORE UPDATE ON wms.jobspace FOR EACH ROW EXECUTE FUNCTION wms.touch_updated_at();
COMMENT ON TABLE wms.jobspace IS 'A workflow document (format mxjobspace): subscriptions, steps in three layers, links and run settings';

-- ---------------------------------------------------------------------------
-- API subscriptions (Layer 3 configuration). The key itself is never stored: it is the service key
-- of the MxAcctMGR secure account the subscription names (srm.secure_account, Banking ▸ Secure
-- Accounts), kept in the login Keychain under service com.k3jdr.MxAcctMGR.secure-accounts,
-- account "<secure_account_id> service key" (ADR-0018).
-- ---------------------------------------------------------------------------

CREATE TABLE wms.api_subscription (
    jobspace_id     uuid NOT NULL REFERENCES wms.jobspace ON DELETE CASCADE,
    subscription_id uuid NOT NULL DEFAULT gen_random_uuid(),
    ordinal         smallint NOT NULL,
    name            text NOT NULL DEFAULT 'New Subscription',
    provider        text NOT NULL DEFAULT '',
    base_url        text NOT NULL DEFAULT 'https://',
    auth            text NOT NULL DEFAULT 'queryParameter'
                    CHECK (auth IN ('none', 'queryParameter', 'header', 'bearer', 'localService')),
    key_name        text NOT NULL DEFAULT 'apikey',      -- query parameter / header name for the key
    rate_limit_per_minute integer NOT NULL DEFAULT 0 CHECK (rate_limit_per_minute >= 0),
    plan            text NOT NULL DEFAULT '',
    docs_url        text NOT NULL DEFAULT '',
    notes           text NOT NULL DEFAULT '',
    project_folder  text NOT NULL DEFAULT '',            -- source of a local service, for Open Project
    ide             text NOT NULL DEFAULT 'vscode' CHECK (ide IN ('vscode', 'intellij', 'clion', 'xcode', 'finder')),
    service_id      text REFERENCES wms.layer3_service ON DELETE SET NULL,   -- the Layer 3 service it calls, if local
    secure_account_id integer,                           -- srm.secure_account whose service key is sent (another database)
    secure_account_name text NOT NULL DEFAULT '',        -- its name as last seen; with no id, the account to link by name
    PRIMARY KEY (jobspace_id, subscription_id),
    UNIQUE (jobspace_id, ordinal) DEFERRABLE
);
CREATE INDEX api_subscription_service_idx ON wms.api_subscription (service_id);
COMMENT ON TABLE wms.api_subscription IS 'A data provider or local service a jobspace calls; the API key stays in MxAcctMGR Secure Accounts (Keychain)';
COMMENT ON COLUMN wms.api_subscription.secure_account_id IS 'MxAcctMGR secure account (srm.secure_account) whose service key is sent: Keychain service com.k3jdr.MxAcctMGR.secure-accounts, account "<id> service key"';
COMMENT ON COLUMN wms.api_subscription.secure_account_name IS 'The secure account''s name as last seen; with no id, the account linked by name once it exists';
COMMENT ON COLUMN wms.api_subscription.service_id IS 'Set when base_url is a Layer 3 service on 127.0.0.1 (matched by port on import)';

CREATE TABLE wms.subscription_header (
    jobspace_id     uuid NOT NULL,
    subscription_id uuid NOT NULL,
    ordinal         smallint NOT NULL,
    item_id         uuid NOT NULL DEFAULT gen_random_uuid(),   -- the KeyValue id in the document
    key             text NOT NULL,
    value           text NOT NULL DEFAULT '',
    PRIMARY KEY (jobspace_id, subscription_id, ordinal),
    FOREIGN KEY (jobspace_id, subscription_id) REFERENCES wms.api_subscription ON DELETE CASCADE
);
COMMENT ON TABLE wms.subscription_header IS 'Headers sent with every call of a subscription (e.g. X-SRM-Dry-Run: 1)';

-- ---------------------------------------------------------------------------
-- Steps (JobNode). Expected outcome and exception handling are 1:1 value objects of the step,
-- kept as columns; their lists (required fields, value checks) are child tables.
-- ---------------------------------------------------------------------------

CREATE TABLE wms.job_node (
    jobspace_id  uuid NOT NULL REFERENCES wms.jobspace ON DELETE CASCADE,
    node_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    kind         text NOT NULL,
    layer        smallint NOT NULL,
    title        text NOT NULL,
    notes        text NOT NULL DEFAULT '',
    x            double precision NOT NULL DEFAULT 0,
    y            double precision NOT NULL DEFAULT 0,
    enabled      boolean NOT NULL DEFAULT true,
    breakpoint   boolean NOT NULL DEFAULT false,
    ordinal      smallint NOT NULL,
    -- Expected outcome (ExpectedOutcome)
    outcome_description text NOT NULL DEFAULT '',
    success_status      text NOT NULL DEFAULT '200-299',
    output_name         text NOT NULL DEFAULT '',   -- name later steps use in {{in:name.path}}
    -- Exception handling (ExceptionPolicy)
    on_failure          text NOT NULL DEFAULT 'retry'
                        CHECK (on_failure IN ('retry', 'skip', 'useFallback', 'escalateToUser', 'abortRun')),
    max_retries         smallint NOT NULL DEFAULT 2 CHECK (max_retries >= 0),
    retry_delay_seconds integer NOT NULL DEFAULT 5 CHECK (retry_delay_seconds >= 0),
    exponential_backoff boolean NOT NULL DEFAULT true,
    timeout_seconds     integer NOT NULL DEFAULT 30 CHECK (timeout_seconds > 0),
    fallback_value      text NOT NULL DEFAULT '',
    notify_user         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (jobspace_id, node_id),
    UNIQUE (jobspace_id, node_id, kind),
    UNIQUE (jobspace_id, ordinal) DEFERRABLE,
    FOREIGN KEY (kind, layer) REFERENCES wms.node_kind (kind, layer)
);
CREATE INDEX job_node_kind_idx ON wms.job_node (kind);
COMMENT ON TABLE wms.job_node IS 'A step on the canvas: its kind fixes its layer (lane) and its settings table';

CREATE TABLE wms.node_argument (
    jobspace_id uuid NOT NULL,
    node_id     uuid NOT NULL,
    ordinal     smallint NOT NULL,
    item_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    type        text NOT NULL DEFAULT 'text' CHECK (type IN ('text', 'number', 'date', 'symbols', 'boolean')),
    value       text NOT NULL DEFAULT '',
    required    boolean NOT NULL DEFAULT false,
    PRIMARY KEY (jobspace_id, node_id, ordinal),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.job_node ON DELETE CASCADE
);
COMMENT ON TABLE wms.node_argument IS 'A step argument, usable as {{name}} in its settings (plus {{today}} / {{yesterday}})';

CREATE TABLE wms.node_required_field (
    jobspace_id uuid NOT NULL,
    node_id     uuid NOT NULL,
    ordinal     smallint NOT NULL,
    field_path  text NOT NULL,
    PRIMARY KEY (jobspace_id, node_id, ordinal),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.job_node ON DELETE CASCADE
);
COMMENT ON TABLE wms.node_required_field IS 'JSON fields the step''s output must contain (expected outcome)';

CREATE TABLE wms.node_assertion (
    jobspace_id uuid NOT NULL,
    node_id     uuid NOT NULL,
    ordinal     smallint NOT NULL,
    item_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    path        text NOT NULL,
    op          text NOT NULL DEFAULT '==' CHECK (op IN ('==', '!=', '<', '<=', '>', '>=', 'contains', 'exists')),
    value       text NOT NULL DEFAULT '',            -- may use {{argument}}
    PRIMARY KEY (jobspace_id, node_id, ordinal),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.job_node ON DELETE CASCADE
);
COMMENT ON TABLE wms.node_assertion IS 'A value check of the expected outcome: path op value, e.g. summary.failed == 0';

-- ---------------------------------------------------------------------------
-- Links. Down the layers = a call; up = a result coming back (drawn dashed); within a layer =
-- sequence (see wms.v_job_link).
-- ---------------------------------------------------------------------------

CREATE TABLE wms.job_link (
    jobspace_id  uuid NOT NULL REFERENCES wms.jobspace ON DELETE CASCADE,
    link_id      uuid NOT NULL DEFAULT gen_random_uuid(),
    from_node_id uuid NOT NULL,
    to_node_id   uuid NOT NULL,
    label        text NOT NULL DEFAULT '',
    ordinal      smallint NOT NULL,
    PRIMARY KEY (jobspace_id, link_id),
    CHECK (from_node_id <> to_node_id),
    UNIQUE (jobspace_id, from_node_id, to_node_id),
    UNIQUE (jobspace_id, ordinal) DEFERRABLE,
    FOREIGN KEY (jobspace_id, from_node_id) REFERENCES wms.job_node (jobspace_id, node_id) ON DELETE CASCADE,
    FOREIGN KEY (jobspace_id, to_node_id)   REFERENCES wms.job_node (jobspace_id, node_id) ON DELETE CASCADE
);
CREATE INDEX job_link_to_idx ON wms.job_link (jobspace_id, to_node_id);
COMMENT ON TABLE wms.job_link IS 'A directed link between two steps of the same jobspace';
