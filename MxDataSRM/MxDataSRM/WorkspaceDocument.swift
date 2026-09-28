//
//  WorkspaceDocument.swift
//  MxDataSRM
//
//  A "workspace" is the document type of MxDataSRM: a small JSON file
//  (*.mxworkspace) that remembers the connection parameters, the selected
//  table and the grid view settings. The password is never written to the
//  file; it is kept in the macOS Keychain (see Keychain.swift).
//

import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
    static let mxWorkspace = UTType(exportedAs: "com.k3jdr.mxdatasrm.workspace", conformingTo: .json)
}

nonisolated enum SSLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disable, prefer, require
    var id: String { rawValue }
}

nonisolated struct ConnectionSettings: Codable, Equatable, Sendable {
    var host = "localhost"
    var port = 5432
    var user = NSUserName()
    var database = "postgres"
    var sslMode: SSLMode = .prefer
    var savePasswordInKeychain = true

    /// Keychain account under which the password for these settings is stored.
    var keychainAccount: String { "\(user)@\(host):\(port)/\(database)" }
}

nonisolated struct TableRef: Codable, Hashable, Sendable {
    var schema: String
    var name: String

    var qualifiedSQL: String { quoteIdent(schema) + "." + quoteIdent(name) }
    var displayName: String { "\(schema).\(name)" }
}

nonisolated struct GridViewSettings: Codable, Equatable, Sendable {
    /// Rows visible in the grid viewport (the rest is reached by scrolling).
    var visibleRows = 10
    /// Columns visible in the grid viewport (the rest is reached by scrolling).
    var visibleColumns = 3
    /// Maximum number of rows fetched from the table.
    var fetchLimit = 1000
}

nonisolated struct Workspace: Codable, Equatable, Sendable {
    var formatVersion = 1
    var connection = ConnectionSettings()
    var selectedTable: TableRef?
    var view = GridViewSettings()
}

nonisolated struct WorkspaceDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.mxWorkspace]

    var workspace: Workspace

    init(workspace: Workspace = Workspace()) {
        self.workspace = workspace
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        workspace = try JSONDecoder().decode(Workspace.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(workspace))
    }
}

/// Quotes a PostgreSQL identifier ("my""table").
nonisolated func quoteIdent(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
