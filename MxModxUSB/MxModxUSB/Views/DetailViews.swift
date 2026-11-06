//
//  DetailViews.swift — MxModxUSB
//
//  The current Performance in full, the current Live Set bank, every System setting, and the user curves and
//  micro-tuning tables — each editable while changes are unlocked.
//

import SwiftUI

// MARK: Performance

struct PerformanceView: View {
    let model: ModxModel
    @State private var showUnused = false
    @State private var selection: ModxPart.ID?
    @State private var editing: EditedPart?

    struct EditedPart: Identifiable { let id: Int }

    var body: some View {
        let c = model.common
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name.isEmpty ? "—" : c.name).font(.largeTitle.weight(.semibold))
                    Text("Tempo \(c.tempo) · Volume \(c.volume) · \(model.partsInUse.count) Parts in use")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
                    Card(title: "Common", systemImage: "slider.horizontal.3") {
                        ForEach(ModxParams.common.filter { $0.group == "Performance" || $0.group == "Portamento" }) {
                            ParamRow(model: model, param: $0, target: .common)
                        }
                    }
                    Card(title: "Effects", systemImage: "sparkles") {
                        ForEach([(ModxTarget.reverb, ModxParams.reverb), (.variation, ModxParams.variation)], id: \.0) { target, params in
                            ForEach(params) { ParamRow(model: model, param: $0, target: target) }
                            Divider()
                        }
                        ParamRow(model: model, param: ModxParams.insertion[0], target: .insertionA, label: "Insertion A (A/D Part)")
                        ParamRow(model: model, param: ModxParams.insertion[0], target: .insertionB, label: "Insertion B (A/D Part)")
                        ParamRow(model: model, param: ModxParams.masterEffect[0], target: .masterEffect)
                        if !model.commonDetailLoaded {
                            Text("Reading the Performance's effects…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Card(title: "Assignable Knobs", systemImage: "dial.medium") {
                        ForEach(0..<8, id: \.self) { k in
                            let name = k < c.knobNames.count && !c.knobNames[k].isEmpty ? c.knobNames[k] : "Knob \(k + 1)"
                            ParamRow(model: model, param: ModxParams.common.first { $0.key == "com.knob\(k + 1)" }!, target: .common,
                                     label: "\(k + 1)  \(name)")
                            ParamRow(model: model, param: ModxParams.common.first { $0.key == "com.knob\(k + 1)CC" }!, target: .common,
                                     label: "     sends")
                        }
                    }
                }
                DisclosureGroup("Tone offsets, switches and controller numbers") {
                    ParamGroups(model: model, target: .common,
                                params: ModxParams.common.filter { !["Performance", "Portamento", "Assignable Knobs"].contains($0.group) })
                        .padding(.top, 8)
                }
                HStack {
                    Text("Parts").font(.title2.weight(.semibold))
                    Spacer()
                    Toggle("Show unused Parts", isOn: $showUnused).toggleStyle(.checkbox)
                    Button("Edit Part…") { if let s = selection { editing = EditedPart(id: s) } }
                        .disabled(selection == nil)
                        .help("Every setting of the selected Part (double-click a row, too)")
                }
                PartsTable(parts: showUnused ? model.parts : model.partsInUse, selection: $selection) { editing = EditedPart(id: $0) }
                    .frame(minHeight: CGFloat((showUnused ? 16 : max(model.partsInUse.count, 1)) * 28 + 60))
            }
            .padding(18)
        }
        .sheet(item: $editing) { PartEditor(model: model, part: $0.id) }
    }
}

private struct PartsTable: View {
    let parts: [ModxPart]
    @Binding var selection: ModxPart.ID?
    let open: (Int) -> Void

