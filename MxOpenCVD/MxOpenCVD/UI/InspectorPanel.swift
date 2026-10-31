import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("Tool").tag(0)
                Text("Job").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                if page == 1 {
                    JobInspector(model: model)
                        .padding(12)
                } else if let index = model.job.tools.firstIndex(where: { $0.id == model.selectedToolID }) {
                    ToolInspector(model: model, live: live, tool: $model.job.tools[index])
                        .id(model.job.tools[index].id)
                        .padding(12)
                } else {
                    Text("Choose a tool on the left, or add one with +.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
    }
}

struct ToolInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveState
    @Binding var tool: ToolConfig

    private var report: ToolReport? { live.report?.tools.first { $0.id == tool.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: tool.kind.symbol)
                TextField("Name", text: $tool.name)
                    .textFieldStyle(.roundedBorder)
            }
            .quickHelpArea(AppQuickHelp.tool(tool, verdict: report?.verdict))
            Text(tool.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SectionTitle("Region")
            HStack {
                Button(model.isDrawingROI ? "Drawing…" : tool.roi == nil ? "Draw Region" : "Redraw Region") {
                    model.isDrawingROI.toggle()
                }
                .quickHelp(AppQuickHelp.region(hasRegion: tool.roi != nil))
                Button("Whole Image") { tool.roi = nil }
                    .disabled(tool.roi == nil)
                    .quickHelp(AppQuickHelp.wholeImage)
            }
            .controlSize(.small)

            if tool.kind == .pattern {
                patternSection
            }

            if tool.kind.usesColors {
                colorsSection
            }

            if tool.kind == .contours {
                Button("Export Contours…") { model.exportContours(toolID: tool.id) }
                    .controlSize(.small)
                    .quickHelp(AppQuickHelp.exportContours)
            }

            if !tool.kind.params.isEmpty {
                SectionTitle("Settings")
                ForEach(tool.kind.params.filter { $0.isRelevant(tool) }) { spec in
                    control(for: spec)
                        .quickHelpArea(AppQuickHelp.param(spec, of: tool.kind))
                }
            }

            if tool.kind.readsText {
                SectionTitle("Expected text")
                TextField("Regular expression, such as ^LOT [A-Z0-9-]+$", text: $tool.expectedText)
                    .textFieldStyle(.roundedBorder)
                    .quickHelpArea(AppQuickHelp.expectedText)
            }

            limitsSection
            resultSection
        }
    }

    @ViewBuilder
    private var colorsSection: some View {
        SectionTitle("Colors")
        Button("Add Color from Region") { model.addColor(toolID: tool.id) }
            .controlSize(.small)
            .disabled(tool.roi == nil)
            .quickHelp(AppQuickHelp.addColor(for: tool.kind))
        if tool.colors.isEmpty {
            Text("Draw a region on a color, then add it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach($tool.colors) { $color in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: color.meanRGB[0] / 255, green: color.meanRGB[1] / 255, blue: color.meanRGB[2] / 255))
                        .frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                    TextField("Name", text: $color.name)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        tool.colors.removeAll { $0.id == color.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                if tool.kind == .colorSegmenter {
                    segmenterRanges($color)
                    colorSlider("Softness", value: $color.softness, range: 0...100, help: AppQuickHelp.segmenterSoftness)
                } else if tool.kind == .colorExtractor {
                    colorSlider("Dilation", value: $color.dilation, range: 0...100, help: AppQuickHelp.extractorDilation)
                    colorSlider("Softness", value: $color.softness, range: 0...100, help: AppQuickHelp.extractorSoftness)
                    colorSlider("Matte line low", value: $color.matteLow, range: 0...1, help: AppQuickHelp.matteLine)
                    colorSlider("Matte line high", value: $color.matteHigh, range: 0...1, help: AppQuickHelp.matteLine)
                    colorSlider("Highlight line", value: $color.highlight, range: 0...1, help: AppQuickHelp.highlightLine)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Each plane's range around its nominal value, which is fixed by what was taught.
    @ViewBuilder
    private func segmenterRanges(_ color: Binding<ColorReference>) -> some View {
        let isHSI = (tool.numbers["colorSpace"] ?? 1) == 1
        let names = isHSI ? ["Hue", "Saturation", "Intensity"] : ["Red", "Green", "Blue"]
        ForEach(0..<3, id: \.self) { plane in
            let nominal = isHSI ? color.wrappedValue.meanHSI[plane] : color.wrappedValue.meanRGB[plane]
            VStack(alignment: .leading, spacing: 0) {
                Text("\(names[plane]): \(Int(nominal.rounded()))")
                    .font(.caption)
                HStack(spacing: 4) {
                    Slider(value: isHSI ? color.lowHSI[plane] : color.lowRGB[plane], in: -128...0)
                    Slider(value: isHSI ? color.highHSI[plane] : color.highRGB[plane], in: 0...128)
                }
                .controlSize(.mini)
            }
            .quickHelpArea(AppQuickHelp.segmenterRange)
        }
    }

    private func colorSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, help: QuickHelpItem) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range).controlSize(.mini)
            Text(range.upperBound <= 1 ? String(format: "%.2f", value.wrappedValue) : String(format: "%.0f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 32, alignment: .trailing)
        }
        .quickHelpArea(help)
    }

    @ViewBuilder
    private var patternSection: some View {
        SectionTitle("Pattern")
        if let data = tool.patternPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 90)
                .border(.separator)
        }
        Button(tool.patternPNG == nil ? "Teach Pattern from Region" : "Teach Again from Region") {
            model.teachPattern(toolID: tool.id)
        }
        .controlSize(.small)
        .disabled(tool.roi == nil)
        .quickHelp(AppQuickHelp.teachPattern)
        Text("Draw a region around one good part, then teach. The search then covers the whole image until you draw a search region.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func control(for spec: ParamSpec) -> some View {
        switch spec.control {
        case .slider(let range, let step):
            let value = Binding(get: { tool.number(spec) }, set: { tool.numbers[spec.key] = $0 })
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spec.label)
                    Spacer()
                    TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                Slider(value: value, in: range, step: step)
                    .controlSize(.small)
            }
        case .choice(let options):
            Picker(spec.label, selection: Binding(get: { tool.number(spec) }, set: { tool.numbers[spec.key] = $0 })) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
        case .toggle:
            Toggle(spec.label, isOn: Binding(get: { tool.number(spec) != 0 }, set: { tool.numbers[spec.key] = $0 ? 1 : 0 }))
        case .file(let extensions):
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.label)
                HStack {
                    Text((tool.strings[spec.key] as NSString?)?.lastPathComponent ?? "None")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(tool.strings[spec.key] ?? "")
                    Spacer()
                    Button("Choose…") { chooseFile(spec.key, extensions: extensions) }
                        .controlSize(.small)
                    if tool.strings[spec.key] != nil {
                        Button("Clear") { tool.strings[spec.key] = nil }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func chooseFile(_ key: String, extensions: [String]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) ?? UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            tool.strings[key] = url.path
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Pass limits")
            HStack(spacing: 6) {
                Text("Measure").frame(maxWidth: .infinity, alignment: .leading)
                Text("Min").frame(width: 62)
                Text("Max").frame(width: 62)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(tool.relevantMeasures, id: \.self) { measure in
                HStack(spacing: 6) {
                    Text(measure.replacingOccurrences(of: "_", with: " "))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", value: limitBinding(measure, \.minimum), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                    TextField("", value: limitBinding(measure, \.maximum), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                }
                .controlSize(.small)
                .quickHelpArea(AppQuickHelp.measure(measure, of: tool.kind))
            }
        }
        .quickHelpArea(AppQuickHelp.limits)
    }

    private func limitBinding(_ measure: String, _ field: WritableKeyPath<Limit, Double?>) -> Binding<Double?> {
        Binding(
            get: { tool.limits.first { $0.measure == measure }?[keyPath: field] },
            set: { value in
                if let index = tool.limits.firstIndex(where: { $0.measure == measure }) {
                    tool.limits[index][keyPath: field] = value
                    if tool.limits[index].minimum == nil && tool.limits[index].maximum == nil {
                        tool.limits.remove(at: index)
                    }
                } else if value != nil {
                    var limit = Limit(measure: measure)
                    limit[keyPath: field] = value
                    tool.limits.append(limit)
                }
            }
        )
    }

    @ViewBuilder
    private var resultSection: some View {
        SectionTitle("Latest result")
            .quickHelpArea(AppQuickHelp.latestResult)
        if let report {
            HStack {
                Text(report.verdict.rawValue).bold().foregroundStyle(report.verdict.color)
                Spacer()
                Text(String(format: "%.1f ms", report.output.elapsedMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(report.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(report.output.measures, id: \.name) { measure in
                HStack {
                    Text(measure.name.replacingOccurrences(of: "_", with: " "))
                    Spacer()
                    Text("\(Evaluator.format(measure.value)) \(measure.unit)").monospacedDigit()
                }
                .font(.callout)
                .quickHelpArea(AppQuickHelp.measure(measure.name, of: tool.kind))
            }
            if !report.output.texts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(report.output.texts.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.callout.monospaced())
                    }
                }
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        } else {
            Text("Press Trigger, or switch to Inspect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct JobInspector: View {
    @ObservedObject var model: AppModel

    @AppStorage("boardCols") private var boardCols = 9
    @AppStorage("boardRows") private var boardRows = 6
    @AppStorage("boardSquare") private var boardSquare = 5.0
    @State private var boardMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Job name", text: $model.job.name)
                .textFieldStyle(.roundedBorder)
                .quickHelpArea(AppQuickHelp.jobName)

            SectionTitle("Scale for \(model.stillName != nil ? "opened images" : model.activeCamera?.name ?? "this camera")")
            Text("Each camera has its own scale, and it holds only at the distance it was calibrated. Move the camera or the part and calibrate again. Lens distortion isn't corrected yet, so keep measurements near the middle of the image.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("mm per pixel")
                Spacer()
                TextField("Not calibrated", value: Binding(get: { model.currentScale }, set: { model.setScale($0) }), format: .number.precision(.significantDigits(1...6)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
            .quickHelpArea(AppQuickHelp.scale)

            SectionTitle("Calibrate with a chessboard")
                .quickHelpArea(AppQuickHelp.chessboard)
            Stepper("Inner corners across: \(boardCols)", value: $boardCols, in: 3...30)
                .quickHelpArea(AppQuickHelp.chessboard)
            Stepper("Inner corners down: \(boardRows)", value: $boardRows, in: 3...30)
                .quickHelpArea(AppQuickHelp.chessboard)
            HStack {
                Text("Square size (mm)")
                Spacer()
                TextField("", value: $boardSquare, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            .quickHelpArea(AppQuickHelp.chessboard)
            Button("Calibrate from Current Image") {
                boardMessage = model.calibrateFromChessboard(cols: boardCols, rows: boardRows, squareMM: boardSquare)
            }
            .controlSize(.small)
            .disabled(boardSquare <= 0)
            .quickHelp(AppQuickHelp.chessboard)
            if !boardMessage.isEmpty {
                Text(boardMessage)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionTitle("Failures")
            Toggle("Save an image of each failure", isOn: $model.job.saveFailureImages)
                .quickHelp(AppQuickHelp.saveFailures)
            if model.job.saveFailureImages {
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: AppModel.failureFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppModel.failureFolder)
                }
                .controlSize(.small)
            }

            SectionTitle("Libraries")
            Text(MXVEngine.libraryVersions() + ", PaddleOCR PP-OCRv5 models")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
