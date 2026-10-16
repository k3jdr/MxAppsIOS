# MxJobsWMS

A multi-document macOS app (SwiftUI) for designing the day-to-day **financial market data gathering
operation** as a three-layer diagram, saved as JSON **jobspace** files (`*.jobspace`).

Open `MxJobsWMS.xcodeproj` in Xcode, then Run. There are no package dependencies.
**File ▸ New Sample Jobspace** (⌥⌘N) opens a worked example; the same example is in
`Samples/DailyMarketRefresh.jobspace`.

## The three layers

| Layer | Lane | Node kinds |
| ----- | ---- | ---------- |
| **1 · Business Operations** — the user-facing refresh that assembles instructions for approval and triggers execution | top (indigo) | Refresh Trigger, Assemble Instructions, User Approval, Execution Request, Outcome Report |
| **2 · Agentic Operations** — agents that call the Layer 3 services and prepare the data points for Layer 1 | middle (orange) | Agent Task, Aggregate Results, Decision |
| **3 · Data Reads** — API calls against configured subscriptions, with keys when needed, and Python | bottom (teal) | API Data Read, Python Script, Normalize Data |

Each node stays in its own lane. Links pointing down the layers are calls; links pointing up (dashed) carry
results back.

## Window

| Part | What it does |
| ---- | ------------ |
| **Palette** (left) | Node kinds grouped by layer. Drag one onto the canvas, or double-click it to add it at the end of its lane. |
| **Canvas** | Drag nodes to move them (10-point grid). Drag a node's ● handle onto another node to link them. Click to select, ⇧-click to add, drag on empty space to rubber-band select. Click a link to select it. Delete removes the selection, arrow keys nudge (⇧ = 100 pt), ⌘D duplicates, Escape deselects. Pinch, ⌘+ / ⌘− / ⌘0 or the toolbar zoom. |
| **Inspector** (right, ⌥⌘I) | Properties of the selection. **Node**: title, notes, enabled; the kind's own settings (schedule, agent / assembly instructions and inputs, approver and expiry, execution target and mode, report recipients, API call, field mappings); **Arguments** (usable as `{{name}}`, plus `{{today}}` / `{{yesterday}}`); **Expected Outcome** (output name, success HTTP status, required JSON fields, value checks); **Exception Handling** (retry / skip / fallback / ask the user / abort, retries, backoff, timeout, notify). **Link**: its label. **Nothing selected**: the jobspace name, description, layer counts, subscriptions and checks. |
| **API Subscriptions** (⌥⌘K) | Layer 3 configuration dialog: name, provider, base URL, plan, rate limit, docs link, how the key is sent (query parameter, header, bearer, local service with optional token, none), headers sent with every call, notes, the **API key**, and an optional **Source Project** folder and IDE for **Open Project**. **+** adds a subscription or a **Local Python Service** preset. |
| **Problems** (⇧⌘K) | Checks: an execution without a User Approval upstream, API reads without a subscription, path or stored key, required arguments without a value, unlinked nodes, links that skip the agent layer, invalid base URLs. Click a problem to jump to it. |

**Adding a key:** in API Subscriptions select the subscription, paste the key under **API Key**, press **Save Key** —
MxJobsWMS then runs **Test Key** (one call to the provider). **?** next to API Key shows that provider's steps (Alpha
Vantage, Finnhub, SEC EDGAR, Frankfurter, local services, others), **Get a Key…** opens its sign-up page, and
**Help ▸ Adding API Keys** has the whole guide. A key belongs to the subscription of the jobspace it was saved in
(Save As keeps it). Alpha Vantage does not reject unknown keys, so for it Test Key confirms that calls work rather
than that the key is yours; it does report its rate-limit notices.

**Test Call** (inspector of an API Data Read) sends the request once with the stored key and shows the status,
time, the checks of the expected outcome, and the response (the key is masked in the URL shown).

**Save the diagram** — right-click anywhere in the swim-lane editor, or use **File ▸ Export Diagram as…**:

- **Save as PNG…** — the whole diagram as a 2× image.
- **Save as draw.io SVG…** (`*.drawio.svg`) — an SVG that any browser or viewer displays, carrying the diagram as
  draw.io XML, so draw.io / diagrams.net opens it for editing: each layer becomes a swimlane holding its nodes,
  and links become connectors (results going up a layer are dashed).

## Run and debug

The **run bar** above the canvas runs the jobspace across its three layers:

