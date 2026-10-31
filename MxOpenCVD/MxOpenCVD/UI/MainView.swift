import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            SidebarPanel(model: model, live: model.live)
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 380)
            VSplitView {
                ViewerPane(model: model, live: model.live)
                    .frame(minWidth: 420, minHeight: 320)
                LogPanel(model: model)
                    .frame(minHeight: 110, idealHeight: 170)
            }
            InspectorPanel(model: model, live: model.live)
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 460)
        }
        .navigationTitle(model.job.name)
        .background(QuickHelpContext(model: model, live: model.live))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppModel.RunMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Mode")
                .quickHelp(AppQuickHelp.mode)

                Button { model.trigger() } label: { Label("Trigger", systemImage: "bolt.fill") }
                    .help("Trigger")
                    .quickHelp(AppQuickHelp.trigger)
                Button { model.toggleFreeze() } label: {
                    Label(model.frozenFrame == nil ? "Freeze" : "Live", systemImage: model.frozenFrame == nil ? "pause.fill" : "play.fill")
                }
                .help(model.frozenFrame == nil ? "Freeze" : "Live")
                .quickHelp(AppQuickHelp.freeze)
                Button { model.openImage() } label: { Label("Open Image", systemImage: "photo") }
                    .help("Open Image")
                    .quickHelp(AppQuickHelp.openImage)
            }
        }
        .onAppear { model.startCameras() }
        .alert("MxOpenCVD", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// Tells Quick Help about the window and the selected tool, for when the pointer is over nothing it can describe.
private struct QuickHelpContext: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState

    var body: some View {
        let tool = model.job.tools.first { $0.id == model.selectedToolID }
        Color.clear.quickHelpScreen(model.job.name, AppQuickHelp.window,
                                    selection: AppQuickHelp.selection(tool: tool, report: live.report?.tools.first { $0.id == tool?.id }))
    }
}

struct SidebarPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CamerasSection(model: model)
                .padding(12)
            Divider()
            ToolsSection(model: model, live: live)
        }
        .quickHelpDock()  // the window's bottom left
    }
}

struct CamerasSection: View {
    @ObservedObject var model: AppModel

