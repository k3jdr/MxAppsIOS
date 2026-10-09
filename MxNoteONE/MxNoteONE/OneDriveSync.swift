//
//  OneDriveSync.swift
//  MxNoteONE
//
//  Two-way sync between an MxNoteONE notebook and a OneNote notebook on
//  OneDrive, through the OneNote API — the notebook then opens in OneNote
//  for Mac, Windows, iPad and the web.
//
//  Save to OneDrive creates the OneNote notebook and uploads everything.
//  Open from OneDrive downloads a OneNote notebook into a new local one.
//  Sync then works page by page:
//    • changed only here → uploaded (the OneNote copy is replaced)
//    • changed only in OneNote → downloaded (the local copy is replaced)
//    • changed in both → the OneNote version comes down as a separate
//      “(OneDrive copy)” page and the local version goes up
//    • deleted on one side and unchanged on the other → deleted on both
//  New sections and section groups are created on both sides. Password-
//  protected sections stay on this Mac. OneNote API limits: renaming or
//  deleting sections and setting subpage levels can't be sent to OneNote.
//

import AppKit
import Observation

struct RemoteNotebook: Identifiable {
    let id: String
    let name: String
    let modified: Date?
    let shared: Bool
}

@Observable
final class OneDriveSync {
    static let shared = OneDriveSync()

    private(set) var busy = false
    var status = ""
    var remoteNotebooks: [RemoteNotebook] = []
    var loadingNotebooks = false

    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    private var store: NotebookStore { .shared }
    private var graph: GraphClient { .shared }
    private var auth: OneDriveAuth { .shared }

    // MARK: Commands

    func signIn() {
        Task {
            do {
                try await auth.signIn()
                status = "Signed in to OneDrive as \(auth.account ?? "your account")."
            } catch OneDriveError.signInCancelled {
                return
            } catch {
                store.report("Couldn't sign in to OneDrive.", error)
            }
        }
    }

