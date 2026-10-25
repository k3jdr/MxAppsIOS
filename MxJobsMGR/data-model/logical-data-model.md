# MxJobsMGR — Logical Data Model

**Scope.** The workflows MxJobsMGR designs and runs: a **jobspace** is a three-layer diagram of steps (Business
Operations, Agentic Operations, Data Reads) joined by links, with the API subscriptions its data reads use, run
settings, and — once run — a history of runs, step results, console log and the questions it asked. Also the
catalog both MxJobsMGR and MxDataHUB show: the Layer 3 services in `MxAppsIOS/Services` and the sample workflows.

Today a jobspace is a JSON file (`format: "mxjobspace"`, `formatVersion: 1`) and runs live in memory. This model
is the relational form of both: every field of the file format has a column (see §6), and
`wms.import_jobspace` / `wms.export_jobspace` reproduce the sample files exactly. Physical form:
[`ddl/`](ddl/README.md); diagrams: [erd.md](erd.md).

## 1. Conventions

| Topic | Rule |
|---|---|
| Identity | A jobspace has a surrogate `jobspace_id` (the file has none). Steps, links and subscriptions keep their document UUIDs, which are unique **only within a document** (Save As and New from Sample copy them), so they are keyed `(jobspace_id, id)`. List items (arguments, checks, headers, mappings) are keyed by parent + `ordinal`; their document ids are kept as `item_id`. |
| Order | `ordinal` = position in the document's array, so a document exports in its own order. Unique per parent, deferrable (reordering in one transaction). |
| Same-document integrity | Composite foreign keys `(jobspace_id, node_id)` / `(jobspace_id, subscription_id)` make it impossible for a link, a settings row or an API call to point into another jobspace. |
| Kind subtypes | A step's kind fixes its layer (`(kind, layer)` → Node Kind) and the one settings table it may use (§3.3). |
| Secrets | API keys are never stored: they live in the login Keychain under `com.k3jdr.MxJobsMGR` / `subscription-<UUID>`; the model keeps only that account name (generated column). |
| Defaults | Every column defaults to the app's own default, so a document missing keys (older versions) imports as the app would open it. |
| Codes | Small closed enumerations are `CHECK`-constrained text with the app's raw values (`autoApprove`, `escalateToUser`, …); lists that carry descriptions are tables (Layer, Node Kind, Service Use Case). |

## 2. Subject areas

| Area | Entities |
|---|---|
| A. Catalog | Layer, Node Kind, Service Use Case, Layer 3 Service, Service Endpoint, Sample, Sample Service |
| B. Jobspace design | Jobspace, API Subscription, Subscription Header, Job Node, Node Argument, Node Required Field, Node Assertion, Job Link |
| C. Step settings | Node Schedule, Node Agent (+ Agent Input), Node Approval, Node Execution, Node Report, Node API Call (+ API Param), Node Script, Node Transform Mapping |
| D. Run history | Job Run, Node Run, Run Log, Run Prompt |

## 3. Entities

### 3.1 Catalog

**Layer** — a swim lane: 1 Business Operations (user-facing refresh, approvals, execution), 2 Agentic Operations
(agents preparing data points), 3 Data Reads (API calls, Python, normalization). Links down the layers are calls;
links up carry results back.

**Node Kind** — the eleven step kinds, each in one layer and with one settings type:

| Layer | Kind | Settings |
|---|---|---|
| 1 | trigger (Refresh Trigger) | Schedule |
| 1 | instructionSet (Assemble Instructions) | Agent |
| 1 | approvalGate (User Approval) | Approval |
| 1 | executeRequest (Execution Request) | Execution |
| 1 | outcomeReport (Outcome Report) | Report |
| 2 | agentTask, aggregate, decision | Agent |
| 3 | apiRead (API Data Read) | API Call |
| 3 | pythonScript (Python Script) | Script |
| 3 | dataNormalize (Normalize Data) | Transform |

