//
//  OneNoteImportCommands.swift
//  MxNoteONE
//
//  File ▸ Import: OneNote packages (.onepkg), section files (.one) and
//  notebook folders. Runs section by section so the window stays live, and
//  reports what came in at the end.
//

import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class ImportActivity {
    static let shared = ImportActivity()
    private(set) var busy = false
    var status = ""

    private var store: NotebookStore { .shared }

    /// File ▸ Import ▸ OneNote Package (.onepkg)…: the package becomes a new notebook.
    func importPackage() {
        let panel = NSOpenPanel()
        panel.title = "Import OneNote Package"
        panel.message = "Choose a OneNote notebook package (.onepkg) — in OneNote for Windows: File ▸ Export ▸ Notebook."
        panel.allowedContentTypes = [UTType(filenameExtension: "onepkg") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let packages = panel.urls
        run {
            for package in packages {
                self.status = "Unpacking \(package.lastPathComponent)…"
                await Task.yield()
                let folder: URL
                do {
                    folder = try OneNoteImport.unpack(package)
                } catch {
                    self.store.showAlert("Can't open the package", "\(package.lastPathComponent) couldn't be unpacked as a OneNote package.")
                    continue
                }
                defer { try? FileManager.default.removeItem(at: folder) }
                let name = package.deletingPathExtension().lastPathComponent
                // A package holds one notebook folder; use it as the root when present.
                let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                let root = items.count == 1 && (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? items[0] : folder
                await self.importNotebook(from: root, name: name)
            }
        }
    }

    /// File ▸ Import ▸ OneNote Notebook Folder…: a folder of .one files (with section-group subfolders).
    func importFolder() {
        let panel = NSOpenPanel()
        panel.title = "Import OneNote Notebook Folder"
        panel.message = "Choose a folder of OneNote section files (.one). Subfolders become section groups."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run { await self.importNotebook(from: folder, name: folder.lastPathComponent) }
    }

    /// File ▸ Import ▸ OneNote Sections (.one)…: sections added to the current notebook.
    func importSections() {
        let panel = NSOpenPanel()
        panel.title = "Import OneNote Sections"
        panel.allowedContentTypes = [UTType(filenameExtension: "one") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = panel.urls.map { ([String](), $0) }
        run {
            guard let nb = self.store.currentNotebook ?? self.store.createNotebook(
                name: "Imported", color: .purple, in: Prefs.notebooksFolder, firstSection: nil) else { return }
            await self.importSections(files, into: nb, searchFolders: [])
        }
    }

    private func importNotebook(from folder: URL, name: String) async {
        let files = OneNoteImport.sectionFiles(in: folder)
        guard !files.isEmpty else {
            store.showAlert("No OneNote sections found", "\(folder.lastPathComponent) doesn't contain any OneNote section files (.one).")
            return
        }
        guard let nb = store.createNotebook(name: name, color: .purple, in: Prefs.notebooksFolder, firstSection: nil) else { return }
        await importSections(files, into: nb, searchFolders: [folder])
    }

    /// Imports section files into a notebook and selects the first imported section.
    func importSections(_ files: [([String], URL)], into nb: Notebook, searchFolders: [URL]) async {
        var sections = 0, pages = 0, missing = 0
        var failed: [String] = []
        var first: SectionRef?
        for (i, (groups, url)) in files.enumerated() {
            status = "Importing \(i + 1) of \(files.count): \(OneNoteImport.sectionName(url))…"
            await Task.yield()
            let imported: ImportedOneNoteSection
            do {
                imported = try OneNoteImport.section(at: url, searchFolders: searchFolders)
            } catch {
                failed.append("\(OneNoteImport.sectionName(url)): \(error.localizedDescription)")
                continue
            }
            let section = store.createImportedSection(name: imported.name, color: imported.color, groups: groups, in: nb)
            first = first ?? section
            var batch: [(PageContent, PageMeta)] = []
            for page in imported.pages {
                var meta = PageMeta(title: page.title, level: page.level)
                if let created = page.created {
                    meta.created = created
                    meta.modified = created
                }
                let ref = PageRef(notebookID: nb.id, sectionID: section.sectionID, pageID: meta.id)
                var elements = page.elements
                for j in elements.indices {
                    guard let (data, ext) = page.assets[elements[j].id] else { continue }
                    elements[j].asset = store.writeAsset(data, ext: ext, for: ref)
                }
                elements.removeAll { $0.asset == "pending" || ($0.kind != .text && $0.kind != .table && $0.asset == nil) }
                let index = PageIndexer.index(elements: elements)
                meta.plainText = index.text
                meta.tags = index.tags
                let content = PageContent(id: meta.id, title: meta.title, created: meta.created,
                                          style: PageStyle(color: Prefs.pageColor, rules: Prefs.ruleLines), elements: elements)
                batch.append((content, meta))
            }
            store.addImportedPages(batch, to: section)
            sections += 1
            pages += imported.pages.count
            missing += imported.missingFiles
        }
        if let first { store.selectSidebar(.section(first)) }
        var message = "\(pages) page\(pages == 1 ? "" : "s") in \(sections) section\(sections == 1 ? "" : "s") imported into “\(nb.name)”."
        if !failed.isEmpty {
            message += "\n\nNot imported:\n" + failed.prefix(10).joined(separator: "\n")
        }
        message += "\n\nInk (handwriting and drawings) isn't imported."
        status = "Imported \(pages) pages."
        if missing > 0 {
            askForPictures(missing: missing, in: nb, summary: message)
        } else {
            store.showAlert("OneNote import finished", message)
        }
    }

    // MARK: Pictures kept outside the section files

    /// After an import with missing pictures: offer to choose the folder that holds them.
    private func askForPictures(missing: Int, in nb: Notebook, summary: String) {
        let alert = NSAlert()
        alert.messageText = "OneNote import finished"
        alert.informativeText = summary + "\n\n\(missing) picture\(missing == 1 ? " is" : "s are") kept outside the section files, in OneNote’s “onefiles” folder, which wasn’t found next to the sections. A note marks where each picture goes.\n\nIf you have that folder (OneNote for Windows keeps it in the notebook folder), choose it now — or later with Notebook ▸ Find Missing OneNote Pictures…"
        alert.addButton(withTitle: "Locate Pictures…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { locateMissingPictures(in: nb) }
    }

    /// Notebook ▸ Find Missing OneNote Pictures… (also when a picture note is clicked).
    func locateMissingPictures(in notebook: Notebook? = nil) {
        guard let nb = notebook ?? store.currentNotebook else { return }
        let count = missingPictureCount(in: nb)
        guard count > 0 else {
            store.showAlert("No missing pictures", "Every OneNote picture in “\(nb.name)” is in place.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Locate OneNote Pictures"
        panel.message = "Choose the folder with the pictures (OneNote’s “onefiles” folder, or any folder that contains it). \(count) picture\(count == 1 ? " is" : "s are") missing in “\(nb.name)”."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        status = "Looking for pictures…"
        let found = relinkMissingPictures(in: nb, folder: folder)
        status = ""
        if found == 0 {
            store.showAlert("No pictures found", "None of the \(count) missing pictures are in \(folder.lastPathComponent). OneNote names them after an ID like {44382328-6B0E-…}.")
        } else {
            store.showAlert("Pictures added", "\(found) of \(count) missing picture\(count == 1 ? "" : "s") added to “\(nb.name)”.")
        }
    }

    private struct MissingPicture {
        var guid: String
        var ext: String
        var width: CGFloat
        var height: CGFloat
    }

    private func missingPicture(in element: PageElement) -> MissingPicture? {
        guard element.kind == .text, let data = element.rtfd,
              let text = NSAttributedString(rtfd: data, documentAttributes: nil), text.length > 0 else { return nil }
        var result: MissingPicture?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let url = value as? URL ?? (value as? String).flatMap({ URL(string: $0) }),
                  url.scheme == OneNoteImport.missingScheme,
                  let guid = OneNoteImport.FileResolver.guid(in: url.path) else { return }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func query(_ name: String) -> String? { items.first { $0.name == name }?.value }
            result = MissingPicture(guid: guid, ext: query("ext") ?? "png",
                                    width: CGFloat(Double(query("w") ?? "") ?? 0), height: CGFloat(Double(query("h") ?? "") ?? 0))
            stop.pointee = true
        }
        return result
    }

    private func missingPictureCount(in nb: Notebook) -> Int {
        var count = 0
        forEachPage(in: nb) { _, _, content in
            count += content.elements.filter { missingPicture(in: $0) != nil }.count
            for element in content.elements where element.kind == .table {
                for row in element.table?.rich ?? [] {
                    for cell in row.compactMap({ $0 }) {
                        if let text = TableData.attributedCell(cell) { count += missingLinks(in: text).count }
                    }
                }
            }
        }
        return count
    }

    /// Picture notes in text: (range, picture).
    private func missingLinks(in text: NSAttributedString) -> [(NSRange, MissingPicture)] {
        var result: [(NSRange, MissingPicture)] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL ?? (value as? String).flatMap({ URL(string: $0) }),
                  url.scheme == OneNoteImport.missingScheme,
                  let guid = OneNoteImport.FileResolver.guid(in: url.path) else { return }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func query(_ name: String) -> String? { items.first { $0.name == name }?.value }
            result.append((range, MissingPicture(guid: guid, ext: query("ext") ?? "png",
                                                 width: CGFloat(Double(query("w") ?? "") ?? 0),
                                                 height: CGFloat(Double(query("h") ?? "") ?? 0))))
        }
        return result
    }

    private func forEachPage(in nb: Notebook, _ body: (SectionRef, PageMeta, PageContent) -> Void) {
        for node in nb.manifest.sections.flattenedSections {
            guard let pages = nb.sections[node.id]?.pages else { continue }
            let section = SectionRef(notebookID: nb.id, sectionID: node.id)
            for meta in pages {
                if let content = store.loadPage(PageRef(notebookID: nb.id, sectionID: node.id, pageID: meta.id)) {
                    body(section, meta, content)
                }
            }
        }
    }

    /// Replaces picture notes with the pictures found in the folder. Returns how many were added.
    @discardableResult
    func relinkMissingPictures(in nb: Notebook, folder: URL) -> Int {
        store.canvas?.flush()
        let index = OneNoteImport.FileResolver.buildIndex(neighbors: [], chosen: [folder])
        guard !index.isEmpty else { return 0 }
        var found = 0
        var updates: [(SectionRef, PageMeta, PageContent)] = []
        forEachPage(in: nb) { section, meta, content in
            var content = content
            var changed = false
            for i in content.elements.indices {
                guard let picture = missingPicture(in: content.elements[i]), let url = index[picture.guid],
                      let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.size.width > 0 else { continue }
                let ref = PageRef(notebookID: nb.id, sectionID: section.sectionID, pageID: meta.id)
                guard let asset = store.writeAsset(data, ext: picture.ext, for: ref) else { continue }
                let old = content.elements[i]
                let width = picture.width > 0 ? picture.width : min(image.size.width, 640)
                var element = PageElement(kind: .image, x: old.x, y: old.y, width: width,
                                          height: ElementView.gripHeight + width * image.size.height / image.size.width)
                element.asset = asset
                content.elements[i] = element
                changed = true
                found += 1
            }
            // Pictures inside table cells.
            for i in content.elements.indices where content.elements[i].kind == .table {
                guard var table = content.elements[i].table, let rich = table.rich else { continue }
                for r in rich.indices {
                    for c in rich[r].indices {
                        guard let data = rich[r][c], let text = TableData.attributedCell(data) else { continue }
                        let links = missingLinks(in: text)
                        guard !links.isEmpty else { continue }
                        let updated = NSMutableAttributedString(attributedString: text)
                        var replaced = 0
                        for (range, picture) in links.reversed() {
                            guard let url = index[picture.guid], let pictureData = try? Data(contentsOf: url),
                                  NSImage(data: pictureData) != nil else { continue }
                            updated.replaceCharacters(in: range, with: OneNoteImport.pictureAttachment(
                                pictureData, ext: picture.ext, width: picture.width, height: picture.height))
                            replaced += 1
                        }
                        guard replaced > 0 else { continue }
                        table.rich![r][c] = TableData.cellData(updated)
                        table.rows[r][c] = updated.string
                        found += replaced
                        changed = true
                    }
                }
                content.elements[i].table = table
            }
            if changed { updates.append((section, meta, content)) }
        }
        for (section, meta, content) in updates {
            var meta = meta
            let index = PageIndexer.index(elements: content.elements)
            meta.plainText = index.text
            meta.tags = index.tags
            meta.modified = Date()
            store.storeImportedPage(content, meta: meta, in: section)
        }
        return found
    }

    /// Runs a notebook-wide job (one at a time) with its progress in the sidebar.
    func runTask(_ title: String, _ work: @escaping (ImportActivity) async -> Void) {
        status = title
        run { await work(self) }
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !busy else {
            store.showAlert("An import is running", "Wait for the current import to finish.")
            return
        }
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}
