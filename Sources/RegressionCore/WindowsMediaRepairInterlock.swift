import Darwin
import Foundation

public struct WindowsMediaRepairLease: Equatable, Sendable {
    public let token: String
    public let ownerPID: Int32
    public let appID: String?
}

package struct WindowsMediaRuntimeLeaseSnapshot: Equatable, Sendable {
    package let token: String
    package let liveOwnerPIDs: Set<Int32>
}

public enum WindowsMediaRepairInterlockError: Error, Equatable {
    case invalidAuthorization
    case runtimeActive
    case leaseActive
    case pendingTransaction
    case leaseMismatch
    case unsafeStorage
}

/// Interlock efímero compartido por el engine y el reparador. El fichero no concede autoridad
/// por sí solo: cada consumo vuelve a comprobar reposo y el token se elimina al terminar.
public enum WindowsMediaRepairInterlock {
    private static let directory = "Locks/WindowsMedia"
    private static let relativePath = "Locks/WindowsMedia/runtime-or-repair.lease"
    /// Este archivo no es una autorización persistente. Solo ancla un `flock` durante la
    /// emisión para que la recuperación de una lease obsoleta no pueda borrar una lease nueva.
    private static let issuanceLockRelativePath = "Locks/WindowsMedia/issuance.lock"

    public static func issueRepairLease(
        appID: String,
        ownerPID: Int32,
        applicationSupportURL: URL,
        runtimeIsIdle: Bool
    ) throws -> WindowsMediaRepairLease {
        guard SteamAppID.normalized(appID) == appID, ownerPID > 1,
              processIsAlive(ownerPID), runtimeIsIdle else {
            throw runtimeIsIdle
                ? WindowsMediaRepairInterlockError.invalidAuthorization
                : WindowsMediaRepairInterlockError.runtimeActive
        }
        return try issue(
            kind: "repair",
            appID: appID,
            ownerPID: ownerPID,
            applicationSupportURL: applicationSupportURL
        )
    }

    public static func issueRuntimeLease(
        ownerPID: Int32,
        applicationSupportURL: URL
    ) throws -> WindowsMediaRepairLease {
        guard ownerPID > 1, processIsAlive(ownerPID) else {
            throw WindowsMediaRepairInterlockError.invalidAuthorization
        }
        return try issue(
            kind: "runtime",
            appID: nil,
            ownerPID: ownerPID,
            applicationSupportURL: applicationSupportURL
        )
    }