| Control | What it does |
| ------- | ------------ |
| ▶ **Run** (⌘R) / **Continue** (⌃⌘Y) | Starts a run, or continues a paused one. |
| ⏸ **Pause** | Pauses before the next step. |
| ↳ **Step** (F6) | Runs to the next step and pauses before it (starts a run when idle). |
| ■ **Stop** (⌘.) | Stops the run. |
| **L1 / L2 / L3** menus | What the run does with each layer, saved in the jobspace: **Layer 1** Interactive (asks for approvals and send confirmations) / Auto-approve (rehearsal) / Skip; **Layer 2** Run (agents simulated, passing on their inputs) / Skip; **Layer 3** Live API calls / Mock data (no network) / Skip. A skipped step passes its inputs straight through. |
| ▸ **Breakpoints** (⌘Y) | Turns breakpoints on or off. Toggle one on the selected step with ⌘\, the step's right-click menu or the inspector; it shows as a blue tag. |
| ⚙ **Options** | Stop the run when a step fails, the delay between steps (to follow the flow on the canvas), Clear Run Results. |
| Status, console toggle (⇧⌘Y) | What the run is doing now; shows or hides the run console. |

**Order.** A step waits for the steps feeding it along its own layer or from below, performs its action, then runs
the steps it calls down the layers. Layer 2 agents act after their calls return, so they see what the Layer 3 reads
brought back. Steps show their state on the canvas (running, paused, waiting, succeeded, warning, failed, skipped).

**Exception handling** of each step applies: retries with delay and optional exponential backoff, skip, fallback value,
ask the user (Retry / Skip / Abort), or abort the run. A step after a failed, rejected or cancelled step is skipped.

**User Approval** pauses the run on a prompt (Approve / Reject) showing the instructions; **Execution Request** asks
to confirm when set to, and does **not send anything yet** — it reports what it would send (target, mode, request).
The **Outcome Report** sums up the run.

The **run console** shows the log (filter by level, click a line to select its step) and the output of the selected
step as JSON; the inspector's **Last Run** section shows a step's result.

## Python at Layer 3

Python automation belongs in **Layer 3 (Data Reads)** when it fetches or computes data the same way every time
(quotes, files, indicators, risk numbers); Python that decides belongs to a Layer 2 agent. Two ways in:

**1. A local Python service (recommended).** Run Python as a small HTTP service on this Mac and call it with
ordinary API Data Read steps. In API Subscriptions choose **+ ▸ Local Python Service**: base URL
`http://127.0.0.1:8765`, authentication **Local service (optional token)** — a token is sent as
`Authorization: Bearer …` only when one is stored. `Samples/python-service/mxjobs_service.py` is a
standard-library example with `/quote`, `/history` and `/indicators`; start it with
`python3 Samples/python-service/mxjobs_service.py`. The service runs outside the app's sandbox, so it can use
any packages, files and credentials you give it.

**2. A Python Script step** (palette ▸ Layer 3 ▸ Python Script) runs code kept in the jobspace:

- **stdin**: `{"arguments": {name: value}, "inputs": {output name: value}, "step": title}` — the step's arguments
  and the outputs of the steps linked into it.
- **stdout**: the step's output, as JSON. The expected outcome then applies (exit code 0, JSON output, required
  fields), and so does the step's exception handling (retry, skip, fallback, ask, abort) and timeout.
- **env**: `MXJOBS_API_KEY` and `MXJOBS_BASE_URL` from the step's optional subscription (the key also under the
  subscription's key name when that is an environment-variable name such as `FINNHUB_TOKEN`).
- **Interpreter**: the step's own path, else the first of Homebrew, python.org and Apple's (developer tools).
  `/usr/bin/python3` is mapped to the developer tools' real binary — its `xcrun` shim can't run in a sandbox.
- **Run Script** in the inspector runs it once with the inputs of the last run.
- Layer 3 **Mock** returns mock data without running Python; **Live** runs it. A run asks once
  **Run Python scripts?** (showing the code) before the first script, because a jobspace file can carry code.