**Layer 3 Service** — a local HTTP service on 127.0.0.1: id (`srm-loader`, `analytics`, `accounts`, `portfolio-java`,
`portfolio-cpp`, `market-sample`), name, language and why, port (unique), purpose, project folder, IDE to develop in.
Has many **Service Endpoints** (method + path, summary, versioned contract such as `mxjobs.risk/1`) and serves
**Service Use Cases** (data-refresh, data-quality, active, passive, attribution, risk, absolute, templates, testing).

**Sample** — a sample workflow (`srm-daily-refresh`, `active-optimization`, `passive-tracking`, `attribution`,
`market-refresh`): title, area, summary, file, whether it takes a portfolio from MxDataHUB. **Sample Service** lists
the services it needs on Live.

### 3.2 Jobspace design

**Jobspace** — a workflow document. Attributes: name (non-blank), description, format version, the sample it came
from, file path; run settings — Layer 1 `interactive | autoApprove | skip`, Layer 2 `run | skip`, Layer 3
`live | mock | skip`, breakpoints enabled, stop on error, delay between steps. Owns everything in this area (cascade).

**API Subscription** — a data provider or local service the jobspace calls: name, provider, base URL, how the key is
sent (`none`, `queryParameter`, `header`, `bearer`, `localService`), key name, rate limit / minute, plan, docs URL,
notes, project folder and IDE for Open Project, the Layer 3 Service it reaches (matched by port), Keychain account.
Has ordered **Subscription Headers** sent with every call.

**Job Node** (step) — kind, layer, title, notes, canvas position (x, y; 10-pt grid), enabled, breakpoint.
*Expected outcome* (1:1, as columns): description, success HTTP status (`200-299` or a code), output name (used by
later steps as `{{in:name.path}}`), plus ordered **Required Fields** and **Assertions** (`path op value`, op in
`== != < <= > >= contains exists`, value may use `{{argument}}`).
*Exception handling* (1:1, as columns): on failure (`retry`, `skip`, `useFallback`, `escalateToUser`, `abortRun`),
retries, delay, exponential backoff, timeout, fallback value, notify user.
Has ordered **Node Arguments** (name, type `text | number | date | symbols | boolean`, value, required).

**Job Link** — a directed link between two steps of the same jobspace (no self-links, one link per ordered pair),
with a label (often the output name it carries). Direction is derived: *call* (down), *result* (up), *sequence*
(same layer) — `v_job_link`.

### 3.3 Step settings (subtypes)

Each is 0..1 per step and allowed only for its kinds (enforced by `kind` in the key plus a `CHECK`).

| Entity | For kinds | Attributes |
|---|---|---|
| Node Schedule | trigger | mode (`manual`, `daily`, `weekdays`, `interval`), time `HH:MM`, time zone, interval minutes |
| Node Agent | instructionSet, agentTask, aggregate, decision | instructions, model, output format; ordered **Agent Inputs** (output names in priority order — a Decision follows the most confident decisionContext, listed inputs first) |
| Node Approval | approvalGate | approver, channel (`inApp`, `email`, `message`), expires after minutes, require comment, summary template |
| Node Execution | executeRequest | target, mode (`dryRun`, `paper`, `live`), confirm before send |
| Node Report | outcomeReport | recipients, detailed, include failures |
| Node API Call | apiRead | subscription (0..1, same jobspace; set null if removed), method (`GET`, `POST`), path, body; ordered **API Params** (location `query` / `header`, key, value). Path, params and body may use `{{argument}}`, `{{in:name.path}}`, `{{json:name.path}}` |
| Node Script | pythonScript | code (stdin JSON in, stdout JSON out), interpreter, optional subscription (gives `MXJOBS_API_KEY`, `MXJOBS_BASE_URL`) |
| Node Transform Mapping | dataNormalize | ordered (target data point ← source JSON path) |

### 3.4 Run history

**Job Run** — one run of a jobspace: start / finish, phase (`running`, `paused`, `waiting`, `finished`, `failed`,
`stopped`), who started it and how (`manual`, `step`, `schedule`, `url`), the layer settings it used (copied), the
MxDataHUB portfolio / benchmark codes it was opened for, and the Outcome Report summary (JSON).

