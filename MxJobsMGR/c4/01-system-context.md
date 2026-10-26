# 01 · System context (C4 level 1)

MxJobsMGR turns a desk's recurring processes — refreshing the security master, active optimization, passive index
tracking, attribution, market-data gathering — into **jobspaces**: diagrams that can be checked, rehearsed, run
step by step, and approved by a person before anything is executed.

```mermaid
C4Context
    title System context — MxJobsMGR

    Person(pm, "Portfolio manager", "Runs optimization, tracking and attribution workflows; approves rebalances")
    Person(steward, "Data steward", "Runs the security master refresh; approves the daily report and backfills")
    Person(designer, "Workflow designer / developer", "Builds jobspaces, subscriptions and Layer 3 services")

    System(wms, "MxJobsMGR", "macOS app: design, check, run and debug three-layer workflows saved as jobspace files")

    System_Ext(services, "Layer 3 services", "Local HTTP services on 127.0.0.1: SRM loaders, analytics, Java active optimizer, C++ tracking and risk, market sample")
    System_Ext(providers, "Market data provider APIs", "Alpha Vantage, Finnhub, Frankfurter FX, SEC EDGAR and others, with API keys")
    System_Ext(hub, "MxDataHUB", "macOS app: the security master — securities, benchmarks, portfolios, data refresh")
    System_Ext(keychain, "macOS login Keychain", "API keys: MxAcctMGR Secure Accounts' service keys")
    System_Ext(acct, "MxAcctMGR", "macOS app: personal accounts; Banking ▸ Secure Accounts keeps the API keys")
    System_Ext(ides, "IDEs", "VS Code, IntelliJ IDEA, CLion, Xcode, Finder — opened on a service's source project")
    System_Ext(python, "Python interpreter", "Homebrew, python.org or Apple developer tools python3")

    Rel(pm, wms, "Runs workflows, approves")
    Rel(steward, wms, "Runs refresh, approves")
    Rel(designer, wms, "Designs jobspaces and subscriptions")
    Rel(wms, services, "API Data Read steps", "HTTP JSON")
    Rel(wms, providers, "API Data Read steps, Test Key, Test Call", "HTTPS")
    Rel(wms, keychain, "Reads keys (moves its old ones once)")
    Rel(acct, keychain, "Saves keys, trusting both apps")
    Rel(wms, acct, "Opens a secure account", "mxacctmgr:// URL")
    Rel(wms, python, "Python Script steps", "stdin and stdout JSON")
    Rel(wms, hub, "Opens a screen", "mxdatahub:// URL")
    Rel(hub, wms, "Opens a sample for a portfolio or benchmark", "mxjobsmgr:// URL")
    Rel(wms, ides, "Open Project in…", "URL schemes or bookmarks")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Actors

| Actor | Goals in MxJobsMGR |
|---|---|
| **Portfolio manager** | Open the Active, Passive or Attribution sample for a portfolio (often from MxDataHUB), run it, review the optimizer's or tracker's outcome and the decision, approve or reject the instructions, see the outcome report. |
| **Data steward** | Run the SRM Daily Refresh (mock, preview or live), review the data-quality report, approve backfills. |
| **Workflow designer / developer** | Build jobspaces from the palette; configure API subscriptions and pick their secure accounts; write Python steps; wire Layer 3 services (Add Step); check Problems; debug with breakpoints and Step; export diagrams; open the service's project in the IDE. |

## External systems

| System | Relationship | Notes |
|---|---|---|
| **Layer 3 services** | Called by API Data Read steps through **Local service** subscriptions; their state, purpose and endpoints shown in Layer 3 Services. | 127.0.0.1 only, outside the sandbox; started with `Services/mxservices.py`. Outcomes carry a `decisionContext` for Layer 2. |
| **Provider APIs** | Called by API Data Read steps with the service key of the subscription's secure account (query parameter, header, bearer). | Keys in MxAcctMGR ▸ Secure Accounts (Keychain), never in the jobspace. Rate limits noted per subscription. |
| **MxDataHUB** | Peer app; hand-offs both ways by URL scheme. | [ADR-0012](adr/0012-data-and-process-apps-linked-by-url-schemes.md). |
| **MxAcctMGR** | Keeps the API keys: Banking ▸ Secure Accounts. *Open in MxAcctMGR* / *New in MxAcctMGR…* (`mxacctmgr://secure-accounts/…`). | [ADR-0018](adr/0018-api-keys-kept-by-mxacctmgr-secure-accounts.md). |
| **Login Keychain** | Secure accounts' service keys (`com.k3jdr.MxAcctMGR.secure-accounts`, account `<id> service key`), saved trusting both apps; read by MxJobsMGR. | Old keys (`com.k3jdr.MxJobsMGR` / `com.k3jdr.MxJobsWMS`, `subscription-<id>`) are read once by Move Keys. |
| **Python interpreter** | Runs Python Script steps inside the app's sandbox. | The run asks once before the first script. |
| **IDEs** | *Open Project in…* for a subscription's source folder. | VS Code and IntelliJ by URL scheme; CLion, Xcode and Finder through a security-scoped bookmark. |

## Scope

In scope: designing, validating, rehearsing, running and debugging workflows; approvals and confirmations; key
management; diagram export. Not yet in scope (by design, see [ADR-0006](adr/0006-execution-requests-never-send-yet.md)):
sending execution requests to order-management or other targets, real LLM agents (agents are simulated), unattended
scheduling (triggers record their schedule; runs start from the app).
