import Foundation

enum PrivateStorage {
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    static func ensureDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: url.path
        )
    }

    static func createFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: filePermissions]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try secureFile(at: url, fileManager: fileManager)
    }

    static func secureFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes(
            [.posixPermissions: filePermissions],
            ofItemAtPath: url.path
        )
    }

    static func write(
        _ data: Data,
        atomicallyTo url: URL,
        fileManager: FileManager = .default
    ) throws {
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
        }

        let temporaryURL = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try createFile(at: temporaryURL, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        try secureFile(at: url, fileManager: fileManager)
    }
}
