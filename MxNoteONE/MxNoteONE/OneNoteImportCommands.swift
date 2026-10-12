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
        if missing > 0 {
            message += "\n\n\(missing) picture\(missing == 1 ? " was" : "s were") kept outside the section files and weren't included in the export; a note marks where each one was."
        }
        if !failed.isEmpty {
            message += "\n\nNot imported:\n" + failed.prefix(10).joined(separator: "\n")
        }
        message += "\n\nInk (handwriting and drawings) isn't imported."
        status = "Imported \(pages) pages."
        store.showAlert("OneNote import finished", message)
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
