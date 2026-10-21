//
//  DiagramCanvas.swift
//  MxDataSQL
//
//  The drawing in a Diagram window: schema panels, relationships (with crow's-foot ends and, for
//  a selected Bézier, its control points), table boxes and sticky notes. Tables and notes are moved
//  by dragging; a note is resized from its corner and edited with a double-click; double-clicking
//  empty canvas adds a note there. Everything is in canvas coordinates, then scaled by the zoom.
//

import SwiftUI

private let canvasSpace = "diagramCanvas"

struct DiagramCanvas: View {
    @Bindable var model: DiagramModel

    var body: some View {
        let size = model.canvasSize
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .named(canvasSpace)) { location in
                        model.addNote(at: CGPoint(x: location.x - 20, y: location.y - 20))
                    }
                    .onTapGesture {
                        model.selection = nil
                        model.editingNote = nil
                    }

                ForEach(model.groupFrames, id: \.name) { group in
                    GroupPanel(name: group.name, frame: group.frame)
                }
                ForEach(model.document.refs) { ref in
                    RefView(model: model, ref: ref)
                }
                ForEach(model.document.tables) { table in
                    TableBox(model: model, table: table)
                }
                ForEach(model.notes) { note in
                    NoteBox(model: model, note: note)
                }
                if case .ref(let id) = model.selection, let ref = model.document.refs.first(where: { $0.id == id }) {
                    ControlHandles(model: model, ref: ref)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named(canvasSpace))
            .scaleEffect(model.zoom, anchor: .topLeading)
            .frame(width: size.width * model.zoom, height: size.height * model.zoom, alignment: .topLeading)
        }
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
            model.visibleRect = rect
        }
        .onDeleteCommand { model.deleteSelection() }
    }
}

private struct GroupPanel: View {
    let name: String
    let frame: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.secondary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .overlay(alignment: .topLeading) {
                Text(name.replacingOccurrences(of: "_schema", with: ""))
                    .font(.headline).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
    }
}

/// A colour per schema, so tables of one schema share a header colour.
func schemaColor(_ schema: String) -> Color {
    let palette: [Color] = [.blue, .teal, .indigo, .purple, .orange, .green, .pink, .brown]
    let index = schema == "public" ? 0 : (abs(schema.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }) % (palette.count - 1)) + 1
    return palette[index]
}

// MARK: - Relationships

private struct RefView: View {
    let model: DiagramModel
    let ref: DBMLRef

    var body: some View {
        let g = model.geometry(of: ref)
        let selected = model.selection == .ref(ref.id)
        let highlighted: Bool = {
            if case .table(let t) = model.selection { return ref.from.table == t || ref.to.table == t }
            return false
        }()
        let color: Color = selected ? .accentColor : highlighted ? .orange : (ref.color.flatMap(Color.init(hex:)) ?? .secondary)
        ZStack {
            g.path.stroke(color, lineWidth: selected || highlighted ? 2.4 : 1.3)
            ends(g).stroke(color, lineWidth: selected || highlighted ? 2 : 1.2)
        }
        .contentShape(g.path.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round)))
        .onTapGesture { model.selection = .ref(ref.id) }
        .contextMenu {
            Text(description)
            Divider()
            ForEach(CurveStyle.allCases) { style in
                Button {
                    model.selection = .ref(ref.id)
                    model.setStyle(style, for: ref.id)
                } label: {
                    if model.curve(ref).style == style { Label(style.title, systemImage: "checkmark") } else { Text(style.title) }
                }
            }
        }
        .help(description)
    }

    private var description: String {
        "\(ref.from.table).\(ref.from.columns.joined(separator: ", ")) \(ref.relation.rawValue) \(ref.to.table).\(ref.to.columns.joined(separator: ", "))"
    }

    /// Crow's foot at a "many" end, a bar at a "one" end.
    private func ends(_ g: RefGeometry) -> Path {
        let manyAtStart = ref.relation == .manyToOne || ref.relation == .manyToMany
        let manyAtEnd = ref.relation == .oneToMany || ref.relation == .manyToMany
        var p = Path()
        mark(&p, at: g.start, direction: g.startTangent, many: manyAtStart)
        mark(&p, at: g.end, direction: g.endTangent, many: manyAtEnd)
        return p
    }

    private func mark(_ p: inout Path, at point: CGPoint, direction d: CGVector, many: Bool) {
        let n = CGVector(dx: -d.dy, dy: d.dx)
        if many {
            let tip = CGPoint(x: point.x + d.dx * 13, y: point.y + d.dy * 13)
            for s: CGFloat in [-7, 0, 7] {
                p.move(to: tip)
                p.addLine(to: CGPoint(x: point.x + n.dx * s, y: point.y + n.dy * s))
            }
        } else {
            let c = CGPoint(x: point.x + d.dx * 9, y: point.y + d.dy * 9)
            p.move(to: CGPoint(x: c.x + n.dx * 6, y: c.y + n.dy * 6))
            p.addLine(to: CGPoint(x: c.x - n.dx * 6, y: c.y - n.dy * 6))
        }
    }
}

/// The control points of the selected quadratic / cubic relationship, dragged to reshape it.
private struct ControlHandles: View {
    let model: DiagramModel
    let ref: DBMLRef

