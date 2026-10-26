# 04 · Code and data model (C4 level 4)

## The jobspace document

A jobspace file is pretty-printed JSON with sorted keys. Every property decodes with a default when missing, links
to unknown nodes are dropped, so files from earlier versions keep opening ([ADR-0001](adr/0001-document-based-app-with-json-jobspace-files.md)).

```mermaid
classDiagram
    direction LR
    class Jobspace {
        format = "mxjobspace"
        formatVersion = 1
        name
        description
        subscriptions: [ApiSubscription]
        nodes: [JobNode]
        links: [JobLink]
        run: RunSettings
    }
    class JobNode {
        id: UUID
        kind: NodeKind
        title, notes
        x, y
        enabled, breakpoint
        arguments: [Argument]
        outcome: ExpectedOutcome
        exceptions: ExceptionPolicy
        schedule: ScheduleSpec?
        agent: AgentSpec?
        approval: ApprovalSpec?
        execution: ExecutionSpec?
        report: ReportSpec?
        api: ApiCallSpec?
        transform: TransformSpec?
        script: ScriptSpec?
        layer: Layer
    }
    class JobLink {
        id: UUID
        from: UUID
        to: UUID
        label
    }
    class ApiSubscription {
        id: UUID
        name, provider
        baseURL, plan, docsURL
        rateLimitPerMinute
        auth: AuthStyle
        keyName
        defaultHeaders: [KeyValue]
        notes
        projectFolder, ide: IDEChoice
        secureAccountID: Int?
        secureAccountName
    }
    class RunSettings {
        operations: OperationsAction = interactive
        agents: AgentsAction = run
        data: DataAction = mock
        breakpointsEnabled = true
        stopOnError = true
        stepDelay = 0.4
    }
    class ExpectedOutcome {
        description
        outputName
        successStatus = 200-299
        requiredFields
        assertions: [ValueAssertion]
    }
    class ExceptionPolicy {
        onFailure: FailureAction = retry
        maxRetries = 2
        retryDelaySeconds = 5
        exponentialBackoff = true
        timeoutSeconds = 30
        fallbackValue
        notifyUser = true
    }
    class Layer {
        <<enum>>
        1 operations
        2 agents
        3 data
    }
    class NodeKind {
        <<enum>>
        L1: trigger, instructionSet, approvalGate, executeRequest, outcomeReport
        L2: agentTask, aggregate, decision
        L3: apiRead, pythonScript, dataNormalize
    }
    Jobspace "1" *-- "*" JobNode
    Jobspace "1" *-- "*" JobLink
    Jobspace "1" *-- "*" ApiSubscription
    Jobspace "1" *-- "1" RunSettings
    JobNode --> NodeKind
    NodeKind --> Layer
    JobNode *-- ExpectedOutcome
    JobNode *-- ExceptionPolicy
    JobLink ..> JobNode : from / to
    JobNode ..> ApiSubscription : api.subscriptionID, script.subscriptionID
```

### Enumerations

| Type | Values |
|---|---|
| `AuthStyle` | `none`, `queryParameter`, `header`, `bearer`, `localService` (bearer only when a token is stored) |
| `FailureAction` | `retry`, `skip`, `useFallback`, `escalateToUser` (Retry / Skip / Abort prompt), `abortRun` |
| `AssertionOp` | `==`, `!=`, `<`, `<=`, `>`, `>=`, `contains`, `exists` (numeric when both sides are numbers) |
| `ScheduleMode` | `manual`, `daily`, `weekdays`, `interval` (recorded; runs start from the app) |
| `ApprovalChannel` | `inApp`, `email`, `message` |
| `ExecutionMode` | `dryRun`, `paper`, `live` |
| `OperationsAction` / `AgentsAction` / `DataAction` | Interactive, Auto-approve, Skip / Run, Skip / Live, Mock, Skip |
| `IDEChoice` | `vscode`, `intellij`, `clion`, `xcode`, `finder` |
| `ArgumentType` | `text`, `number`, `date`, `symbols`, `boolean` |

### Links

A link from a higher layer to a lower one is a **call**; from lower to higher it **returns results** (drawn
dashed); within a layer it is **flow**. The Validator warns when a link skips the agent layer (1 ↔ 3).

## What each step kind does when run

| Kind | Layer | Run behaviour (`RunEngine.perform`) | Output |
|---|---|---|---|
| Refresh Trigger | 1 | Records the start time and its arguments | `startedAt`, arguments |
| Assemble Instructions | 1 | Collects its inputs with the assembly instructions | `instructions`, `assembly` |
| User Approval | 1 | Interactive: **Approve / Reject** prompt with the summary and inputs; Auto-approve: approves with a warning. Reject blocks everything after it. | `approved`, `instructions` |
| Execution Request | 1 | Optional **Send / Cancel** confirmation; **never sends** — reports target, mode and request (warning state) | `sent: false`, `mode`, `target`, `request` |
| Outcome Report | 1 | Counts step states | succeeded, warnings, failed, skipped, recipients, results |
| Agent Task, Aggregate Results | 2 | Simulated: passes its inputs on (model noted as not connected) | inputs |
| Decision | 2 | Follows the `decisionContext` of its inputs — those named in its Inputs list first, then the most confident — else **escalate** (warning) | `nextStep`, `confidence`, `source`, `alternatives`, `reason` |
| API Data Read | 3 | Live: HTTP with substitutions, auth and checks, under the exception policy; Mock: generated data that passes the checks | response JSON |
| Python Script | 3 | Live: asks once *Run Python scripts?*, then runs; Mock: generated data | stdout JSON |
| Normalize Data | 3 | Maps fields by path from its input; missing fields → exception policy | mapped fields |

## Run engine states

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> running: Run (⌘R) or Step (F6)
    running --> paused: breakpoint, Step, Pause
    paused --> running: Continue (⌃⌘Y) or Step
    running --> waiting: approval, send confirmation,<br/>ask-the-user failure, Python consent
    waiting --> running: answer
    running --> finished: all steps done
    running --> failed: step failed with stop on error, or abort
    running --> stopped: Stop (⌘.)
    paused --> stopped: Stop
    waiting --> stopped: Stop
    finished --> idle: Clear Run Results
    failed --> idle: Clear Run Results
    stopped --> idle: Clear Run Results
```

Each node shows its own `NodeRunState`: pending, paused, running, waiting (for you), succeeded, warning
(completed with warnings), failed, skipped.

## Scheduling algorithm

```mermaid
flowchart TD
    A[Start: steps in the jobspace] --> B[Pick a step whose dependencies are done:<br/>steps feeding it in its own layer or from below]
    B --> C{Enabled, layer not skipped,<br/>nothing upstream failed or rejected?}
    C -- no --> D[Mark skipped, pass inputs through]
    C -- yes --> E[Checkpoint: breakpoint or Step pauses here]
    E --> F[Perform the step's action]
    F --> G[Run the steps it calls down the layers,<br/>and whatever they call]
    G --> H{Layer 2 agent?}
    H -- yes --> I[Agent acts after its calls return,<br/>so it sees the Layer 3 results]
    H -- no --> J[Record state and output]
    I --> J
    D --> J
    J --> K{More steps?}
    K -- yes --> B
    K -- no --> L([Finished: Outcome Report sums up])
```

Each step runs once; cycles (a call down whose result comes back up) are allowed. Inputs of a step are the outputs
of the steps linked into it, by their *output name*.
