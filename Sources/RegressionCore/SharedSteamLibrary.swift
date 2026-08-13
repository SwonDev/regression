import CryptoKit
import Darwin
import Foundation

public enum SharedLibraryStatus: Equatable, Sendable {
    case notConfigured
    case ready
    case blocked(String)
}

public struct SharedLibraryAssessment: Equatable, Sendable {
    public let status: SharedLibraryStatus
    public let regressionSteamAppsURL: URL
    public let crossOverSteamAppsURL: URL
    public let onlyInRegression: [String]
    public let onlyInCrossOver: [String]

    public init(
        status: SharedLibraryStatus,
        regressionSteamAppsURL: URL,
        crossOverSteamAppsURL: URL,
        onlyInRegression: [String],
        onlyInCrossOver: [String]
    ) {
        self.status = status
        self.regressionSteamAppsURL = regressionSteamAppsURL
        self.crossOverSteamAppsURL = crossOverSteamAppsURL
        self.onlyInRegression = onlyInRegression
        self.onlyInCrossOver = onlyInCrossOver
    }
}

public enum PhysicalLibraryCustodyStatus: Equatable, Sendable {
    case eligibleForTransfer
    case migrationPlanned
    case alreadyOwned
    case blocked(String)
}

/// Ruta heredada que identifica la biblioteca compartida aunque CrossOver ya no esté instalado.
public struct PhysicalLibraryCustodyIdentity: Equatable, Sendable {
    public let legacySteamAppsURL: URL

    public init(legacySteamAppsURL: URL) {
        self.legacySteamAppsURL = legacySteamAppsURL.standardizedFileURL
    }
}

public struct PhysicalLibraryInventoryLimits: Equatable, Sendable {
    public static let standard = PhysicalLibraryInventoryLimits(
        maxEntries: 1_000_000,
        maxDepth: 256,
        maxTotalRegularFileBytes: 64 * 1_024 * 1_024 * 1_024 * 1_024,
        maxManifestBytes: 4 * 1_024 * 1_024,
        maxJournalBytes: 1 * 1_024 * 1_024
    )

    public let maxEntries: Int
    public let maxDepth: Int
    public let maxTotalRegularFileBytes: UInt64
    public let maxManifestBytes: Int
    public let maxJournalBytes: Int

    public init(
        maxEntries: Int,
        maxDepth: Int,
        maxTotalRegularFileBytes: UInt64,
        maxManifestBytes: Int = 4 * 1_024 * 1_024,
        maxJournalBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.maxEntries = maxEntries
        self.maxDepth = maxDepth
        self.maxTotalRegularFileBytes = maxTotalRegularFileBytes
        self.maxManifestBytes = maxManifestBytes
        self.maxJournalBytes = maxJournalBytes
    }
}

public struct PhysicalLibraryInventory: Codable, Equatable, Sendable {
    public let manifestAppIDs: [String]
    public let manifestSHA256ByAppID: [String: String]
    public let regularFileCount: Int
    public let directoryCount: Int
    public let totalRegularFileBytes: UInt64
    /// Huella de estructura, tamaños, mtimes y manifiestos. No acredita identidad byte a byte.
    public let structuralFingerprint: String

    public init(
        manifestAppIDs: [String],
        manifestSHA256ByAppID: [String: String],
        regularFileCount: Int,
        directoryCount: Int,
        totalRegularFileBytes: UInt64,
        structuralFingerprint: String
    ) {
        self.manifestAppIDs = manifestAppIDs
        self.manifestSHA256ByAppID = manifestSHA256ByAppID
        self.regularFileCount = regularFileCount
        self.directoryCount = directoryCount
        self.totalRegularFileBytes = totalRegularFileBytes
        self.structuralFingerprint = structuralFingerprint
    }

    fileprivate static let empty = PhysicalLibraryInventory(
        manifestAppIDs: [],
        manifestSHA256ByAppID: [:],
        regularFileCount: 0,
        directoryCount: 0,
        totalRegularFileBytes: 0,
        structuralFingerprint: ""
    )
}

public struct PhysicalLibraryCustodyAssessment: Equatable, Sendable {
    public let status: PhysicalLibraryCustodyStatus
    public let sourceSteamAppsURL: URL
    public let destinationSteamAppsURL: URL
    public let inventory: PhysicalLibraryInventory

    public init(
        status: PhysicalLibraryCustodyStatus,
        sourceSteamAppsURL: URL,
        destinationSteamAppsURL: URL,
        inventory: PhysicalLibraryInventory
    ) {
        self.status = status
        self.sourceSteamAppsURL = sourceSteamAppsURL
        self.destinationSteamAppsURL = destinationSteamAppsURL
        self.inventory = inventory
    }
}

