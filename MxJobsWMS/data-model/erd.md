# MxJobsWMS — Entity Relationship Diagram (schema `wms`)

MxJobsWMS keeps each workflow as a `*.jobspace` JSON document today. Schema `wms` ([`ddl/install.sql`](ddl/install.sql))
is the relational form of that document — every field of the format maps to a column, and
`wms.import_jobspace` / `wms.export_jobspace` round-trip the sample files unchanged — plus the run history
the run bar produces and the Layer 3 service catalog the app shows. 30 tables.

Crow's-foot notation: `||` exactly one, `o|` zero or one, `|{` one or more, `o{` zero or more.

## 1. Overview

```mermaid
erDiagram
    SAMPLE |o--o{ JOBSPACE : "is copied into"
    JOBSPACE ||--o{ API_SUBSCRIPTION : configures
    JOBSPACE ||--o{ JOB_NODE : contains
    JOBSPACE ||--o{ JOB_LINK : contains
    JOB_NODE ||--o{ JOB_LINK : "starts"
    JOB_NODE ||--o{ JOB_LINK : "ends"
    NODE_KIND ||--o{ JOB_NODE : types
    LAYER ||--o{ NODE_KIND : "holds"
    JOB_NODE ||--o| NODE_SETTINGS : "is configured by"
    API_SUBSCRIPTION |o--o{ NODE_SETTINGS : "is called by"
    LAYER3_SERVICE |o--o{ API_SUBSCRIPTION : "is reached through"
    LAYER3_SERVICE ||--o{ SERVICE_ENDPOINT : exposes
    SAMPLE ||--o{ SAMPLE_SERVICE : needs
    LAYER3_SERVICE ||--o{ SAMPLE_SERVICE : "is needed by"
    JOBSPACE ||--o{ JOB_RUN : "is run as"
    JOB_RUN ||--o{ NODE_RUN : "runs steps"
    JOB_RUN ||--o{ RUN_LOG : logs
    JOB_RUN ||--o{ RUN_PROMPT : asks
    JOB_NODE |o--o{ NODE_RUN : "ran as"
```

`NODE_SETTINGS` stands for the eight kind-specific settings tables (diagram 3).

## 2. Jobspace, subscriptions, steps and links

```mermaid
erDiagram
    JOBSPACE {
        uuid jobspace_id PK
        text name
        text description
        int format_version
        text sample_id FK
        text file_path
        text run_operations "interactive | autoApprove | skip"
        text run_agents "run | skip"
        text run_data "live | mock | skip"
        boolean breakpoints_enabled
        boolean stop_on_error
        float step_delay
    }
    API_SUBSCRIPTION {
        uuid jobspace_id PK, FK
        uuid subscription_id PK
        smallint ordinal
        text name
        text provider
        text base_url
        text auth "none | queryParameter | header | bearer | localService"
        text key_name
        int rate_limit_per_minute
        text project_folder
        text ide
        text service_id FK
        text keychain_account "generated: subscription-UUID"
    }
    SUBSCRIPTION_HEADER {
        uuid jobspace_id PK, FK
        uuid subscription_id PK, FK
        smallint ordinal PK
        text key
        text value
    }
    JOB_NODE {
        uuid jobspace_id PK, FK
        uuid node_id PK
        text kind FK
        smallint layer FK "fixed by kind"
        text title
        float x
        float y
        boolean enabled
        boolean breakpoint
        text success_status "expected outcome"
        text output_name
        text on_failure "retry | skip | useFallback | escalateToUser | abortRun"
        smallint max_retries
        int timeout_seconds
    }
    NODE_ARGUMENT {
        uuid jobspace_id PK, FK
        uuid node_id PK, FK
        smallint ordinal PK
        text name
        text type "text | number | date | symbols | boolean"
        text value
        boolean required
    }
    NODE_REQUIRED_FIELD {
        uuid jobspace_id PK, FK
        uuid node_id PK, FK
        smallint ordinal PK
        text field_path
    }
    NODE_ASSERTION {
        uuid jobspace_id PK, FK
        uuid node_id PK, FK
        smallint ordinal PK
        text path
        text op "== != < <= > >= contains exists"
        text value
    }
    JOB_LINK {
        uuid jobspace_id PK, FK
        uuid link_id PK
        uuid from_node_id FK
        uuid to_node_id FK
        text label
    }
    NODE_KIND {
        text kind PK
        smallint layer FK
        text spec "its settings table"
    }
    LAYER {
        smallint layer PK "1 Operations, 2 Agents, 3 Data"
        text title
    }

    JOBSPACE ||--o{ API_SUBSCRIPTION : configures
    API_SUBSCRIPTION ||--o{ SUBSCRIPTION_HEADER : sends
    JOBSPACE ||--o{ JOB_NODE : contains
    LAYER ||--o{ NODE_KIND : holds
    NODE_KIND ||--o{ JOB_NODE : types
    JOB_NODE ||--o{ NODE_ARGUMENT : takes
    JOB_NODE ||--o{ NODE_REQUIRED_FIELD : expects
    JOB_NODE ||--o{ NODE_ASSERTION : checks
    JOBSPACE ||--o{ JOB_LINK : contains
    JOB_NODE ||--o{ JOB_LINK : "from"
    JOB_NODE ||--o{ JOB_LINK : "to"
```

