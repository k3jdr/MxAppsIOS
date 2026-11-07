//
//  EditorViews.swift — MxModxUSB
//
//  Editing the MODX's settings. One row type serves every setting in ModxParams: it shows the value, and while
//  changes are unlocked it edits it with the control that suits it — a menu for named values, effect types and
//  controller numbers, a switch for on/off, a stepper (and slider) for numbers, a field for names.
//

import SwiftUI

struct ParamRow: View {
    let model: ModxModel
    let param: ModxParam
    let target: ModxTarget
    var label: String?
    var showAddress = true

    @State private var confirming: Int?

    private var current: Int? { model.value(param, target) }
    private var editable: Bool { model.canEdit(param, target) }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label ?? param.name).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 10)
            if editable { editor } else {
                HStack(spacing: 4) {
                    Text(valueText).fontWeight(.medium).textSelection(.enabled)
                    unitLabel
                }
            }
            if showAddress {
                Text(String(format: "%02X %02X %02X", target.base.high, target.base.mid, param.offset))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .help(help)
        .quickHelp(label ?? param.name, quickHelpDetail, symbol: "slider.horizontal.3")
        .confirmationDialog("Change \(param.name)?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Change It") { if let v = confirming { model.set(param, target, to: v) }; confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(param.warning ?? "")
        }
    }

    /// The value's unit or scale, beside it ("of 99", "ratio").
    @ViewBuilder private var unitLabel: some View {
        if let unit = param.unit, !param.isText {
            Text(unit).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var valueText: String {
        if param.isText { return model.text(param, target).map { $0.isEmpty ? "—" : $0 } ?? "—" }
        return current.map(param.display) ?? "—"
    }

    private var help: String {
        var text = "\(param.name), \(target.title)"
        if !param.applies(to: partOfTarget) { text += " — not available for this Part" }
        else if model.editsUnlocked && model.data(target) == nil { text += " — not read from the MODX yet" }
        else if !model.editsUnlocked { text += " — unlock changes to edit" }
        return text
    }

    private var quickHelpDetail: String {
        var parts = ["\(target.title), address \(String(format: "%02X %02X %02X", target.base.high, target.base.mid, target.base.low + UInt8(param.offset))) in the Data List."]
        if !param.isText {
            let unit = param.unit.map { " " + $0 } ?? ""
            parts.append("Values \(param.display(param.range.lowerBound)) to \(param.display(param.range.upperBound))\(unit); now \(valueText)\(unit).")
        }
        if let warning = param.warning { parts.append(warning) }
        if editable { parts.append(target.isEditBuffer ? "Changes go to the MODX's edit buffer and are read back." : "Changes take effect on the MODX at once and are read back.") }
        else { parts.append(help.contains("—") ? String(help.split(separator: "—").last ?? "").trimmingCharacters(in: .whitespaces).capitalizedFirst + "." : "") }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var partOfTarget: ModxPart? {
        target.partIndex.map { model.parts[$0] }
    }

    private func send(_ value: Int) {
        if param.warning != nil { confirming = value } else { model.set(param, target, to: value) }
    }

    private var binding: Binding<Int> {
        Binding(get: { current ?? param.range.lowerBound }, set: { send($0) })
    }

    @ViewBuilder private var editor: some View {
        switch param.format {
        case .text:
            NameField(model: model, param: param, target: target)
        case .onOff:
            Toggle("", isOn: Binding(get: { (current ?? 0) != 0 }, set: { send($0 ? 1 : 0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        case .effect(let slot):
            Picker("", selection: binding) {
                ForEach(categories(slot), id: \.self) { category in
                    Section(category) {
                        ForEach(ModxEffects.allowed(slot).filter { $0.category == category }) { Text($0.name).tag($0.value) }
                    }
                }
            }
            .labelsHidden().fixedSize()
        case .names, .choices, .cc:
            Picker("", selection: binding) {
                ForEach(param.allowedValues, id: \.self) { Text(param.display($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        default:
            HStack(spacing: 6) {
                if param.range.count > 16 {
                    Slider(value: Binding(get: { Double(current ?? param.range.lowerBound) }, set: { send(Int($0.rounded())) }),
                           in: Double(param.range.lowerBound)...Double(param.range.upperBound))
                        .frame(width: 110).controlSize(.mini)
                }
                HStack(spacing: 4) {
                    Text(valueText).monospacedDigit()
                    unitLabel
                }
                .frame(minWidth: param.unit == nil ? 64 : 92, alignment: .trailing)
                Stepper("", value: binding, in: param.range).labelsHidden()
            }
        }
    }

    private func categories(_ slot: ModxEffectSlot) -> [String] {
        var seen: [String] = []
        for t in ModxEffects.allowed(slot) where !seen.contains(t.category) { seen.append(t.category) }
        return seen
    }
}

/// A 20-character name, sent when you press Return or leave the field. It follows the MODX (an undo, a re-read)
/// unless you've typed something not yet sent.
struct NameField: View {
    let model: ModxModel
    let param: ModxParam
    let target: ModxTarget
    /// Without its border and at the width it's given (inside a NameCombo).
    var plain = false
    @State private var text = ""
    @State private var committed = ""
    @FocusState private var focused: Bool

    @ViewBuilder private var field: some View {
        if plain {
            TextField("Name", text: $text).textFieldStyle(.plain)
        } else {
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 190)
        }
    }

    var body: some View {
        field
            .focused($focused)
            .onAppear { text = model.text(param, target) ?? ""; committed = text }
            .onChange(of: model.text(param, target)) { _, new in
                if !focused || text == committed { text = new ?? ""; committed = text }
            }
            .onChange(of: text) { _, new in
                let clean = String(new.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(20).map(Character.init))
                if clean != new { text = clean }
            }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard text != committed else { return }   // nothing typed since the last send or update
        committed = text
        if text != (model.text(param, target) ?? "") { model.set(param, target, text: text) }
    }
}

/// Settings of one block, grouped as the parameter table groups them.
struct ParamGroups: View {
    let model: ModxModel
    let target: ModxTarget
    var params: [ModxParam]? = nil
    var columns = 2

    var body: some View {
        let list = params ?? target.params
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns), spacing: 16) {
            ForEach(groups(list), id: \.0) { group, rows in
                Card(title: group) {
                    ForEach(rows) { param in ParamRow(model: model, param: param, target: target) }
                }
            }
        }
    }

    private func groups(_ params: [ModxParam]) -> [(String, [ModxParam])] {
        var order: [String] = []
        var map: [String: [ModxParam]] = [:]
        for p in params {
            if map[p.group] == nil { order.append(p.group) }
            map[p.group, default: []].append(p)
        }
        return order.map { ($0, map[$0]!) }
    }
}

/// Every setting of one Part, in a sheet.
struct PartEditor: View {
    let model: ModxModel
    let part: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = model.parts[part]
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RoundedRectangle(cornerRadius: 3).fill(Modx.partColors[part % 16]).frame(width: 6, height: 30)
                VStack(alignment: .leading) {
                    Text("Part \(part + 1)  \(info.inUse ? info.name : "(unused)")").font(.title2.weight(.semibold))
                    Text("\(info.category) · \(info.type.rawValue)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if model.data(.part(part)) == nil {
                ContentUnavailableView("Reading Part \(part + 1)…", systemImage: "hourglass").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SubCategoryRow(model: model, part: part)
                        ParamGroups(model: model, target: .part(part), params: ModxParams.part.filter { $0.key != "part.sub" })
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { model.ensurePartBlock(part) }
    }
}

/// The Part's sub category, named for its main category.
private struct SubCategoryRow: View {
    let model: ModxModel
    let part: Int

    var body: some View {
        let param = ModxParams.part.first { $0.key == "part.sub" }!
        let main = Int(model.parts[part].mainCategory)
        let names = main < 16 ? ModxNames.subCategories[main] : []
        HStack {
            Text("Sub Category").foregroundStyle(.secondary)
            Spacer()
            if model.canEdit(param, .part(part)), !names.isEmpty {
                Picker("", selection: Binding(get: { model.value(param, .part(part)) ?? 0 },
                                              set: { model.set(param, .part(part), to: $0) })) {
                    ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
                }
                .labelsHidden().fixedSize()
            } else {
                Text(model.parts[part].category).fontWeight(.medium)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
    }
}

/// A Live Set slot's settings, in a popover.
struct SlotEditor: View {
    let model: ModxModel
    let page: Int
    let slot: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page \(page + 1), Slot \(slot + 1)").font(.headline)
            if let s = model.liveSet?.slots.first(where: { $0.page == page && $0.slot == slot }) {
                ValueRow(name: "Performance", value: model.performanceName(for: s).map { $0.source == .seen ? "\($0.name) (as last seen)" : $0.name }
                         ?? "Not known — choose the slot on the MODX once")
            }
            ForEach(ModxParams.slot) { ParamRow(model: model, param: $0, target: .liveSetSlot(page: page, slot: slot), showAddress: false) }
            Text("Goes to the MODX's Live Set edit buffer: store the Live Set on the MODX to keep it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 400)
    }
}

/// A user curve's name, type and points, in a sheet.
struct CurveEditor: View {
    let model: ModxModel
    let number: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("User Curve \(number + 1)").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let curve = model.curves.first(where: { $0.number == number + 1 }) {
                CurvePreview(curve: curve).frame(height: 140)
            }
            ParamGroups(model: model, target: .curve(number))
        }
        .padding(16)
        .frame(width: 760)
    }
}

struct CurvePreview: View {
    let curve: ModxUserCurve

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Color(white: 0.12)))
            var path = Path()
            for (i, (x, y)) in zip(curve.inputs, curve.outputs).enumerated() {
                let point = CGPoint(x: CGFloat(x) / 127 * size.width, y: size.height - CGFloat(y) / 127 * size.height)
                if i == 0 { path.move(to: point) } else if curve.step {
                    path.addLine(to: CGPoint(x: point.x, y: path.currentPoint?.y ?? point.y))
                    path.addLine(to: point)
                } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Modx.live), lineWidth: 1.8)
        }
    }
}

/// The strip shown while changes are unlocked: what happens to them, and the last change's result.
struct EditBanner: View {
    let model: ModxModel

    var body: some View {
        if model.editsUnlocked {
            HStack(spacing: 10) {
                Image(systemName: "lock.open.fill").foregroundStyle(.orange)
                Text("Changes go to the MODX as you make them. Performance, Part, effect and Live Set changes land in its edit buffer — press STORE on the MODX to keep them. ⌥⌘Z undoes the last change.")
                    .font(.caption).lineLimit(2)
                Spacer()
                if let status = model.editStatus { Text(status).font(.caption.weight(.medium)).lineLimit(2) }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.orange.opacity(0.12))
        }
    }
}


extension String {
    /// The string with its first letter capitalized.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
