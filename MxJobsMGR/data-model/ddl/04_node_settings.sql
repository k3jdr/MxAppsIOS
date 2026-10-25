-- MxJobsMGR · wms DDL package · 04 kind-specific step settings
--
-- One table per settings type (ScheduleSpec, AgentSpec, ApprovalSpec, ExecutionSpec, ReportSpec,
-- ApiCallSpec, ScriptSpec, TransformSpec): a 1:0..1 subtype of wms.job_node. Each row repeats the
-- step's kind, and the composite key (jobspace_id, node_id, kind) with a CHECK on kind makes a
-- settings row possible only for the kinds that use it (an approval only on a User Approval).

CREATE TABLE wms.node_schedule (
    jobspace_id      uuid NOT NULL,
    node_id          uuid NOT NULL,
    kind             text NOT NULL DEFAULT 'trigger' CHECK (kind = 'trigger'),
    mode             text NOT NULL DEFAULT 'weekdays' CHECK (mode IN ('manual', 'daily', 'weekdays', 'interval')),
    run_time         text NOT NULL DEFAULT '07:30' CHECK (run_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
    time_zone        text NOT NULL DEFAULT 'America/New_York',
    interval_minutes integer NOT NULL DEFAULT 60 CHECK (interval_minutes > 0),
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE wms.node_schedule IS 'Refresh Trigger: when the workflow starts';

CREATE TABLE wms.node_agent (
    jobspace_id   uuid NOT NULL,
    node_id       uuid NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('instructionSet', 'agentTask', 'aggregate', 'decision')),
    instructions  text NOT NULL DEFAULT '',
    model         text NOT NULL DEFAULT '',
    output_format text NOT NULL DEFAULT '',
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE wms.node_agent IS 'Assemble Instructions, Agent Task, Aggregate Results, Decision: instructions and inputs';

-- Output names the agent reads, in priority order (a Decision follows the first most confident one).
CREATE TABLE wms.node_agent_input (
    jobspace_id uuid NOT NULL,
    node_id     uuid NOT NULL,
    ordinal     smallint NOT NULL,
    input_name  text NOT NULL,
    PRIMARY KEY (jobspace_id, node_id, ordinal),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.node_agent ON DELETE CASCADE
);

CREATE TABLE wms.node_approval (
    jobspace_id           uuid NOT NULL,
    node_id               uuid NOT NULL,
    kind                  text NOT NULL DEFAULT 'approvalGate' CHECK (kind = 'approvalGate'),
    approver              text NOT NULL DEFAULT '',
    channel               text NOT NULL DEFAULT 'inApp' CHECK (channel IN ('inApp', 'email', 'message')),
    expires_after_minutes integer NOT NULL DEFAULT 120 CHECK (expires_after_minutes > 0),
    require_comment       boolean NOT NULL DEFAULT false,
    summary_template      text NOT NULL DEFAULT '',
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE wms.node_approval IS 'User Approval: who approves, how, and when the request expires';

CREATE TABLE wms.node_execution (
    jobspace_id         uuid NOT NULL,
    node_id             uuid NOT NULL,
    kind                text NOT NULL DEFAULT 'executeRequest' CHECK (kind = 'executeRequest'),
    target              text NOT NULL DEFAULT '',
    mode                text NOT NULL DEFAULT 'dryRun' CHECK (mode IN ('dryRun', 'paper', 'live')),
    confirm_before_send boolean NOT NULL DEFAULT true,
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE wms.node_execution IS 'Execution Request: where approved instructions go (dry run, paper, live)';

CREATE TABLE wms.node_report (
    jobspace_id      uuid NOT NULL,
    node_id          uuid NOT NULL,
    kind             text NOT NULL DEFAULT 'outcomeReport' CHECK (kind = 'outcomeReport'),
    recipients       text NOT NULL DEFAULT '',
    detailed         boolean NOT NULL DEFAULT false,
    include_failures boolean NOT NULL DEFAULT true,
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE wms.node_report IS 'Outcome Report: who receives the run summary';

CREATE TABLE wms.node_api_call (
    jobspace_id     uuid NOT NULL,
    node_id         uuid NOT NULL,
    kind            text NOT NULL DEFAULT 'apiRead' CHECK (kind = 'apiRead'),
    subscription_id uuid,
    method          text NOT NULL DEFAULT 'GET' CHECK (method IN ('GET', 'POST')),
    path            text NOT NULL DEFAULT '',   -- may use {{argument}}, {{in:name.path}}
    body            text NOT NULL DEFAULT '',   -- may use {{json:name.path}}
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (jobspace_id, subscription_id) REFERENCES wms.api_subscription (jobspace_id, subscription_id)
        ON DELETE SET NULL (subscription_id)
);
CREATE INDEX node_api_call_subscription_idx ON wms.node_api_call (jobspace_id, subscription_id);
COMMENT ON TABLE wms.node_api_call IS 'API Data Read: the endpoint of a subscription it calls';

-- Query parameters and per-call headers of an API Data Read.
CREATE TABLE wms.node_api_param (
    jobspace_id uuid NOT NULL,
    node_id     uuid NOT NULL,
    location    text NOT NULL CHECK (location IN ('query', 'header')),
    ordinal     smallint NOT NULL,
    item_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    key         text NOT NULL,
    value       text NOT NULL DEFAULT '',
    PRIMARY KEY (jobspace_id, node_id, location, ordinal),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.node_api_call ON DELETE CASCADE
);

CREATE TABLE wms.node_script (
    jobspace_id     uuid NOT NULL,
    node_id         uuid NOT NULL,
    kind            text NOT NULL DEFAULT 'pythonScript' CHECK (kind = 'pythonScript'),
    code            text NOT NULL,              -- stdin: {arguments, inputs, step}; stdout: JSON output
    interpreter     text NOT NULL DEFAULT '',   -- empty = first of Homebrew, python.org, developer tools
    subscription_id uuid,                       -- gives MXJOBS_API_KEY / MXJOBS_BASE_URL
    PRIMARY KEY (jobspace_id, node_id),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (jobspace_id, subscription_id) REFERENCES wms.api_subscription (jobspace_id, subscription_id)
        ON DELETE SET NULL (subscription_id)
);
COMMENT ON TABLE wms.node_script IS 'Python Script: code kept in the jobspace, run inside the app sandbox';

-- Normalize Data: output field ← JSON path in the input.
CREATE TABLE wms.node_transform_mapping (
    jobspace_id uuid NOT NULL,
    node_id     uuid NOT NULL,
    kind        text NOT NULL DEFAULT 'dataNormalize' CHECK (kind = 'dataNormalize'),
    ordinal     smallint NOT NULL,
    item_id     uuid NOT NULL DEFAULT gen_random_uuid(),
    target      text NOT NULL,      -- named data point (the KeyValue key)
    source_path text NOT NULL DEFAULT '',   -- the KeyValue value
    PRIMARY KEY (jobspace_id, node_id, ordinal),
    FOREIGN KEY (jobspace_id, node_id, kind) REFERENCES wms.job_node (jobspace_id, node_id, kind)
        ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE wms.node_transform_mapping IS 'Normalize Data: maps raw response fields to named data points';