    var body: some View {
        Table(parts, selection: $selection) {
            TableColumn("#") { (part: ModxPart) in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Modx.partColors[part.index % 16]).frame(width: 4, height: 14)
                    Text("\(part.number)").monospacedDigit()
                }
            }
            .width(38)
            TableColumn("Name") { (part: ModxPart) in
                Text(part.inUse ? part.name : "(unused)").foregroundStyle(part.inUse ? .primary : .secondary)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Category") { (part: ModxPart) in Text(part.category) }.width(min: 110, ideal: 150)
            TableColumn("Type") { (part: ModxPart) in
                Text(part.type == .awm2 ? "AWM2 · \(part.elementsOn) el" : part.type.rawValue)
            }
            .width(80)
            TableColumn("State") { (part: ModxPart) in
                HStack(spacing: 6) {
                    Image(systemName: part.partSwitch ? "power.circle.fill" : "power.circle").help(part.partSwitch ? "Part on" : "Part off")
                    Image(systemName: part.keyboardControl ? "pianokeys" : "pianokeys.inverse").opacity(part.keyboardControl ? 1 : 0.3)
                    if part.mute { Image(systemName: "speaker.slash.fill").help("Muted") }
                }
                .foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Keys") { (part: ModxPart) in Text(part.noteRange).monospacedDigit() }.width(86)
            TableColumn("Velocity") { (part: ModxPart) in Text(part.velocityRange).monospacedDigit() }.width(64)
            TableColumn("Volume · Pan") { (part: ModxPart) in Text("\(part.volume) · \(ModxNames.pan(part.pan))").monospacedDigit() }
                .width(84)
            TableColumn("Reverb · Variation") { (part: ModxPart) in Text("\(part.reverbSend) · \(part.variationSend)").monospacedDigit() }
                .width(112)
            TableColumn("Output · Mode") { (part: ModxPart) in
                Text("\(part.outputName) · \(part.monoPoly == 0 ? "Mono" : "Poly") · shift \(ModxNames.signed(part.noteShift))")
                    .help("Receives: \(part.receives)")
            }
            .width(min: 150, ideal: 190)
        }
        .contextMenu(forSelectionType: ModxPart.ID.self) { ids in
            if let id = ids.first { Button("Edit Part \(id + 1)…") { open(id) } }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
    }
}

// MARK: System

struct SystemView: View {
    let model: ModxModel

    var body: some View {
        if model.system == nil {
            ContentUnavailableView(model.connected ? "Reading System settings…" : "No MODX connected", systemImage: "gearshape.2")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ParamGroups(model: model, target: .system)
                    ParamGroups(model: model, target: .sequencer)
                    Text("Every value comes from the MODX's System block (00 00 00) and Sequencer block (00 05 00); the grey numbers are each setting's address in the MODX Data List. System changes take effect on the MODX at once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
            }
        }
    }
}

// MARK: User data

struct UserDataView: View {
    let model: ModxModel
    @State private var editingCurve: EditedCurve?

    struct EditedCurve: Identifiable { let id: Int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("User Curves").font(.title2.weight(.semibold))
                if model.curves.isEmpty {
                    Text(model.connected ? "Reading…" : "No MODX connected").foregroundStyle(.secondary)
                } else if model.editsUnlocked {
                    Text("Click a curve to change it.").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(model.curves) { curve in
                        VStack(alignment: .leading, spacing: 4) {
                            CurvePreview(curve: curve).frame(height: 70)
                            Text("\(curve.number)  \(curve.name)").font(.caption.weight(.medium)).lineLimit(1)
                            Text(curve.step ? "Step" : "Linear").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { if model.editsUnlocked { editingCurve = EditedCurve(id: curve.number - 1) } }
                    }
                }
                Text("Micro-Tuning User Tables").font(.title2.weight(.semibold)).padding(.top, 8)
                ForEach(0..<8, id: \.self) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        ParamRow(model: model, param: ModxParams.name[0], target: .microTuningName(n), label: "Table \(n + 1)")
                        if model.data(.microTuningTable(n)) != nil {
                            DisclosureGroup("Tuning, cents per note") {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 4) {
                                    ForEach(ModxParams.microTuning) {
                                        ParamRow(model: model, param: $0, target: .microTuningTable(n), showAddress: false)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(18)
        }
        .sheet(item: $editingCurve) { CurveEditor(model: model, number: $0.id) }
    }
}
