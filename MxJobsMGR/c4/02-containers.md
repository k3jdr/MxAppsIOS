# 02 · Containers (C4 level 2)

```mermaid
C4Container
    title Containers — MxJobsMGR and what it runs with

    Person(user, "Portfolio manager / data steward / designer")

    System_Boundary(wmssys, "MxJobsMGR") {
        Container(app, "MxJobsMGR.app", "Swift, SwiftUI DocumentGroup", "Swim-lane editor, inspector, validation, run engine with debugger, API and Python runners, Layer 3 Services and sample windows. Sandboxed.")
        ContainerDb(doc, "Jobspace files", "*.jobspace, pretty-printed JSON", "format mxjobspace v1: subscriptions, nodes, links, run settings. No keys.")
        Container(pyproc, "Python Script process", "python3, inside the app sandbox", "One process per step run: JSON on stdin, JSON on stdout")
    }

    System_Boundary(l3, "Layer 3 services (shared with MxDataHUB)") {
        Container(loader, "srm-loader", "Python HTTP :8770", "/load/{loader}, /status — SRM Daily Refresh")
        Container(analytics, "analytics", "Python HTTP :8772", "/inputs (covariance, alpha), /inputs/{id}, /attribution")
        Container(java, "portfolio-java", "Java 17 HTTP :8766", "/optimize/active, /optimize")
        Container(cpp, "portfolio-cpp", "C++ HTTP :8767", "/optimize/tracking, /risk, /optimize")
        Container(sample, "market-sample", "Python HTTP :8765", "/quote, /history, /indicators")
    }

    System_Ext(providers, "Provider APIs", "Alpha Vantage, Finnhub, Frankfurter, SEC EDGAR")
    SystemDb_Ext(pg, "SRM database", "PostgreSQL schema srm")
    System_Ext(keychain, "Login Keychain", "subscription-<id> keys")
    System_Ext(hub, "MxDataHUB.app")

    Rel(user, app, "Uses")
    Rel(app, doc, "Opens, saves, exports", "FileDocument")
    Rel(app, keychain, "Keys", "Security framework")
    Rel(app, pyproc, "Runs", "Process, stdin and stdout")
    Rel(app, loader, "API Data Read", "HTTP JSON")
    Rel(app, analytics, "API Data Read", "HTTP JSON")
    Rel(app, java, "API Data Read", "HTTP JSON")
    Rel(app, cpp, "API Data Read", "HTTP JSON")
    Rel(app, sample, "API Data Read", "HTTP JSON")
    Rel(app, providers, "API Data Read, Test Key, Test Call", "HTTPS")
    Rel(java, analytics, "GET inputsUrl", "HTTP")
    Rel(cpp, analytics, "GET inputsUrl", "HTTP")
    Rel(analytics, pg, "Reads", "psycopg2")
    Rel(loader, pg, "srm.py loads", "psycopg2")
    Rel(hub, app, "mxjobsmgr://sample/...", "URL scheme")
    Rel(app, hub, "mxdatahub://...", "URL scheme")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="2")
```

## Containers

| Container | Technology | Responsibility | Owns |
|---|---|---|---|
| **MxJobsMGR.app** | Swift 5 mode, SwiftUI `DocumentGroup`, Observation; no third-party packages | Each window edits one jobspace: palette, swim-lane canvas, inspector, run bar and console; validation (*Problems*); runs and debugs; manages subscriptions and keys; exports PNG and draw.io SVG; Layer 3 Services, New from Sample and Adding API Keys windows. | Window and editor state; bookmarks for project folders (`UserDefaults`) |
| **Jobspace files** | JSON (`format: "mxjobspace"`, `formatVersion: 1`), UTType `com.k3jdr.mxjobsmgr.jobspace` | The workflow definition: subscriptions (without keys), nodes with kind-specific settings, links, run settings. Missing keys decode to defaults, so older files keep opening; plain `.json` files open too. | Everything except secrets and run results |
| **Python Script process** | `python3` from the step's path, else Homebrew, python.org or Apple's developer tools (mapped past the `xcrun` shim) | Runs a step's code: stdin `{"arguments","inputs","step"}`, stdout = the step's output (JSON); env `MXJOBS_API_KEY`, `MXJOBS_BASE_URL`. | Nothing; runs in the app's sandbox |
| **Layer 3 services** | Python, Java, C++ HTTP on 127.0.0.1 | Data reads and computations the steps call; each outcome includes a `decisionContext` (recommendation, confidence, alternatives, reason). | Their computations; large matrices stay inside (`inputsUrl`) |

## Interfaces

| From → to | Interface | Details |
|---|---|---|
| App ↔ jobspace file | `FileDocument` (`JobspaceDocument`) | Pretty-printed, sorted keys; reads `.jobspace` and `.json`, writes `.jobspace`. |
| App → services and providers | HTTP(S) via `URLSession` (`ApiTester`) | Method, base URL + path, query parameters, headers, JSON body; values may use `{{argument}}`, `{{today}}`, `{{yesterday}}`, `{{in:output.path}}`, `{{json:output.path}}`. Auth per subscription: none, query parameter, header, bearer, local service (bearer only when a token is stored). Checks: success status, required JSON fields, value checks (`path op value`). |
| Layer 3 contracts | JSON, versioned (`mxjobs.optimization/1`, `mxjobs.risk/1`, `mxjobs.inputs/1`, `mxjobs.active-optimization/1`, `mxjobs.tracking/1`, `mxjobs.attribution/1`) | Defined in `Services/contracts`; a breaking change gets `/2` served alongside `/1`. |
| App → Python | `Process` | JSON on stdin and stdout; exit code 0 expected; timeout and exception policy of the step apply. |
| App → Keychain | Security framework | Service `com.k3jdr.MxJobsMGR`, account `subscription-<uuid>`; `KeychainChanges` revision redraws key status. |
| App ↔ MxDataHUB | URL schemes | `mxjobsmgr://sample/<id>?portfolio=&benchmark=` in; `mxdatahub://…` out (`Shared/AppLinks.swift`). |
| App → IDEs | `vscode://file/<path>/`, IntelliJ's URL scheme; CLion, Xcode, Finder via `NSWorkspace` with a security-scoped bookmark | *Open Project in…* on a subscription's Source Project. |
