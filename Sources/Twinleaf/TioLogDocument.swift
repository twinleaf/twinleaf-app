// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import UniformTypeIdentifiers

private final class TioLogBacking: @unchecked Sendable {
    let temporaryURL: URL

    init(initialData: Data = Data()) {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Twinleaf-\(UUID().uuidString)")
            .appendingPathExtension("tio")

        writeInitialData(initialData)

        TwinleafConsole.debug("[Twinleaf] document temporary log: \(temporaryURL.path)")
    }

    func readData() throws -> Data {
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
            return Data()
        }
        return try Data(contentsOf: temporaryURL)
    }

    func ensureLogFile() {
        guard !FileManager.default.fileExists(atPath: temporaryURL.path) else { return }
        _ = FileManager.default.createFile(atPath: temporaryURL.path, contents: Data())
    }

    /// Size of the log on disk, or 0 when it does not exist. Reads the file
    /// attributes rather than the contents so this stays cheap for long
    /// recordings.
    var logByteCount: Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    func removeLogFile() {
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private func writeInitialData(_ data: Data) {
        if data.isEmpty {
            _ = FileManager.default.createFile(atPath: temporaryURL.path, contents: Data())
        } else {
            try? data.write(to: temporaryURL, options: .atomic)
        }
    }
}

struct TioLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.twinleafTIO] }
    static var writableContentTypes: [UTType] { [.twinleafTIO] }

    private var backing: TioLogBacking
    private var changeRevision: UInt64 = 0
    let isLoadedFromFile: Bool
    let initialByteCount: Int

    var shouldOpenForInspection: Bool {
        isLoadedFromFile && initialByteCount > 0
    }

    var temporaryLogURL: URL {
        backing.temporaryURL
    }

    func ensureTemporaryLogFile() {
        backing.ensureLogFile()
    }

    func removeTemporaryLogFile() {
        backing.removeLogFile()
    }

    /// Whether nothing has been recorded yet, so the log can be discarded
    /// without losing data.
    var temporaryLogIsEmpty: Bool {
        backing.logByteCount == 0
    }

    init(data: Data = Data()) {
        backing = TioLogBacking(initialData: data)
        isLoadedFromFile = false
        initialByteCount = data.count
    }

    init(importedData data: Data) {
        backing = TioLogBacking(initialData: data)
        isLoadedFromFile = true
        initialByteCount = data.count
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        backing = TioLogBacking(initialData: data)
        isLoadedFromFile = true
        initialByteCount = data.count
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try backing.readData()
        TwinleafConsole.debug("[Twinleaf] saving \(data.count) byte(s) from \(backing.temporaryURL.path)")
        return FileWrapper(regularFileWithContents: data)
    }

    mutating func markLogUpdated() {
        changeRevision &+= 1
    }
}
