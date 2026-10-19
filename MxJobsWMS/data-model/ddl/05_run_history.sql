-- MxJobsWMS · wms DDL package · 05 run history
--
-- What the run bar does (RunEngine.swift), kept: one job_run per Run, a node_run per step it
-- reached (state, attempts, output as JSON, failed checks), the console log, and every prompt a
-- run asked (approvals, send confirmations, ask-the-user exceptions) with its answer.
-- Steps can be deleted after a run, so node references are SET NULL and the title is copied;
-- jobspace_id on the step-level rows equals the run's (the composite key needs it).
-- portfolio_code / benchmark_code are the MxDataHUB codes a run was opened with
-- (mxjobswms://sample/<id>?portfolio=&benchmark=); they name srm.portfolio.code and
-- srm.benchmark.code but are not foreign keys, so wms installs without srm.

CREATE TABLE wms.job_run (
    run_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    jobspace_id    uuid NOT NULL REFERENCES wms.jobspace ON DELETE CASCADE,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    phase          text NOT NULL DEFAULT 'running'
                   CHECK (phase IN ('running', 'paused', 'waiting', 'finished', 'failed', 'stopped')),
    started_by     text NOT NULL DEFAULT current_user,
    trigger_source text NOT NULL DEFAULT 'manual' CHECK (trigger_source IN ('manual', 'step', 'schedule', 'url')),
    -- The layer settings the run used (copied from the jobspace when it started).
    run_operations text NOT NULL CHECK (run_operations IN ('interactive', 'autoApprove', 'skip')),
    run_agents     text NOT NULL CHECK (run_agents IN ('run', 'skip')),
    run_data       text NOT NULL CHECK (run_data IN ('live', 'mock', 'skip')),
    stop_on_error  boolean NOT NULL,
    portfolio_code text,
    benchmark_code text,
    summary        jsonb,            -- the Outcome Report: counts by state, failures
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX job_run_jobspace_idx ON wms.job_run (jobspace_id, started_at DESC);
COMMENT ON TABLE wms.job_run IS 'One run of a jobspace across its three layers';

CREATE TABLE wms.node_run (
    node_run_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        bigint NOT NULL REFERENCES wms.job_run ON DELETE CASCADE,
    jobspace_id   uuid NOT NULL,
    node_id       uuid,
    node_title    text NOT NULL,
    layer         smallint NOT NULL REFERENCES wms.layer,
    state         text NOT NULL DEFAULT 'pending'
                  CHECK (state IN ('pending', 'paused', 'running', 'waiting', 'succeeded', 'warning', 'failed', 'skipped')),
    attempts      smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    started_at    timestamptz,
    finished_at   timestamptz,
    http_status   smallint,
    output        jsonb,             -- the step's output (what {{in:name.path}} reads)
    failed_checks text[] NOT NULL DEFAULT '{}',   -- e.g. 'solverStatus == optimal (got infeasible)'
    error         text,
    CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.job_node ON DELETE SET NULL (node_id)
);
CREATE UNIQUE INDEX node_run_once_idx ON wms.node_run (run_id, node_id) WHERE node_id IS NOT NULL;
COMMENT ON TABLE wms.node_run IS 'How one step did in a run';

CREATE TABLE wms.run_log (
    log_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id    bigint NOT NULL REFERENCES wms.job_run ON DELETE CASCADE,
    logged_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    level     text NOT NULL CHECK (level IN ('debug', 'info', 'success', 'warning', 'error')),
    jobspace_id uuid NOT NULL,
    node_id   uuid,
    message   text NOT NULL,
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.job_node ON DELETE SET NULL (node_id)
);
CREATE INDEX run_log_run_idx ON wms.run_log (run_id, log_id);
COMMENT ON TABLE wms.run_log IS 'The run console';

CREATE TABLE wms.run_prompt (
    prompt_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id      bigint NOT NULL REFERENCES wms.job_run ON DELETE CASCADE,
    jobspace_id uuid NOT NULL,
    node_id     uuid,
    prompt_type text NOT NULL CHECK (prompt_type IN ('approval', 'confirmSend', 'exception', 'runScripts')),
    title       text NOT NULL,
    message     text NOT NULL DEFAULT '',
    detail      text NOT NULL DEFAULT '',
    options     text[] NOT NULL,           -- e.g. {Approve,Reject} or {Retry,Skip,Abort}
    asked_at    timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    answer      text,
    answered_at timestamptz,
    answered_by text,
    comment     text,
    CHECK (answer IS NULL OR answer = ANY (options)),
    CHECK ((answer IS NULL) = (answered_at IS NULL)),
    FOREIGN KEY (jobspace_id, node_id) REFERENCES wms.job_node ON DELETE SET NULL (node_id)
);
CREATE INDEX run_prompt_run_idx ON wms.run_prompt (run_id);
COMMENT ON TABLE wms.run_prompt IS 'A question a run asked the user (approval, send confirmation, exception) and the answer';