    /// One row for each tier in the acquisition order, whether or not its camera is connected.
    private var rows: [(tier: CameraTier, cameras: [CameraInfo])] {
        var result: [(CameraTier, [CameraInfo])] = [.iPhone, .usb, .builtIn].map { tier in
            (tier, model.cameras.filter { $0.tier == tier })
        }
        let others = model.cameras.filter { $0.tier == .other }
        if !others.isEmpty { result.append((.other, others)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cameras").font(.headline)
                Spacer()
                Toggle("Auto", isOn: Binding(
                    get: { model.pinnedCameraID == nil },
                    set: { auto in model.pinCamera(auto ? nil : model.activeCameraID) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Auto")
                .quickHelp(AppQuickHelp.auto)
            }

            ForEach(rows, id: \.tier) { row in
                if row.cameras.isEmpty {
                    emptyRow(row.tier)
                } else {
                    ForEach(row.cameras) { cameraRow($0) }
                }
            }

            Text(model.cameraStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.cameraAccessDenied {
                Button("Open Privacy Settings") { model.openCameraPrivacySettings() }
                    .controlSize(.small)
            }

            controls
        }
        .quickHelpArea(AppQuickHelp.cameras)
    }

    private func cameraRow(_ camera: CameraInfo) -> some View {
        let active = camera.id == model.activeCameraID
        return Button {
            model.pinCamera(camera.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: camera.tier.symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(camera.name).lineLimit(1)
                    Text(camera.isDeskView ? "\(camera.tier.role) • Desk View" : camera.isSuspended ? "\(camera.tier.role) • Suspended" : camera.tier.role)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                }
                if model.pinnedCameraID == camera.id {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(camera.isSuspended)
        .help("Use this camera")
        .quickHelp(AppQuickHelp.camera(camera, isActive: active, isPinned: model.pinnedCameraID == camera.id, controls: model.controls))
    }

    private func emptyRow(_ tier: CameraTier) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tier.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tier.title).lineLimit(1)
                Text("\(tier.role) • Not connected").font(.caption2)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .help("Not connected")
        .quickHelp(AppQuickHelp.missingCamera(tier))
    }

    @ViewBuilder
    private var controls: some View {
        let controls = model.controls
        if !controls.formatDescription.isEmpty {
            Text(controls.formatDescription)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        ForEach(controls.effectWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if controls.supportsFocusLock {
            Toggle("Lock focus", isOn: Binding(get: { controls.focusLocked }, set: { model.setFocusLocked($0) }))
                .controlSize(.small)
                .quickHelp(AppQuickHelp.focusLock)
        }
        if controls.supportsExposureLock {
            Toggle("Lock exposure", isOn: Binding(get: { controls.exposureLocked }, set: { model.setExposureLocked($0) }))
                .controlSize(.small)
                .quickHelp(AppQuickHelp.exposureLock)
        }
    }
}

struct ToolsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Menu {
                    ForEach(ToolKind.allCases) { kind in
                        Button { model.addTool(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a tool")
                .quickHelp(AppQuickHelp.addTool)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            List(selection: $model.selectedToolID) {
                ForEach($model.job.tools) { $tool in
                    toolRow($tool).tag(tool.id)
                }
                .onMove { model.job.tools.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .quickHelpArea(AppQuickHelp.tools)
    }

    private func toolRow(_ tool: Binding<ToolConfig>) -> some View {
        let id = tool.wrappedValue.id
        let verdict = live.report?.tools.first { $0.id == id }?.verdict
        return HStack(spacing: 8) {
            Toggle("", isOn: tool.enabled)
                .labelsHidden()
                .controlSize(.small)
                .help("Include")
                .quickHelp(AppQuickHelp.toolEnabled)
            Image(systemName: tool.wrappedValue.kind.symbol)
                .frame(width: 18)
            Text(tool.wrappedValue.name).lineLimit(1)
            Spacer()
            if let verdict, tool.wrappedValue.enabled {
                Circle().fill(verdict.color).frame(width: 9, height: 9).help(verdict.rawValue)
            }
        }
        .quickHelpArea(AppQuickHelp.tool(tool.wrappedValue, verdict: verdict))
        .contextMenu {
            Button("Delete Tool", role: .destructive) { model.removeTool(id) }
        }
    }
}

struct LogPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Results").font(.headline)
                Text("\(model.log.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Export…") { model.exportLog() }.disabled(model.log.isEmpty).quickHelp(AppQuickHelp.exportResults)
                Button("Clear") { model.clearLog() }.disabled(model.log.isEmpty).quickHelp(AppQuickHelp.clearResults)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Table(model.log) {
                TableColumn("Time") { Text($0.date, format: .dateTime.hour().minute().second()).monospacedDigit() }
                    .width(min: 70, ideal: 80, max: 100)
                TableColumn("Result") { entry in
                    Text(entry.verdict.rawValue).bold().foregroundStyle(entry.verdict.color)
                }
                .width(min: 50, ideal: 70, max: 100)
                TableColumn("Camera") { Text($0.source).lineLimit(1) }
                    .width(min: 80, ideal: 130)
                TableColumn("ms") { Text(String(format: "%.0f", $0.milliseconds)).monospacedDigit() }
                    .width(min: 30, ideal: 45, max: 70)
                // The column is often too narrow for a failure's reasons; Quick Help shows them all.
                TableColumn("Details") { entry in
                    Text(entry.summary).lineLimit(1).quickHelpArea(AppQuickHelp.logEntry(entry))
                }
            }
        }
        .quickHelpArea(AppQuickHelp.results)
    }
}
