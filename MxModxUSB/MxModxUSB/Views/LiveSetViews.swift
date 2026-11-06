//
//  LiveSetViews.swift — MxModxUSB
//
//  The Live Set screen, laid out like the MODX's own: a top row with the bank and page names, each a drop-down (the
//  bank menu offers the MODX's bank and the banks kept in workspace files; the page menu the bank's 16 pages) that
//  can also be typed in to rename it while changes are unlocked, and Refresh at the far right; below, the page's 16
//  slots, each shown by the name of the Performance it recalls, as the MODX shows them.
//

import SwiftUI

struct LiveSetView: View {
    let model: ModxModel
    @State private var page = 0
    @State private var openSlot: Int?
    /// The workspace file whose bank is shown; nil for the MODX's own.
    @State private var shownFile: URL?
    @State private var confirmSend = false
    @State private var sending = false
    @State private var report: String?
    /// A slot waiting for "Choose it anyway" (the Performance has changes made here that aren't stored).
    @State private var confirmSlot: ModxLiveSlot?
    @State private var selectNote: String?

    private var fileBank: ModxWorkspaceLiveSet? {
        shownFile.flatMap { url in model.workspaceLiveSets.first { $0.url == url } }
    }
    private var onMODX: Bool { shownFile == nil }
    private var shown: ModxLiveSet? { onMODX ? model.liveSet : fileBank?.liveSet }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Divider()
            if let bank = fileBank { fileBanner(bank); Divider() }
            if let liveSet = shown {
                HStack(spacing: 0) {
                    pageList(liveSet)
                    Divider()
                    slots(liveSet)
                }
            } else {
                ContentUnavailableView(model.connected ? "Reading the Live Set…" : "No MODX connected",
                                       systemImage: "square.grid.4x3.fill",
                                       description: Text(model.workspaceLiveSets.isEmpty ? ""
                                                         : "The Bank menu has Live Set banks from workspace files."))
                    .frame(maxHeight: .infinity)
            }
        }
        .task { await model.findWorkspaceLiveSets() }
        .onAppear { if let current = model.currentSlot { page = current.page } }
        .onChange(of: model.workspaceLiveSets) { _, banks in
            if let shownFile, !banks.contains(where: { $0.url == shownFile }) { self.shownFile = nil }
        }
        .alert("Send this Live Set bank to the MODX?", isPresented: $confirmSend) {
            Button("Send") { send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(fileBank?.liveSet.bankName ?? "")” from \(fileBank?.fileName ?? "the workspace") replaces the Live Set in the MODX's edit buffer — its bank name, 16 page names and 256 slots. The MODX keeps it only if you store it there. Everything sent is read back and compared.")
        }
        .alert("Live Set sent", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK") { report = nil }
        } message: {
            Text(report ?? "")
        }
        .alert("Choose another slot?", isPresented: Binding(get: { confirmSlot != nil }, set: { if !$0 { confirmSlot = nil } })) {
            Button("Choose It") { if let slot = confirmSlot { model.selectLiveSetSlot(slot) }; confirmSlot = nil }
            Button("Cancel", role: .cancel) { confirmSlot = nil }
        } message: {
            Text("“\(model.common.name)” has changes made here that aren't stored on the MODX. Choosing another slot replaces it, and they're lost.")
        }
    }

    /// Clicking a slot of the MODX's own bank plays it, as touching it on the MODX does.
    private func choose(_ slot: ModxLiveSlot) {
        if slot.isEmpty { selectNote = "Slot \(slot.slot + 1) is empty."; return }
        if let problem = model.liveSetSelectProblem { selectNote = problem; return }
        selectNote = nil
        openSlot = nil
        if model.hasUnstoredPerformanceEdits { confirmSlot = slot } else { model.selectLiveSetSlot(slot) }
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 10) {
            Text("Bank").foregroundStyle(.secondary)
            NameCombo(model: model, target: onMODX ? .liveSetBank : nil, shown: shown?.bankName ?? "",
                      placeholder: model.connected ? "Reading…" : "No Live Set", width: 260,
                      help: "The Live Set bank: the MODX's own, or one kept in a workspace file. Unlocked, type here to rename the MODX's bank.") {
                bankMenu
            }
            Text("Page").foregroundStyle(.secondary).padding(.leading, 8)
            NameCombo(model: model, target: onMODX ? .liveSetPage(page) : nil, shown: shown.map { pageName($0, page) } ?? "",
                      placeholder: "—", width: 240,
                      help: "The page shown. Unlocked, type here to rename it on the MODX.") {
                Picker("Page", selection: $page) {
                    ForEach(0..<16, id: \.self) { p in
                        Text("\(p + 1)   \(shown.map { pageName($0, p) } ?? "Page \(p + 1)")").tag(p)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(shown == nil)
            Spacer(minLength: 12)
            Button {
                Task { await model.refreshLiveSet() }
            } label: {
                HStack(spacing: 5) {
                    if model.liveSetRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    Text("Refresh")
                }
            }
            .disabled(model.liveSetRefreshing)
            .help("Reads the MODX's Live Set again (after choosing another bank on the MODX, say) and looks for workspace files again")
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var bankMenu: some View {
        Section("On the MODX") {
            Toggle(isOn: Binding(get: { onMODX }, set: { if $0 { shownFile = nil } })) {
                Text(model.liveSet.map { $0.bankName.isEmpty ? "(no name)" : $0.bankName } ?? "Not read yet")
                Text("The bank in use on the MODX")
            }
            .disabled(model.liveSet == nil)
        }
        Section("In workspace files") {
            if model.workspaceLiveSets.isEmpty {
                Text("None found in Documents or recent files").disabled(true)
            }
            ForEach(model.workspaceLiveSets) { bank in
                Toggle(isOn: Binding(get: { shownFile == bank.url }, set: { if $0 { shownFile = bank.url } })) {
                    Text(bank.liveSet.bankName.isEmpty ? "(no name)" : bank.liveSet.bankName)
                    Text("\(bank.fileName) · \(bank.savedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
        Divider()
        Button("Choose a Workspace File…") {
            if let url = model.chooseWorkspaceLiveSet() { shownFile = url }
        }
    }

    private func fileBanner(_ bank: ModxWorkspaceLiveSet) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext").foregroundStyle(Modx.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("From the workspace “\(bank.fileName)”, saved \(bank.savedAt.formatted(date: .abbreviated, time: .shortened))"
                     + (bank.model.isEmpty ? "" : " from a \(bank.model)\(bank.firmware.isEmpty ? "" : " on firmware \(bank.firmware)")") + ".")
                    .font(.callout.weight(.medium))
                Text(sendHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if sending { ProgressView().controlSize(.small) }
            Button("Send to MODX…") { confirmSend = true }
                .disabled(!model.editsUnlocked || !model.connected || sending || model.workspaceBusy != nil)
            Button("Show the MODX's Bank") { shownFile = nil }
                .disabled(model.liveSet == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Modx.accent.opacity(0.08))
    }

    private var sendHint: String {
        if !model.connected { return "This bank isn't on the MODX. Connect the MODX to send it there." }
        if !model.editsUnlocked { return "This bank isn't on the MODX. Unlock changes (the lock in the toolbar) to send it to the MODX's Live Set edit buffer." }
        return "This bank isn't on the MODX. Send it to put it in the MODX's Live Set edit buffer."
    }

    private func send() {
        guard let bank = fileBank else { return }
        sending = true
        Task {
            let result = await model.sendLiveSet(bank)
            sending = false
            shownFile = nil
            report = result
        }
    }

    // MARK: Pages and slots

    private func pageName(_ liveSet: ModxLiveSet, _ p: Int) -> String {
        liveSet.pageNames[p].isEmpty ? "Page \(p + 1)" : liveSet.pageNames[p]
    }

    private func pageList(_ liveSet: ModxLiveSet) -> some View {
        List(selection: Binding(get: { page }, set: { page = $0 ?? 0 })) {
            Section(liveSet.bankName.isEmpty ? "Live Set" : liveSet.bankName) {
                ForEach(0..<16, id: \.self) { p in
                    HStack {
                        Text("\(p + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                        Text(pageName(liveSet, p))
                    }
                    .tag(p)
                }
            }
        }
        .frame(width: 230)
    }

    private func slots(_ liveSet: ModxLiveSet) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(pageName(liveSet, page)).font(.title2.weight(.semibold))
                Text(caption(liveSet)).font(.callout).foregroundStyle(.secondary)
                if let selectNote {
                    Label(selectNote, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(liveSet.slots(onPage: page)) { slot in
                        SlotTile(slot: slot, performance: model.performanceName(for: slot),
                                 current: onMODX && model.currentSlot?.id == slot.id,
                                 choosing: onMODX && model.selectingSlot == slot.id,
                                 showDetails: { openSlot = slot.id })
                            .onTapGesture { if onMODX { choose(slot) } else { openSlot = slot.id } }
                            .contextMenu {
                                if onMODX {
                                    Button("Play This Slot") { choose(slot) }
                                        .disabled(slot.isEmpty || model.liveSetSelectProblem != nil || model.selectingSlot != nil)
                                }
                                Button(onMODX && model.editsUnlocked ? "Edit Slot…" : "Show Slot Details…") { openSlot = slot.id }
                            }
                            .popover(isPresented: Binding(get: { openSlot == slot.id }, set: { if !$0 { openSlot = nil } })) {
                                VStack(alignment: .leading, spacing: 0) {
                                    if onMODX && model.editsUnlocked {
                                        SlotEditor(model: model, page: slot.page, slot: slot.slot)
                                    } else {
                                        SlotInfo(slot: slot, performance: model.performanceName(for: slot), onMODX: onMODX)
                                    }
                                    if onMODX && !slot.isEmpty {
                                        Divider()
                                        HStack {
                                            if let problem = model.liveSetSelectProblem {
                                                Text(problem).font(.caption).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer()
                                            Button("Play This Slot") { choose(slot) }
                                                .keyboardShortcut(.defaultAction)
                                                .disabled(model.liveSetSelectProblem != nil || model.selectingSlot != nil)
                                        }
                                        .padding(14)
                                    }
                                }
                            }
                    }
                }
            }
            .padding(18)
        }
    }

    private func caption(_ liveSet: ModxLiveSet) -> String {
        let place = "“\(liveSet.bankName)” · page \(page + 1) of 16"
        if !onMODX { return "\(place) · from a workspace file · click a slot to see it" }
        return model.editsUnlocked ? "\(place) · the bank in use on the MODX · click a slot to play it, ⓘ to change it"
            : "\(place) · the bank in use on the MODX · click a slot to play it, ⓘ for its settings"
    }
}

/// A name with a drop-down beside it, like the MODX's own Live Set screen: the menu chooses, typing renames (while
/// `target` can be edited); otherwise the whole box opens the menu.
struct NameCombo<Items: View>: View {
    let model: ModxModel
    let target: ModxTarget?
    let shown: String
    let placeholder: String
    let width: CGFloat
    let help: String
    @ViewBuilder let items: () -> Items

    private var editable: Bool { target.map { model.canEdit(ModxParams.name[0], $0) } ?? false }

    var body: some View {
        Group {
            if editable, let target {
                HStack(spacing: 2) {
                    NameField(model: model, param: ModxParams.name[0], target: target, plain: true)
                        .id(target)   // a fresh field for each page: typing never carries over to another
                    Menu { items() } label: { chevron }
                        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                }
            } else {
                Menu { items() } label: {
                    HStack {
                        Text(shown.isEmpty ? placeholder : shown).lineLimit(1)
                            .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                        Spacer(minLength: 4)
                        chevron
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(width: width, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .help(help)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// A slot as the MODX shows it: the name of the Performance it recalls, in the slot's colour.
private struct SlotTile: View {
    let slot: ModxLiveSlot
    let performance: (name: String, source: ModxPerformanceNames.Source)?
    let current: Bool
    /// Chosen from the app; the MODX is loading it.
    var choosing = false
    let showDetails: () -> Void

    /// Yellow, Sakura, Cream, Lime, Aqua, Beige, Mint and Lilac are light: dark text reads better on them.
    private var ink: Color { !slot.isEmpty && [2, 9, 10, 11, 12, 13, 14, 15].contains(slot.color) ? .black : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(slot.slot + 1)").font(.caption.monospacedDigit()).foregroundStyle(ink.opacity(0.7))
                Spacer()
                if choosing {
                    ProgressView().controlSize(.mini).tint(ink)
                } else if current {
                    Text("CURRENT").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(Modx.live)
                }
                Button(action: showDetails) {
                    Image(systemName: "info.circle").foregroundStyle(ink.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("The slot's settings")
            }
            Group {
                if slot.isEmpty { Text("—") }
                else if let performance { Text(performance.name) }
                else { Text(slot.name).italic() }   // a User or Library Performance the app hasn't seen: the slot's own name
            }
            .font(.callout.weight(.semibold)).foregroundStyle(ink)
            .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Text(slot.isEmpty ? " " : "\(slot.bankName) · #\(slot.number) · vol \(slot.volume)")
                .font(.caption2).foregroundStyle(ink.opacity(0.75))
        }
        .padding(10)
        .background(Modx.slotColor(slot.color).opacity(slot.isEmpty ? 0.25 : 0.8).gradient, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(current ? Modx.live : .clear, lineWidth: 2.5))
        .opacity(slot.on || slot.isEmpty ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(help)
    }

    private var help: String {
        if slot.isEmpty { return "Empty slot" }
        let place = "\(slot.bankName), Performance \(slot.number)"
        switch performance?.source {
        case .preset?: return "\(performance!.name) — \(place). Slot name “\(slot.name)”, \(slot.colorName)."
        case .seen?: return "\(performance!.name) (as last seen on the MODX) — \(place). Slot name “\(slot.name)”, \(slot.colorName)."
        case nil: return "Slot name “\(slot.name)” — \(place), \(slot.colorName). The MODX doesn't report this Performance's name over USB; choose the slot on the MODX once and the app learns it."
        }
    }
}

/// A slot's settings, to look at (a locked or workspace bank).
struct SlotInfo: View {
    let slot: ModxLiveSlot
    let performance: (name: String, source: ModxPerformanceNames.Source)?
    let onMODX: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page \(slot.page + 1), Slot \(slot.slot + 1)").font(.headline)
            if slot.isEmpty {
                Text("Empty slot").foregroundStyle(.secondary)
            } else {
                ValueRow(name: "Performance", value: performance.map { $0.source == .seen ? "\($0.name) (as last seen)" : $0.name } ?? "Not known")
                ValueRow(name: "Slot Name", value: slot.name)
                ValueRow(name: "Recalls", value: slot.bankMSB == 63 ? "One Part (MSB 63)" : "Performance (MSB 64)")
                ValueRow(name: "Bank", value: slot.bankName)
                ValueRow(name: "Performance Number", value: "\(slot.number)")
                ValueRow(name: "Color", value: slot.colorName)
                ValueRow(name: "Volume", value: "\(slot.volume)")
                ValueRow(name: "Slot Switch", value: slot.on ? "On" : "Off")
            }
            Text(onMODX ? "Unlock changes to edit the slot on the MODX." : "From a workspace file: send the bank to the MODX to use it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
    }
}
