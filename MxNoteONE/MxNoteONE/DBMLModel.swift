//
//  DBMLModel.swift
//  MxNoteONE
//
//  A DBML database diagram as the page keeps it: the DBML, where each table was dragged, each
//  relationship's curve, the notes over it, and how it's shown (DBML pane, zoom, column types). The
//  diagram itself — reading DBML and MxDataSQL's .dbml files, laying out, drawing, arranging, cutting
//  out a schema — is the shared DBML library (Shared/DBML), which MxDataSQL uses too, so a diagram
//  looks and works the same in both apps.
//

import AppKit

/// A relationship line as the page keeps it (DBMLRefCurve in the shared library).
struct DBMLLine: Codable, Equatable {
    /// nil: drawn the diagram's way.
    var curve: DBMLCurveStyle?
    var c1: DBMLPoint?
    var c2: DBMLPoint?
    var fromSide: DBMLSide?
    var toSide: DBMLSide?
    var color: String?
}

/// A note over the diagram, as the page keeps it.
struct DBMLNote: Codable, Equatable, Identifiable {
    /// Saved as a UUID before the shared library (still read as its text).
    var id: String = UUID().uuidString
    var text: String
    var x: Double
    var y: Double
    var width: Double = 220
    var height: Double = 120
    var color: String?

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct DBMLData: Codable, Equatable {
    /// The DBML (a file's MxDataSQL section is kept apart, in `section`).
    var source: String
    var title: String?
    /// Where each table, enum ("enum:…") and DBML sticky note ("note:…") sits.
    var positions: [String: DBMLPoint] = [:]
    /// Each relationship's line, by the relationship's id (earlier pages: by "a.b > c.d").
    var lines: [String: DBMLLine]?
    var notes: [DBMLNote]?
    /// How lines without a style of their own are drawn (automatic when not chosen).
    var curve: DBMLCurveStyle?
    /// The diagram's scale (nil: fit the container's width, at most 100%).
    var zoom: Double?
    /// The DBML is shown beside the diagram, this wide.
    var showsSource: Bool?
    var sourceWidth: Double?
    var hidesTypes: Bool?
    /// The MxDataSQL section of the file the diagram came from (its layout, for File Layout).
    var section: String?

    static let starter = DBMLData(source: """
    // A database diagram in DBML — edit it in the DBML pane (Show DBML), drag the
    // tables around, click a relationship's line to bend it, and add notes.
    // DBML: https://dbml.dbdiagram.io/docs

    Table authors {
      id integer [pk, increment]
      name varchar [not null]
      email varchar [unique]
      joined_at timestamp
    }

    Table books {
      id integer [pk, increment]
      title varchar [not null]
      author_id integer [ref: > authors.id]
      published date
      status book_status
      Note: 'Every book has one author'
    }

    Table reviews {
      id integer [pk]
      book_id integer
      reader_id integer
      stars integer [note: '1 to 5']
      body text
    }

    Enum book_status {
      draft
      published
      out_of_print
    }

    Ref: reviews.book_id > books.id
    Ref: reviews.reader_id > authors.id
    """)

    /// A diagram from a .dbml file's text (an MxDataSQL file comes with its layout, curves and notes).
    static func fromFile(_ text: String, title: String?) -> DBMLData {
        var d = DBMLData(source: text)
        d.title = title
        d.take(d.diagram)
        return d
    }

    /// The layout of the file the diagram came from (MxDataSQL's), if it had one.
    var fileLayout: DBMLFileLayout.Layout? {
        (section ?? DBMLFileLayout.split(source).section).flatMap { DBMLFileLayout.layout(inSection: $0) }
    }

    // MARK: The shared diagram

    /// The diagram (the shared library's) for this data.
    var diagram: DBMLDiagram {
        let parts = DBMLFileLayout.split(source)
        var d = DBMLDiagram(source: parts.body)
        let schema = d.schema
        let fileNotes = Set(schema.notes.map(\.name))
        for (k, p) in positions {
            if k.hasPrefix("note:") {
                let name = String(k.dropFirst(5))
                if fileNotes.contains(name) { d.stickyFrames[name] = CGRect(origin: p.cg, size: DBMLDiagramNote.size) }
            } else {
                d.positions[k] = p.cg
            }
        }
        for r in schema.refs {
            guard let l = lines?[r.id] ?? lines?[r.key] else { continue }
            let c = DBMLRefCurve(style: l.curve, c1: l.c1?.cg, c2: l.c2?.cg, fromSide: l.fromSide, toSide: l.toSide, color: l.color)
            if !c.isPlain { d.curves[r.id] = c }
        }
        d.notes = (notes ?? []).map { DBMLDiagramNote(id: $0.id, text: $0.text, frame: $0.rect, color: $0.color) }
        d.defaultStyle = curve ?? .automatic
        d.hidesTypes = hidesTypes == true
        // From a file, before anything was placed here: its layout and its notes.
        if positions.isEmpty, let section = parts.section ?? section { d.apply(section: section) }
        return d
    }

    /// Takes what the diagram has (positions, curves, notes); a file's MxDataSQL section is kept apart.
    mutating func take(_ d: DBMLDiagram) {
        if let s = DBMLFileLayout.split(source).section { section = s }
        source = d.source
        var p: [String: DBMLPoint] = [:]
        for (k, v) in d.positions { p[k] = DBMLPoint(v) }
        for (k, f) in d.stickyFrames { p["note:" + k] = DBMLPoint(f.origin) }
        positions = p
        var l: [String: DBMLLine] = [:]
        for (k, c) in d.curves where !c.isPlain {
            l[k] = DBMLLine(curve: c.style, c1: c.c1.map { DBMLPoint($0) }, c2: c.c2.map { DBMLPoint($0) },
                            fromSide: c.fromSide, toSide: c.toSide, color: c.color)
        }
        lines = l.isEmpty ? nil : l
        notes = d.notes.isEmpty ? nil : d.notes.map {
            DBMLNote(id: $0.id, text: $0.text, x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height, color: $0.color)
        }
        curve = d.defaultStyle == .automatic ? nil : d.defaultStyle
        hidesTypes = d.hidesTypes ? true : nil
    }

    // MARK: Files and search

    /// The diagram as a .dbml file: its DBML, then MxDataSQL's section (the notes and the layout), so MxDataSQL
    /// opens it laid out the same.
    var exportText: String { diagram.fileText() }

    /// The DBML with the notes as sticky notes, without the layout line (shown in Markdown and OneNote).
    func dbmlText(includingLayout: Bool) -> String { diagram.fileText(includingLayout: includingLayout) }

    var searchText: String {
        let s = DBMLParser.parse(DBMLFileLayout.split(source).body)
        var words: [String] = [title ?? ""]
        for t in s.tables { words.append(t.name); words += t.columns.map(\.name); if let n = t.note { words.append(n) } }
        for e in s.enums { words.append(e.name); words += e.values.map(\.name) }
        words += s.groups.map(\.name)
        words += s.notes.map(\.text)
        words += (notes ?? []).map(\.text)
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
