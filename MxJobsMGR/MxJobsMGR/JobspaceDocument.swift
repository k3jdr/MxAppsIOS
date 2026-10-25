//
//  JobspaceDocument.swift
//  MxJobsMGR
//
//  The document type of MxJobsMGR: a jobspace (*.jobspace), pretty-printed JSON.
//  Plain *.json files holding a jobspace can be opened too (saved back as *.jobspace).
//

import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
    static let jobspace = UTType(exportedAs: "com.k3jdr.mxjobsmgr.jobspace", conformingTo: .json)
}

nonisolated struct JobspaceDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.jobspace, .json]
    static let writableContentTypes: [UTType] = [.jobspace]

    var space: Jobspace

    init(space: Jobspace = Jobspace()) {
        self.space = space
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        space = try JSONDecoder().decode(Jobspace.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Self.encode(space))
    }

    static func encode(_ space: Jobspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(space)
    }
}
