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
| **3 · Data Reads** — API calls against configured subscriptions, with keys when needed | bottom (teal) | API Data Read, Normalize Data |

Each node stays in its own lane. Links pointing down the layers are calls; links pointing up (dashed) carry
results back.

## Window

| Part | What it does |
| ---- | ------------ |
| **Palette** (left) | Node kinds grouped by layer. Drag one onto the canvas, or double-click it to add it at the end of its lane. |
| **Canvas** | Drag nodes to move them (10-point grid). Drag a node's ● handle onto another node to link them. Click to select, ⇧-click to add, drag on empty space to rubber-band select. Click a link to select it. Delete removes the selection, arrow keys nudge (⇧ = 100 pt), ⌘D duplicates, Escape deselects. Pinch, ⌘+ / ⌘− / ⌘0 or the toolbar zoom. |
| **Inspector** (right, ⌥⌘I) | Properties of the selection. **Node**: title, notes, enabled; the kind's own settings (schedule, agent / assembly instructions and inputs, approver and expiry, execution target and mode, report recipients, API call, field mappings); **Arguments** (usable as `{{name}}`, plus `{{today}}` / `{{yesterday}}`); **Expected Outcome** (output name, success HTTP status, required JSON fields); **Exception Handling** (retry / skip / fallback / ask the user / abort, retries, backoff, timeout, notify). **Link**: its label. **Nothing selected**: the jobspace name, description, layer counts, subscriptions and checks. |
| **API Subscriptions** (⌥⌘K) | Layer 3 configuration dialog: name, provider, base URL, plan, rate limit, docs link, how the key is sent (query parameter, header, bearer, none), headers sent with every call, notes, and the **API key**. |
| **Problems** (⇧⌘K) | Checks: an execution without a User Approval upstream, API reads without a subscription, path or stored key, required arguments without a value, unlinked nodes, links that skip the agent layer, invalid base URLs. Click a problem to jump to it. |

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
