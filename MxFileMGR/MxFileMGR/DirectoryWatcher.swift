//
//  DirectoryWatcher.swift
//  MxFileMGR
//
//  Calls back when entries are added, removed or renamed in a folder,
//  so panes stay current without pressing Refresh.
//

import Foundation

nonisolated final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.fsPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .attrib], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
