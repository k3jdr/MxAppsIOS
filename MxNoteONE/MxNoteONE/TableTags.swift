//
//  TableTags.swift
//  MxNoteONE
//
//  Names and tags for tables, rows and cells, so notebook scripts can find
//  them on any page: Table ▸ Name & Tags (a name, unique in the notebook, and
//  tags like #expenses), Tag Rows and Tag Cells for the selection, and Copy
//  Python Reference (mx.table("Inventory")["B3"], mx.cell("grand-total")…).
//  Tagged cells show a small blue corner; tagged rows a blue mark at the left.
//

import AppKit

extension TableGridView {
    private var notebook: Notebook? {
        owner?.controller?.ref.flatMap { NotebookStore.shared.notebook($0.notebookID) }
    }

    /// Asks for a name and tags in a small dialog.
    private func ask(_ title: String, _ info: String, fields: [(label: String, value: String, placeholder: String)]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(fields.count) * 32))
        var inputs: [NSTextField] = []
        for (i, f) in fields.enumerated() {
            let y = CGFloat(fields.count - 1 - i) * 32
            let label = NSTextField(labelWithString: f.label)
            label.frame = NSRect(x: 0, y: y + 4, width: 60, height: 18)
            let field = NSTextField(frame: NSRect(x: 64, y: y, width: 236, height: 24))
            field.stringValue = f.value
            field.placeholderString = f.placeholder
            box.addSubview(label)
            box.addSubview(field)
            inputs.append(field)
        }
        alert.accessoryView = box
        alert.window.initialFirstResponder = inputs.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue }
    }

    private func committed(_ name: String) {
        model.checkpoint(name)
        model.changed()
        needsDisplay = true
        owner?.controller?.markDirty()
    }

    /// Table ▸ Name & Tags: the table's name (scripts: mx.table("Name")) and its tags (mx.tables(tag="…")).
    func editTableNameAndTags() {
        guard let answer = ask("Table Name & Tags",
                               "Scripts find a table by its name — mx.table(\"Inventory\") — or by a tag: mx.tables(tag=\"expenses\"). Names should be unique in the notebook.",
                               fields: [("Name", model.data.name ?? "", "Inventory"),
                                        ("Tags", (model.data.tags ?? []).map { "#" + $0 }.joined(separator: " "), "#expenses #weekly")]) else { return }
        let name = answer[0].trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let nb = notebook, let id = owner?.element.id {
            let clash = NotebookTables.others(named: name, except: id, in: nb)
            if !clash.isEmpty {
                let warn = NSAlert()
                warn.messageText = "Another table is called “\(name)”"
                warn.informativeText = "On \(clash.map { "“\($0.page)” (\($0.section))" }.joined(separator: ", ")). Scripts would find only one of them by name — give this one a different name, or use tags for a group of tables."
                warn.addButton(withTitle: "Use It Anyway")
                warn.addButton(withTitle: "Cancel")
                guard warn.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        model.data.name = name.isEmpty ? nil : name
        let tags = TableData.parseTags(answer[1])
        model.data.tags = tags.isEmpty ? nil : tags
        committed("Table Name & Tags")
    }

    /// The tags every one of the lists has.
    private static func shared(_ lists: [[String]]) -> Set<String> {
        guard var common = lists.first.map(Set.init) else { return [] }
        for list in lists.dropFirst() { common.formIntersection(list) }
        return common
    }

    private var selectedRowIndices: [Int] { Array(Set(targetCells.map(\.row))).sorted() }

    /// Tag Rows: tags on the selected rows (scripts: mx.rows("late"), table.row(tag="total")).
    func tagRows() {
        let rows = selectedRowIndices
        guard !rows.isEmpty else { return NSSound.beep() }
        let common = Self.shared(rows.map { model.data.rowTags?[$0] ?? [] })
        guard let answer = ask(rows.count == 1 ? "Tag Row \(rows[0] + 1)" : "Tag \(rows.count) Rows",
                               "Scripts find tagged rows anywhere in the notebook: mx.rows(\"late\"), or in one table: table.row(tag=\"total\").",
                               fields: [("Tags", common.sorted().map { "#" + $0 }.joined(separator: " "), "#total #late")]) else { return }
        let tags = TableData.parseTags(answer[0])
        var all = model.data.rowTags ?? [:]
        for r in rows { all[r] = tags.isEmpty ? nil : tags }
        model.data.rowTags = all.isEmpty ? nil : all
        committed("Tag Rows")
    }

    /// Tag Cells: tags (or a name) on the selected cells (scripts: mx.cell("grand-total")).
    func tagCells() {
        let cells = targetCells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        guard !cells.isEmpty else { return NSSound.beep() }
        let common = Self.shared(cells.map { model.data.cellTags?[TableData.key($0)] ?? [] })
        let name = cells.count == 1 ? TableData.columnName(cells[0].column) + "\(cells[0].row + 1)" : "\(cells.count) Cells"
        guard let answer = ask("Tag \(name)",
                               "Scripts find a tagged cell anywhere in the notebook: mx.cell(\"grand-total\") — a tag used once works like a name.",
                               fields: [("Tags", common.sorted().map { "#" + $0 }.joined(separator: " "), "#grand-total")]) else { return }
        let tags = TableData.parseTags(answer[0])
        var all = model.data.cellTags ?? [:]
        for c in cells { all[TableData.key(c)] = tags.isEmpty ? nil : tags }
        model.data.cellTags = all.isEmpty ? nil : all
        committed("Tag Cells")
    }

    /// Copy Python Reference: how a script gets to the selected cell (or the table).
    func copyPythonReference() {
        let cell = targetCells.min { ($0.row, $0.column) < ($1.row, $1.column) }
        var table: String
        if let name = model.data.name {
            table = "mx.table(\"\(name)\")"
        } else if let tag = model.data.tags?.first {
            table = "mx.tables(tag=\"\(tag)\")[0]"
        } else {
            let page = notebook.flatMap { nb in owner?.controller?.ref.flatMap { NotebookStore.shared.meta($0)?.displayTitle } } ?? ""
            table = "mx.tables(page=\"\(page)\")[0]"
        }
        var reference = table
        if let cell {
            if let tag = model.data.cellTags?[TableData.key(cell)]?.first {
                reference = "mx.cell(\"\(tag)\")"
            } else {
                reference = table + "[\"\(TableData.columnName(cell.column))\(cell.row + 1)\"]"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference, forType: .string)
    }

    /// The right-click submenu.
    func automationMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Name & Tags", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(model.data.name.map { "Table Name & Tags… (\($0))" } ?? "Table Name & Tags…") { [weak self] in self?.editTableNameAndTags() })
        menu.addItem(ClosureMenuItem("Tag Rows…") { [weak self] in self?.tagRows() })
        menu.addItem(ClosureMenuItem("Tag Cells…") { [weak self] in self?.tagCells() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Python Reference") { [weak self] in self?.copyPythonReference() })
        menu.addItem(ClosureMenuItem("Notebook Scripts…") { ScriptsIDE.openWindow() })
        item.submenu = menu
        return item
    }

    /// The blue marks of tagged cells (a corner) and rows (a bar at the left).
    func drawTagMarks(_ cell: CellRef, in rect: NSRect) {
        guard !isExport else { return }
        if model.data.cellTags?[TableData.key(cell)] != nil {
            let corner = NSBezierPath()
            corner.move(to: NSPoint(x: rect.maxX - 7, y: rect.minY))
            corner.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            corner.line(to: NSPoint(x: rect.maxX, y: rect.minY + 7))
            corner.close()
            NSColor.systemBlue.setFill()
            corner.fill()
        }
        if cell.column == 0, model.data.rowTags?[cell.row] != nil {
            NSColor.systemBlue.withAlphaComponent(0.8).setFill()
            NSRect(x: rect.minX, y: rect.minY + 2, width: 2.5, height: rect.height - 4).fill()
        }
    }

    /// Names and tags of a cell, its row and the table (for Quick Help).
    func tagFacts(_ cell: CellRef) -> [String] {
        var facts: [String] = []
        if let name = model.data.name { facts.append("table “\(name)”") }
        if let tags = model.data.tags, !tags.isEmpty { facts.append("table " + tags.map { "#" + $0 }.joined(separator: " ")) }
        if let tags = model.data.rowTags?[cell.row] { facts.append("row " + tags.map { "#" + $0 }.joined(separator: " ")) }
        if let tags = model.data.cellTags?[TableData.key(cell)] { facts.append("cell " + tags.map { "#" + $0 }.joined(separator: " ")) }
        return facts
    }
}

extension ScriptsIDE {
    /// Opens the Scripts window (from AppKit menus).
    static func openWindow() {
        if let window = shared.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .mxOpenScripts, object: nil)
        }
    }
}

extension Notification.Name {
    static let mxOpenScripts = Notification.Name("MxOpenScriptsWindow")
}