- Scripts run **inside the app's sandbox**: network (local service and internet) and the app's own container
  only — not your files, `/tmp`, or interpreters and `pip --user` packages under your home folder. Install
  packages into the interpreter itself (e.g. Homebrew's `pip3 install`), or use a local service.

## Java and C/C++ at Layer 3

Portfolio optimization and risk run as **Layer 3 compute services** (see [Modules/](Modules/)); their outcomes give
the **Layer 2 decision agent** its context for the next step:

- `Modules/portfolio-java` — Java optimizer on 127.0.0.1:8766 (`POST /optimize`).
- `Modules/portfolio-cpp` — C++ optimizer and risk engine on 127.0.0.1:8767 (`POST /optimize`, `POST /risk`).
- `Modules/contracts` — the versioned JSON Schemas (`mxjobs.optimization/1`, `mxjobs.risk/1`), the shared algorithm
  and decision rules, and `check_engines.py`, which checks running services against the schemas and each other.

Each outcome carries a `decisionContext` — `recommendation` (rebalance, rebalance_partially, hold, rerun_relaxed,
escalate), `confidence`, `alternatives`, `reason`. A **Decision** step follows the most confident decisionContext
among its inputs (`nextStep`), and escalates when there is none. The sample's **Choose next step** calls
**Optimize portfolio (Java)** and **Portfolio risk (C++)** and passes `nextStep` up to Assemble Instructions.

**Value checks.** Expected Outcome takes value checks besides required fields — `path op value` with `==`, `!=`,
`<`, `<=`, `>`, `>=`, `contains`, `exists`, compared as numbers when both sides are numbers; values may use
`{{argument}}` (e.g. `valueAtRisk < {{maxVaR}}`). They apply to live runs, Test Call and Python steps; a failed check
reads e.g. “solverStatus == optimal (got infeasible)” and the step's exception handling takes over. Mock runs
generate values that pass them.

**Source projects.** A subscription can name the folder of the service's source and an IDE (VS Code, IntelliJ
IDEA, CLion, Xcode, Finder); its steps then show **Open Project in …**. VS Code and IntelliJ IDEA are opened through
their URL schemes, which works from the sandbox for any folder. CLion, Xcode and Finder have no such scheme, so the
sandbox can hand them only a folder you chose: pick it with **Choose…** in the subscription, or **Grant Access…** next
to the button, once — MxJobsWMS keeps a security-scoped bookmark for it.

## Samples

| File ▸ … | Jobspace | Service |
| -------- | -------- | ------- |
| **New Sample Jobspace** (⌥⌘N) | `Samples/DailyMarketRefresh.jobspace` — market data, Python, Java and C++ steps | `Samples/python-service`, `Modules/portfolio-*` |
| **New SRM Daily Refresh Sample** | `Samples/SRMDailyRefresh.jobspace` — MxDataSRM's daily securities-master refresh | `Samples/srm-service` |

### SRM daily refresh

MxDataSRM's daily automation (`MxDataSRM/SRM/srm.py load all`, then `srm.py status`) as a jobspace:

- **Layer 3**: the 12 SRM loaders as API Data Read steps (`POST /load/<loader>` on the **SRM loader service**,
  127.0.0.1:8770), left to right in srm.py's dependency order, and **SRM status & data quality** (`GET /status`).
  Each loader expects `status != failed`; its exception handling follows the source (retries for the free reference
  files, skip for optional enrichment, ask the user for constituents and prices). The status step expects
  `summary.failed == 0` and asks the data steward otherwise.
- **Layer 2**: Universe → Benchmark constituents → Identifier enrichment → Market data agents, chained so each stage
  waits for the one before, each calling its loaders; the **Data quality analyst** combines their results with the
  status checks into the daily report and follow-up list.
- **Layer 1**: weekday 18:30 New York trigger, the report and follow-ups, **Data steward approval**, **Run approved
  backfills** (long loads such as `fmp-corporate-actions --history`, dry run), and the outcome report.

Start the service with `python3 Samples/srm-service/srm_service.py`. The sample opens with Layer 3 on **Mock**.
On **Live**, the subscription's `X-SRM-Dry-Run: 1` header makes every loader report the `srm.py` command it would
run while the status step reads the real database; remove the header (API Subscriptions) to run the loads.
Open in IDE on the subscription opens `MxDataSRM/SRM`.

## Files and keys

- A jobspace is pretty-printed JSON (`format: "mxjobspace"`, `formatVersion: 1`) with `subscriptions`,
  `nodes` (position, kind, arguments, outcome, exceptions and kind-specific settings) and `links`.
  Missing keys fall back to defaults, so files from earlier versions keep opening. Plain `.json` files
  holding a jobspace open too.
- **API keys are never written to the jobspace.** They are kept in the login Keychain
  (service `com.k3jdr.MxJobsWMS`, account `subscription-<id>`), so a jobspace can be shared without its keys;
  on another Mac, enter the keys again under API Subscriptions.
- The app is sandboxed with outgoing network access and user-selected file access.

## Next

Filesystem, network device and remote data service interfaces, and running a jobspace end to end.