## 3. Kind-specific step settings (subtypes of `JOB_NODE`)

Each settings row repeats the step's `kind`, and its foreign key is `(jobspace_id, node_id, kind)` with a `CHECK` on
`kind`, so a step can only carry the settings of its own kind.

```mermaid
erDiagram
    JOB_NODE {
        uuid jobspace_id PK
        uuid node_id PK
        text kind
    }
    NODE_SCHEDULE {
        uuid node_id PK, FK "kind = trigger"
        text mode "manual | daily | weekdays | interval"
        text run_time
        text time_zone
        int interval_minutes
    }
    NODE_AGENT {
        uuid node_id PK, FK "instructionSet, agentTask, aggregate, decision"
        text instructions
        text model
        text output_format
    }
    NODE_AGENT_INPUT {
        uuid node_id PK, FK
        smallint ordinal PK "priority order"
        text input_name
    }
    NODE_APPROVAL {
        uuid node_id PK, FK "kind = approvalGate"
        text approver
        text channel "inApp | email | message"
        int expires_after_minutes
        boolean require_comment
    }
    NODE_EXECUTION {
        uuid node_id PK, FK "kind = executeRequest"
        text target
        text mode "dryRun | paper | live"
        boolean confirm_before_send
    }
    NODE_REPORT {
        uuid node_id PK, FK "kind = outcomeReport"
        text recipients
        boolean detailed
    }
    NODE_API_CALL {
        uuid node_id PK, FK "kind = apiRead"
        uuid subscription_id FK
        text method "GET | POST"
        text path
        text body
    }
    NODE_API_PARAM {
        uuid node_id PK, FK
        text location PK "query | header"
        smallint ordinal PK
        text key
        text value
    }
    NODE_SCRIPT {
        uuid node_id PK, FK "kind = pythonScript"
        text code
        text interpreter
        uuid subscription_id FK
    }
    NODE_TRANSFORM_MAPPING {
        uuid node_id PK, FK "kind = dataNormalize"
        smallint ordinal PK
        text target
        text source_path
    }
    API_SUBSCRIPTION {
        uuid subscription_id PK
    }

    JOB_NODE ||--o| NODE_SCHEDULE : "trigger"
    JOB_NODE ||--o| NODE_AGENT : "agent steps"
    NODE_AGENT ||--o{ NODE_AGENT_INPUT : reads
    JOB_NODE ||--o| NODE_APPROVAL : "approval"
    JOB_NODE ||--o| NODE_EXECUTION : "execution"
    JOB_NODE ||--o| NODE_REPORT : "report"
    JOB_NODE ||--o| NODE_API_CALL : "API read"
    NODE_API_CALL ||--o{ NODE_API_PARAM : sends
    JOB_NODE ||--o| NODE_SCRIPT : "Python"
    JOB_NODE ||--o{ NODE_TRANSFORM_MAPPING : "normalize"
    API_SUBSCRIPTION |o--o{ NODE_API_CALL : "is called by"
    API_SUBSCRIPTION |o--o{ NODE_SCRIPT : "keys"
```

