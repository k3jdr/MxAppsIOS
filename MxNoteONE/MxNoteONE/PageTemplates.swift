//
//  PageTemplates.swift
//  MxNoteONE
//
//  Ready-made pages: New Page from Template and Insert ▸ Page Templates.
//

import AppKit

enum PageTemplate: String, CaseIterable, Identifiable {
    case blank, todo, meeting, project, lecture, journal, weekly, decisions, welcome

    var id: String { rawValue }

    /// Templates offered in the menus (Welcome is only used for a new library).
    static var choices: [PageTemplate] { allCases.filter { $0 != .welcome } }

    var title: String {
        switch self {
        case .blank: "Blank Page"
        case .todo: "To Do List"
        case .meeting: "Meeting Notes"
        case .project: "Project Overview"
        case .lecture: "Lecture Notes (Cornell)"
        case .journal: "Daily Journal"
        case .weekly: "Weekly Planner"
        case .decisions: "Decision Log"
        case .welcome: "Welcome to MxNoteONE"
        }
    }

    var symbol: String {
        switch self {
        case .blank: "doc"
        case .todo: "checklist"
        case .meeting: "person.3"
        case .project: "folder"
        case .lecture: "graduationcap"
        case .journal: "book"
        case .weekly: "calendar"
        case .decisions: "arrow.triangle.branch"
        case .welcome: "hand.wave"
        }
    }

    struct Built {
        var title: String
        var elements: [PageElement] = []
        var style: PageStyle?
    }

