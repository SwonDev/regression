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
}