    var body: some View {
        let g = model.geometry(of: ref)
        if g.style == .quadratic || g.style == .cubic {
            ZStack(alignment: .topLeading) {
                Path { p in
                    if g.style == .quadratic {
                        p.move(to: g.start); p.addLine(to: g.controls[0]); p.addLine(to: g.end)
                    } else {
                        p.move(to: g.start); p.addLine(to: g.controls[0])
                        p.move(to: g.end); p.addLine(to: g.controls[1])
                    }
                }
                .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)

                ForEach(Array(g.controls.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 13, height: 13)
                        .contentShape(Circle().inset(by: -5))
                        .position(point)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasSpace)).onChanged { value in
                            model.moveControl(index, of: ref.id, to: value.location)
                        })
                        .help("Drag to reshape the curve")
                }
            }
        }
    }
}

// MARK: - Tables

private struct TableBox: View {
    let model: DiagramModel
    let table: DBMLTable
    @State private var dragOrigin: CGPoint?

    var body: some View {
        let frame = model.frame(of: table.id)
        let selected = model.selection == .table(table.id)
        let fkColumns = Set(model.document.refs.filter { $0.from.table == table.id }.flatMap(\.from.columns)
            + model.document.refs.filter { $0.to.table == table.id && $0.relation == .oneToMany }.flatMap(\.to.columns))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(table.schema == "public" ? table.name : "\(table.schema).\(table.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if table.indexCount > 0 {
                    Image(systemName: "list.number").font(.system(size: 9)).opacity(0.8)
                        .help("\(table.indexCount) index\(table.indexCount == 1 ? "" : "es")")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: DiagramModel.headerHeight)
            .background(schemaColor(table.schema))
            .help(table.note ?? table.id)

            ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                HStack(spacing: 4) {
                    Group {
                        if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow) }
                        else if fkColumns.contains(column.name) { Image(systemName: "link").foregroundStyle(.secondary) }
                        else { Color.clear }
                    }
                    .font(.system(size: 9))
                    .frame(width: 12)
                    Text(column.name)
                        .font(.system(size: 11, weight: column.isPrimaryKey ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(column.type)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: DiagramModel.rowHeight)
                .help(columnHelp(column))
            }
            Spacer(minLength: 0)
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: selected ? 2.5 : 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .position(x: frame.midX, y: frame.midY)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = frame.origin
                    model.selection = .table(table.id)
                }
                if let o = dragOrigin {
                    model.moveTable(table.id, to: CGPoint(x: o.x + value.translation.width, y: o.y + value.translation.height))
                }
            }
            .onEnded { _ in dragOrigin = nil })
        .onTapGesture { model.selection = .table(table.id) }
    }

    private func columnHelp(_ c: DBMLColumn) -> String {
        var parts = ["\(c.name) \(c.type)"]
        if c.isPrimaryKey { parts.append("primary key") }
        if c.isNotNull && !c.isPrimaryKey { parts.append("not null") }
        if c.isUnique { parts.append("unique") }
        if let d = c.defaultValue { parts.append("default \(d)") }
        var text = parts.joined(separator: ", ")
        if let note = c.note { text += "\n\(note)" }
        return text
    }
}

// MARK: - Notes

private struct NoteBox: View {
    let model: DiagramModel
    let note: DBMLStickyNote
    @State private var dragOrigin: CGRect?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let frame = model.noteFrame(note.id)
        let selected = model.selection == .note(note.id)
        let editing = model.editingNote == note.id && note.isOwn
        ZStack(alignment: .bottomTrailing) {
            Group {
                if editing {
                    TextEditor(text: $text)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .onAppear { text = note.text; focused = true }
                        .onChange(of: text) { model.setNoteText(note.id, text) }
                } else {
                    Text(note.text.isEmpty ? " " : note.text)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(8)
            .frame(width: frame.width, height: frame.height)

            if note.isOwn {
                // Resize from the corner.
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(canvasSpace))
                        .onChanged { value in
                            if dragOrigin == nil { dragOrigin = frame }
                            if let o = dragOrigin {
                                model.moveNote(note.id, to: CGRect(x: o.minX, y: o.minY,
                                                                    width: o.width + value.translation.width,
                                                                    height: o.height + value.translation.height))
                            }
                        }
                        .onEnded { _ in dragOrigin = nil })
                        .help("Drag to resize the note")
            }
        }
        .background(note.isOwn ? Color.yellow.opacity(0.28) : Color.gray.opacity(0.18))
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(selected ? Color.accentColor : Color.yellow.opacity(0.8), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        .position(x: frame.midX, y: frame.midY)
        .gesture(editing ? nil : DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = frame; model.selection = .note(note.id) }
                if let o = dragOrigin {
                    model.moveNote(note.id, to: o.offsetBy(dx: value.translation.width, dy: value.translation.height))
                }
            }
            .onEnded { _ in dragOrigin = nil })
        .onTapGesture(count: 2) {
            guard note.isOwn else { return }
            model.selection = .note(note.id)
            model.editingNote = note.id
        }
        .onTapGesture { model.selection = .note(note.id) }
        .contextMenu {
            if note.isOwn {
                Button("Edit Note") { model.selection = .note(note.id); model.editingNote = note.id }
                Button("Delete Note", role: .destructive) { model.deleteNote(note.id) }
            } else {
                Text("Note \(note.id) is part of the DBML file (read-only)")
            }
        }
        .help(note.isOwn ? "Double-click to edit; drag to move" : "Sticky note \(note.id) from the DBML file")
    }
}

extension Color {
    /// "#9aa0a6" / "9aa0a6".
    nonisolated init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#'\" "))
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