    func loadRemoteNotebooks() async {
        guard auth.isSignedIn else { return }
        loadingNotebooks = true
        defer { loadingNotebooks = false }
        do {
            let items = try await graph.list("/me/onenote/notebooks?$select=id,displayName,lastModifiedDateTime,isShared&$orderby=lastModifiedDateTime%20desc")
            remoteNotebooks = items.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return RemoteNotebook(id: id, name: item["displayName"] as? String ?? "Notebook",
                                      modified: GraphClient.date(item["lastModifiedDateTime"]),
                                      shared: item["isShared"] as? Bool ?? false)
            }
        } catch {
            store.report("Couldn't list your OneNote notebooks.", error)
        }
    }

    /// Downloads a OneNote notebook into a new local notebook (or syncs the one already linked to it).
    func open(_ remote: RemoteNotebook, in folder: URL) {
        if let existing = store.notebooks.first(where: { $0.manifest.oneNote?.notebookID == remote.id }) {
            sync(existing)
            return
        }
        guard let nb = store.createNotebook(name: remote.name, color: .purple, in: folder, firstSection: nil) else { return }
        nb.manifest.oneNote = OneNoteLink(notebookID: remote.id, name: remote.name, account: auth.account ?? "")
        store.saveManifest(nb)
        run("Opening “\(remote.name)” from OneDrive") { [self] in
            try await self.syncNotebook(nb)
            if let first = nb.manifest.sections.flattenedSections.first {
                store.selectSidebar(.section(SectionRef(notebookID: nb.id, sectionID: first.id)))
            }
        }
    }

    /// Creates the notebook on OneDrive if needed, then syncs it.
    func save(_ nb: Notebook) {
        run("Saving “\(nb.name)” to OneDrive") { [self] in
            if nb.manifest.oneNote == nil {
                let id = try await self.createRemoteNotebook(named: nb.name)
                nb.manifest.oneNote = OneNoteLink(notebookID: id.id, name: id.name, account: self.auth.account ?? "")
                self.store.saveManifest(nb)
            }
            try await self.syncNotebook(nb)
        }
    }

    func sync(_ nb: Notebook) {
        guard nb.manifest.oneNote != nil else { return save(nb) }
        run("Syncing “\(nb.name)”") { [self] in try await self.syncNotebook(nb) }
    }

    func syncAll(quiet: Bool = false) {
        let linked = store.notebooks.filter { $0.manifest.oneNote != nil }
        guard !linked.isEmpty else {
            if !quiet { store.showAlert("No OneDrive notebooks", "Use File ▸ OneDrive ▸ Save Notebook to OneDrive first.") }
            return
        }
        run("Syncing OneDrive notebooks", quiet: quiet) { [self] in
            for nb in linked { try await self.syncNotebook(nb) }
        }
    }

    func unlink(_ nb: Notebook) {
        nb.manifest.oneNote = nil
        store.saveManifest(nb)
        status = "“\(nb.name)” is no longer synced with OneDrive."
    }

    /// Restarts the automatic sync timer (Settings ▸ OneDrive).
    func scheduleAutoSync() {
        autoSyncTask?.cancel()
        let minutes = Prefs.oneDriveAutoSyncMinutes
        guard minutes > 0 else { return }
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled, let self, !self.busy, self.auth.isSignedIn else { continue }
                self.syncAll(quiet: true)
            }
        }
    }

    private func run(_ title: String, quiet: Bool = false, _ work: @escaping () async throws -> Void) {
        guard !busy else {
            if !quiet { store.showAlert("OneDrive is busy", "Wait for the current sync to finish.") }
            return
        }
        guard !auth.clientID.isEmpty else {
            if !quiet { store.showAlert("OneDrive isn't set up", OneDriveError.noClientID.localizedDescription) }
            return
        }
        busy = true
        status = title + "…"
        Task {
            do {
                if !auth.isSignedIn { try await auth.signIn() }
                try await work()
                status = "Synced with OneDrive at \(Date().formatted(date: .omitted, time: .shortened))."
            } catch OneDriveError.signInCancelled {
                status = ""
            } catch {
                status = "OneDrive sync failed."
                if !quiet { store.report("OneDrive sync failed.", error) }
            }
            busy = false
        }
    }

    // MARK: Sync engine

    private struct RemoteNode {
        let id: String
        let name: String
        let isGroup: Bool
        let parent: String?
    }

    private struct RemotePage {
        let id: String
        let section: String
        let title: String
        let modified: Date
        let level: Int
        let order: Int
    }

    /// OneNote rejects these characters in notebook and section names (and limits them to 50 characters).
    static func oneNoteName(_ name: String) -> String {
        let cleaned = String(name.filter { !"?*\\/:<>|&#'%~\"".contains($0) }).trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(50))
    }

    private func isConflict(_ error: Error) -> Bool {
        error.localizedDescription.contains("409")
    }

    private func createRemoteNotebook(named name: String) async throws -> (id: String, name: String) {
        let base = Self.oneNoteName(name)
        for attempt in 0..<6 {
            let candidate = attempt == 0 ? base : String(base.prefix(46)) + " \(attempt + 1)"
            do {
                let created = try await graph.json("POST", "/me/onenote/notebooks", body: ["displayName": candidate])
                if let id = created["id"] as? String { return (id, candidate) }
            } catch let error where self.isConflict(error) {
                continue
            }
        }
        throw OneDriveError.server("A OneNote notebook named “\(base)” already exists. Rename this notebook and try again.")
    }

    private func createRemoteNode(_ node: SectionNode, under parent: String?, notebookID: String) async throws -> String {
        let container = parent.map { "/me/onenote/sectionGroups/\($0)" } ?? "/me/onenote/notebooks/\(notebookID)"
        let path = container + (node.isGroup ? "/sectionGroups" : "/sections")
        let base = Self.oneNoteName(node.name)
        for attempt in 0..<6 {
            let candidate = attempt == 0 ? base : String(base.prefix(46)) + " \(attempt + 1)"
            do {
                let created = try await graph.json("POST", path, body: ["displayName": candidate])
                if let id = created["id"] as? String { return id }
            } catch let error where self.isConflict(error) {
                continue
            }
        }
        throw OneDriveError.server("Couldn't create “\(base)” in OneNote.")
    }

    private func syncNotebook(_ nb: Notebook) async throws {
        store.canvas?.flush()
        guard var link = nb.manifest.oneNote else { return }
        defer {
            nb.manifest.oneNote = link
            store.saveManifest(nb)
        }

        // The OneNote notebook.
        let remoteNotebook: [String: Any]
        do {
            remoteNotebook = try await graph.json("GET", "/me/onenote/notebooks/\(link.notebookID)")
        } catch {
            throw OneDriveError.server("The OneNote notebook “\(link.name)” can't be reached — it may have been deleted or belong to another account. Unlink it, then save it to OneDrive again.\n\n\(error.localizedDescription)")
        }
        let links = remoteNotebook["links"] as? [String: Any]
        link.clientURL = (links?["oneNoteClientUrl"] as? [String: Any])?["href"] as? String
        link.webURL = (links?["oneNoteWebUrl"] as? [String: Any])?["href"] as? String

        // Remote sections and section groups.
        status = "Syncing “\(nb.name)”: reading OneNote sections…"
        var remote: [String: RemoteNode] = [:]
        var remoteOrder: [String] = []
        func walk(_ container: String, parent: String?) async throws {
            for item in try await graph.list("\(container)/sections?$select=id,displayName") {
                guard let id = item["id"] as? String else { continue }
                remote[id] = RemoteNode(id: id, name: item["displayName"] as? String ?? "Section", isGroup: false, parent: parent)
                remoteOrder.append(id)
            }
            for item in try await graph.list("\(container)/sectionGroups?$select=id,displayName") {
                guard let id = item["id"] as? String else { continue }
                remote[id] = RemoteNode(id: id, name: item["displayName"] as? String ?? "Section Group", isGroup: true, parent: parent)
                remoteOrder.append(id)
                try await walk("/me/onenote/sectionGroups/\(id)", parent: id)
            }
        }
        try await walk("/me/onenote/notebooks/\(link.notebookID)", parent: nil)

        // New in OneNote → create here.
        var localForRemote: [String: String] = [:]
        for (local, remoteID) in link.nodes { localForRemote[remoteID] = local }
        for id in remoteOrder where localForRemote[id] == nil {
            guard let node = remote[id] else { continue }
            let count = nb.manifest.sections.flattenedSections.count
            let local = SectionNode(kind: node.isGroup ? .group : .section, name: node.name,
                                    color: NoteColor.allCases[count % NoteColor.allCases.count],
                                    children: node.isGroup ? [] : nil)
            let parent = node.parent.flatMap { localForRemote[$0] }.flatMap(UUID.init(uuidString:))
            nb.manifest.sections.append(local, toGroup: parent)
            if !node.isGroup {
                nb.sections[local.id] = SectionContent()
                store.saveSection(nb, local.id)
            }
            link.nodes[local.id.uuidString] = id
            localForRemote[id] = local.id.uuidString
        }
        store.saveManifest(nb)

        // New here (or gone from OneNote) → create in OneNote.
        func push(_ nodes: [SectionNode], parent: String?) async throws {
            for node in nodes where !node.isProtected {
                var remoteID = link.nodes[node.id.uuidString]
                if let id = remoteID, remote[id] == nil { remoteID = nil }
                if remoteID == nil {
                    status = "Syncing “\(nb.name)”: creating “\(node.name)” in OneNote…"
                    let id = try await createRemoteNode(node, under: parent, notebookID: link.notebookID)
                    remote[id] = RemoteNode(id: id, name: node.name, isGroup: node.isGroup, parent: parent)
                    link.nodes[node.id.uuidString] = id
                    remoteID = id
                }
                if node.isGroup { try await push(node.children ?? [], parent: remoteID) }
            }
        }
        try await push(nb.manifest.sections, parent: nil)

        // Sections that stay local (password protected or locked).
        let localOnly = Set(nb.manifest.sections.flattenedSections.filter(\.isProtected).compactMap { link.nodes[$0.id.uuidString] })

        // Remote pages.
        var remotePages: [String: RemotePage] = [:]
        for (id, node) in remote where !node.isGroup && !localOnly.contains(id) {
            status = "Syncing “\(nb.name)”: reading pages of “\(node.name)”…"
            let items = try await graph.list("/me/onenote/sections/\(id)/pages?$select=id,title,lastModifiedDateTime,level,order&pagelevel=true&$top=100")
            for item in items {
                guard let pageID = item["id"] as? String else { continue }
                remotePages[pageID] = RemotePage(id: pageID, section: id, title: item["title"] as? String ?? "",
                                                 modified: GraphClient.date(item["lastModifiedDateTime"]) ?? .distantPast,
                                                 level: item["level"] as? Int ?? 0, order: item["order"] as? Int ?? 0)
            }
        }

        var handled: Set<String> = []
        let tolerance: TimeInterval = 120
        var uploads = 0, downloads = 0

        // Local pages.
        for node in nb.manifest.sections.flattenedSections where !node.isProtected {
            guard let sectionRemote = link.nodes[node.id.uuidString], let pages = nb.sections[node.id]?.pages else { continue }
            let section = SectionRef(notebookID: nb.id, sectionID: node.id)
            for meta in pages {
                let key = meta.id.uuidString
                let ref = PageRef(notebookID: nb.id, sectionID: node.id, pageID: meta.id)
                status = "Syncing “\(nb.name)”: \(meta.displayTitle)…"
                if let synced = link.pages[key], let remotePage = remotePages[synced.remoteID] {
                    handled.insert(synced.remoteID)
                    let localChanged = meta.modified > synced.localModified.addingTimeInterval(1)
                    let remoteChanged = remotePage.modified > synced.remoteModified.addingTimeInterval(tolerance)
                    let moved = remotePage.section != sectionRemote
                    if remoteChanged && !localChanged && !moved {
                        link.pages[key] = try await download(remotePage, into: section, replacing: meta)
                        downloads += 1
                    } else if localChanged || moved {
                        if remoteChanged {
                            let copy = try await download(remotePage, into: section, replacing: nil, suffix: " (OneDrive copy)")
                            if let copyID = copy.localID { link.pages[copyID] = nil }
                            downloads += 1
                        }
                        link.pages[key] = try await upload(ref, meta: meta, section: sectionRemote, replacing: synced.remoteID)
                        uploads += 1
                    }
                } else if let synced = link.pages[key], meta.modified <= synced.localModified.addingTimeInterval(1) {
                    // Deleted in OneNote and unchanged here.
                    store.removeSyncedPage(ref)
                    link.pages[key] = nil
                } else {
                    link.pages[key] = try await upload(ref, meta: meta, section: sectionRemote, replacing: nil)
                    uploads += 1
                }
            }
        }

        // Pages deleted here, and pages new in OneNote.
        var localForRemotePage: [String: String] = [:]
        for (local, synced) in link.pages { localForRemotePage[synced.remoteID] = local }
        let localPageIDs = Set(nb.sections.values.flatMap { $0.pages.map(\.id.uuidString) })
        for remotePage in remotePages.values.sorted(by: { ($0.section, $0.order) < ($1.section, $1.order) })
            where !handled.contains(remotePage.id) {
            if let local = localForRemotePage[remotePage.id], !localPageIDs.contains(local), let synced = link.pages[local] {
                if remotePage.modified > synced.remoteModified.addingTimeInterval(tolerance) {
                    link.pages[local] = nil
                } else {
                    status = "Syncing “\(nb.name)”: deleting “\(remotePage.title)” in OneNote…"
                    try? await graph.delete("/me/onenote/pages/\(remotePage.id)")
                    link.pages[local] = nil
                    continue
                }
            }
            guard let localSection = localForRemote[remotePage.section].flatMap(UUID.init(uuidString:)),
                  nb.sections[localSection] != nil else { continue }
            status = "Syncing “\(nb.name)”: downloading “\(remotePage.title)”…"
            let synced = try await download(remotePage, into: SectionRef(notebookID: nb.id, sectionID: localSection), replacing: nil, suffix: "")
            if let local = synced.localID { link.pages[local] = synced.page }
            downloads += 1
        }
        // Forget pages whose local page is gone and whose OneNote page is gone too.
        link.pages = link.pages.filter { localPageIDs.contains($0.key) || remotePages[$0.value.remoteID] != nil }
        link.lastSync = Date()
        status = "“\(nb.name)”: \(uploads) uploaded, \(downloads) downloaded."
    }

    private struct Downloaded {
        var page: SyncedPage
        var localID: String?
    }

    private func download(_ remotePage: RemotePage, into section: SectionRef, replacing existing: PageMeta?) async throws -> SyncedPage {
        try await download(remotePage, into: section, replacing: existing, suffix: "").page
    }

    private func download(_ remotePage: RemotePage, into section: SectionRef, replacing existing: PageMeta?,
                          suffix: String) async throws -> Downloaded {
        let data = try await graph.data("/me/onenote/pages/\(remotePage.id)/content")
        let graph = graph
        let imported = await OneNoteHTML.importPage(String(decoding: data, as: UTF8.self)) { url in
            try? await graph.data(url)
        }
        var meta = existing ?? PageMeta()
        meta.title = (imported.title.isEmpty ? remotePage.title : imported.title) + suffix
        if existing == nil {
            meta.level = min(max(remotePage.level, 0), 2)
            meta.created = imported.created ?? Date()
        }
        let ref = PageRef(notebookID: section.notebookID, sectionID: section.sectionID, pageID: meta.id)
        var elements = imported.elements
        for i in elements.indices {
            guard let (assetData, ext) = imported.assets[elements[i].id] else { continue }
            elements[i].asset = store.writeAsset(assetData, ext: ext, for: ref)
        }
        elements.removeAll { $0.asset == "pending" }
        let style = existing.flatMap { _ in store.loadPage(ref)?.style } ?? PageStyle(color: Prefs.pageColor, rules: Prefs.ruleLines)
        let content = PageContent(id: meta.id, title: meta.title, created: meta.created, style: style, elements: elements)
        let index = PageIndexer.index(elements: elements)
        meta.plainText = index.text
        meta.tags = index.tags
        meta.modified = Date()
        store.storeImportedPage(content, meta: meta, in: section)
        let synced = SyncedPage(remoteID: remotePage.id, remoteSectionID: remotePage.section,
                                remoteModified: remotePage.modified, localModified: meta.modified)
        return Downloaded(page: synced, localID: meta.id.uuidString)
    }

    private func upload(_ ref: PageRef, meta: PageMeta, section: String, replacing old: String?) async throws -> SyncedPage {
        guard var content = store.loadPage(ref) else { throw OneDriveError.server("Couldn't read “\(meta.displayTitle)”.") }
        content.title = meta.title
        let export = OneNoteHTML.export(content) { store.assetData($0, for: ref) }
        let created = try await graph.createPage(inSection: section, html: export.html, parts: export.parts)
        guard let id = created["id"] as? String else { throw OneDriveError.server("OneNote didn't accept “\(meta.displayTitle)”.") }
        if let old { try? await graph.delete("/me/onenote/pages/\(old)") }
        let modified = GraphClient.date(created["lastModifiedDateTime"]) ?? Date()
        return SyncedPage(remoteID: id, remoteSectionID: section, remoteModified: modified, localModified: meta.modified)
    }
}
