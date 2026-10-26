//
//  JobsQuickHelp.swift
//  MxJobsMGR
//
//  What Quick Help (Shared/QuickHelp) says in MxJobsMGR: the jobspace window — canvas, palette,
//  inspector, run bar and console — the API subscriptions, and the Services, Samples and API key windows.
//

import SwiftUI

enum JobsHelp {
    // MARK: Screens

    /// The jobspace window's screen: the jobspace, or the API subscriptions while that sheet is open.
    static func screen(_ space: Jobspace, editor: EditorState, problems: Int) -> (name: String, item: QuickHelpItem) {
        if editor.showSubscriptions { return ("API Subscriptions", subscriptions) }
        let counts = "\(space.nodes.count) step\(space.nodes.count == 1 ? "" : "s"), \(space.links.count) link\(space.links.count == 1 ? "" : "s")"
            + (problems == 0 ? ", no problems." : ", \(problems) problem\(problems == 1 ? "" : "s") (⇧⌘K).")
        return ("Jobspace", QuickHelpItem(
            title: space.name.isEmpty ? "Jobspace" : space.name,
            detail: "A three-layer workflow: business operations in Layer 1 at the top, agents in Layer 2, data reads in Layer 3. "
                + "Drag steps from the palette onto the canvas, link them with the ● handle, set each up in the inspector (⌥⌘I), "
                + "and run it with ▶ (⌘R) or a step at a time (F6).\n" + counts,
            symbol: "flowchart"))
    }

    static let subscriptions = QuickHelpItem(
        title: "API Subscriptions",
        detail: "The data services this jobspace's Layer 3 steps call: base URL, plan, rate limit, how the key is sent, and headers sent "
            + "with every call. Each sends the service key of its MxAcctMGR secure account; keys are never in the jobspace file. + adds a subscription or the local Python "
            + "service; Get a Key… and ? show how to get one, Secure account picks the MxAcctMGR account that holds it, Test Key tries it.",
        shortcut: "⌥⌘K", symbol: "key.horizontal")

    /// What's selected on the canvas.
    static func selection(_ space: Jobspace, editor: EditorState) -> QuickHelpItem? {
        if editor.selectedNodes.count > 1 {
            return QuickHelpItem(title: "\(editor.selectedNodes.count) steps selected",
                                 detail: "Drag one to move them together; arrow keys nudge them (⇧ for bigger steps). ⌘D duplicates, Delete removes.",
                                 symbol: "square.on.square")
        }
        if let id = editor.selectedNodes.first, let node = space.node(id) {
            return self.node(node, state: editor.run.states[id], issue: nil, selected: true)
        }
        if let id = editor.selectedLink, let link = space.links.first(where: { $0.id == id }) {
            let from = space.node(link.from), to = space.node(link.to)
            let up = (to?.layer.rawValue ?? 0) < (from?.layer.rawValue ?? 0)
            return QuickHelpItem(title: "Link: \(from?.title ?? "–") → \(to?.title ?? "–")",
                                 detail: (up ? "Points up the layers (dashed): it carries results back. " : "Points down the layers: a call. ")
                                    + "Name it in the inspector; Delete removes it.",
                                 symbol: "arrow.right")
        }
        return nil
    }

    // MARK: Canvas

    static func canvas(lane: Layer?) -> QuickHelpItem {
        guard let lane else {
            return QuickHelpItem(title: "Canvas", detail: canvasDetail, symbol: "rectangle.3.group")
        }
        return QuickHelpItem(title: "Layer \(lane.rawValue) · \(lane.title)",
                             detail: lane.subtitle + ". " + laneDetail[lane.rawValue - 1] + "\n" + canvasDetail,
                             symbol: "rectangle.split.1x2")
    }

    private static let canvasDetail = "Click a step to select it, ⇧-click to add to the selection, drag on empty canvas to select several. "
        + "Drop palette steps here. Pinch or ⌘+ ⌘− to zoom; right-click to run or save the diagram as PNG or draw.io SVG."