    /// Añade un emisor efímero a la misma sesión de runtime ya acreditada. Se usa únicamente
    /// para enviar `-applaunch` al Steam de Regression que ya está abierto: todos los PID vivos
    /// quedan en el mismo registro y una reparación continúa bloqueada hasta que terminen.
    package static func joinExistingRuntimeLease(
        ownerPID: Int32,
        expectedToken: String,
        expectedRuntimeOwnerPIDs: Set<Int32>,
        applicationSupportURL: URL
    ) throws -> WindowsMediaRepairLease {
        guard ownerPID > 1, processIsAlive(ownerPID), UUID(uuidString: expectedToken) != nil,
              !expectedRuntimeOwnerPIDs.isEmpty,
              expectedRuntimeOwnerPIDs.count <= 32 else {
            throw WindowsMediaRepairInterlockError.invalidAuthorization
        }
        guard let directoryRoot = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        try directoryRoot.ensurePrivateDirectory(relativePath: directory)
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return try withAnchoredIssuanceLock(applicationSupportURL: applicationSupportURL) {
            guard root.isStillNamedBy(applicationSupportURL) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            let current = try read(root: root)
            guard current.kind == "runtime", current.state == "issued", current.appID == nil,
                  current.token == expectedToken else {
                throw WindowsMediaRepairInterlockError.leaseActive
            }
            var liveOwners = current.ownerPIDs.filter(processIsAlive)
            guard !Set(liveOwners).isDisjoint(with: expectedRuntimeOwnerPIDs) else {
                throw WindowsMediaRepairInterlockError.leaseMismatch
            }
            if !liveOwners.contains(ownerPID) {
                guard liveOwners.count < 32 else {
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                liveOwners.append(ownerPID)
            }
            try write(
                LeaseRecord(
                    kind: current.kind,
                    state: current.state,
                    appID: current.appID,
                    ownerPIDs: liveOwners,
                    token: current.token
                ),
                replacing: true,
                root: root
            )
            guard root.isStillNamedBy(applicationSupportURL) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            return WindowsMediaRepairLease(
                token: current.token,
                ownerPID: ownerPID,
                appID: nil
            )
        }
    }

    package static func snapshotExistingRuntimeLease(
        applicationSupportURL: URL
    ) throws -> WindowsMediaRuntimeLeaseSnapshot {
        try withAnchoredIssuanceLock(applicationSupportURL: applicationSupportURL) {
            guard let root = AnchoredDirectory.open(applicationSupportURL),
                  root.isStillNamedBy(applicationSupportURL) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            let current = try read(root: root)
            let liveOwners = Set(current.ownerPIDs.filter(processIsAlive))
            guard current.kind == "runtime", current.state == "issued", current.appID == nil,
                  !liveOwners.isEmpty else {
                throw WindowsMediaRepairInterlockError.leaseMismatch
            }
            return WindowsMediaRuntimeLeaseSnapshot(
                token: current.token,
                liveOwnerPIDs: liveOwners
            )
        }
    }

    public static func consumeRepairLease(
        appID: String,
        token: String,
        ownerPID: Int32,
        applicationSupportURL: URL,
        runtimeIsIdle: Bool
    ) throws {
        guard runtimeIsIdle else { throw WindowsMediaRepairInterlockError.runtimeActive }
        let current = try read(applicationSupportURL: applicationSupportURL)
        guard current.kind == "repair", ["issued", "consumed"].contains(current.state), current.appID == appID,
              current.token == token, current.ownerPIDs == [ownerPID],
              processIsAlive(ownerPID) else {
            throw WindowsMediaRepairInterlockError.leaseMismatch
        }
        try write(
            LeaseRecord(
                kind: current.kind,
                state: "consumed",
                appID: current.appID,
                ownerPIDs: current.ownerPIDs,
                token: current.token
            ),
            replacing: true,
            applicationSupportURL: applicationSupportURL
        )
    }

    public static func release(
        token: String,
        ownerPID: Int32,
        applicationSupportURL: URL
    ) throws {
        try withAnchoredIssuanceLock(applicationSupportURL: applicationSupportURL) {
            guard let root = AnchoredDirectory.open(applicationSupportURL),
                  root.isStillNamedBy(applicationSupportURL) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            let current = try read(root: root)
            guard current.token == token, current.ownerPIDs.contains(ownerPID) else {
                throw WindowsMediaRepairInterlockError.leaseMismatch
            }
            if current.kind == "runtime" {
                let remaining = current.ownerPIDs.filter {
                    $0 != ownerPID && processIsAlive($0)
                }
                if !remaining.isEmpty {
                    try write(
                        LeaseRecord(
                            kind: current.kind,
                            state: current.state,
                            appID: current.appID,
                            ownerPIDs: remaining,
                            token: current.token
                        ),
                        replacing: true,
                        root: root
                    )
                    return
                }
            }
            try root.unlinkRegularFile(relativePath: relativePath)
        }
    }

    private struct LeaseRecord {
        let kind: String
        let state: String
        let appID: String?
        let ownerPIDs: [Int32]
        let token: String

        var data: Data {
            let ownerField = kind == "runtime"
                ? "owner_pids=\(ownerPIDs.map(String.init).joined(separator: ","))"
                : "owner_pid=\(ownerPIDs[0])"
            return Data([
                "schema=\(kind == "runtime" ? "2" : "1")",
                "kind=\(kind)",
                "state=\(state)",
                "app_id=\(appID ?? "none")",
                ownerField,
                "token=\(token)",
            ].joined(separator: "\n").appending("\n").utf8)
        }
    }

    private static func issue(
        kind: String,
        appID: String?,
        ownerPID: Int32,
        applicationSupportURL: URL
    ) throws -> WindowsMediaRepairLease {
        guard let directoryRoot = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        try directoryRoot.ensurePrivateDirectory(relativePath: directory)
        // `ensurePrivateDirectory` sincroniza el padre y cambia su mtime; anclamos una identidad
        // nueva para las comprobaciones de nombre que siguen a la preparación del directorio.
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return try withAnchoredIssuanceLock(applicationSupportURL: applicationSupportURL) {
            // El descriptor de la lease y el del lock deben referirse a la misma raíz todavía
            // nombrada. Si la raíz cambia, no devolvemos una autorización de un estado huérfano.
            guard root.isStillNamedBy(applicationSupportURL) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }

            let current: LeaseRecord?
            do {
                current = try read(root: root)
            } catch {
                // Una lease existente pero ilegible nunca se trata como ausente. Solo ENOENT
                // permite continuar; cualquier registro malformado o sustituido bloquea.
                let exists: Bool
                do {
                    exists = try root.regularFileExists(relativePath: relativePath)
                } catch {
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                guard !exists else { throw WindowsMediaRepairInterlockError.unsafeStorage }
                current = nil
            }
            if let current {
                if current.ownerPIDs.contains(where: processIsAlive) {
                    throw WindowsMediaRepairInterlockError.leaseActive
                }
#if DEBUG
                invokeTestingStaleLeaseObservedHook()
#endif
                // La observación y el unlink están bajo el mismo flock anclado. Otro emisor no
                // puede sustituir este nombre entre ambas operaciones.
                try root.unlinkRegularFile(relativePath: relativePath)
            }
            if kind == "runtime" {
                let pendingIntent: Bool
                do {
                    pendingIntent = try root.regularFileExists(
                        relativePath: WindowsMediaAnchoredPrivateFile.intent.relativePath
                    )
                } catch {
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                guard !pendingIntent else {
                    throw WindowsMediaRepairInterlockError.pendingTransaction
                }
            }
            let lease = WindowsMediaRepairLease(
                token: UUID().uuidString.lowercased(),
                ownerPID: ownerPID,
                appID: appID
            )
            try write(
                LeaseRecord(
                    kind: kind,
                    state: "issued",
                    appID: appID,
                    ownerPIDs: [ownerPID],
                    token: lease.token
                ),
                replacing: false,
                root: root
            )
            guard root.isStillNamedBy(applicationSupportURL) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            return lease
        }
    }

    /// Serializa exactamente el tramo `read stale -> unlink -> createExclusive`. El lock se abre
    /// recorriendo la raíz con `openat(O_NOFOLLOW)`: no se toma un lock mediante una ruta que
    /// pueda redirigirse entre la comprobación y la apertura.
    private static func withAnchoredIssuanceLock<T>(
        applicationSupportURL: URL,
        _ body: () throws -> T
    ) throws -> T {
        let lock = try AnchoredIssuanceLock(
            rootURL: applicationSupportURL,
            relativePath: issuanceLockRelativePath
        )
        defer { lock.release() }
        return try body()
    }

    private static func write(
        _ record: LeaseRecord,
        replacing: Bool,
        applicationSupportURL: URL
    ) throws {
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        try write(record, replacing: replacing, root: root)
    }

    private static func write(
        _ record: LeaseRecord,
        replacing: Bool,
        root: AnchoredDirectory
    ) throws {
        if replacing {
            try root.replaceRegularFile(relativePath: relativePath, data: record.data)
        } else {
            try root.createExclusiveRegularFile(relativePath: relativePath, data: record.data)
        }
    }

    private static func read(applicationSupportURL: URL) throws -> LeaseRecord {
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return try read(root: root)
    }

    private static func read(root: AnchoredDirectory) throws -> LeaseRecord {
        guard let text = String(
            data: try root.readPrivateRegularFile(
                relativePath: relativePath,
                maximumBytes: 1_024,
                ownerUID: Darwin.getuid()
            ),
            encoding: .utf8
        ) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            let key = String(line[..<separator])
            guard values[key] == nil else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            values[key] = String(line[line.index(after: separator)...])
        }
        guard values.count == 6,
              let schema = values["schema"], ["1", "2"].contains(schema),
              let kind = values["kind"], ["repair", "runtime"].contains(kind),
              let state = values["state"], ["issued", "consumed"].contains(state),
              let token = values["token"], UUID(uuidString: token) != nil else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        let ownerPIDs: [Int32]
        if schema == "1", let rawPID = values["owner_pid"],
           let ownerPID = Int32(rawPID), ownerPID > 1, values["owner_pids"] == nil {
            ownerPIDs = [ownerPID]
        } else if schema == "2", kind == "runtime", values["owner_pid"] == nil,
                  let rawPIDs = values["owner_pids"] {
            let fields = rawPIDs.split(separator: ",", omittingEmptySubsequences: false)
            guard !fields.isEmpty, fields.count <= 32 else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            ownerPIDs = try fields.map { field in
                guard let ownerPID = Int32(field), ownerPID > 1 else {
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                return ownerPID
            }
            guard Set(ownerPIDs).count == ownerPIDs.count else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
        } else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        let appID = values["app_id"].flatMap { $0 == "none" ? nil : $0 }
        guard (kind == "runtime" && appID == nil)
            || (kind == "repair" && appID.flatMap(SteamAppID.normalized) == appID) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return LeaseRecord(
            kind: kind,
            state: state,
            appID: appID,
            ownerPIDs: ownerPIDs,
            token: token
        )
    }

    private static func processIsAlive(_ processID: Int32) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

#if DEBUG
    /// Gancho interno de pruebas para forzar la única intercalación peligrosa conocida. No está
    /// presente en Release y nunca participa en la autorización de producción.
    static func withTestingStaleLeaseObservedHook<T>(
        _ hook: @escaping () -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        testingHookLock.lock()
        testingStaleLeaseObservedHook = hook
        testingHookLock.unlock()
        defer {
            testingHookLock.lock()
            testingStaleLeaseObservedHook = nil
            testingHookLock.unlock()
        }
        return try body()
    }

    private static let testingHookLock = NSLock()
    private nonisolated(unsafe) static var testingStaleLeaseObservedHook: (() -> Void)?

    private static func invokeTestingStaleLeaseObservedHook() {
        testingHookLock.lock()
        let hook = testingStaleLeaseObservedHook
        testingHookLock.unlock()
        hook?()
    }
#endif
}

/// Lock de emisión con un descriptor propio. Persistir el fichero es deliberado: `flock` vive en
/// el descriptor y se libera automáticamente si el emisor muere, así que no existe recuperación
/// por pathname ni un segundo token que pueda convertirse en autoridad.
private final class AnchoredIssuanceLock {
    private let descriptor: Int32

    init(rootURL: URL, relativePath: String) throws {
        let rootFD = try Self.openRootDirectory(rootURL)
        var parentFD = rootFD
        do {
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count >= 2,
                  components.dropLast().allSatisfy(Self.isSafeComponent),
                  let fileName = components.last,
                  Self.isSafeComponent(fileName) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            for component in components.dropLast() {
                let nextFD = component.withCString {
                    Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard nextFD >= 0, try Self.isPrivateDirectory(nextFD) else {
                    if nextFD >= 0 { Darwin.close(nextFD) }
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                Darwin.close(parentFD)
                parentFD = nextFD
            }
            let lockFD = fileName.withCString {
                Darwin.openat(parentFD, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard lockFD >= 0 else { throw WindowsMediaRepairInterlockError.unsafeStorage }
            do {
                var metadata = stat()
                guard Darwin.fstat(lockFD, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG,
                      metadata.st_nlink == 1,
                      metadata.st_uid == Darwin.getuid(),
                      metadata.st_mode & 0o7777 == 0o600,
                      Darwin.fsync(lockFD) == 0,
                      Darwin.fsync(parentFD) == 0 else {
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                while flock(lockFD, LOCK_EX) != 0 {
                    guard errno == EINTR else { throw WindowsMediaRepairInterlockError.unsafeStorage }
                }
                descriptor = lockFD
            } catch {
                Darwin.close(lockFD)
                throw error
            }
        } catch {
            Darwin.close(parentFD)
            throw error
        }
        Darwin.close(parentFD)
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func openRootDirectory(_ rootURL: URL) throws -> Int32 {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"), rootURL.path != "/" else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        let path = try canonicalSystemAliasPath(rootURL.standardizedFileURL.path)
        let components = Array(URL(fileURLWithPath: path).pathComponents.dropFirst())
        guard !components.isEmpty, components.allSatisfy(isSafeComponent) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        var currentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else { throw WindowsMediaRepairInterlockError.unsafeStorage }
        do {
            for component in components {
                let nextFD = component.withCString {
                    Darwin.openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard nextFD >= 0, try isDirectory(nextFD) else {
                    if nextFD >= 0 { Darwin.close(nextFD) }
                    throw WindowsMediaRepairInterlockError.unsafeStorage
                }
                Darwin.close(currentFD)
                currentFD = nextFD
            }
            guard try isPrivateDirectory(currentFD) else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            return currentFD
        } catch {
            Darwin.close(currentFD)
            throw error
        }
    }

    private static func canonicalSystemAliasPath(_ path: String) throws -> String {
        let aliases = [
            (alias: "/tmp", target: "/private/tmp"),
            (alias: "/var", target: "/private/var"),
            (alias: "/etc", target: "/private/etc"),
        ]
        for candidate in aliases where path == candidate.alias || path.hasPrefix(candidate.alias + "/") {
            var metadata = stat()
            guard candidate.alias.withCString({ Darwin.lstat($0, &metadata) }) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFLNK else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = candidate.alias.withCString {
                Darwin.readlink($0, &target, Int(PATH_MAX))
            }
            guard count > 0 else { throw WindowsMediaRepairInterlockError.unsafeStorage }
            let actual = String(
                decoding: target.prefix(Int(count)).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            let expectedRelative = String(candidate.target.dropFirst())
            guard actual == candidate.target || actual == expectedRelative else {
                throw WindowsMediaRepairInterlockError.unsafeStorage
            }
            return candidate.target + path.dropFirst(candidate.alias.count)
        }
        return path
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private static func isPrivateDirectory(_ descriptor: Int32) throws -> Bool {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == Darwin.getuid()
            && metadata.st_mode & 0o0022 == 0
    }

    private static func isDirectory(_ descriptor: Int32) throws -> Bool {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return metadata.st_mode & S_IFMT == S_IFDIR
    }
}

public enum WindowsMediaAnchoredLinkMutation: Sendable {
    case createStage(stageName: String, targetURL: URL)
    case backupCurrent(backupName: String)
    case commitStage(stageName: String)
    case restoreBackup(backupName: String)
    case removeCurrent
    case removeStage(stageName: String)
}

public enum WindowsMediaAnchoredLinkMutator {
    public static func apply(
        _ mutation: WindowsMediaAnchoredLinkMutation,
        applicationSupportURL: URL,
        authorizedPayloadURL: URL
    ) throws {
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        try root.ensurePrivateDirectory(relativePath: "Components/WindowsMedia")
        try root.ensurePrivateDirectory(relativePath: "Backups/Components/WindowsMedia")
        switch mutation {
        case .createStage(let stageName, let targetURL):
            guard validStage(stageName),
                  targetURL.standardizedFileURL == authorizedPayloadURL.standardizedFileURL else {
                throw WindowsMediaRepairInterlockError.invalidAuthorization
            }
            try root.createSymbolicLink(
                relativePath: "Components/WindowsMedia/\(stageName)",
                target: authorizedPayloadURL.path
            )
        case .backupCurrent(let backupName):
            guard validBackup(backupName) else {
                throw WindowsMediaRepairInterlockError.invalidAuthorization
            }
            try root.rename(
                relativeSource: "Components/WindowsMedia/1",
                relativeDestination: "Backups/Components/WindowsMedia/\(backupName)"
            )
        case .commitStage(let stageName):
            guard validStage(stageName) else {
                throw WindowsMediaRepairInterlockError.invalidAuthorization
            }
            try root.rename(
                relativeSource: "Components/WindowsMedia/\(stageName)",
                relativeDestination: "Components/WindowsMedia/1"
            )
        case .restoreBackup(let backupName):
            guard validBackup(backupName) else {
                throw WindowsMediaRepairInterlockError.invalidAuthorization
            }
            try root.rename(
                relativeSource: "Backups/Components/WindowsMedia/\(backupName)",
                relativeDestination: "Components/WindowsMedia/1"
            )
        case .removeCurrent:
            try root.unlink(relativePath: "Components/WindowsMedia/1")
        case .removeStage(let stageName):
            guard validStage(stageName) else {
                throw WindowsMediaRepairInterlockError.invalidAuthorization
            }
            try root.unlink(relativePath: "Components/WindowsMedia/\(stageName)")
        }
    }

    private static func validStage(_ value: String) -> Bool {
        value.hasPrefix(".1-stage-")
            && !value.dropFirst(".1-stage-".count).isEmpty
            && value.dropFirst(".1-stage-".count).allSatisfy(\.isNumber)
    }

    private static func validBackup(_ value: String) -> Bool {
        let prefix = "1-before-repair-"
        guard value.hasPrefix(prefix), value.utf8.count <= 80 else { return false }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || byte == 0x2d
        }
    }
}

public enum WindowsMediaAnchoredPrivateFile: String, Sendable {
    case intent
    case receipt

    fileprivate var relativePath: String {
        switch self {
        case .intent:
            "Transactions/WindowsMedia/1-link-repair.intent"
        case .receipt:
            "Receipts/Components/WindowsMedia/1-link-repair.receipt"
        }
    }

    fileprivate var parentDirectory: String {
        switch self {
        case .intent: "Transactions/WindowsMedia"
        case .receipt: "Receipts/Components/WindowsMedia"
        }
    }
}

public enum WindowsMediaAnchoredPrivateFileStore {
    public static func prepare(applicationSupportURL: URL) throws {
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        for relativePath in [
            "Components/WindowsMedia",
            "Backups/Components/WindowsMedia",
            "Transactions/WindowsMedia",
            "Receipts/Components/WindowsMedia",
        ] {
            try root.ensurePrivateDirectory(relativePath: relativePath)
        }
    }

    public static func read(
        _ file: WindowsMediaAnchoredPrivateFile,
        applicationSupportURL: URL
    ) throws -> Data {
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        return try root.readPrivateRegularFile(
            relativePath: file.relativePath,
            maximumBytes: 8 * 1_024,
            ownerUID: Darwin.getuid()
        )
    }

    public static func write(
        _ data: Data,
        to file: WindowsMediaAnchoredPrivateFile,
        applicationSupportURL: URL
    ) throws {
        guard !data.isEmpty, data.count <= 8 * 1_024, !data.contains(0),
              let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        try root.ensurePrivateDirectory(relativePath: file.parentDirectory)
        try root.replaceRegularFile(relativePath: file.relativePath, data: data)
    }

    public static func remove(
        _ file: WindowsMediaAnchoredPrivateFile,
        applicationSupportURL: URL
    ) throws {
        guard let root = AnchoredDirectory.open(applicationSupportURL) else {
            throw WindowsMediaRepairInterlockError.unsafeStorage
        }
        try root.unlinkRegularFile(relativePath: file.relativePath)
    }
}
