# Workflows — MxJobsMGR

How people use the app, how a run executes, and the sample workflows as they are wired (taken from
`Samples/*.jobspace`).

1. [Design a jobspace](#1-design-a-jobspace)
2. [Add a subscription and its key](#2-add-a-subscription-and-its-key)
3. [Run and debug](#3-run-and-debug)
4. [An API Data Read step under its exception policy](#4-an-api-data-read-step-under-its-exception-policy)
5. [Approval and execution request](#5-approval-and-execution-request)
6. [A Python Script step](#6-a-python-script-step)
7. [A Decision step](#7-a-decision-step)
8. [Sample: SRM Daily Refresh](#8-sample-srm-daily-refresh)
9. [Sample: Active Portfolio Optimization](#9-sample-active-portfolio-optimization)
10. [Sample: Passive Index Tracking](#10-sample-passive-index-tracking)
11. [Sample: Performance & Risk Attribution](#11-sample-performance--risk-attribution)
12. [Open a sample from MxDataHUB](#12-open-a-sample-from-mxdatahub)

## 1. Design a jobspace

```mermaid
flowchart TD
    A([New, New from Sample, or a link from MxDataHUB]) --> B[Add steps from the palette<br/>drag or double-click, each kind in its layer]
    B --> C[Link steps with the ● handle<br/>down = call, up = result, across = flow]
    C --> D[Configure each step in the inspector:<br/>kind settings, Arguments, Expected Outcome,<br/>Exception Handling]
    D --> E[API Subscriptions: base URL, auth, key<br/>or Layer 3 Services ▸ Add Step]
    E --> F{Problems ⇧⌘K?}
    F -- errors or warnings --> G[Click a problem: jump to the step or subscription] --> D
    F -- none --> H[Rehearse: L3 Mock, L1 Auto-approve]
    H --> I[Test Call / Run Script on single steps]
    I --> J[Run Live with breakpoints]
    J --> K[Save .jobspace, export PNG or draw.io SVG]
```

## 2. Add a subscription and its key

```mermaid
sequenceDiagram
    actor D as Designer
    participant S as SubscriptionsDialog
    participant K as Keychain (com.k3jdr.MxJobsMGR)
    participant T as ApiTester
    participant P as Provider API

    D->>S: New Subscription (or Local Python Service preset)
    D->>S: name, provider, base URL, auth style, key name, headers, plan
    D->>S: paste key, Save Key (or Paste & Save)
    S->>K: save secret for subscription-<id>
    S->>T: Test Key
    T->>P: one call with the key
    P-->>T: status, body (rate-limit notices reported)
    T-->>S: OK or the error
    Note over S,K: the key never goes into the .jobspace file
    D->>S: optional Source Project folder and IDE, Choose…
```

## 3. Run and debug

```mermaid
sequenceDiagram
    actor U as User
    participant RB as Run bar
    participant E as RunEngine
    participant C as Canvas
    participant L3 as Layer 3 (API / Python)

    U->>RB: Run (⌘R)
    RB->>E: run(space)
    loop each step in dependency order
        E->>E: dependencies done? layer skipped? upstream failed or rejected?
        alt breakpoint or Step
            E-->>C: paused before step
            U->>RB: Continue (⌃⌘Y) or Step (F6)
        end
        E-->>C: running
        alt Layer 3 step, Live
            E->>L3: request / script
            L3-->>E: output, checked against Expected Outcome
        else Layer 3 step, Mock
            E->>E: generated output that passes the checks
        else Layer 1 approval or confirmation
            E-->>U: prompt (Approve / Reject, Send / Cancel)
            U-->>E: answer
        end
        E-->>C: succeeded, warning, failed or skipped
        E->>E: run the steps it calls down the layers
    end
    E-->>RB: finished, failed or stopped
    U->>RB: console ⇧⌘Y: log and outputs
```

## 4. An API Data Read step under its exception policy

```mermaid
flowchart TD
    A[Build request: base URL + path,<br/>query, headers, body] --> B[Substitute arguments, today, yesterday,<br/>in: and json: values from linked steps]
    B --> C[Add the key by auth style:<br/>query parameter, header, bearer, local service]
    C --> D[Send, with timeout]
    D --> E{Status in success range,<br/>required fields present,<br/>value checks pass?}
    E -- yes --> F([Succeeded: output under its output name])
    E -- no --> G{On failure}
    G -- retry --> H{Retries left?}
    H -- yes --> I[Wait delay, doubled with backoff] --> D
    H -- no --> J([Failed])
    G -- skip --> K([Skipped: inputs pass through])
    G -- use fallback --> L([Warning: fallback value as output])
    G -- ask the user --> M{Retry / Skip / Abort}
    M -- Retry --> D
    M -- Skip --> K
    M -- Abort --> N([Run aborted])
    G -- abort run --> N
    J --> O{Stop on error?}
    O -- yes --> N
    O -- no --> P([Run continues; steps after it are skipped])
```

## 5. Approval and execution request

```mermaid
sequenceDiagram
    participant E as RunEngine
    actor A as Approver (PM, index PM, data steward)
    participant X as Execution target

    E->>E: Assemble Instructions collects the inputs
    alt L1 Interactive
        E-->>A: Approve "title"? summary with {{argument}} values, approver, instructions
        alt Approve
            A-->>E: Approve
        else Reject
            A-->>E: Reject
            E->>E: block every step after it
        end
    else L1 Auto-approve (rehearsal)
        E->>E: approved, marked as warning
    end
    opt Confirm again before sending
        E-->>A: Send "title"? target, mode
        A-->>E: Send or Cancel
    end
    E--xX: nothing is sent (connectors not available yet)
    E->>E: Execution Request reports target, mode, request: sent false
    E->>E: Outcome Report: succeeded, warnings, failed, skipped
```

## 6. A Python Script step

```mermaid
sequenceDiagram
    participant E as RunEngine
    actor U as User
    participant R as PythonRunner
    participant P as python3 (sandboxed)

    E-->>U: Run Python scripts? (first script of the run, shows the code)
    U-->>E: Allow
    E->>R: run(step, arguments, inputs)
    R->>R: interpreter: step's path, else Homebrew, python.org, developer tools
    R->>P: start, env MXJOBS_API_KEY and MXJOBS_BASE_URL
    R->>P: stdin {"arguments": {...}, "inputs": {...}, "step": "title"}
    P-->>R: stdout JSON, exit code
    R-->>E: output, or error / timeout
    E->>E: Expected Outcome checks, then the exception policy
```

## 7. A Decision step

```mermaid
flowchart TD
    A[Inputs: outputs of linked steps] --> B[Keep inputs that carry a decisionContext]
    B --> C{Any?}
    C -- no --> D([nextStep = escalate, warning])
    C -- yes --> E[Order: names in the step's Inputs list first, in that order,<br/>then by confidence, highest first]
    E --> F([nextStep = recommendation of the first,<br/>with confidence, source, alternatives, reason])
    F --> G[Passed up to Assemble Instructions<br/>and shown to the approver]
```

Recommendations come from the contracts' rules: e.g. optimal with turnover < 2 % → `hold` (0.9); turnover above
`maxTurnover` → `rebalance_partially`; infeasible → `rerun_relaxed`; `invalid_input` → `escalate`.

## 8. Sample: SRM Daily Refresh

Weekday 18:30 New York; opens on Mock; subscription *SRM loader service* (127.0.0.1:8770, header `X-SRM-Dry-Run: 1`).

```mermaid
flowchart LR
    t([Weekday SRM refresh<br/>L1 trigger]) --> ua
    subgraph L2[Layer 2 agents, each waits for the one before]
        direction LR
        ua[Universe agent] --> ca[Benchmark constituents agent] --> ia[Identifier enrichment agent] --> ma[Market data agent] --> dq[Data quality analyst]
    end
    ua <--> l1[[L3: POST /load/reference,<br/>nasdaqtrader, sec-tickers]]
    ca <--> l2[[L3: POST /load/ssga,<br/>nasdaq100]]
    ia <--> l3[[L3: POST /load/openfigi, fmp-profiles,<br/>sec-submissions, gleif]]
    ma <--> l4[[L3: POST /load/fmp-prices,<br/>fmp-index-levels, fmp-corporate-actions]]
    dq <--> st[[L3: GET /status<br/>summary.failed == 0]]
    dq --> rep[SRM daily report & follow-ups<br/>L1] --> ap{Data steward approval<br/>L1} --> bf[Run approved backfills<br/>L1, dry run] --> out([SRM daily load report<br/>L1])
```

Each loader expects `status != failed`; its exception handling follows the source (retries for free reference files,
skip for optional enrichment, ask the user for constituents and prices). The status step expects `summary.failed == 0`.

## 9. Sample: Active Portfolio Optimization

Monthly rebalance review of DEMO_GROWTH (or the portfolio from MxDataHUB) against its benchmark.

```mermaid
sequenceDiagram
    participant T as Monthly rebalance review (L1)
    participant RA as Research agent (L2)
    participant AN as analytics :8772 (Python)
    participant D as Construction decision (L2)
    participant J as portfolio-java :8766
    participant C as portfolio-cpp :8767
    participant TP as Trade proposal (L1)
    actor PM as Portfolio manager
    participant O as Send orders to OMS (L1)

    T->>RA: start
    RA->>AN: POST /inputs (universe, Ledoit-Wolf covariance, momentum alpha)
    AN-->>RA: optInputs (inputsUrl)
    RA->>D: research
    D->>J: POST /optimize/active, inputsUrl, 3% tracking error, ±3% per name, ±5% per sector
    J->>AN: GET inputsUrl
    J-->>D: optimization + decisionContext
    D->>C: POST /risk, weights from the optimization
    C->>AN: GET inputsUrl
    C-->>D: risk (VaR, ES, tracking error, active risk) + decisionContext
    D->>TP: nextStep: rebalance, rebalance_partially or hold
    TP->>PM: Approve?
    PM-->>TP: Approve
    TP->>O: request (dry run: not sent)
    O-->>O: Rebalance report
```

## 10. Sample: Passive Index Tracking

```mermaid
flowchart LR
    t[Daily drift check L1] --> ida[Index data agent L2]
    ida <--> cov[Benchmark covariance<br/>analytics POST /inputs]
    ida --> dec[Rebalance decision L2]
    dec --> st[Sampled tracker<br/>portfolio-cpp POST /optimize/tracking<br/>100 names, stratified]
    dec --> fr[Full replication<br/>portfolio-cpp POST /optimize/tracking]
    cov --> st & fr
    st & fr --> dec
    dec --> prop[Index rebalance proposal L1] --> ap{Index PM approval} --> send[Send index trades<br/>not sent] --> rep[Tracking report]
```

Rebalance when drift exceeds the 1 % tracking-error budget, else hold.

## 11. Sample: Performance & Risk Attribution

```mermaid
flowchart LR
    t[Month-end attribution L1] --> pa[Performance analyst L2]
    pa <--> attr[Sector attribution<br/>analytics POST /attribution<br/>Brinson-Fachler, monthly, Carino]
    pa --> com[Commentary agent L2]
    attr --> com
    com --> ri[Risk inputs<br/>analytics POST /inputs]
    com --> ex[Ex-ante active risk<br/>portfolio-cpp POST /risk]
    ri --> ex --> com
    com --> pack[Attribution pack L1] --> rev{Performance team review} --> pub[Publish to client reporting<br/>not sent] --> rep[Publication report]
```

Months without their own weight snapshot are marked `review` (see MxDataHUB's snapshot history).

## 12. Open a sample from MxDataHUB

```mermaid
sequenceDiagram
    actor U as User
    participant H as MxDataHUB
    participant OS as Launch Services
    participant AD as AppDelegate
    participant PS as PendingSample
    participant DC as NSDocumentController
    participant W as New jobspace window

    U->>H: Portfolios ▸ Workflows ▸ Track SP500 — passive
    H->>OS: mxjobsmgr://sample/passive-tracking?portfolio=…&benchmark=SP500
    OS->>AD: application(_:open:)
    AD->>PS: open(id, portfolio, benchmark)
    PS->>PS: Jobspace.fromSample(...) stored as next
    PS->>DC: newDocument
    DC->>W: DocumentGroup(newDocument: JobspaceDocument(space: PendingSample.take()))
    W-->>U: sample ready, L3 Live (start services) or switch to Mock
```