    private static let laneDetail = [
        "Steps here start the run, assemble instructions, wait for approval, execute and report. Steps stay in their own lane.",
        "Agents call the Layer 3 steps linked below them and hand their results up; Decision routes the run.",
        "API reads and Python steps call the data services with your subscriptions' keys; Normalize maps their fields.",
    ]

    /// A step on the canvas: what kind it is, how it last ran, and what to do with it.
    static func node(_ node: JobNode, state: NodeRunState?, issue: IssueSeverity?, selected: Bool = false) -> QuickHelpItem {
        var facts: [String] = ["Layer \(node.layer.rawValue)"]
        if !node.enabled { facts.append("disabled") }
        if node.breakpoint { facts.append("breakpoint") }
        if let state, state != .pending { facts.append("last run: " + state.title.lowercased()) }
        if let issue { facts.append(issue == .error ? "has an error (see Checks)" : "has a warning (see Checks)") }
        let how = selected
            ? "The inspector on the right sets it up. ⌘\\ toggles a breakpoint, ⌘D duplicates, Delete removes it."
            : "Click to select it and set it up in the inspector; drag to move it; drag its ● handle onto another step to link them. Right-click for breakpoint, disable, duplicate, delete."
        return QuickHelpItem(title: "\(node.kind.title): \(node.title)",
                             detail: (kindDetail[node.kind] ?? node.kind.summary) + "\n" + facts.joined(separator: " · ") + ". " + how,
                             symbol: node.kind.symbol)
    }

    static let handle = QuickHelpItem(title: "Link Handle", detail: "Drag onto another step to link them: calls go down the layers, results come back up (dashed).",
                                      symbol: "smallcircle.filled.circle")

    static let breakpoint = QuickHelpItem(title: "Breakpoint", detail: "Runs pause before this step (when breakpoints are on, ⌘Y). ⌘\\ toggles it on the selected step.",
                                          shortcut: "⌘\\", symbol: "arrowshape.right.fill")

    // MARK: Palette

    /// What each kind of step does (the palette, the canvas and the inspector).
    static let kindDetail: [NodeKind: String] = [
        .trigger: "Starts a run: manually, daily or on weekdays at a set time, or every so many minutes (Schedule in the inspector). It goes first in Layer 1.",
        .instructionSet: "Builds the instructions that go for approval — a trade list, say — from the results linked into it. Set the assembly instructions and output format in the inspector.",
        .approvalGate: "Pauses the run until the approver answers in the banner above the canvas; nothing downstream runs before then. Set the approver, how they're asked, the expiry and the summary they see.",
        .executeRequest: "Sends the approved instructions to their target: a dry run (nothing sent), a paper / sandbox account, or live. Confirm Again asks once more before sending.",
        .outcomeReport: "Reports what the run did to its recipients, optionally in detail and with failures and data gaps.",
        .agentTask: "An agent that gathers data points by calling the Layer 3 steps linked below it, following its instructions (simulated: it passes its inputs on).",
        .aggregate: "Combines the outputs of the steps linked into it into one result.",
        .decision: "Routes the run on its inputs' decision context (the first of its Inputs that has one, else the most confident); with none, it escalates to you.",
        .apiRead: "Calls one endpoint of an API subscription — method, path, query parameters, headers — sending the service key of the subscription's secure account (MxAcctMGR ▸ Secure Accounts). Test Call in the inspector tries it now.",
        .pythonScript: "Runs Python: arguments and linked inputs arrive as JSON on stdin and it prints JSON. Layer 3 service steps call the shared services (Services/). Run Script in the inspector tries it.",
        .dataNormalize: "Maps fields of a raw response to named data points: each output field takes the value at a dotted JSON path.",
    ]

    static func paletteKind(_ kind: NodeKind) -> QuickHelpItem {
        QuickHelpItem(title: kind.title,
                      detail: (kindDetail[kind] ?? kind.summary) + "\nDrag it onto its lane on the canvas, or double-click to add it at the end of Layer \(kind.layer.rawValue).",
                      symbol: kind.symbol)
    }

