//
//  Sheets.swift
//  MxNoteONE
//
//  Dialogs shown over the main window.
//

import SwiftUI

struct SheetView: View {
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .newNotebook: NewNotebookSheet()
        case .renameNotebook(let id): RenameSheet(target: .notebook(id))
        case .renameNode(let ref): RenameSheet(target: .node(ref))
        case .password(let ref, let mode): PasswordSheet(ref: ref, mode: mode)
        case .movePage(let ref): MovePageSheet(ref: ref)
        case .insertTable: InsertTableSheet()
        case .insertLink: LinkSheet()
        case .oneDriveOpen: OneDriveOpenSheet()
        case .notebookFonts(let id): NotebookFontsSheet(notebookID: id)
        }
    }
}

/// Title, content and OK / Cancel buttons.
private struct DialogFrame<Content: View>: View {
    let title: String
    let okTitle: String
    let okDisabled: Bool
    let ok: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, okTitle: String = "OK", okDisabled: Bool = false, ok: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.okTitle = okTitle
        self.okDisabled = okDisabled
        self.ok = ok
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(okTitle) {
                    ok()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(okDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Notebook"
    @State private var color: NoteColor = .blue
    @State private var folder = Prefs.notebooksFolder

    var body: some View {
        DialogFrame("New Notebook", okTitle: "Create", okDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
            NotebookStore.shared.createNotebook(name: name.trimmingCharacters(in: .whitespaces), color: color, in: folder)
            dismiss()
        } content: {
            Form {
                TextField("Name:", text: $name)
                Picker("Color:", selection: $color) {
                    ForEach(NoteColor.allCases) { color in
                        Label { Text(color.title) } icon: { Image(nsImage: Palette.swatch(color.nsColor)) }
                            .tag(color)
                    }
                }
                LabeledContent("Location:") {
                    HStack {
                        Text(folder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path(percentEncoded: false))
                        Spacer()
                        Menu("Choose") {
                            Button("Documents") { folder = Prefs.notebooksFolder }
                            ForEach(Prefs.oneDriveFolders, id: \.self) { url in
                                Button(url.lastPathComponent.replacingOccurrences(of: "OneDrive-", with: "OneDrive – ")) {
                                    folder = url.appending(path: "MxNoteONE Notebooks", directoryHint: .isDirectory)
                                }
                            }
                            Divider()
                            Button("Other Folder…") { chooseFolder() }
                        }
                        .fixedSize()
                    }
                }
            }
            Text("Tip: put the notebook in your OneDrive folder to use it on your other Macs, or use File ▸ OneDrive ▸ Save Notebook to OneDrive to open it in Microsoft OneNote.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

struct RenameSheet: View {
    enum Target {
        case notebook(UUID)
        case node(SectionRef)
    }

    let target: Target
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var store: NotebookStore { .shared }

    private var title: String {
        switch target {
        case .notebook: return "Rename Notebook"
        case .node(let ref): return store.node(ref)?.isGroup == true ? "Rename Section Group" : "Rename Section"
        }
    }

    var body: some View {
        DialogFrame(title, okTitle: "Rename", okDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            switch target {
            case .notebook(let id): store.renameNotebook(id, to: trimmed)
            case .node(let ref): store.renameNode(ref, to: trimmed)
            }
            dismiss()
        } content: {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
        }
        .onAppear {
            switch target {
            case .notebook(let id): name = store.notebook(id)?.name ?? ""
            case .node(let ref): name = store.node(ref)?.name ?? ""
            }
        }
    }
}

struct PasswordSheet: View {
    let ref: SectionRef
    let mode: PasswordMode
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var error = ""

    private var store: NotebookStore { .shared }
    private var sectionName: String { store.node(ref)?.name ?? "Section" }

    private var title: String {
        switch mode {
        case .set: "Password Protect “\(sectionName)”"
        case .change: "Change Password for “\(sectionName)”"
        case .remove: "Remove Password from “\(sectionName)”"
        case .unlock: "Unlock “\(sectionName)”"
        }
    }

    private var needsCurrent: Bool { mode != .set }
    private var needsNew: Bool { mode == .set || mode == .change }

    var body: some View {
        DialogFrame(title, okTitle: mode == .unlock ? "Unlock" : "OK",
                    okDisabled: (needsCurrent && current.isEmpty) || (needsNew && password.isEmpty)) {
            submit()
        } content: {
            Form {
                if needsCurrent {
                    SecureField(mode == .unlock ? "Password:" : "Current password:", text: $current)
                }
                if needsNew {
                    SecureField("New password:", text: $password)
                    SecureField("Confirm:", text: $confirm)
                    TextField("Hint (optional):", text: $hint)
                }
            }
            if needsNew {
                Text("The section's pages, pictures and files are encrypted. If you forget the password, nobody — not even MxNoteONE — can recover them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        if needsCurrent {
            guard let protection = store.node(ref)?.protection,
                  NoteCrypto.unlock(protection, password: current) != nil else {
                let hintText = store.node(ref)?.protection?.hint ?? ""
                error = "The password is not correct." + (hintText.isEmpty ? "" : " Hint: \(hintText)")
                return
            }
            if store.isLocked(ref) { _ = store.unlock(ref, password: current) }
        }
        if needsNew {
            guard password == confirm else {
                error = "The passwords don't match."
                return
            }
            guard store.setPassword(ref, password: password, hint: hint) else { return }
        }
        if mode == .remove { store.removePassword(ref) }
        dismiss()
    }
}

struct MovePageSheet: View {
    let ref: PageRef
    @Environment(\.dismiss) private var dismiss
    @State private var destination: SectionRef?

    private var store: NotebookStore { .shared }

    var body: some View {
        DialogFrame("Move or Copy “\(store.meta(ref)?.displayTitle ?? "Page")”", okTitle: "Move",
                    okDisabled: destination == nil || destination == ref.section) {
            if let destination { store.movePage(ref, to: destination, copy: false) }
            dismiss()
        } content: {
            List(selection: $destination) {
                ForEach(store.notebooks) { notebook in
                    Section(notebook.name) {
                        ForEach(notebook.manifest.sections.flattenedSections) { node in
                            let sectionRef = SectionRef(notebookID: notebook.id, sectionID: node.id)
                            HStack {
                                RoundedRectangle(cornerRadius: 2).fill(node.color.color).frame(width: 9, height: 13)
                                Text(store.location(sectionRef).components(separatedBy: " › ").dropFirst().joined(separator: " › "))
                                if store.isLocked(sectionRef) {
                                    Spacer()
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                }
                            }
                            .tag(sectionRef)
                            .selectionDisabled(store.isLocked(sectionRef))
                        }
                    }
                }
            }
            .frame(height: 280)
            HStack {
                Button("Copy") {
                    if let destination { store.movePage(ref, to: destination, copy: true) }
                    dismiss()
                }
                .disabled(destination == nil)
                Text("Copy keeps the page where it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 460)
    }
}

struct InsertTableSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 3
    @State private var columns = 3

    var body: some View {
        DialogFrame("Insert Table", okTitle: "Insert") {
            NotebookStore.shared.canvas?.insertTable(rows: rows, columns: columns)
            dismiss()
        } content: {
            Form {
                Stepper("Rows: \(rows)", value: $rows, in: 1...60)
                Stepper("Columns: \(columns)", value: $columns, in: 1...12)
            }
        }
    }
}

struct LinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var address = ""
    @State private var filter = ""
    @State private var page: PageRef?
    /// The hover text shown on the link's card.
    @State private var tip = NSAttributedString()
    @State private var tipBox = TipEditorBox()

    private var store: NotebookStore { .shared }

    private var pages: [(PageRef, String, String)] {
        var result: [(PageRef, String, String)] = []
        for notebook in store.notebooks {
            for node in notebook.manifest.sections.flattenedSections {
                for meta in notebook.sections[node.id]?.pages ?? [] {
                    let ref = PageRef(notebookID: notebook.id, sectionID: node.id, pageID: meta.id)
                    if filter.isEmpty || meta.displayTitle.localizedCaseInsensitiveContains(filter) {
                        result.append((ref, meta.displayTitle, notebook.name + " › " + node.name))
                    }
                }
            }
        }
        return result
    }

    private var url: URL? {
        if let page { return store.link(for: page) }
        return NoteRichText.url(fromAddress: address)
    }

    private var editing: Bool { store.linkExisting != nil }

    var body: some View {
        DialogFrame(editing ? "Edit Link" : "Link", okTitle: editing ? "Update" : "Insert", okDisabled: url == nil) {
            if let url, let tv = store.linkTextView {
                let title = text.isEmpty ? (page.flatMap { store.meta($0)?.displayTitle } ?? address) : text
                let hover = tip.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : tip
                if editing {
                    TextFormatter.replaceLink(url, title: title, in: tv, range: store.linkRange, tip: hover)
                } else {
                    TextFormatter.addLink(url, title: title, in: tv, range: store.linkRange, tip: hover)
                }
            }
            store.linkExisting = nil
            dismiss()
        } content: {
            Form {
                TextField("Text to display:", text: $text)
                    .help("The words shown for the link in your notes (leave empty to use the page's title or the address)")
                TextField("Address:", text: $address, prompt: Text("https://… or pick a page below"))
                    .onChange(of: address) { if !address.isEmpty { page = nil } }
                    .help("A web address (https://…), an email address, or a link copied with Copy Link to Page or Paragraph")
            }
            HStack {
                Text("Hover text — shown when the pointer rests on the link:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TipToolbar(box: tipBox)
            }
            TipEditor(text: $tip, box: tipBox)
                .frame(height: 64)
                .help("Your own description for the link's hover card (optional). Format it with the buttons or ⌘B ⌘I ⌘U; ⌘K (or the link button) links words in it, and addresses typed in it become links.")
            if let url {
                DisclosureGroup("Hover card preview") {
                    LinkCard(info: LinkInfo(url, tip: tip, text: text.isEmpty ? nil : text), edit: {}, copy: {}, remove: {}, preview: true)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .padding(.vertical, 4)
                }
                .font(.caption)
            }
            Text("Or link to a page in your notebooks:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter pages", text: $filter)
                .textFieldStyle(.roundedBorder)
                .help("Type part of a page's title to narrow the list")
            List(selection: $page) {
                ForEach(pages, id: \.0) { ref, title, location in
                    VStack(alignment: .leading) {
                        Text(title)
                        Text(location).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(ref)
                }
            }
            .frame(height: 150)
            .onChange(of: page) { if page != nil { address = "" } }
            .help("Pick a page to link to it (the link follows the page if it's renamed or moved)")
            if editing {
                Button("Remove Link", role: .destructive) {
                    if let tv = store.linkTextView {
                        tv.window?.makeFirstResponder(tv)
                        tv.setSelectedRange(store.linkRange)
                        TextFormatter.removeLink()
                    }
                    store.linkExisting = nil
                    dismiss()
                }
                .help("Keep the text, take the link off")
            }
        }
        .frame(width: 480)
        .onAppear {
            if let tv = store.linkTextView, let storage = tv.textStorage, store.linkRange.length > 0,
               NSMaxRange(store.linkRange) <= storage.length {
                text = (storage.string as NSString).substring(with: store.linkRange)
                // The link's hover text, to edit.
                if store.linkExisting != nil, let existing = NoteRichText.tip(in: storage, at: store.linkRange.location) {
                    tip = existing
                    tipBox.textView?.textStorage?.setAttributedString(existing)
                }
            }
            // Editing a link: its address (a link to a whole page shows as that page in the list).
            if let existing = store.linkExisting {
                if existing.query == nil, let ref = store.resolve(existing) {
                    page = ref
                    filter = ""
                } else {
                    address = existing.absoluteString
                }
            }
        }
        .onDisappear { store.linkExisting = nil }
    }
}