enum PhysicalLibraryCustodyPhase: String, Codable, Equatable, Sendable {
    case planned
}

/// Plan durable de una futura transferencia. No ejecuta ni autoriza el cutover: la huella del
/// inventario es estructural y no demuestra que cada byte de los juegos sea idéntico.
struct PhysicalLibraryCustodyPlan: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let planID: UUID
    let createdAt: Date
    let phase: PhysicalLibraryCustodyPhase
    let sourceSteamAppsURL: URL
    let destinationSteamAppsURL: URL
    let transitionalLinks: [URL: URL]
    let inventory: PhysicalLibraryInventory

    init(
        schemaVersion: Int = 2,
        planID: UUID,
        createdAt: Date,
        phase: PhysicalLibraryCustodyPhase,
        sourceSteamAppsURL: URL,
        destinationSteamAppsURL: URL,
        transitionalLinks: [URL: URL],
        inventory: PhysicalLibraryInventory
    ) {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.createdAt = createdAt
        self.phase = phase
        self.sourceSteamAppsURL = sourceSteamAppsURL
        self.destinationSteamAppsURL = destinationSteamAppsURL
        self.transitionalLinks = transitionalLinks
        self.inventory = inventory
    }
}

public actor SharedSteamLibraryManager {
    public typealias VolumeIdentityProvider = @Sendable (URL) -> String?
    typealias DirectoryEnumeratorProvider = @Sendable (
        URL,
        [URLResourceKey],
        FileManager.DirectoryEnumerationOptions,
        @escaping @Sendable (URL, String) -> Void
    ) -> FileManager.DirectoryEnumerator?

    private let fileManager: FileManager
    private let backupRootURL: URL
    private let volumeIdentityProvider: VolumeIdentityProvider
    private let inventoryLimits: PhysicalLibraryInventoryLimits
    private let directoryEnumeratorProvider: DirectoryEnumeratorProvider
    private let beforeJournalUnlink: @Sendable () -> Void

    public init(
        fileManager: FileManager = .default,
        backupRootURL: URL,
        volumeIdentityProvider: VolumeIdentityProvider? = nil,
        inventoryLimits: PhysicalLibraryInventoryLimits = .standard
    ) {
        self.fileManager = fileManager
        self.backupRootURL = backupRootURL.standardizedFileURL
        self.volumeIdentityProvider = volumeIdentityProvider ?? { url in
            SharedSteamLibraryManager.defaultVolumeIdentity(for: url)
        }
        self.inventoryLimits = inventoryLimits
        let enumeratingFileManager = SendableFileManager(fileManager)
        self.directoryEnumeratorProvider = { root, keys, options, reportFailure in
            enumeratingFileManager.value.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options,
                errorHandler: { url, error in
                    reportFailure(url, error.localizedDescription)
                    return false
                }
            )
        }
        self.beforeJournalUnlink = {}
    }

    init(
        fileManager: FileManager = .default,
        backupRootURL: URL,
        volumeIdentityProvider: VolumeIdentityProvider? = nil,
        inventoryLimits: PhysicalLibraryInventoryLimits = .standard,
        directoryEnumeratorProvider: @escaping DirectoryEnumeratorProvider,
        beforeJournalUnlink: @escaping @Sendable () -> Void = {}
    ) {
        self.fileManager = fileManager
        self.backupRootURL = backupRootURL.standardizedFileURL
        self.volumeIdentityProvider = volumeIdentityProvider ?? { url in
            SharedSteamLibraryManager.defaultVolumeIdentity(for: url)
        }
        self.inventoryLimits = inventoryLimits
        self.directoryEnumeratorProvider = directoryEnumeratorProvider
        self.beforeJournalUnlink = beforeJournalUnlink
    }

    nonisolated var physicalCustodyJournalURL: URL {
        backupRootURL.appendingPathComponent("physical-custody-journal.json")
    }

    public func assess(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation
    ) -> SharedLibraryAssessment {
        let regressionSteamApps = regression.steamRootURL.appendingPathComponent("steamapps", isDirectory: true)
        let crossOverSteamApps = crossOver.steamRootURL.appendingPathComponent("steamapps", isDirectory: true)

        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: regressionSteamApps.path) {
            let resolved: URL
            if destination.hasPrefix("/") {
                resolved = URL(fileURLWithPath: destination)
            } else {
                resolved = regressionSteamApps.deletingLastPathComponent().appendingPathComponent(destination)
            }
            let ready = resolved.standardizedFileURL.resolvingSymlinksInPath()
                == crossOverSteamApps.standardizedFileURL.resolvingSymlinksInPath()
            return SharedLibraryAssessment(
                status: ready ? .ready : .blocked("steamapps ya apunta a otra ubicación"),
                regressionSteamAppsURL: regressionSteamApps,
                crossOverSteamAppsURL: crossOverSteamApps,
                onlyInRegression: [],
                onlyInCrossOver: []
            )
        }

        guard fileManager.fileExists(atPath: crossOverSteamApps.path) else {
            return SharedLibraryAssessment(
                status: .blocked("CrossOver no contiene una carpeta steamapps"),
                regressionSteamAppsURL: regressionSteamApps,
                crossOverSteamAppsURL: crossOverSteamApps,
                onlyInRegression: [],
                onlyInCrossOver: []
            )
        }

        let regressionIDs = Set(SteamManifestParser.games(in: regression.steamRootURL, backend: .regression).map(\.appID))
        let crossOverIDs = Set(SteamManifestParser.games(in: crossOver.steamRootURL, backend: .crossOver).map(\.appID))
        return SharedLibraryAssessment(
            status: .notConfigured,
            regressionSteamAppsURL: regressionSteamApps,
            crossOverSteamAppsURL: crossOverSteamApps,
            onlyInRegression: regressionIDs.subtracting(crossOverIDs).sorted(),
            onlyInCrossOver: crossOverIDs.subtracting(regressionIDs).sorted()
        )
    }

    /// Wrapper compatible para el comparador opcional mientras siga disponible.
    public func assessPhysicalCustody(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) -> PhysicalLibraryCustodyAssessment {
        assessPhysicalCustody(
            regression: regression,
            legacyIdentity: PhysicalLibraryCustodyIdentity(
                legacySteamAppsURL: crossOver.steamRootURL
                    .appendingPathComponent("steamapps", isDirectory: true)
            ),
            regressionOwnedSteamAppsURL: regressionOwnedSteamAppsURL,
            runningState: runningState
        )
    }

    /// Evalúa la custodia física sin modificar bibliotecas ni enlaces y sin requerir CrossOver.
    public func assessPhysicalCustody(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) -> PhysicalLibraryCustodyAssessment {
        let source = legacyIdentity.legacySteamAppsURL.standardizedFileURL
        let destination = regressionOwnedSteamAppsURL.standardizedFileURL
        let regressionLink = regression.steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
            .standardizedFileURL

        func blocked(_ reason: String, inventory: PhysicalLibraryInventory = .empty)
            -> PhysicalLibraryCustodyAssessment
        {
            PhysicalLibraryCustodyAssessment(
                status: .blocked(reason),
                sourceSteamAppsURL: source,
                destinationSteamAppsURL: destination,
                inventory: inventory
            )
        }

        guard !runningState.crossOverIsRunning, !runningState.regressionIsRunning else {
            return blocked("Steam debe estar completamente cerrado")
        }

        do {
            try validateNoLinkedAncestors(at: source, includeFinalItem: false, role: "fuente heredada")
            try validateNoLinkedAncestors(at: destination, includeFinalItem: true, role: "destino")
            try validateNoLinkedAncestors(at: regressionLink, includeFinalItem: false, role: "enlace de Regression")

            let destinationCanonical = try canonicalPath(for: destination)
            if let sourceLink = symbolicLinkDestination(at: source) {
                guard let regressionLinkDestination = symbolicLinkDestination(at: regressionLink),
                      try canonicalPath(for: sourceLink) == destinationCanonical,
                      try canonicalPath(for: regressionLinkDestination) == destinationCanonical,
                      directoryExistsWithoutSymbolicLink(at: destination) else {
                    return blocked("La fuente steamapps heredada es un enlace simbólico inesperado")
                }
                do {
                    return PhysicalLibraryCustodyAssessment(
                        status: .alreadyOwned,
                        sourceSteamAppsURL: source,
                        destinationSteamAppsURL: destination,
                        inventory: try inventory(at: destination)
                    )
                } catch {
                    return blocked(
                        "No se pudo verificar la biblioteca bajo custodia de Regression: "
                            + error.localizedDescription
                    )
                }
            }

            try validateNoLinkedAncestors(at: source, includeFinalItem: true, role: "fuente heredada")
            let sourceCanonical = try canonicalPath(for: source)
            guard !sourceCanonical.overlaps(destinationCanonical) else {
                return blocked("El destino de Regression se solapa con la biblioteca de origen")
            }
            if pathExistsWithoutFollowingSymbolicLinks(destination) {
                return blocked("El destino de Regression ya está ocupado")
            }
            guard directoryExistsWithoutSymbolicLink(at: source) else {
                return blocked("La ruta heredada no contiene una carpeta steamapps física")
            }
            guard let regressionDestination = symbolicLinkDestination(at: regressionLink),
                  try canonicalPath(for: regressionDestination) == sourceCanonical else {
                return blocked("steamapps de Regression no apunta exactamente a la biblioteca compartida actual")
            }
            guard let sourceVolume = volumeIdentityProvider(source),
                  let destinationVolume = volumeIdentityProvider(destination),
                  sourceVolume == destinationVolume else {
                return blocked("La transferencia cruza volúmenes distintos y no puede ser atómica")
            }

            let inventory = try inventory(at: source)
            try validateJournalParent()
            let status: PhysicalLibraryCustodyStatus
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL) {
                do {
                    _ = try validatedPendingPhysicalCustodyPlan(
                        source: source,
                        destination: destination,
                        regressionLink: regressionLink,
                        inventory: inventory
                    )
                    status = .migrationPlanned
                } catch let RegressionCoreError.unsafeLibraryState(detail) {
                    return blocked("El journal de custodia no es válido: \(detail)", inventory: inventory)
                } catch {
                    return blocked(
                        "El journal de custodia no es válido: \(error.localizedDescription)",
                        inventory: inventory
                    )
                }
            } else {
                status = .eligibleForTransfer
            }
            return PhysicalLibraryCustodyAssessment(
                status: status,
                sourceSteamAppsURL: source,
                destinationSteamAppsURL: destination,
                inventory: inventory
            )
        } catch is CancellationError {
            return blocked("El inventario de steamapps fue cancelado")
        } catch {
            return blocked("No se pudo inventariar steamapps de forma segura: \(error.localizedDescription)")
        }
    }

    /// Wrapper compatible para el comparador opcional mientras siga disponible.
    @discardableResult
    func preparePhysicalCustodyPlan(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) throws -> PhysicalLibraryCustodyPlan {
        try preparePhysicalCustodyPlan(
            regression: regression,
            legacyIdentity: PhysicalLibraryCustodyIdentity(
                legacySteamAppsURL: crossOver.steamRootURL
                    .appendingPathComponent("steamapps", isDirectory: true)
            ),
            regressionOwnedSteamAppsURL: regressionOwnedSteamAppsURL,
            runningState: runningState
        )
    }

    /// Persiste un journal privado e idempotente. No mueve archivos ni cambia enlaces.
    @discardableResult
    func preparePhysicalCustodyPlan(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) throws -> PhysicalLibraryCustodyPlan {
        try validateJournalParent()
        if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL) {
            return try recoverPhysicalCustodyPlan(
                regression: regression,
                legacyIdentity: legacyIdentity,
                regressionOwnedSteamAppsURL: regressionOwnedSteamAppsURL,
                runningState: runningState
            )
        }

        let assessment = assessPhysicalCustody(
            regression: regression,
            legacyIdentity: legacyIdentity,
            regressionOwnedSteamAppsURL: regressionOwnedSteamAppsURL,
            runningState: runningState
        )
        guard case .eligibleForTransfer = assessment.status else {
            throw RegressionCoreError.unsafeLibraryState(assessment.status.blockingReason)
        }

        let regressionLink = regression.steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
            .standardizedFileURL
        let plan = PhysicalLibraryCustodyPlan(
            planID: UUID(),
            createdAt: Date(),
            phase: .planned,
            sourceSteamAppsURL: assessment.sourceSteamAppsURL,
            destinationSteamAppsURL: assessment.destinationSteamAppsURL,
            transitionalLinks: [
                assessment.sourceSteamAppsURL: assessment.destinationSteamAppsURL,
                regressionLink: assessment.destinationSteamAppsURL
            ],
            inventory: assessment.inventory
        )
        try write(plan: plan)
        return plan
    }

    /// Wrapper compatible para el comparador opcional mientras siga disponible.
    func recoverPhysicalCustodyPlan(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) throws -> PhysicalLibraryCustodyPlan {
        try recoverPhysicalCustodyPlan(
            regression: regression,
            legacyIdentity: PhysicalLibraryCustodyIdentity(
                legacySteamAppsURL: crossOver.steamRootURL
                    .appendingPathComponent("steamapps", isDirectory: true)
            ),
            regressionOwnedSteamAppsURL: regressionOwnedSteamAppsURL,
            runningState: runningState
        )
    }

    /// Recupera una planificación interrumpida solo si rutas, estado e inventario siguen idénticos.
    func recoverPhysicalCustodyPlan(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) throws -> PhysicalLibraryCustodyPlan {
        guard !runningState.crossOverIsRunning, !runningState.regressionIsRunning else {
            throw RegressionCoreError.unsafeLibraryState("Steam debe estar completamente cerrado")
        }
        let plan = try readPhysicalCustodyPlan()
        let expectedSource = legacyIdentity.legacySteamAppsURL.standardizedFileURL
        let expectedDestination = regressionOwnedSteamAppsURL.standardizedFileURL
        let expectedRegressionLink = regression.steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
            .standardizedFileURL
        let current = assessPhysicalCustody(
            regression: regression,
            legacyIdentity: legacyIdentity,
            regressionOwnedSteamAppsURL: regressionOwnedSteamAppsURL,
            runningState: runningState
        )
        guard current.status == .migrationPlanned else {
            throw RegressionCoreError.unsafeLibraryState(current.status.blockingReason)
        }
        return try validatePendingPhysicalCustodyPlan(
            plan,
            source: expectedSource,
            destination: expectedDestination,
            regressionLink: expectedRegressionLink,
            inventory: current.inventory
        )
    }

    /// Rollback de la fase de planificación: elimina únicamente el journal, nunca la biblioteca.
    func cancelPhysicalCustodyPlan() throws {
        try validateJournalParent()
        let parentDescriptor = open(
            backupRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo anclar el directorio privado del journal: "
                    + String(cString: strerror(errno))
            )
        }
        defer { close(parentDescriptor) }

        let journalName = physicalCustodyJournalURL.lastPathComponent
        var metadata = stat()
        guard fstatat(parentDescriptor, journalName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo inspeccionar el journal de custodia: "
                    + String(cString: strerror(errno))
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw RegressionCoreError.unsafeLibraryState("El journal de custodia no es un archivo regular")
        }

        beforeJournalUnlink()
        guard unlinkat(parentDescriptor, journalName, 0) == 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo cancelar el journal de custodia de forma segura: "
                    + String(cString: strerror(errno))
            )
        }
    }

    @discardableResult
    public func configure(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation,
        runningState: RunningBackendState
    ) throws -> URL {
        guard !runningState.crossOverIsRunning, !runningState.regressionIsRunning else {
            throw RegressionCoreError.unsafeLibraryState("Steam debe estar completamente cerrado")
        }
        let assessment = assess(regression: regression, crossOver: crossOver)
        if case .ready = assessment.status { return assessment.regressionSteamAppsURL }
        if case let .blocked(reason) = assessment.status {
            throw RegressionCoreError.unsafeLibraryState(reason)
        }
        guard assessment.onlyInRegression.isEmpty else {
            throw RegressionCoreError.unsafeLibraryState(
                "Hay juegos instalados solo en Regression: \(assessment.onlyInRegression.joined(separator: ", "))"
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = backupRootURL.appendingPathComponent(
            "steamapps-regression-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)

        let sourceExists = fileManager.fileExists(atPath: assessment.regressionSteamAppsURL.path)
        if sourceExists {
            try fileManager.moveItem(at: assessment.regressionSteamAppsURL, to: backupURL)
        }

        var linkCreated = false
        do {
            try fileManager.createSymbolicLink(
                at: assessment.regressionSteamAppsURL,
                withDestinationURL: assessment.crossOverSteamAppsURL
            )
            linkCreated = true
            let receipt = SharedLibraryReceipt(
                configuredAt: Date(),
                regressionSteamApps: PrivacySanitizer.normalizedPath(assessment.regressionSteamAppsURL.path),
                crossOverSteamApps: PrivacySanitizer.normalizedPath(assessment.crossOverSteamAppsURL.path),
                backup: sourceExists ? PrivacySanitizer.normalizedPath(backupURL.path) : nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try PrivateStorage.write(
                encoder.encode(receipt),
                atomicallyTo: backupRootURL.appendingPathComponent("shared-library-receipt.json"),
                fileManager: fileManager
            )
            return assessment.regressionSteamAppsURL
        } catch {
            var rollbackFailures: [String] = []
            if linkCreated {
                do {
                    try fileManager.removeItem(at: assessment.regressionSteamAppsURL)
                } catch {
                    rollbackFailures.append("no se pudo retirar el enlace incompleto: \(error.localizedDescription)")
                }
            }

            if sourceExists {
                let destinationStillExists = fileManager.fileExists(
                    atPath: assessment.regressionSteamAppsURL.path
                ) || (try? fileManager.destinationOfSymbolicLink(
                    atPath: assessment.regressionSteamAppsURL.path
                )) != nil
                if destinationStillExists {
                    rollbackFailures.append("steamapps sigue ocupado y no puede restaurarse la copia")
                } else if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        try fileManager.moveItem(
                            at: backupURL,
                            to: assessment.regressionSteamAppsURL
                        )
                    } catch {
                        rollbackFailures.append("no se pudo restaurar steamapps: \(error.localizedDescription)")
                    }
                } else {
                    rollbackFailures.append("no se encontró la copia temporal de steamapps")
                }
            }

            if !rollbackFailures.isEmpty {
                let original = error.localizedDescription
                throw RegressionCoreError.unsafeLibraryState(
                    "Falló la unificación (\(original)) y el rollback necesita atención: "
                        + rollbackFailures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    private func write(plan: PhysicalLibraryCustodyPlan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(plan)
        guard encoded.count <= inventoryLimits.maxJournalBytes else {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal de custodia supera el límite seguro"
            )
        }
        try validateJournalParent()
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)
        try validateJournalParent()
        try PrivateStorage.write(
            encoded,
            atomicallyTo: physicalCustodyJournalURL,
            fileManager: fileManager
        )
    }

    private func readPhysicalCustodyPlan() throws -> PhysicalLibraryCustodyPlan {
        do {
            try validateJournalParent()
            let data = try readBoundedRegularFile(
                at: physicalCustodyJournalURL,
                maxBytes: inventoryLimits.maxJournalBytes,
                role: "journal de custodia"
            )
            let decoder = JSONDecoder()
            return try decoder.decode(PhysicalLibraryCustodyPlan.self, from: data)
        } catch let error as RegressionCoreError {
            throw error
        } catch {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal de custodia no se puede recuperar: \(error.localizedDescription)"
            )
        }
    }

    private func validatedPendingPhysicalCustodyPlan(
        source: URL,
        destination: URL,
        regressionLink: URL,
        inventory: PhysicalLibraryInventory
    ) throws -> PhysicalLibraryCustodyPlan {
        let plan = try readPhysicalCustodyPlan()
        return try validatePendingPhysicalCustodyPlan(
            plan,
            source: source,
            destination: destination,
            regressionLink: regressionLink,
            inventory: inventory
        )
    }

    private func validatePendingPhysicalCustodyPlan(
        _ plan: PhysicalLibraryCustodyPlan,
        source: URL,
        destination: URL,
        regressionLink: URL,
        inventory: PhysicalLibraryInventory
    ) throws -> PhysicalLibraryCustodyPlan {
        guard plan.schemaVersion == 2,
              plan.phase == .planned,
              try canonicalPath(for: plan.sourceSteamAppsURL) == canonicalPath(for: source),
              try canonicalPath(for: plan.destinationSteamAppsURL) == canonicalPath(for: destination),
              try transitionalLinksAreExpected(
                  plan.transitionalLinks,
                  source: source,
                  regressionLink: regressionLink,
                  destination: destination
              ) else {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal de custodia no corresponde a estas instalaciones"
            )
        }
        guard plan.inventory == inventory else {
            throw RegressionCoreError.unsafeLibraryState(
                "El inventario cambió desde que se preparó la transferencia"
            )
        }
        return plan
    }

    private func inventory(at root: URL) throws -> PhysicalLibraryInventory {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey
        ]
        let enumerationFailure = DirectoryEnumerationFailure()
        guard let enumerator = directoryEnumeratorProvider(
            root,
            Array(keys),
            [],
            { url, detail in
                enumerationFailure.record(url: url, detail: detail)
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var structuralDigest = StreamingStructuralDigest()
        var manifests: [String] = []
        var manifestHashes: [String: String] = [:]
        var regularFiles = 0
        var directories = 0
        var entries = 0
        var bytes: UInt64 = 0
        try Task.checkCancellation()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let (nextEntries, entryOverflow) = entries.addingReportingOverflow(1)
            guard !entryOverflow, nextEntries <= inventoryLimits.maxEntries else {
                throw RegressionCoreError.unsafeLibraryState(
                    "steamapps supera el límite seguro de entradas"
                )
            }
            entries = nextEntries
            let values = try url.resourceValues(forKeys: keys)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let depth = url.pathComponents.count - root.pathComponents.count
            guard depth <= inventoryLimits.maxDepth else {
                throw RegressionCoreError.unsafeLibraryState(
                    "steamapps supera el límite seguro de profundidad"
                )
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw RegressionCoreError.unsafeLibraryState(
                    "steamapps contiene un enlace simbólico inesperado: \(relative)"
                )
            }
            if values.isDirectory == true {
                directories += 1
                structuralDigest.combine("d:\(relative)")
            } else if values.isRegularFile == true {
                regularFiles += 1
                let size = UInt64(max(values.fileSize ?? 0, 0))
                let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(size)
                guard !byteOverflow, nextBytes <= inventoryLimits.maxTotalRegularFileBytes else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "steamapps supera el límite seguro de bytes inventariados"
                    )
                }
                bytes = nextBytes
                let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                structuralDigest.combine("f:\(relative):\(size):\(modificationTime)")
                let name = url.lastPathComponent
                if name.hasPrefix("appmanifest_"), name.hasSuffix(".acf") {
                    let appID = name.dropFirst("appmanifest_".count).dropLast(".acf".count)
                    if let normalizedAppID = SteamAppID.normalized(String(appID)) {
                        guard manifestHashes[normalizedAppID] == nil else {
                            throw RegressionCoreError.unsafeLibraryState(
                                "steamapps contiene el App ID duplicado \(normalizedAppID)"
                            )
                        }
                        guard size <= UInt64(max(inventoryLimits.maxManifestBytes, 0)) else {
                            throw RegressionCoreError.unsafeLibraryState(
                                "El manifiesto \(name) supera el límite seguro de inventario"
                            )
                        }
                        let manifestData = try readBoundedRegularFile(
                            at: url,
                            maxBytes: inventoryLimits.maxManifestBytes,
                            role: "manifiesto \(name)"
                        )
                        let manifestHash = SHA256.hash(data: manifestData)
                            .map { String(format: "%02x", $0) }.joined()
                        manifests.append(normalizedAppID)
                        manifestHashes[normalizedAppID] = manifestHash
                        structuralDigest.combine("m:\(normalizedAppID):\(manifestHash)")
                    }
                }
            } else {
                throw RegressionCoreError.unsafeLibraryState(
                    "steamapps contiene un tipo de archivo no permitido: \(relative)"
                )
            }
        }
        if let failure = enumerationFailure.first {
            let relative = failure.url.path.hasPrefix(root.path + "/")
                ? String(failure.url.path.dropFirst(root.path.count + 1))
                : failure.url.lastPathComponent
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo enumerar steamapps en \(relative): "
                    + failure.detail
            )
        }
        let digest = structuralDigest.finalize(
            entryCount: entries,
            regularFileCount: regularFiles,
            directoryCount: directories,
            totalRegularFileBytes: bytes
        )
        return PhysicalLibraryInventory(
            manifestAppIDs: manifests.sorted(),
            manifestSHA256ByAppID: manifestHashes,
            regularFileCount: regularFiles,
            directoryCount: directories,
            totalRegularFileBytes: bytes,
            structuralFingerprint: digest
        )
    }

    private func validateJournalParent() throws {
        try validateNoLinkedAncestors(
            at: backupRootURL,
            includeFinalItem: true,
            role: "directorio privado del journal"
        )
    }

    private func validateNoLinkedAncestors(
        at url: URL,
        includeFinalItem: Bool,
        role: String
    ) throws {
        let components = url.standardizedFileURL.pathComponents
        let inspected = includeFinalItem ? components : Array(components.dropLast())
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in inspected.dropFirst().enumerated() {
            current.appendPathComponent(component)
            if symbolicLinkDestination(at: current) != nil {
                // macOS publica alias de sistema inmutables en la raíz, como /var y /tmp.
                // Se canonicalizan con realpath; los enlaces dentro del árbol mutable sí bloquean.
                if index == 0 { continue }
                throw RegressionCoreError.unsafeLibraryState(
                    "El ancestro de \(role) es un enlace simbólico inesperado: \(current.path)"
                )
            }
            guard fileManager.fileExists(atPath: current.path) else { break }
            let values = try current.resourceValues(forKeys: [.isAliasFileKey])
            if values.isAliasFile == true {
                throw RegressionCoreError.unsafeLibraryState(
                    "El ancestro de \(role) es un alias inesperado: \(current.path)"
                )
            }
        }
    }

    private func canonicalPath(
        for url: URL,
        resolvingFinalItem: Bool = true
    ) throws -> CanonicalFilePath {
        let standardized = url.standardizedFileURL
        var existing = resolvingFinalItem ? standardized : standardized.deletingLastPathComponent()
        var missing = resolvingFinalItem ? [String]() : [standardized.lastPathComponent]
        while !pathExistsWithoutFollowingSymbolicLinks(existing), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolvedPath = realpath(existing.path, nil) else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo canonicalizar la ruta existente \(existing.path)"
            )
        }
        defer { free(resolvedPath) }
        let resolved = URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        guard let caseSensitive = try resolved.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo determinar la sensibilidad a mayúsculas del volumen"
            )
        }
        let rawComponents = resolved.pathComponents + missing
        let normalized = rawComponents.map { component in
            let unicode = component.precomposedStringWithCanonicalMapping
            return caseSensitive ? unicode : unicode.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        return CanonicalFilePath(components: normalized)
    }

    private func transitionalLinksAreExpected(
        _ links: [URL: URL],
        source: URL,
        regressionLink: URL,
        destination: URL
    ) throws -> Bool {
        guard links.count == 2 else { return false }
        let expectedKeys = [
            try canonicalPath(for: source, resolvingFinalItem: false),
            try canonicalPath(for: regressionLink, resolvingFinalItem: false)
        ]
        let expectedDestination = try canonicalPath(for: destination, resolvingFinalItem: false)
        var observedKeys: [CanonicalFilePath] = []
        for (key, value) in links {
            guard try canonicalPath(for: value, resolvingFinalItem: false) == expectedDestination else {
                return false
            }
            observedKeys.append(try canonicalPath(for: key, resolvingFinalItem: false))
        }
        return observedKeys.sorted() == expectedKeys.sorted()
    }

    private func readBoundedRegularFile(at url: URL, maxBytes: Int, role: String) throws -> Data {
        guard maxBytes >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("El límite de \(role) no es válido")
        }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo abrir \(role) de forma segura: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo inspeccionar \(role): \(String(cString: strerror(errno)))"
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw RegressionCoreError.unsafeLibraryState("El \(role) no es un archivo regular")
        }
        guard metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maxBytes) else {
            throw RegressionCoreError.unsafeLibraryState("El \(role) supera el límite seguro")
        }

        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = maxBytes - data.count
            let capacity = min(64 * 1_024, remaining + 1)
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = Darwin.read(descriptor, &buffer, capacity)
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw RegressionCoreError.unsafeLibraryState(
                    "No se pudo leer \(role): \(String(cString: strerror(errno)))"
                )
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxBytes else {
                throw RegressionCoreError.unsafeLibraryState("El \(role) supera el límite seguro")
            }
        }
    }

    private func directoryExistsWithoutSymbolicLink(at url: URL) -> Bool {
        guard symbolicLinkDestination(at: url) == nil else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func pathExistsWithoutFollowingSymbolicLinks(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || symbolicLinkDestination(at: url) != nil
    }

    private func symbolicLinkDestination(at url: URL) -> URL? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        if destination.hasPrefix("/") { return URL(fileURLWithPath: destination) }
        return url.deletingLastPathComponent().appendingPathComponent(destination)
    }

    private nonisolated static func defaultVolumeIdentity(for url: URL) -> String? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path),
              candidate.path != "/"
        {
            candidate.deleteLastPathComponent()
        }
        guard let identifier = try? candidate.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return nil
        }
        return String(describing: identifier)
    }
}