    static func paletteService(_ service: ServiceInfo, running: Bool) -> QuickHelpItem {
        QuickHelpItem(title: "\(service.name) (\(service.language))",
                      detail: service.purpose + "\n" + (running ? "Running on this Mac. " : "Not running on this Mac. ")
                        + "Double-click to add a Layer 3 step calling it; right-click for each endpoint.",
                      symbol: "server.rack")
    }

    static let palette = QuickHelpItem(title: "Palette",
                                       detail: "The steps you can add, by layer, and the shared Layer 3 services. Drag a step onto the canvas or double-click it; right-click a service for its endpoints.",
                                       symbol: "square.grid.2x2")

    // MARK: Inspector

    static func inspector(_ space: Jobspace, editor: EditorState) -> QuickHelpItem {
        if editor.selectedNodes.count == 1, let id = editor.selectedNodes.first, let node = space.node(id) {
            return QuickHelpItem(title: "Inspector: \(node.kind.title)",
                                 detail: "The selected step's settings: title, enabled, breakpoint and notes; what a \(node.kind.title) does; its arguments ({{name}} in paths and templates); "
                                    + "the expected outcome that decides success; and what happens when it fails.",
                                 shortcut: "⌥⌘I", symbol: "sidebar.trailing")
        }
        if editor.selectedLink != nil {
            return QuickHelpItem(title: "Inspector: Link", detail: "Where the link runs from and to, and its label on the canvas.", shortcut: "⌥⌘I", symbol: "sidebar.trailing")
        }
        return QuickHelpItem(title: "Inspector: Jobspace",
                             detail: "With nothing selected: the jobspace's name and description, steps per layer, its API subscriptions with their key status, and the configuration checks. Click a check to go to its step.",
                             shortcut: "⌥⌘I", symbol: "sidebar.trailing")
    }

    /// Inspector sections, by header.
    static func section(_ name: String) -> QuickHelpItem? {
        guard let detail = sectionDetail[name] else { return nil }
        return QuickHelpItem(title: name, detail: detail, symbol: "slider.horizontal.3")
    }

    private static let sectionDetail: [String: String] = [
        "Schedule": "When the trigger starts a run: manually, daily or on weekdays at a time in a time zone, or every N minutes.",
        "Agent": "What the agent is told to do, the model it would use, the output format, and the inputs (linked steps' outputs) it reads.",
        "Instruction Assembly": "How the instructions are put together from the linked results, and their output format.",
        "Decision": "What the decision weighs. Its Inputs list sets which linked result's decision context comes first.",
        "User Approval": "Who approves, how they're asked (in app, email, message), when the request expires, whether a comment is required, and the summary they see.",
        "Execution Request": "Where approved instructions go and how: dry run, paper / sandbox, or live (real requests once approved).",
        "Outcome Report": "Who gets the report, whether it's detailed, and whether failures and data gaps are included.",
        "API Call": "The subscription (base URL and key), method and endpoint path. Use {{argument}} placeholders in the path.",
        "Query Parameters": "Name / value pairs added to the URL; values may use {{argument}} and {{today}}.",
        "Headers": "Headers sent with this call, on top of the subscription's own.",
        "Try It": "Sends one request (or runs the script) now with the stored key and the inputs from the last run, and checks the expected outcome.",
        "Python Script": "The python3 that runs the script and the subscription whose key and base URL it gets (MXJOBS_API_KEY, MXJOBS_BASE_URL).",
        "Code": "The script: it reads {\"arguments\", \"inputs\", \"step\"} as JSON on stdin and prints its result as JSON.",
        "Field Mappings": "Each output field takes the value at a dotted JSON path of the incoming data.",
        "Arguments": "Named values for this step: use {{name}} in paths, parameters, headers and templates. Built-ins: {{today}}, {{yesterday}}.",
        "Expected Outcome": "What success means: HTTP status, required fields, and value checks (path, comparison, value). The output name publishes the result to the steps downstream.",
        "Exception Handling": "What a failure does: retry then fail, skip and continue, use a fallback value, ask you, or abort the run.",
        "Checks": "Configuration problems with this step or the jobspace. Click one to go to it.",
        "Last Run": "How the step did in the last run and its last log message; Show Output opens it in the console.",
        "About This Service": "The shared Layer 3 service behind this step (Services/): what it's for, its endpoints, and the Layer 3 Services window.",
        // API Subscriptions
        "Service": "The subscription's name, provider, base URL, plan, rate limit and documentation link.",
        "API Key": "How the key is sent (query parameter, header, bearer token, local service, none) and the MxAcctMGR secure account whose service key is sent. Keys are entered and changed in MxAcctMGR ▸ Banking ▸ Secure Accounts: Open in MxAcctMGR shows the account, New in MxAcctMGR… makes one. Test Key tries it.",
        "Headers Sent With Every Call": "Headers every step using this subscription sends.",
        "Source Project": "For services you develop (Services/portfolio-java, portfolio-cpp): the project folder and the IDE its steps' Open Project button opens.",
        "Notes": "Anything worth remembering about the subscription.",
    ]