(All settings and list tables also carry `jobspace_id` as the first key column; it is left out above for space.)

## 4. Layer 3 services, samples and run history

```mermaid
erDiagram
    LAYER3_SERVICE {
        text service_id PK "srm-loader, analytics, accounts, portfolio-java, portfolio-cpp, market-sample"
        text name
        text language "Python | Java | C++"
        int port UK "127.0.0.1"
        text purpose
        text folder
    }
    SERVICE_USE_CASE {
        text use_case PK "data-refresh, active, passive, risk, ..."
        text title
        text when_to_use
    }
    LAYER3_SERVICE_USE {
        text service_id PK, FK
        text use_case PK, FK
    }
    SERVICE_ENDPOINT {
        text service_id PK, FK
        text method PK
        text path PK
        text summary
        text contract "mxjobs.risk/1"
    }
    SAMPLE {
        text sample_id PK
        text title
        text area "Data | Active | Passive | Analytics | Templates"
        text file_name UK
        boolean takes_portfolio
    }
    SAMPLE_SERVICE {
        text sample_id PK, FK
        text service_id PK, FK
    }
    JOBSPACE {
        uuid jobspace_id PK
        text sample_id FK
    }
    JOB_RUN {
        bigint run_id PK
        uuid jobspace_id FK
        timestamptz started_at
        timestamptz finished_at
        text phase "running | paused | waiting | finished | failed | stopped"
        text trigger_source "manual | step | schedule | url"
        text run_data "layer settings used"
        text portfolio_code "srm.portfolio.code"
        text benchmark_code "srm.benchmark.code"
        jsonb summary
    }
    NODE_RUN {
        bigint node_run_id PK
        bigint run_id FK
        uuid node_id FK "SET NULL if the step is deleted"
        text node_title
        text state "pending ... succeeded | warning | failed | skipped"
        smallint attempts
        smallint http_status
        jsonb output
        text_array failed_checks
    }
    RUN_LOG {
        bigint log_id PK
        bigint run_id FK
        uuid node_id FK
        text level "debug | info | success | warning | error"
        text message
    }
    RUN_PROMPT {
        bigint prompt_id PK
        bigint run_id FK
        uuid node_id FK
        text prompt_type "approval | confirmSend | exception | runScripts"
        text_array options
        text answer
        text answered_by
        timestamptz answered_at
    }

    LAYER3_SERVICE ||--o{ LAYER3_SERVICE_USE : "serves"
    SERVICE_USE_CASE ||--o{ LAYER3_SERVICE_USE : "is served by"
    LAYER3_SERVICE ||--o{ SERVICE_ENDPOINT : exposes
    SAMPLE ||--o{ SAMPLE_SERVICE : needs
    LAYER3_SERVICE ||--o{ SAMPLE_SERVICE : "is needed by"
    SAMPLE |o--o{ JOBSPACE : "is copied into"
    JOBSPACE ||--o{ JOB_RUN : "is run as"
    JOB_RUN ||--o{ NODE_RUN : "runs steps"
    JOB_RUN ||--o{ RUN_LOG : logs
    JOB_RUN ||--o{ RUN_PROMPT : asks
```

## Cross-application references


| From                                            | To                                                    | How                                                                          |
| ------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `wms.job_run.portfolio_code` / `benchmark_code` | MxDataHUB `srm.portfolio.code` / `srm.benchmark.code` | by code, as passed in `mxjobswms://sample/<id>?portfolio=&benchmark=`        |
| `wms.api_subscription.keychain_account`         | login Keychain, service `com.k3jdr.MxJobsWMS`         | API keys are never stored in the database                                    |
| `wms.layer3_service`                            | `MXcodeIDE/Services/<folder>`                         | the service code; MxPortMGR's `pmg.engine_run.service_id` names the same ids |