    func build() -> Built {
        let left = Double(PageCanvasView.margin)
        let top = Double(PageCanvasView.contentTop) + 10
        let today = Date().formatted(date: .long, time: .omitted)
        switch self {
        case .blank:
            return Built(title: "")

        case .todo:
            var text = RichText()
            text.add("Tasks", .heading1)
            for _ in 0..<5 { text.add(TagKind.todo.symbol + " ") }
            text.add("")
            text.add("Done", .heading2)
            text.add(TagKind.todoDone + " Create this list")
            return Built(title: "To Do List", elements: [text.element(x: left, y: top)])

        case .meeting:
            var text = RichText()
            text.add("Meeting Details", .heading2)
            text.add("Date: \(today)")
            text.add("Location: ")
            text.add("")
            text.add("Attendees", .heading2)
            text.add(TextFormatter.bullet)
            text.add("")
            text.add("Agenda", .heading2)
            text.add("1. ")
            text.add("")
            text.add("Notes", .heading2)
            text.add(TextFormatter.bullet)
            text.add("")
            text.add("Action Items", .heading2)
            text.add(TagKind.todo.symbol + " ")
            return Built(title: "Meeting Notes – \(today)", elements: [text.element(x: left, y: top, width: 600)])

        case .project:
            var text = RichText()
            text.add("Goal", .heading2)
            text.add("")
            text.add("Scope", .heading2)
            text.add(TextFormatter.bullet)
            text.add("")
            text.add("Risks", .heading2)
            text.add(TagKind.critical.symbol + " ")
            text.add("")
            text.add("Open Questions", .heading2)
            text.add(TagKind.question.symbol + " ")
            var milestones = PageElement(kind: .table, x: left, y: top + 400, width: 620)
            var table = TableData(rows: 5, columns: 4, width: 620)
            table.rows[0] = ["Milestone", "Owner", "Due", "Status"]
            milestones.table = table
            return Built(title: "Project Overview", elements: [text.element(x: left, y: top, width: 620), milestones])

        case .lecture:
            var cues = RichText()
            cues.add("Cues", .heading3)
            cues.add(TagKind.question.symbol + " ")
            var notes = RichText()
            notes.add("Notes", .heading3)
            notes.add(TextFormatter.bullet)
            var summary = RichText()
            summary.add("Summary", .heading3)
            summary.add("")
            return Built(title: "Lecture – \(today)",
                         elements: [cues.element(x: left, y: top, width: 200),
                                    notes.element(x: left + 230, y: top, width: 470),
                                    summary.element(x: left, y: top + 520, width: 700)],
                         style: PageStyle(color: .none, rules: .college))

        case .journal:
            var text = RichText()
            text.add("Grateful for", .heading2)
            text.add("1. ")
            text.add("")
            text.add("Today's focus", .heading2)
            text.add(TagKind.todo.symbol + " ")
            text.add("")
            text.add("Notes", .heading2)
            text.add("")
            text.add("Reflection", .heading2)
            text.add("")
            return Built(title: today, elements: [text.element(x: left, y: top)],
                         style: PageStyle(color: .cream, rules: .none))

        case .weekly:
            let calendar = Calendar.current
            let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
            var table = TableData(rows: 8, columns: 3, width: 700)
            table.rows[0] = ["Day", "Plans", "Done"]
            for d in 0..<7 {
                let day = calendar.date(byAdding: .day, value: d, to: start) ?? start
                table.rows[d + 1][0] = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            table.columnWidths = [170, 330, 200]
            var element = PageElement(kind: .table, x: left, y: top, width: 700)
            element.table = table
            return Built(title: "Week of \(start.formatted(date: .abbreviated, time: .omitted))", elements: [element])

        case .decisions:
            var table = TableData(rows: 6, columns: 5, width: 760)
            table.rows[0] = ["Date", "Decision", "Options Considered", "Reason", "Owner"]
            table.columnWidths = [100, 180, 180, 200, 100]
            var element = PageElement(kind: .table, x: left, y: top, width: 760)
            element.table = table
            return Built(title: "Decision Log", elements: [element])

        case .welcome:
            var text = RichText()
            text.add("Your notes, organized like a binder", .heading1)
            text.add("Notebooks hold sections (the coloured tabs in the sidebar), and sections hold pages. Group sections into section groups, and indent pages to make subpages.")
            text.add("")
            text.add("Write anywhere", .heading2)
            text.add(TextFormatter.bullet + "Click anywhere on a page and start typing. Drag a container by its top bar; resize it from its right edge.")
            text.add(TextFormatter.bullet + "Drop pictures and files onto a page, or use the Insert tab for tables, screen clippings and audio recordings.")
            text.add(TextFormatter.bullet + "Use the Draw tab to write and sketch with a pen, highlighter and shapes.")
            text.add("")
            text.add("Tags", .heading2)
            text.add(TagKind.todo.symbol + " Press ⌘1 for a To Do checkbox – click the box to check it off")
            text.add(TagKind.important.symbol + " ⌘2 Important, ⌘3 Question, ⌘4 Critical, ⌘5 Idea … see the Tags menu")
            text.add(TagKind.idea.symbol + " View ▸ Tag Summary collects tagged notes from every notebook")
            text.add("")
            text.add("Find and link", .heading2)
            text.add(TextFormatter.bullet + "⌘E searches all open notebooks; ⌘F finds on the current page.")
            text.add(TextFormatter.bullet + "Type [[Page Name]] to link to a page (it's created if it doesn't exist), or use ⌘K.")
            text.add("")
            text.add("Keep things safe", .heading2)
            text.add(TextFormatter.bullet + "Right-click a section ▸ Password Protect Section… to encrypt it.")
            text.add(TextFormatter.bullet + "Deleted pages and sections wait in the Recycle Bin for 60 days.")
            text.add(TextFormatter.bullet + "Notebooks are folders, so you can keep them in iCloud Drive, OneDrive or Dropbox.")
            return Built(title: "Welcome to MxNoteONE", elements: [text.element(x: left, y: top, width: 680)])
        }
    }
}

/// Builds the rich text of a template's text container.
struct RichText {
    private var text = NSMutableAttributedString()

    mutating func add(_ line: String, _ style: TextStyleKind = .normal) {
        if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: style.attributes)) }
        text.append(NSAttributedString(string: line, attributes: style.attributes))
    }

    func element(x: Double, y: Double, width: Double = 560) -> PageElement {
        var element = PageElement(kind: .text, x: x, y: y, width: width)
        element.rtfd = NoteRichText.data(text)
        return element
    }
}