    // MARK: Run

    static let runBar = QuickHelpItem(title: "Run Bar",
                                      detail: "Run, pause, step and stop the jobspace; choose what each layer does in a run (L1 interactive or auto-approve, L2 run or skip, L3 live, mock or skip); breakpoints; options; the run's status.",
                                      symbol: "play.rectangle")

    static func layerAction(_ layer: Layer) -> QuickHelpItem {
        let detail: String
        switch layer {
        case .operations: detail = "Interactive asks you at each approval; Auto-approve rehearses the run without asking; Skip leaves Layer 1 out."
        case .agents: detail = "Run the agents (simulated: they pass their inputs on), or skip Layer 2."
        case .data: detail = "Live calls the APIs with your keys; Mock makes up responses that pass the checks, with no network; Skip leaves Layer 3 out."
        }
        return QuickHelpItem(title: "Layer \(layer.rawValue) in a Run", detail: detail, symbol: "\(layer.rawValue).square")
    }

    static let console = QuickHelpItem(title: "Run Console",
                                       detail: "The run log on the left (filter by level; click an entry to select its step) and the selected step's output as JSON on the right. Drag the line above it to resize.",
                                       shortcut: "⇧⌘Y", symbol: "rectangle.bottomthird.inset.filled")

    static func prompt(_ prompt: RunPrompt) -> QuickHelpItem {
        QuickHelpItem(title: "Waiting for You: \(prompt.title)",
                      detail: "The run is paused on this step until you choose. " + prompt.options.map(\.label).joined(separator: " · ")
                        + (prompt.detail.isEmpty ? "" : ". Details shows what you're approving."),
                      symbol: "person.crop.circle.badge.questionmark")
    }

    // MARK: Other windows

    static let services = QuickHelpItem(title: "Layer 3 Services",
                                        detail: "The shared services (Services/) the workflows call: what each is for, its language, endpoints and how to start it. Add Step puts a step calling an endpoint into the front jobspace; a sample opens a complete workflow built on it.",
                                        shortcut: "⌥⌘L", symbol: "server.rack")

    static let samples = QuickHelpItem(title: "New from Sample",
                                       detail: "Complete three-layer workflows to start from: data refresh, active optimization, passive tracking, attribution. Create opens one as a new jobspace.",
                                       shortcut: "⌥⌘N", symbol: "doc.on.doc")

    static let keys = QuickHelpItem(title: "Adding API Keys",
                                    detail: "How to get a key for each data provider, put it in MxAcctMGR ▸ Secure Accounts, and choose that secure account for a subscription. Keys are never in the jobspace file.",
                                    symbol: "key")
}
