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

**File ▸ Export Diagram as PNG…** saves the whole diagram as an image.

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