private struct CanonicalFilePath: Equatable, Comparable {
    let components: [String]

    static func < (lhs: CanonicalFilePath, rhs: CanonicalFilePath) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    func overlaps(_ other: CanonicalFilePath) -> Bool {
        let sharedCount = min(components.count, other.components.count)
        return Array(components.prefix(sharedCount)) == Array(other.components.prefix(sharedCount))
    }
}

private final class DirectoryEnumerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (url: URL, detail: String)?

    var first: (url: URL, detail: String)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(url: URL, detail: String) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = (url, detail) }
    }
}

private final class SendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}

/// Resumen conmutativo de memoria constante. Combina XOR y suma modular de cada SHA-256 para
/// que el orden no especificado de DirectoryEnumerator no cambie la huella estructural.
private struct StreamingStructuralDigest {
    private var xor = [UInt8](repeating: 0, count: 32)
    private var sums = [UInt64](repeating: 0, count: 4)

    mutating func combine(_ record: String) {
        let leaf = Array(SHA256.hash(data: Data(record.utf8)))
        for index in leaf.indices {
            xor[index] ^= leaf[index]
        }
        for wordIndex in 0..<4 {
            let offset = wordIndex * 8
            var word: UInt64 = 0
            for byte in leaf[offset..<(offset + 8)] {
                word = (word << 8) | UInt64(byte)
            }
            sums[wordIndex] &+= word
        }
    }

    func finalize(
        entryCount: Int,
        regularFileCount: Int,
        directoryCount: Int,
        totalRegularFileBytes: UInt64
    ) -> String {
        var payload = Data("structural-inventory-v2\n".utf8)
        payload.append(contentsOf: xor)
        for sum in sums {
            var bigEndian = sum.bigEndian
            withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        }
        payload.append(
            Data("\n\(entryCount):\(regularFileCount):\(directoryCount):\(totalRegularFileBytes)".utf8)
        )
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

private extension PhysicalLibraryCustodyStatus {
    var blockingReason: String {
        switch self {
        case let .blocked(reason): reason
        case .eligibleForTransfer: "La transferencia todavía no tiene autorización de ejecución"
        case .migrationPlanned: "La transferencia ya tiene un journal pendiente de recuperación"
        case .alreadyOwned: "La biblioteca ya está bajo custodia física de Regression"
        }
    }
}

private struct SharedLibraryReceipt: Codable {
    let configuredAt: Date
    let regressionSteamApps: String
    let crossOverSteamApps: String
    let backup: String?
}