**Node Run** — how one step did in a run: state (`pending`, `paused`, `running`, `waiting`, `succeeded`, `warning`,
`failed`, `skipped`), attempts, times, HTTP status, output (JSON), failed checks, error. Keeps the step title so
history survives the step being deleted (node reference set null). One per step per run.

**Run Log** — the console: time, level (`debug`, `info`, `success`, `warning`, `error`), step, message.

**Run Prompt** — a question the run asked: type (`approval`, `confirmSend`, `exception`, `runScripts`), title,
message, detail, options, when asked / expires, the answer (one of the options), who answered and when, comment.

## 4. Relationships (cardinality)

| Parent | Child | Cardinality | Delete rule |
|---|---|---|---|
| Sample | Jobspace | 0..1 : 0..n | set null |
| Jobspace | API Subscription, Job Node, Job Link, Job Run | 1 : 0..n | cascade |
| API Subscription | Subscription Header | 1 : 0..n | cascade |
| Layer 3 Service | API Subscription | 0..1 : 0..n | set null |
| Layer | Node Kind | 1 : 1..n | restrict |
| Node Kind | Job Node | 1 : 0..n | restrict |
| Job Node | Argument, Required Field, Assertion | 1 : 0..n | cascade |
| Job Node | each settings subtype | 1 : 0..1 | cascade |
| Job Node | Job Link (from), Job Link (to) | 1 : 0..n | cascade |
| API Subscription | Node API Call, Node Script | 0..1 : 0..n | set null (subscription only) |
| Node Agent / Node API Call | Agent Input / API Param | 1 : 0..n | cascade |
| Layer 3 Service | Service Endpoint, Service Use | 1 : 0..n | cascade |
| Sample × Layer 3 Service | Sample Service | n : m | cascade from sample |
| Job Run | Node Run, Run Log, Run Prompt | 1 : 0..n | cascade |
| Job Node | Node Run, Run Log, Run Prompt | 0..1 : 0..n | set null (node only) |

## 5. Business rules (the Problems panel, `v_jobspace_problem`)

| Severity | Rule |
|---|---|
| error | An Execution Request needs a User Approval somewhere upstream (recursive over links). |
| error | An API Data Read needs a subscription; a Python Script needs code; a subscription needs a valid base URL. |
| warning | A step with no links (when the jobspace has more than one step); a required argument without a value; an API read without a path; a link that skips the agent layer (Layer 1 ↔ 3). |
| info | An execution in `live` mode; an approval without a named approver. |
| app only | Key stored in the Keychain; a Python interpreter found — these depend on the Mac, not the data. |

## 6. Mapping to the `.jobspace` file

| JSON | Table.column |
|---|---|
| `name`, `description`, `formatVersion` | `jobspace` |
| `run.{operations, agents, data, breakpointsEnabled, stopOnError, stepDelay}` | `jobspace.run_*`, `breakpoints_enabled`, `stop_on_error`, `step_delay` |
| `subscriptions[]` (+ `defaultHeaders[]`) | `api_subscription` (+ `subscription_header`) |
| `nodes[].{id, kind, title, notes, x, y, enabled, breakpoint}` | `job_node` |
| `nodes[].arguments[]` | `node_argument` |
| `nodes[].outcome.{description, successStatus, outputName}` / `requiredFields[]` / `assertions[]` | `job_node.outcome_description, success_status, output_name` / `node_required_field` / `node_assertion` |
| `nodes[].exceptions.*` | `job_node.on_failure … notify_user` |
| `nodes[].schedule` · `agent` (+`inputs`) · `approval` · `execution` · `report` | `node_schedule` · `node_agent` (+`node_agent_input`) · `node_approval` · `node_execution` · `node_report` |
| `nodes[].api` (+ `query[]`, `headers[]`) · `script` · `transform.mappings[]` | `node_api_call` (+ `node_api_param`) · `node_script` · `node_transform_mapping` |
| `links[]` | `job_link` |
