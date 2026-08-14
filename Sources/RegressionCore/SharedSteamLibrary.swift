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
    case preparing
    case preCutover
    case cutover
    case verifying
    case pendingValidation
    case validating
    case rollingBack
    case independent
    case blocked(String)
}

public enum PhysicalLibraryCustodyMutationPolicy: Equatable, Sendable {
    case unrestricted
    case blocked
    case regressionValidationOnly
}

public struct PhysicalLibraryCustodyInterlockSnapshot: Equatable, Sendable {
    public let status: PhysicalLibraryCustodyStatus
    public let mutationPolicy: PhysicalLibraryCustodyMutationPolicy

    public init(
        status: PhysicalLibraryCustodyStatus,
        mutationPolicy: PhysicalLibraryCustodyMutationPolicy
    ) {
        self.status = status
        self.mutationPolicy = mutationPolicy
    }

    public var crossOverUnavailable: Bool {
        switch status {
        case .cutover, .verifying, .pendingValidation, .validating, .rollingBack, .independent,
             .blocked:
            true
        case .eligibleForTransfer, .preparing, .preCutover:
            false
        }
    }
}

public struct PhysicalLibraryCustodyValidationLease: Equatable, Sendable {
    fileprivate let transactionID: UUID
    fileprivate let nonce: UUID
}

public final class PhysicalLibraryCustodyMutationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var onRelease: (@Sendable () -> Void)?

    init(descriptor: Int32, onRelease: (@Sendable () -> Void)? = nil) {
        self.descriptor = descriptor
        self.onRelease = onRelease
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        self.descriptor = nil
        let callback = onRelease
        onRelease = nil
        callback?()
    }

    deinit { release() }
}

public protocol PhysicalLibraryCustodyInterlocking: Sendable {
    func currentPhysicalLibraryCustodyInterlock() async -> PhysicalLibraryCustodyInterlockSnapshot
    func authorizePhysicalLibraryCustodyMutation(
        backend: BackendKind,
        validationLease: PhysicalLibraryCustodyValidationLease?
    ) async -> Bool
    func acquirePhysicalLibraryCustodyMutationPermit(
        backend: BackendKind,
        validationLease: PhysicalLibraryCustodyValidationLease?
    ) async throws -> PhysicalLibraryCustodyMutationPermit
    func registerPhysicalLibraryLaunchIntent(
        backend: BackendKind
    ) async throws -> PhysicalLibraryCustodyLaunchIntent
    func attachPhysicalLibraryLaunch(
        _ launch: BackendLaunch,
        to intent: PhysicalLibraryCustodyLaunchIntent
    ) async throws
    func resolvePhysicalLibraryLaunchIntent(
        _ intent: PhysicalLibraryCustodyLaunchIntent
    ) async throws
}

public struct PhysicalLibraryCustodyLaunchIntent: Equatable, Sendable {
    fileprivate let id: UUID
    init(id: UUID = UUID()) { self.id = id }
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
    case prepared
    case willStageDestination
    case destinationStaged
    case willCommitCutover
    case cutoverCommitted
    case verifyingDestination
    case awaitingRuntimeValidation
    case validatingRuntime
    case validationAccepted
    case willFinalize
    case completed
    case willRollback
    case rolledBack
    case needsManualRecovery
}

/// Write-ahead log durable del traslado físico. Registra intención, identidades de filesystem,
/// inventario y fase antes de cada mutación para recuperar o revertir sin crear otra biblioteca.
/// La huella estructural detecta cambios durante el cutover, pero no certifica cada byte: esa
/// verificación y la prueba funcional se exigen antes de aceptar y finalizar la custodia.
struct PhysicalLibraryCustodyPlan: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let planID: UUID
    let createdAt: Date
    let phase: PhysicalLibraryCustodyPhase
    let sourceSteamAppsURL: URL
    let destinationSteamAppsURL: URL
    let stagedRegressionLinkURL: URL
    let originalRegressionLinkTarget: String
    let sourceDevice: UInt64
    let sourceInode: UInt64
    let sourceParentDevice: UInt64
    let sourceParentInode: UInt64
    let destinationParentDevice: UInt64
    let destinationParentInode: UInt64
    let regressionLinkDevice: UInt64
    let regressionLinkInode: UInt64
    let validationStartedAt: Date?
    let validationEvidence: String?
    let inventory: PhysicalLibraryInventory

    init(
        schemaVersion: Int = 3,
        planID: UUID,
        createdAt: Date,
        phase: PhysicalLibraryCustodyPhase,
        sourceSteamAppsURL: URL,
        destinationSteamAppsURL: URL,
        stagedRegressionLinkURL: URL,
        originalRegressionLinkTarget: String,
        sourceDevice: UInt64,
        sourceInode: UInt64,
        sourceParentDevice: UInt64,
        sourceParentInode: UInt64,
        destinationParentDevice: UInt64,
        destinationParentInode: UInt64,
        regressionLinkDevice: UInt64,
        regressionLinkInode: UInt64,
        validationStartedAt: Date? = nil,
        validationEvidence: String? = nil,
        inventory: PhysicalLibraryInventory
    ) {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.createdAt = createdAt
        self.phase = phase
        self.sourceSteamAppsURL = sourceSteamAppsURL
        self.destinationSteamAppsURL = destinationSteamAppsURL
        self.stagedRegressionLinkURL = stagedRegressionLinkURL
        self.originalRegressionLinkTarget = originalRegressionLinkTarget
        self.sourceDevice = sourceDevice
        self.sourceInode = sourceInode
        self.sourceParentDevice = sourceParentDevice
        self.sourceParentInode = sourceParentInode
        self.destinationParentDevice = destinationParentDevice
        self.destinationParentInode = destinationParentInode
        self.regressionLinkDevice = regressionLinkDevice
        self.regressionLinkInode = regressionLinkInode
        self.validationStartedAt = validationStartedAt
        self.validationEvidence = validationEvidence
        self.inventory = inventory
    }
}

enum PhysicalLibraryCustodyFaultPoint: Sendable {
    case afterPrepared
    case afterWillStageDestination
    case afterDestinationStagedRename
    case afterDestinationStagedJournal
    case afterWillCommitCutover
    case afterCutoverRename
    case afterCutoverJournal
    case afterVerifyingJournal
    case afterWillFinalizeJournal
    case afterFinalizeReceipt
    case beforeFinalizeMarkerQuarantine
    case afterFinalizeMarkerQuarantine
    case afterFinalizeMarkerUnlink
    case afterCompletedJournal
    case beforeFinalJournalUnlink
    case afterJournalQuarantine
    case afterWillRollback
    case afterRollbackSourceRename
    case afterRollbackLinkRename
    case afterRollbackStartedMarkerUnlink
    case afterStartedMarkerQuarantine
}

public actor SharedSteamLibraryManager: PhysicalLibraryCustodyInterlocking {
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
    private let custodyFault: @Sendable (PhysicalLibraryCustodyFaultPoint) throws -> Void
    private var activeValidationLease: PhysicalLibraryCustodyValidationLease?

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
        self.custodyFault = { _ in }
        self.activeValidationLease = nil
    }

    init(
        fileManager: FileManager = .default,
        backupRootURL: URL,
        volumeIdentityProvider: VolumeIdentityProvider? = nil,
        inventoryLimits: PhysicalLibraryInventoryLimits = .standard,
        directoryEnumeratorProvider: @escaping DirectoryEnumeratorProvider,
        beforeJournalUnlink: @escaping @Sendable () -> Void = {},
        custodyFault: @escaping @Sendable (PhysicalLibraryCustodyFaultPoint) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.backupRootURL = backupRootURL.standardizedFileURL
        self.volumeIdentityProvider = volumeIdentityProvider ?? { url in
            SharedSteamLibraryManager.defaultVolumeIdentity(for: url)
        }
        self.inventoryLimits = inventoryLimits
        self.directoryEnumeratorProvider = directoryEnumeratorProvider
        self.beforeJournalUnlink = beforeJournalUnlink
        self.custodyFault = custodyFault
        self.activeValidationLease = nil
    }

    nonisolated var physicalCustodyJournalURL: URL {
        backupRootURL.appendingPathComponent("physical-custody-journal.json")
    }

    nonisolated var physicalCustodyReceiptURL: URL {
        backupRootURL.appendingPathComponent("physical-custody-receipt.json")
    }

    nonisolated var physicalCustodyReceiptMirrorURL: URL {
        backupRootURL.appendingPathComponent("physical-custody-receipt.mirror.json")
    }

    nonisolated var physicalCustodyStartedMarkerURL: URL {
        backupRootURL.appendingPathComponent("physical-custody-started.json")
    }

    nonisolated var physicalCustodyLaunchIntentURL: URL {
        backupRootURL.appendingPathComponent("physical-custody-launch-intent.json")
    }

    package func assess(
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

    package func assessPhysicalCustody(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        runningState: RunningBackendState
    ) -> PhysicalLibraryCustodyAssessment {
        let source = legacyIdentity.legacySteamAppsURL.standardizedFileURL
        let destination = custodyDestination(for: regression)
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

        do {
            try withCustodyLockSync {
                try recoverLaunchIntentQuarantine()
                try reconcileLaunchIntent(runningState: runningState)
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL) {
                let plan = try readPhysicalCustodyPlan()
                try validatePlanIdentity(plan, source: source, destination: destination)
                return PhysicalLibraryCustodyAssessment(
                    status: status(for: plan.phase),
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    inventory: plan.inventory
                )
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL) {
                let receipt = try readPhysicalCustodyReceipt()
                guard receipt.sourceSteamAppsURL == source,
                      receipt.destinationSteamAppsURL == destination,
                      try legacySourceStateIsValid(for: receipt),
                      try directoryIdentity(at: destination) == receipt.identity else {
                    return blocked("El recibo de custodia no coincide con la topología actual")
                }
                return PhysicalLibraryCustodyAssessment(
                    status: .independent,
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    inventory: receipt.inventory
                )
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptMirrorURL) {
                let receipt = try readPhysicalCustodyReceipt(at: physicalCustodyReceiptMirrorURL)
                guard receipt.sourceSteamAppsURL == source,
                      receipt.destinationSteamAppsURL == destination,
                      try legacySourceStateIsValid(for: receipt),
                      try directoryIdentity(at: destination) == receipt.identity else {
                    return blocked("El recibo redundante no coincide con la topología actual")
                }
                return PhysicalLibraryCustodyAssessment(
                    status: .independent,
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    inventory: receipt.inventory
                )
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyStartedMarkerURL) {
                return blocked(
                    "Existe una custodia previa sin recibo final; se bloquean mutaciones hasta recuperar"
                )
            }
            guard !runningState.crossOverIsRunning, !runningState.regressionIsRunning else {
                return blocked("Steam debe estar completamente cerrado")
            }
            if !pathExistsWithoutFollowingSymbolicLinks(source) {
                return try initializeIndependentPhysicalCustody(
                    source: source,
                    destination: destination
                )
            }
            try validateInitialTopology(source: source, destination: destination)
            return PhysicalLibraryCustodyAssessment(
                status: .eligibleForTransfer,
                sourceSteamAppsURL: source,
                destinationSteamAppsURL: destination,
                inventory: try inventory(at: source)
            )
        } catch is CancellationError {
            return blocked("El inventario de steamapps fue cancelado")
        } catch {
            return blocked("No se pudo verificar la custodia: \(error.localizedDescription)")
        }
    }

    private func initializeIndependentPhysicalCustody(
        source: URL,
        destination: URL
    ) throws -> PhysicalLibraryCustodyAssessment {
        try withCustodyLockSync {
            guard !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL),
                  !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL),
                  !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptMirrorURL),
                  !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyStartedMarkerURL),
                  !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyLaunchIntentURL) else {
                throw RegressionCoreError.unsafeLibraryState(
                    "El estado durable de custodia cambió durante la inicialización"
                )
            }
            try validateNoLinkedAncestors(
                at: destination,
                includeFinalItem: false,
                role: "destino Regression"
            )
            guard !pathExistsWithoutFollowingSymbolicLinks(source) else {
                throw RegressionCoreError.unsafeLibraryState(
                    "La biblioteca heredada apareció durante la inicialización"
                )
            }

            let destinationParent = destination.deletingLastPathComponent()
            let parentDescriptor = open(
                destinationParent.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
            )
            guard parentDescriptor >= 0 else {
                throw RegressionCoreError.unsafeLibraryState(
                    "No se pudo anclar la carpeta de Steam de Regression"
                )
            }
            defer { close(parentDescriptor) }

            let createdDestination: Bool
            if pathExistsWithoutFollowingSymbolicLinks(destination) {
                guard directoryExistsWithoutSymbolicLink(at: destination) else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "steamapps de Regression existe pero no es un directorio físico"
                    )
                }
                createdDestination = false
            } else {
                guard mkdirat(parentDescriptor, destination.lastPathComponent, 0o700) == 0 else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "No se pudo crear steamapps dentro de la botella de Regression"
                    )
                }
                createdDestination = true
                try syncDirectory(parentDescriptor)
            }

            do {
                let identityBeforeInventory = try directoryIdentity(at: destination)
                let verifiedInventory = try inventory(at: destination)
                guard !pathExistsWithoutFollowingSymbolicLinks(source),
                      try directoryIdentity(at: destination) == identityBeforeInventory else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "La topología cambió durante la inicialización de steamapps"
                    )
                }
                let receipt = PhysicalLibraryCustodyReceipt(
                    schemaVersion: 2,
                    completedAt: Date(),
                    transactionID: UUID(),
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    identity: identityBeforeInventory,
                    validationEvidence: try validatedEvidence(
                        "Inicialización local verificada de la biblioteca propia de Regression"
                    ),
                    inventory: verifiedInventory,
                    origin: .independentInitialization
                )
                try writePhysicalCustodyReceipt(receipt)
                try validateIndependentReceipt(
                    receipt,
                    source: source,
                    destination: destination
                )
                return PhysicalLibraryCustodyAssessment(
                    status: .independent,
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    inventory: verifiedInventory
                )
            } catch {
                if createdDestination,
                   !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL),
                   !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptMirrorURL)
                {
                    _ = unlinkat(parentDescriptor, destination.lastPathComponent, AT_REMOVEDIR)
                    try? syncDirectory(parentDescriptor)
                }
                throw error
            }
        }
    }

    /// Compatibilidad temporal: el destino proporcionado nunca gobierna el traslado.
    public func assessPhysicalCustody(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        regressionOwnedSteamAppsURL: URL,
        runningState: RunningBackendState
    ) -> PhysicalLibraryCustodyAssessment {
        let derived = custodyDestination(for: regression)
        guard regressionOwnedSteamAppsURL.standardizedFileURL == derived else {
            return PhysicalLibraryCustodyAssessment(
                status: .blocked("El destino debe ser steamapps dentro de la botella de Regression"),
                sourceSteamAppsURL: legacyIdentity.legacySteamAppsURL,
                destinationSteamAppsURL: derived,
                inventory: .empty
            )
        }
        return assessPhysicalCustody(
            regression: regression,
            legacyIdentity: legacyIdentity,
            runningState: runningState
        )
    }

    @discardableResult
    public func migratePhysicalCustody(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        runningStateProvider: @escaping @Sendable () async -> RunningBackendState
    ) async throws -> PhysicalLibraryCustodyAssessment {
        try await withCustodyLock {
            let source = legacyIdentity.legacySteamAppsURL.standardizedFileURL
            let destination = custodyDestination(for: regression)
            let initialRunningState = await runningStateProvider()
            try reconcileLaunchIntent(runningState: initialRunningState)
            if !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL),
               let recoveredPlan = try recoverDeterministicJournalQuarantine() {
                try write(plan: recoveredPlan)
            }
            if !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL),
               pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL) {
                let receipt = try readPhysicalCustodyReceipt()
                guard receipt.sourceSteamAppsURL == source,
                      receipt.destinationSteamAppsURL == destination,
                      try legacySourceStateIsValid(for: receipt),
                      try directoryIdentity(at: destination) == receipt.identity else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "El recibo de custodia no coincide con la topología actual"
                    )
                }
                return PhysicalLibraryCustodyAssessment(
                    status: .independent,
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    inventory: receipt.inventory
                )
            }
            var plan: PhysicalLibraryCustodyPlan
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL) {
                plan = try readPhysicalCustodyPlan()
                try recoverStartedMarkerQuarantine(planID: plan.planID)
                try recoverDeterministicMarkerQuarantine(plan: plan)
                try validatePlanIdentity(plan, source: source, destination: destination)
                if plan.phase == .rolledBack {
                    try validateInitialTopology(source: source, destination: destination)
                    if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyStartedMarkerURL) {
                        try unlinkStartedMarker(planID: plan.planID)
                    }
                    try unlinkJournal(expectedPlan: plan)
                    return PhysicalLibraryCustodyAssessment(
                        status: .eligibleForTransfer,
                        sourceSteamAppsURL: source,
                        destinationSteamAppsURL: destination,
                        inventory: plan.inventory
                    )
                }
            } else {
                try ensureSteamStopped(initialRunningState)
                try validateInitialTopology(source: source, destination: destination)
                let identity = try directoryIdentity(at: source)
                let linkTarget = try readRawSymbolicLink(at: destination)
                let sourceParentIdentity = try directoryIdentity(at: source.deletingLastPathComponent())
                let destinationParentIdentity = try directoryIdentity(at: destination.deletingLastPathComponent())
                let regressionLinkIdentity = try symbolicLinkIdentity(at: destination)
                let initialInventory = try inventory(at: source)
                let staged = destination.deletingLastPathComponent().appendingPathComponent(
                    ".steamapps-custody-\(UUID().uuidString).rollback"
                )
                plan = PhysicalLibraryCustodyPlan(
                    planID: UUID(),
                    createdAt: Date(),
                    phase: .prepared,
                    sourceSteamAppsURL: source,
                    destinationSteamAppsURL: destination,
                    stagedRegressionLinkURL: staged,
                    originalRegressionLinkTarget: linkTarget,
                    sourceDevice: identity.device,
                    sourceInode: identity.inode,
                    sourceParentDevice: sourceParentIdentity.device,
                    sourceParentInode: sourceParentIdentity.inode,
                    destinationParentDevice: destinationParentIdentity.device,
                    destinationParentInode: destinationParentIdentity.inode,
                    regressionLinkDevice: regressionLinkIdentity.device,
                    regressionLinkInode: regressionLinkIdentity.inode,
                    validationEvidence: nil,
                    inventory: initialInventory
                )
                try writeCustodyStartedMarker(planID: plan.planID)
                try write(plan: plan)
                try custodyFault(.afterPrepared)
            }
            plan = try await advanceCutover(
                plan: plan,
                runningStateProvider: runningStateProvider
            )
            return PhysicalLibraryCustodyAssessment(
                status: plan.phase == .completed
                    && !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL)
                    ? .independent
                    : status(for: plan.phase),
                sourceSteamAppsURL: source,
                destinationSteamAppsURL: destination,
                inventory: plan.inventory
            )
        }
    }

    public func beginPhysicalCustodyValidation(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        runningState: RunningBackendState
    ) throws -> PhysicalLibraryCustodyValidationLease {
        try withCustodyLockSync {
            try ensureSteamStopped(runningState)
            var plan = try readPhysicalCustodyPlan()
            try recoverDeterministicMarkerQuarantine(plan: plan)
            try validatePlanIdentity(
                plan,
                source: legacyIdentity.legacySteamAppsURL,
                destination: custodyDestination(for: regression)
            )
            guard plan.phase == .awaitingRuntimeValidation || plan.phase == .validatingRuntime else {
                throw RegressionCoreError.unsafeLibraryState("La migración todavía no espera validación")
            }
            let lease = activeValidationLease ?? PhysicalLibraryCustodyValidationLease(
                transactionID: plan.planID,
                nonce: UUID()
            )
            activeValidationLease = lease
            if plan.phase != .validatingRuntime {
                plan = replacingPhase(
                    of: plan,
                    with: .validatingRuntime,
                    validationStartedAt: plan.validationStartedAt ?? Date()
                )
                try write(plan: plan)
            }
            return lease
        }
    }

    /// Cierra la custodia únicamente después de recargar la ejecución exacta desde el repositorio
    /// local. El caller solo aporta una identidad; Core obtiene tanto los hechos como la frontera
    /// temporal del estado durable bajo el mismo lock exclusivo que protege la finalización.
    @discardableResult
    package func finalizePhysicalCustodyValidated(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        request: PhysicalLibraryCustodyValidationRequest,
        repository: CompatibilityRepository,
        runningState: RunningBackendState
    ) async throws -> PhysicalLibraryCustodyAssessment {
        return try await withCustodyLock {
            try ensureSteamStopped(runningState)
            var plan = try readPhysicalCustodyPlan()
            try recoverDeterministicMarkerQuarantine(plan: plan)
            try validatePlanIdentity(
                plan,
                source: legacyIdentity.legacySteamAppsURL,
                destination: custodyDestination(for: regression)
            )
            guard plan.phase == .awaitingRuntimeValidation
                    || plan.phase == .validatingRuntime
                    || plan.phase == .validationAccepted
                    || plan.phase == .willFinalize
                    || plan.phase == .completed else {
                throw RegressionCoreError.unsafeLibraryState("La migración todavía no espera validación")
            }
            guard let run = try await repository.sealedPerfectRun(
                appID: request.appID,
                runID: request.runID
            ) else {
                throw RegressionCoreError.invalidEvidence(
                    "La ejecución indicada no existe en la base local de Regression"
                )
            }
            guard let validationStartedAt = plan.validationStartedAt else {
                throw RegressionCoreError.invalidEvidence(
                    "La validación no conserva una frontera temporal posterior al cutover"
                )
            }
            let evidence = try custodyValidationEvidence(
                request: request,
                run: run,
                validationBoundary: validationStartedAt
            )
            activeValidationLease = nil
            plan = try finishValidatedCustody(
                plan,
                validationEvidence: plan.validationEvidence
                    ?? (try validatedEvidence(evidence))
            )
            return PhysicalLibraryCustodyAssessment(
                status: .independent,
                sourceSteamAppsURL: plan.sourceSteamAppsURL,
                destinationSteamAppsURL: plan.destinationSteamAppsURL,
                inventory: plan.inventory
            )
        }
    }

    private func custodyValidationEvidence(
        request: PhysicalLibraryCustodyValidationRequest,
        run: RunSummary,
        validationBoundary: Date
    ) throws -> String {
        guard SteamAppID.normalized(request.appID) == request.appID,
              run.id == request.runID,
              SteamAppID.normalized(run.appID) == request.appID,
              run.backend == .regression,
              run.startedAt > validationBoundary,
              run.endedAt != nil,
              run.result == .succeeded,
              run.processID != nil,
              let verification = run.verification,
              verification.runID == run.id,
              verification.verifiedAt >= (run.endedAt ?? .distantFuture),
              verification.verdict == .perfect,
              verification.rendering == .passed,
              verification.inputPrecision == .passed,
              verification.graphicsSettings == .passed,
              verification.gameplay == .passed,
              verification.source == .user || verification.source == .visualInspection else {
            throw RegressionCoreError.invalidEvidence(
                "La ejecución no es una validación local perfecta, finalizada y posterior al cutover"
            )
        }
        return "custody-validation-v1 app-id=\(request.appID) "
            + "run-id=\(run.id.uuidString) "
            + "verification-source=\(verification.source.rawValue)"
    }

    @discardableResult
    public func rollbackPhysicalCustody(
        regression: RegressionInstallation,
        legacyIdentity: PhysicalLibraryCustodyIdentity,
        runningState: RunningBackendState
    ) async throws -> PhysicalLibraryCustodyAssessment {
        try await withCustodyLock {
            try ensureSteamStopped(runningState)
            let plan = try readPhysicalCustodyPlan()
            try recoverDeterministicMarkerQuarantine(plan: plan)
            try validatePlanIdentity(
                plan,
                source: legacyIdentity.legacySteamAppsURL,
                destination: custodyDestination(for: regression)
            )
            activeValidationLease = nil
            let rolledBack = try rollback(plan: plan)
            return PhysicalLibraryCustodyAssessment(
                // `rollback(plan:)` has already restored the original topology and removed the
                // durable journal before returning. Reporting the transient `.rollingBack`
                // phase here would leave the caller showing a recovery that no longer exists.
                status: .eligibleForTransfer,
                sourceSteamAppsURL: rolledBack.sourceSteamAppsURL,
                destinationSteamAppsURL: rolledBack.destinationSteamAppsURL,
                inventory: rolledBack.inventory
            )
        }
    }

    public func currentPhysicalLibraryCustodyInterlock() -> PhysicalLibraryCustodyInterlockSnapshot {
        do {
            try recoverLaunchIntentQuarantine()
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyLaunchIntentURL) {
                _ = try readLaunchIntent()
                return .init(
                    status: .blocked("Hay un lanzamiento de Steam todavía no reconciliado"),
                    mutationPolicy: .blocked
                )
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyJournalURL) {
                let plan = try readPhysicalCustodyPlan()
                let currentStatus = status(for: plan.phase)
                let policy: PhysicalLibraryCustodyMutationPolicy =
                    plan.phase == .validatingRuntime ? .regressionValidationOnly : .blocked
                return .init(status: currentStatus, mutationPolicy: policy)
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL) {
                let receipt = try readPhysicalCustodyReceipt()
                guard try legacySourceStateIsValid(for: receipt),
                      try directoryIdentity(at: receipt.destinationSteamAppsURL) == receipt.identity else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "El recibo de custodia no coincide con la topología actual"
                    )
                }
                return .init(status: .independent, mutationPolicy: .unrestricted)
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptMirrorURL) {
                let receipt = try readPhysicalCustodyReceipt(at: physicalCustodyReceiptMirrorURL)
                guard try legacySourceStateIsValid(for: receipt),
                      try directoryIdentity(at: receipt.destinationSteamAppsURL) == receipt.identity else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "El recibo redundante no coincide con la topología actual"
                    )
                }
                return .init(status: .independent, mutationPolicy: .unrestricted)
            }
            if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyStartedMarkerURL) {
                return .init(
                    status: .blocked("La custodia previa carece de recibo final recuperable"),
                    mutationPolicy: .blocked
                )
            }
            return .init(status: .eligibleForTransfer, mutationPolicy: .unrestricted)
        } catch {
            return .init(
                status: .blocked("El journal de custodia no es válido"),
                mutationPolicy: .blocked
            )
        }
    }

    public func authorizePhysicalLibraryCustodyMutation(
        backend: BackendKind,
        validationLease: PhysicalLibraryCustodyValidationLease?
    ) -> Bool {
        guard backend == .regression else { return false }
        let snapshot = currentPhysicalLibraryCustodyInterlock()
        switch snapshot.mutationPolicy {
        case .unrestricted:
            return true
        case .blocked:
            return false
        case .regressionValidationOnly:
            return backend == .regression
                && validationLease != nil
                && validationLease == activeValidationLease
        }
    }

    public func acquirePhysicalLibraryCustodyMutationPermit(
        backend: BackendKind,
        validationLease: PhysicalLibraryCustodyValidationLease?
    ) throws -> PhysicalLibraryCustodyMutationPermit {
        guard backend == .regression else {
            throw RegressionCoreError.unsafeLibraryState(
                "Solo Regression puede adquirir autoridad de mutación sobre su biblioteca"
            )
        }
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)
        let lockURL = backupRootURL.appendingPathComponent("physical-custody.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW_ANY | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo abrir el lock de custodia")
        }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            close(descriptor)
            throw RegressionCoreError.unsafeLibraryState("Hay una migración de biblioteca en curso")
        }
        guard authorizePhysicalLibraryCustodyMutation(
            backend: backend,
            validationLease: validationLease
        ) else {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw RegressionCoreError.unsafeLibraryState(
                "La custodia de la biblioteca bloquea esta operación de Steam"
            )
        }
        return PhysicalLibraryCustodyMutationPermit(descriptor: descriptor)
    }

    public func registerPhysicalLibraryLaunchIntent(
        backend: BackendKind
    ) throws -> PhysicalLibraryCustodyLaunchIntent {
        guard backend == .regression else {
            throw RegressionCoreError.unsafeLibraryState("CrossOver no es un backend operativo")
        }
        try recoverLaunchIntentQuarantine()
        guard !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyLaunchIntentURL) else {
            throw RegressionCoreError.unsafeLibraryState("Ya existe un lanzamiento de Steam en curso")
        }
        let token = PhysicalLibraryCustodyLaunchIntent()
        try createLaunchIntentExclusive(.init(
            schemaVersion: 1,
            id: token.id,
            backend: backend,
            startedAt: Date(),
            processID: nil
        ))
        return token
    }

    public func attachPhysicalLibraryLaunch(
        _ launch: BackendLaunch,
        to intent: PhysicalLibraryCustodyLaunchIntent
    ) throws {
        let stored = try readLaunchIntent()
        guard stored.id == intent.id, stored.backend == launch.backend else {
            throw RegressionCoreError.unsafeLibraryState("La intención de lanzamiento no coincide")
        }
        try writeLaunchIntent(.init(
            schemaVersion: stored.schemaVersion,
            id: stored.id,
            backend: stored.backend,
            startedAt: stored.startedAt,
            processID: launch.processID
        ))
    }

    public func resolvePhysicalLibraryLaunchIntent(
        _ intent: PhysicalLibraryCustodyLaunchIntent
    ) throws {
        let stored = try readLaunchIntent()
        guard stored.id == intent.id else {
            throw RegressionCoreError.unsafeLibraryState("La intención de lanzamiento no coincide")
        }
        try unlinkLaunchIntent(expected: stored)
    }

    private struct CustodyDirectoryIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private enum PhysicalLibraryCustodyReceiptOrigin: String, Codable, Sendable {
        case independentInitialization
    }

    private struct PhysicalLibraryCustodyReceipt: Codable, Sendable {
        let schemaVersion: Int
        let completedAt: Date
        let transactionID: UUID
        let sourceSteamAppsURL: URL
        let destinationSteamAppsURL: URL
        let identity: CustodyDirectoryIdentity
        let validationEvidence: String
        let inventory: PhysicalLibraryInventory
        let origin: PhysicalLibraryCustodyReceiptOrigin?

        init(
            schemaVersion: Int,
            completedAt: Date,
            transactionID: UUID,
            sourceSteamAppsURL: URL,
            destinationSteamAppsURL: URL,
            identity: CustodyDirectoryIdentity,
            validationEvidence: String,
            inventory: PhysicalLibraryInventory,
            origin: PhysicalLibraryCustodyReceiptOrigin? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.completedAt = completedAt
            self.transactionID = transactionID
            self.sourceSteamAppsURL = sourceSteamAppsURL
            self.destinationSteamAppsURL = destinationSteamAppsURL
            self.identity = identity
            self.validationEvidence = validationEvidence
            self.inventory = inventory
            self.origin = origin
        }
    }

    private struct PhysicalLibraryCustodyLaunchIntentRecord: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let id: UUID
        let backend: BackendKind
        let startedAt: Date
        let processID: Int32?
    }

    private func legacySourceStateIsValid(
        for receipt: PhysicalLibraryCustodyReceipt
    ) throws -> Bool {
        guard pathExistsWithoutFollowingSymbolicLinks(receipt.sourceSteamAppsURL) else {
            return true
        }
        guard receipt.origin == .independentInitialization,
              directoryExistsWithoutSymbolicLink(at: receipt.sourceSteamAppsURL) else {
            return false
        }

        // Una instalación posterior de CrossOver puede crear un esqueleto steamapps vacío.
        // Se toleran directorios vacíos, pero el primer archivo indica otra biblioteca real y
        // debe bloquearse para que el usuario nunca tenga juegos o manifiestos duplicados.
        let identity = try directoryIdentity(at: receipt.sourceSteamAppsURL)
        let observed = try inventory(at: receipt.sourceSteamAppsURL)
        guard observed.regularFileCount == 0 else { return false }
        return try directoryIdentity(at: receipt.sourceSteamAppsURL) == identity
    }

    private func custodyDestination(for regression: RegressionInstallation) -> URL {
        regression.steamRootURL.appendingPathComponent("steamapps", isDirectory: true)
            .standardizedFileURL
    }

    private func ensureSteamStopped(_ state: RunningBackendState) throws {
        guard !state.crossOverIsRunning, !state.regressionIsRunning else {
            throw RegressionCoreError.unsafeLibraryState("Steam debe estar completamente cerrado")
        }
    }

    private func writeLaunchIntent(_ intent: PhysicalLibraryCustodyLaunchIntentRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeDurableRegularFile(try encoder.encode(intent), to: physicalCustodyLaunchIntentURL)
    }

    private func createLaunchIntentExclusive(
        _ intent: PhysicalLibraryCustodyLaunchIntentRecord
    ) throws {
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)
        let parent = open(backupRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar la intención")
        }
        defer { close(parent) }
        let descriptor = openat(
            parent,
            physicalCustodyLaunchIntentURL.lastPathComponent,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("Ya existe un lanzamiento de Steam en curso")
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded {
                _ = unlinkat(parent, physicalCustodyLaunchIntentURL.lastPathComponent, 0)
            }
        }
        let data = try JSONEncoder().encode(intent)
        let written = data.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == data.count else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo persistir la intención")
        }
        try fullSync(descriptor)
        succeeded = true
        try syncDirectory(parent)
    }

    private func readLaunchIntent() throws -> PhysicalLibraryCustodyLaunchIntentRecord {
        let data = try readBoundedRegularFile(
            at: physicalCustodyLaunchIntentURL,
            maxBytes: 16 * 1_024,
            role: "intención de lanzamiento"
        )
        let value = try JSONDecoder().decode(PhysicalLibraryCustodyLaunchIntentRecord.self, from: data)
        guard value.schemaVersion == 1, value.backend == .regression else {
            throw RegressionCoreError.unsafeLibraryState("La intención de lanzamiento no es válida")
        }
        return value
    }

    private func unlinkLaunchIntent(expected: PhysicalLibraryCustodyLaunchIntentRecord) throws {
        let parent = open(backupRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo sincronizar la intención eliminada")
        }
        defer { close(parent) }
        let source = physicalCustodyLaunchIntentURL.lastPathComponent
        var metadata = stat()
        guard fstatat(parent, source, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw RegressionCoreError.unsafeLibraryState("La intención de lanzamiento no es regular")
        }
        let quarantine = ".physical-custody-launch-\(expected.id.uuidString.lowercased()).quarantine"
        try quarantineLeaf(parent: parent, sourceName: source, quarantineName: quarantine, role: "intención")
        do {
            var quarantined = stat()
            let data = try readAnchoredRegularData(parent: parent, name: quarantine, maxBytes: 16 * 1_024)
            guard fstatat(parent, quarantine, &quarantined, AT_SYMLINK_NOFOLLOW) == 0,
                  quarantined.st_dev == metadata.st_dev,
                  quarantined.st_ino == metadata.st_ino,
                  try JSONDecoder().decode(PhysicalLibraryCustodyLaunchIntentRecord.self, from: data) == expected else {
                throw RegressionCoreError.unsafeLibraryState("La intención de lanzamiento fue sustituida")
            }
        } catch {
            try restoreQuarantinedLeaf(parent: parent, quarantineName: quarantine, originalName: source, role: "intención")
            throw error
        }
        guard unlinkat(parent, quarantine, 0) == 0 else {
            try restoreQuarantinedLeaf(parent: parent, quarantineName: quarantine, originalName: source, role: "intención")
            throw RegressionCoreError.unsafeLibraryState("No se pudo retirar la intención")
        }
        try syncDirectory(parent)
    }

    private func readAnchoredRegularData(parent: Int32, name: String, maxBytes: Int) throws -> Data {
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo abrir el archivo anclado")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maxBytes else {
            throw RegressionCoreError.unsafeLibraryState("El archivo anclado no es regular y acotado")
        }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard count == data.count else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo leer el archivo anclado")
        }
        return data
    }

    private func reconcileLaunchIntent(runningState: RunningBackendState) throws {
        try recoverLaunchIntentQuarantine()
        guard pathExistsWithoutFollowingSymbolicLinks(physicalCustodyLaunchIntentURL) else { return }
        let intent = try readLaunchIntent()
        guard !runningState.crossOverIsRunning, !runningState.regressionIsRunning else {
            throw RegressionCoreError.unsafeLibraryState("Existe un lanzamiento de Steam todavía activo")
        }
        if let processID = intent.processID {
            errno = 0
            if kill(processID, 0) == 0 || errno == EPERM {
                throw RegressionCoreError.unsafeLibraryState(
                    "El proceso lanzador de Steam todavía no ha terminado"
                )
            }
            guard errno == ESRCH else {
                throw RegressionCoreError.unsafeLibraryState(
                    "No se pudo demostrar que el proceso lanzador terminó"
                )
            }
        }
        guard Date().timeIntervalSince(intent.startedAt) >= 30 else {
            throw RegressionCoreError.unsafeLibraryState(
                "El lanzamiento sigue dentro de su ventana durable de observabilidad"
            )
        }
        try unlinkLaunchIntent(expected: intent)
    }

    private func recoverLaunchIntentQuarantine() throws {
        guard fileManager.fileExists(atPath: backupRootURL.path) else { return }
        let candidates = try fileManager.contentsOfDirectory(
            at: backupRootURL,
            includingPropertiesForKeys: nil,
            options: []
        ).filter {
            $0.lastPathComponent.hasPrefix(".physical-custody-launch-")
                && $0.lastPathComponent.hasSuffix(".quarantine")
        }
        guard candidates.count <= 1 else {
            throw RegressionCoreError.unsafeLibraryState("Hay múltiples intenciones en cuarentena")
        }
        guard let candidate = candidates.first else { return }
        guard !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyLaunchIntentURL) else {
            throw RegressionCoreError.unsafeLibraryState("La intención y su cuarentena coexisten")
        }
        let parent = open(backupRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar la intención en cuarentena")
        }
        defer { close(parent) }
        let data = try readAnchoredRegularData(
            parent: parent,
            name: candidate.lastPathComponent,
            maxBytes: 16 * 1_024
        )
        let intent = try JSONDecoder().decode(PhysicalLibraryCustodyLaunchIntentRecord.self, from: data)
        guard candidate.lastPathComponent
            == ".physical-custody-launch-\(intent.id.uuidString.lowercased()).quarantine" else {
            throw RegressionCoreError.unsafeLibraryState("La cuarentena de lanzamiento tiene otra identidad")
        }
        try restoreQuarantinedLeaf(
            parent: parent,
            quarantineName: candidate.lastPathComponent,
            originalName: physicalCustodyLaunchIntentURL.lastPathComponent,
            role: "intención"
        )
    }

    private func status(for phase: PhysicalLibraryCustodyPhase) -> PhysicalLibraryCustodyStatus {
        switch phase {
        case .prepared: .preparing
        case .willStageDestination, .destinationStaged: .preCutover
        case .willCommitCutover, .cutoverCommitted: .cutover
        case .verifyingDestination: .verifying
        case .awaitingRuntimeValidation: .pendingValidation
        case .validatingRuntime: .validating
        case .validationAccepted, .willFinalize, .completed: .verifying
        case .willRollback: .rollingBack
        case .rolledBack: .rollingBack
        case .needsManualRecovery: .blocked("La custodia necesita recuperación manual")
        }
    }

    private func replacingPhase(
        of plan: PhysicalLibraryCustodyPlan,
        with phase: PhysicalLibraryCustodyPhase,
        validationStartedAt: Date? = nil
    ) -> PhysicalLibraryCustodyPlan {
        PhysicalLibraryCustodyPlan(
            schemaVersion: plan.schemaVersion,
            planID: plan.planID,
            createdAt: plan.createdAt,
            phase: phase,
            sourceSteamAppsURL: plan.sourceSteamAppsURL,
            destinationSteamAppsURL: plan.destinationSteamAppsURL,
            stagedRegressionLinkURL: plan.stagedRegressionLinkURL,
            originalRegressionLinkTarget: plan.originalRegressionLinkTarget,
            sourceDevice: plan.sourceDevice,
            sourceInode: plan.sourceInode,
            sourceParentDevice: plan.sourceParentDevice,
            sourceParentInode: plan.sourceParentInode,
            destinationParentDevice: plan.destinationParentDevice,
            destinationParentInode: plan.destinationParentInode,
            regressionLinkDevice: plan.regressionLinkDevice,
            regressionLinkInode: plan.regressionLinkInode,
            validationStartedAt: validationStartedAt ?? plan.validationStartedAt,
            validationEvidence: plan.validationEvidence,
            inventory: plan.inventory
        )
    }

    private func validatePlanIdentity(
        _ plan: PhysicalLibraryCustodyPlan,
        source: URL,
        destination: URL
    ) throws {
        guard plan.schemaVersion == 3,
              plan.sourceSteamAppsURL.standardizedFileURL == source.standardizedFileURL,
              plan.destinationSteamAppsURL.standardizedFileURL == destination.standardizedFileURL,
              plan.stagedRegressionLinkURL.deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL,
              plan.stagedRegressionLinkURL.lastPathComponent.hasPrefix(".steamapps-custody-"),
              plan.stagedRegressionLinkURL.lastPathComponent.hasSuffix(".rollback") else {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal de custodia no corresponde a estas instalaciones"
            )
        }
        try verifyParentIdentities(plan)
    }

    private func validateInitialTopology(source: URL, destination: URL) throws {
        try validateNoLinkedAncestors(at: source, includeFinalItem: true, role: "fuente heredada")
        try validateNoLinkedAncestors(at: destination, includeFinalItem: false, role: "destino Regression")
        guard directoryExistsWithoutSymbolicLink(at: source) else {
            throw RegressionCoreError.unsafeLibraryState(
                "La ruta heredada no contiene una carpeta steamapps física"
            )
        }
        guard let target = symbolicLinkDestination(at: destination),
              try canonicalPath(for: target) == canonicalPath(for: source) else {
            if pathExistsWithoutFollowingSymbolicLinks(destination) {
                throw RegressionCoreError.unsafeLibraryState("El destino de Regression ya está ocupado")
            }
            throw RegressionCoreError.unsafeLibraryState(
                "steamapps de Regression no apunta exactamente a la biblioteca compartida actual"
            )
        }
        guard let sourceVolume = volumeIdentityProvider(source),
              let destinationVolume = volumeIdentityProvider(destination),
              sourceVolume == destinationVolume else {
            throw RegressionCoreError.unsafeLibraryState(
                "La transferencia cruza volúmenes distintos y no puede ser atómica"
            )
        }
    }

    private func directoryIdentity(at url: URL) throws -> CustodyDirectoryIdentity {
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo anclar steamapps: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw RegressionCoreError.unsafeLibraryState("steamapps dejó de ser un directorio físico")
        }
        return CustodyDirectoryIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private func expectedIdentity(of plan: PhysicalLibraryCustodyPlan) -> CustodyDirectoryIdentity {
        CustodyDirectoryIdentity(device: plan.sourceDevice, inode: plan.sourceInode)
    }

    private func sourceParentIdentity(of plan: PhysicalLibraryCustodyPlan) -> CustodyDirectoryIdentity {
        .init(device: plan.sourceParentDevice, inode: plan.sourceParentInode)
    }

    private func destinationParentIdentity(of plan: PhysicalLibraryCustodyPlan) -> CustodyDirectoryIdentity {
        .init(device: plan.destinationParentDevice, inode: plan.destinationParentInode)
    }

    private func regressionLinkIdentity(of plan: PhysicalLibraryCustodyPlan) -> CustodyDirectoryIdentity {
        .init(device: plan.regressionLinkDevice, inode: plan.regressionLinkInode)
    }

    private func verifyParentIdentities(_ plan: PhysicalLibraryCustodyPlan) throws {
        guard try directoryIdentity(at: plan.sourceSteamAppsURL.deletingLastPathComponent())
                == sourceParentIdentity(of: plan),
              try directoryIdentity(at: plan.destinationSteamAppsURL.deletingLastPathComponent())
                == destinationParentIdentity(of: plan) else {
            throw RegressionCoreError.unsafeLibraryState(
                "Un directorio padre de custodia fue sustituido"
            )
        }
    }

    private func symbolicLinkIdentity(at url: URL) throws -> CustodyDirectoryIdentity {
        let parent = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el enlace steamapps")
        }
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, url.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              (metadata.st_mode & S_IFMT) == S_IFLNK else {
            throw RegressionCoreError.unsafeLibraryState("steamapps de Regression no es el enlace esperado")
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func readRawSymbolicLink(at url: URL) throws -> String {
        let parent = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el enlace steamapps")
        }
        defer { close(parent) }
        return try readRawSymbolicLink(parent: parent, name: url.lastPathComponent)
    }

    private func readRawSymbolicLink(parent: Int32, name: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(parent, name, &buffer, Int(PATH_MAX))
        guard count >= 0, count < Int(PATH_MAX) else {
            throw RegressionCoreError.unsafeLibraryState("steamapps de Regression no es el enlace esperado")
        }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func symbolicLinkIdentity(
        parent: Int32,
        name: String
    ) throws -> CustodyDirectoryIdentity {
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              (metadata.st_mode & S_IFMT) == S_IFLNK else {
            throw RegressionCoreError.unsafeLibraryState("steamapps de Regression no es el enlace esperado")
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func advanceCutover(
        plan initialPlan: PhysicalLibraryCustodyPlan,
        runningStateProvider: @escaping @Sendable () async -> RunningBackendState
    ) async throws -> PhysicalLibraryCustodyPlan {
        var plan = initialPlan
        let source = plan.sourceSteamAppsURL
        let destination = plan.destinationSteamAppsURL
        switch plan.phase {
        case .prepared:
            try ensureSteamStopped(await runningStateProvider())
            try validateInitialTopology(source: source, destination: destination)
            guard try directoryIdentity(at: source) == expectedIdentity(of: plan),
                  try inventory(at: source) == plan.inventory,
                  try readRawSymbolicLink(at: destination) == plan.originalRegressionLinkTarget,
                  try symbolicLinkIdentity(at: destination) == regressionLinkIdentity(of: plan) else {
                throw RegressionCoreError.unsafeLibraryState("La topología cambió antes del traslado")
            }
            plan = replacingPhase(of: plan, with: .willStageDestination)
            try write(plan: plan)
            try custodyFault(.afterWillStageDestination)
            fallthrough
        case .willStageDestination:
            if pathExistsWithoutFollowingSymbolicLinks(destination) {
                try anchoredRenameExclusive(
                    from: destination,
                    to: plan.stagedRegressionLinkURL,
                    expectedSourceParent: destinationParentIdentity(of: plan),
                    expectedDestinationParent: destinationParentIdentity(of: plan),
                    expectedItem: regressionLinkIdentity(of: plan),
                    expectedItemType: S_IFLNK
                )
                try custodyFault(.afterDestinationStagedRename)
            } else {
                try verifyStagedLink(plan)
            }
            plan = replacingPhase(of: plan, with: .destinationStaged)
            try write(plan: plan)
            try custodyFault(.afterDestinationStagedJournal)
            fallthrough
        case .destinationStaged:
            try verifyStagedLink(plan)
            try await ensureSteamRemainsStopped(runningStateProvider)
            guard try directoryIdentity(at: source) == expectedIdentity(of: plan),
                  try inventory(at: source) == plan.inventory else {
                throw RegressionCoreError.unsafeLibraryState(
                    "La biblioteca de origen cambió antes del cutover"
                )
            }
            plan = replacingPhase(of: plan, with: .willCommitCutover)
            try write(plan: plan)
            try custodyFault(.afterWillCommitCutover)
            fallthrough
        case .willCommitCutover:
            let sourceExists = directoryExistsWithoutSymbolicLink(at: source)
            let destinationExists = directoryExistsWithoutSymbolicLink(at: destination)
            if sourceExists && !destinationExists {
                try anchoredRenameExclusive(
                    from: source,
                    to: destination,
                    expectedSourceParent: sourceParentIdentity(of: plan),
                    expectedDestinationParent: destinationParentIdentity(of: plan),
                    expectedItem: expectedIdentity(of: plan),
                    expectedItemType: S_IFDIR
                )
                try custodyFault(.afterCutoverRename)
            } else if !sourceExists && destinationExists {
                guard try directoryIdentity(at: destination) == expectedIdentity(of: plan) else {
                    throw RegressionCoreError.unsafeLibraryState("El destino no conserva la biblioteca original")
                }
            } else {
                throw RegressionCoreError.unsafeLibraryState("Topología ambigua durante el cutover")
            }
            plan = replacingPhase(of: plan, with: .cutoverCommitted)
            try write(plan: plan)
            try custodyFault(.afterCutoverJournal)
            fallthrough
        case .cutoverCommitted:
            try verifyCommittedTopology(plan)
            plan = replacingPhase(of: plan, with: .verifyingDestination)
            try write(plan: plan)
            try custodyFault(.afterVerifyingJournal)
            fallthrough
        case .verifyingDestination:
            try verifyCommittedTopology(plan)
            guard try inventory(at: destination) == plan.inventory else {
                throw RegressionCoreError.unsafeLibraryState("El inventario cambió durante el traslado")
            }
            plan = replacingPhase(
                of: plan,
                with: .awaitingRuntimeValidation,
                validationStartedAt: Date()
            )
            try write(plan: plan)
            return plan
        case .awaitingRuntimeValidation, .validatingRuntime:
            try verifyCommittedTopology(plan)
            return plan
        case .validationAccepted, .willFinalize, .completed:
            return try finishValidatedCustody(plan)
        case .willRollback, .rolledBack:
            throw RegressionCoreError.unsafeLibraryState("La custodia está en rollback")
        case .needsManualRecovery:
            throw RegressionCoreError.unsafeLibraryState("La custodia necesita recuperación manual")
        }
    }

    private func verifyStagedLink(_ plan: PhysicalLibraryCustodyPlan) throws {
        guard !pathExistsWithoutFollowingSymbolicLinks(plan.destinationSteamAppsURL),
              try readRawSymbolicLink(at: plan.stagedRegressionLinkURL)
                == plan.originalRegressionLinkTarget,
              try symbolicLinkIdentity(at: plan.stagedRegressionLinkURL)
                == regressionLinkIdentity(of: plan),
              try directoryIdentity(at: plan.sourceSteamAppsURL) == expectedIdentity(of: plan) else {
            throw RegressionCoreError.unsafeLibraryState("La fase preparada no coincide con la topología")
        }
    }

    private func verifyCommittedTopology(_ plan: PhysicalLibraryCustodyPlan) throws {
        try verifyOwnedTree(plan)
        guard
              try readRawSymbolicLink(at: plan.stagedRegressionLinkURL)
                == plan.originalRegressionLinkTarget,
              try symbolicLinkIdentity(at: plan.stagedRegressionLinkURL)
                == regressionLinkIdentity(of: plan) else {
            throw RegressionCoreError.unsafeLibraryState(
                "El cutover no conserva una única biblioteca física verificable"
            )
        }
    }

    private func verifyOwnedTree(_ plan: PhysicalLibraryCustodyPlan) throws {
        try verifyParentIdentities(plan)
        guard !pathExistsWithoutFollowingSymbolicLinks(plan.sourceSteamAppsURL),
              try directoryIdentity(at: plan.destinationSteamAppsURL) == expectedIdentity(of: plan) else {
            throw RegressionCoreError.unsafeLibraryState(
                "El cutover no conserva la biblioteca física original"
            )
        }
    }

    private func finishValidatedCustody(
        _ initialPlan: PhysicalLibraryCustodyPlan,
        validationEvidence: String? = nil
    ) throws -> PhysicalLibraryCustodyPlan {
        var plan = initialPlan
        try verifyOwnedTree(plan)
        if let validationEvidence {
            plan = replacingValidationEvidence(of: plan, with: validationEvidence)
        }
        guard plan.validationEvidence != nil else {
            throw RegressionCoreError.unsafeLibraryState("Falta la evidencia de validación")
        }
        if plan.phase != .validationAccepted && plan.phase != .willFinalize && plan.phase != .completed {
            plan = replacingPhase(of: plan, with: .validationAccepted)
            try write(plan: plan)
        }
        if plan.phase == .validationAccepted {
            plan = replacingPhase(of: plan, with: .willFinalize)
            try write(plan: plan)
            try custodyFault(.afterWillFinalizeJournal)
        }
        if !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL) {
            try writePhysicalCustodyReceipt(for: plan)
        } else {
            try validatePhysicalCustodyReceipt(for: plan)
        }
        try custodyFault(.afterFinalizeReceipt)
        if pathExistsWithoutFollowingSymbolicLinks(plan.stagedRegressionLinkURL) {
            try unlinkExpectedSymlink(at: plan.stagedRegressionLinkURL, plan: plan)
        }
        try custodyFault(.afterFinalizeMarkerUnlink)
        plan = replacingPhase(of: plan, with: .completed)
        try write(plan: plan)
        try custodyFault(.afterCompletedJournal)
        try custodyFault(.beforeFinalJournalUnlink)
        try unlinkJournal(expectedPlan: plan)
        return plan
    }

    private func replacingValidationEvidence(
        of plan: PhysicalLibraryCustodyPlan,
        with evidence: String
    ) -> PhysicalLibraryCustodyPlan {
        PhysicalLibraryCustodyPlan(
            schemaVersion: plan.schemaVersion,
            planID: plan.planID,
            createdAt: plan.createdAt,
            phase: plan.phase,
            sourceSteamAppsURL: plan.sourceSteamAppsURL,
            destinationSteamAppsURL: plan.destinationSteamAppsURL,
            stagedRegressionLinkURL: plan.stagedRegressionLinkURL,
            originalRegressionLinkTarget: plan.originalRegressionLinkTarget,
            sourceDevice: plan.sourceDevice,
            sourceInode: plan.sourceInode,
            sourceParentDevice: plan.sourceParentDevice,
            sourceParentInode: plan.sourceParentInode,
            destinationParentDevice: plan.destinationParentDevice,
            destinationParentInode: plan.destinationParentInode,
            regressionLinkDevice: plan.regressionLinkDevice,
            regressionLinkInode: plan.regressionLinkInode,
            validationStartedAt: plan.validationStartedAt,
            validationEvidence: evidence,
            inventory: plan.inventory
        )
    }

    private func validatedEvidence(_ raw: String) throws -> String {
        let evidence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty, evidence.utf8.count <= 4_096,
              evidence.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) || $0.value == 0x0A
              }) else {
            throw RegressionCoreError.unsafeLibraryState(
                "La evidencia debe contener entre 1 y 4096 bytes de texto seguro"
            )
        }
        return evidence
    }

    private func rollback(plan initialPlan: PhysicalLibraryCustodyPlan) throws -> PhysicalLibraryCustodyPlan {
        guard initialPlan.phase != .validationAccepted,
              initialPlan.phase != .willFinalize,
              initialPlan.phase != .completed else {
            throw RegressionCoreError.unsafeLibraryState(
                "La validación ya fue aceptada; solo puede completarse la finalización durable"
            )
        }
        var plan = replacingPhase(of: initialPlan, with: .willRollback)
        try write(plan: plan)
        try custodyFault(.afterWillRollback)

        let source = plan.sourceSteamAppsURL
        let destination = plan.destinationSteamAppsURL
        if directoryExistsWithoutSymbolicLink(at: destination) {
            guard !pathExistsWithoutFollowingSymbolicLinks(source),
                  try directoryIdentity(at: destination) == expectedIdentity(of: plan) else {
                throw RegressionCoreError.unsafeLibraryState("No se puede restaurar la biblioteca con seguridad")
            }
            try anchoredRenameExclusive(
                from: destination,
                to: source,
                expectedSourceParent: destinationParentIdentity(of: plan),
                expectedDestinationParent: sourceParentIdentity(of: plan),
                expectedItem: expectedIdentity(of: plan),
                expectedItemType: S_IFDIR
            )
            try custodyFault(.afterRollbackSourceRename)
        } else {
            guard try directoryIdentity(at: source) == expectedIdentity(of: plan) else {
                throw RegressionCoreError.unsafeLibraryState("No se encuentra la biblioteca original")
            }
        }
        if pathExistsWithoutFollowingSymbolicLinks(plan.stagedRegressionLinkURL) {
            guard !pathExistsWithoutFollowingSymbolicLinks(destination) else {
                throw RegressionCoreError.unsafeLibraryState("El destino está ocupado durante el rollback")
            }
            guard try readRawSymbolicLink(at: plan.stagedRegressionLinkURL)
                    == plan.originalRegressionLinkTarget,
                  try symbolicLinkIdentity(at: plan.stagedRegressionLinkURL)
                    == regressionLinkIdentity(of: plan) else {
                throw RegressionCoreError.unsafeLibraryState(
                    "El enlace de rollback fue sustituido y no se restaurará"
                )
            }
            try anchoredRenameExclusive(
                from: plan.stagedRegressionLinkURL,
                to: destination,
                expectedSourceParent: destinationParentIdentity(of: plan),
                expectedDestinationParent: destinationParentIdentity(of: plan),
                expectedItem: regressionLinkIdentity(of: plan),
                expectedItemType: S_IFLNK
            )
            try custodyFault(.afterRollbackLinkRename)
        }
        try validateInitialTopology(source: source, destination: destination)
        plan = replacingPhase(of: plan, with: .rolledBack)
        try write(plan: plan)
        try unlinkStartedMarker(planID: plan.planID)
        try custodyFault(.afterRollbackStartedMarkerUnlink)
        try unlinkJournal(expectedPlan: plan)
        return plan
    }

    private func anchoredRenameExclusive(
        from source: URL,
        to destination: URL,
        expectedSourceParent: CustodyDirectoryIdentity,
        expectedDestinationParent: CustodyDirectoryIdentity,
        expectedItem: CustodyDirectoryIdentity,
        expectedItemType: mode_t
    ) throws {
        let sourceParent = open(
            source.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard sourceParent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el origen del rename")
        }
        defer { close(sourceParent) }
        let destinationParent = open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard destinationParent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el destino del rename")
        }
        defer { close(destinationParent) }
        guard try descriptorIdentity(sourceParent) == expectedSourceParent,
              try descriptorIdentity(destinationParent) == expectedDestinationParent else {
            throw RegressionCoreError.unsafeLibraryState(
                "Un directorio padre fue sustituido durante el rename"
            )
        }
        var itemMetadata = stat()
        guard fstatat(sourceParent, source.lastPathComponent, &itemMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              (itemMetadata.st_mode & S_IFMT) == expectedItemType,
              CustodyDirectoryIdentity(
                  device: UInt64(itemMetadata.st_dev),
                  inode: UInt64(itemMetadata.st_ino)
              ) == expectedItem else {
            throw RegressionCoreError.unsafeLibraryState(
                "El elemento que se iba a trasladar fue sustituido"
            )
        }
        var destinationMetadata = stat()
        guard fstatat(
            destinationParent,
            destination.lastPathComponent,
            &destinationMetadata,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw RegressionCoreError.unsafeLibraryState("El destino del rename ya está ocupado")
        }
        guard renameatx_np(
            sourceParent,
            source.lastPathComponent,
            destinationParent,
            destination.lastPathComponent,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let code = errno
            let detail = code == EXDEV ? "volúmenes distintos (EXDEV)" : String(cString: strerror(code))
            throw RegressionCoreError.unsafeLibraryState("El rename atómico fue rechazado: \(detail)")
        }
        try syncDirectory(sourceParent)
        if destinationParent != sourceParent { try syncDirectory(destinationParent) }
    }

    private func descriptorIdentity(_ descriptor: Int32) throws -> CustodyDirectoryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw RegressionCoreError.unsafeLibraryState("El descriptor padre dejó de ser un directorio")
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func ensureSteamRemainsStopped(
        _ runningStateProvider: @escaping @Sendable () async -> RunningBackendState
    ) async throws {
        for sample in 0..<3 {
            try ensureSteamStopped(await runningStateProvider())
            guard sample < 2 else { break }
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
        }
    }

    private func withCustodyLock<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)
        try validateJournalParent()
        let lockURL = backupRootURL.appendingPathComponent("physical-custody.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW_ANY | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo abrir el lock de custodia")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RegressionCoreError.unsafeLibraryState("Ya hay otra operación de custodia en curso")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try await operation()
    }

    private func withCustodyLockSync<T>(_ operation: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)
        try validateJournalParent()
        let lockURL = backupRootURL.appendingPathComponent("physical-custody.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW_ANY | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo abrir el lock de custodia")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RegressionCoreError.unsafeLibraryState("Ya hay otra operación de custodia en curso")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func write(plan: PhysicalLibraryCustodyPlan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        guard data.count <= inventoryLimits.maxJournalBytes else {
            throw RegressionCoreError.unsafeLibraryState("El journal de custodia supera el límite seguro")
        }
        try writeDurableRegularFile(data, to: physicalCustodyJournalURL)
    }

    private func readPhysicalCustodyPlan() throws -> PhysicalLibraryCustodyPlan {
        do {
            try validateJournalParent()
            let data = try readBoundedRegularFile(
                at: physicalCustodyJournalURL,
                maxBytes: inventoryLimits.maxJournalBytes,
                role: "journal de custodia"
            )
            return try JSONDecoder().decode(PhysicalLibraryCustodyPlan.self, from: data)
        } catch let error as RegressionCoreError {
            throw error
        } catch {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal de custodia no se puede recuperar: \(error.localizedDescription)"
            )
        }
    }

    private func readPhysicalCustodyPlan(
        parent: Int32,
        name: String
    ) throws -> PhysicalLibraryCustodyPlan {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo abrir el journal en cuarentena"
            )
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(inventoryLimits.maxJournalBytes) else {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal en cuarentena no es un archivo regular acotado"
            )
        }
        var data = Data()
        while data.count <= inventoryLimits.maxJournalBytes {
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw RegressionCoreError.unsafeLibraryState(
                    "No se pudo leer el journal en cuarentena"
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= inventoryLimits.maxJournalBytes else {
            throw RegressionCoreError.unsafeLibraryState(
                "El journal en cuarentena supera el límite seguro"
            )
        }
        return try JSONDecoder().decode(PhysicalLibraryCustodyPlan.self, from: data)
    }

    private func writePhysicalCustodyReceipt(for plan: PhysicalLibraryCustodyPlan) throws {
        let receipt = PhysicalLibraryCustodyReceipt(
            schemaVersion: 2,
            completedAt: Date(),
            transactionID: plan.planID,
            sourceSteamAppsURL: plan.sourceSteamAppsURL,
            destinationSteamAppsURL: plan.destinationSteamAppsURL,
            identity: expectedIdentity(of: plan),
            validationEvidence: try validatedEvidence(plan.validationEvidence ?? ""),
            inventory: plan.inventory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        try writeDurableRegularFile(data, to: physicalCustodyReceiptMirrorURL)
        try writeDurableRegularFile(data, to: physicalCustodyReceiptURL)
    }

    private func writePhysicalCustodyReceipt(
        _ receipt: PhysicalLibraryCustodyReceipt
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= inventoryLimits.maxJournalBytes else {
            throw RegressionCoreError.unsafeLibraryState(
                "El recibo de la biblioteca propia supera el límite seguro"
            )
        }
        try writeDurableRegularFile(data, to: physicalCustodyReceiptMirrorURL)
        do {
            try writeDurableRegularFile(data, to: physicalCustodyReceiptURL)
        } catch {
            let recovered = try readPhysicalCustodyReceipt(at: physicalCustodyReceiptMirrorURL)
            guard recovered.transactionID == receipt.transactionID,
                  recovered.sourceSteamAppsURL == receipt.sourceSteamAppsURL,
                  recovered.destinationSteamAppsURL == receipt.destinationSteamAppsURL,
                  recovered.identity == receipt.identity,
                  recovered.validationEvidence == receipt.validationEvidence,
                  recovered.inventory == receipt.inventory,
                  recovered.origin == receipt.origin else {
                throw error
            }
        }
    }

    private func validateIndependentReceipt(
        _ expected: PhysicalLibraryCustodyReceipt,
        source: URL,
        destination: URL
    ) throws {
        let receipt: PhysicalLibraryCustodyReceipt
        if pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL) {
            receipt = try readPhysicalCustodyReceipt()
        } else {
            receipt = try readPhysicalCustodyReceipt(at: physicalCustodyReceiptMirrorURL)
        }
        guard receipt.transactionID == expected.transactionID,
              receipt.sourceSteamAppsURL == source,
              receipt.destinationSteamAppsURL == destination,
              receipt.identity == expected.identity,
              receipt.validationEvidence == expected.validationEvidence,
              receipt.inventory == expected.inventory,
              receipt.origin == expected.origin,
              !pathExistsWithoutFollowingSymbolicLinks(source),
              try directoryIdentity(at: destination) == expected.identity else {
            throw RegressionCoreError.unsafeLibraryState(
                "El recibo de la biblioteca propia no coincide con la topología verificada"
            )
        }
    }

    private func readPhysicalCustodyReceipt() throws -> PhysicalLibraryCustodyReceipt {
        try readPhysicalCustodyReceipt(at: physicalCustodyReceiptURL)
    }

    private func readPhysicalCustodyReceipt(at url: URL) throws -> PhysicalLibraryCustodyReceipt {
        let data = try readBoundedRegularFile(
            at: url,
            maxBytes: inventoryLimits.maxJournalBytes,
            role: "recibo de custodia"
        )
        let receipt = try JSONDecoder().decode(PhysicalLibraryCustodyReceipt.self, from: data)
        guard receipt.schemaVersion == 2 else {
            throw RegressionCoreError.unsafeLibraryState("El recibo de custodia tiene otra versión")
        }
        return receipt
    }

    private func writeCustodyStartedMarker(planID: UUID) throws {
        let data = try JSONEncoder().encode(["schemaVersion": "1", "transactionID": planID.uuidString])
        try writeDurableRegularFile(data, to: physicalCustodyStartedMarkerURL)
    }

    private func unlinkStartedMarker(planID: UUID) throws {
        guard pathExistsWithoutFollowingSymbolicLinks(physicalCustodyStartedMarkerURL) else { return }
        let parent = open(
            backupRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el marcador de custodia")
        }
        defer { close(parent) }
        let source = physicalCustodyStartedMarkerURL.lastPathComponent
        var metadata = stat()
        guard fstatat(parent, source, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw RegressionCoreError.unsafeLibraryState("El marcador de custodia no es regular")
        }
        let quarantine = ".physical-custody-started-\(planID.uuidString.lowercased()).quarantine"
        try quarantineLeaf(parent: parent, sourceName: source, quarantineName: quarantine, role: "marcador")
        try custodyFault(.afterStartedMarkerQuarantine)
        do {
            var quarantined = stat()
            let data = try readAnchoredRegularData(parent: parent, name: quarantine, maxBytes: 16 * 1_024)
            let marker = try JSONDecoder().decode([String: String].self, from: data)
            guard fstatat(parent, quarantine, &quarantined, AT_SYMLINK_NOFOLLOW) == 0,
                  quarantined.st_dev == metadata.st_dev,
                  quarantined.st_ino == metadata.st_ino,
                  marker["schemaVersion"] == "1",
                  marker["transactionID"] == planID.uuidString else {
                throw RegressionCoreError.unsafeLibraryState("El marcador de custodia fue sustituido")
            }
        } catch {
            try restoreQuarantinedLeaf(parent: parent, quarantineName: quarantine, originalName: source, role: "marcador")
            throw error
        }
        guard unlinkat(parent, quarantine, 0) == 0 else {
            try restoreQuarantinedLeaf(parent: parent, quarantineName: quarantine, originalName: source, role: "marcador")
            throw RegressionCoreError.unsafeLibraryState("No se pudo retirar el marcador de custodia")
        }
        try syncDirectory(parent)
    }

    private func recoverStartedMarkerQuarantine(planID: UUID) throws {
        let name = ".physical-custody-started-\(planID.uuidString.lowercased()).quarantine"
        let url = backupRootURL.appendingPathComponent(name)
        guard pathExistsWithoutFollowingSymbolicLinks(url) else { return }
        guard !pathExistsWithoutFollowingSymbolicLinks(physicalCustodyStartedMarkerURL) else {
            throw RegressionCoreError.unsafeLibraryState("El marcador y su cuarentena coexisten")
        }
        let parent = open(backupRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el marcador en cuarentena")
        }
        defer { close(parent) }
        let data = try readAnchoredRegularData(parent: parent, name: name, maxBytes: 16 * 1_024)
        let marker = try JSONDecoder().decode([String: String].self, from: data)
        guard marker["schemaVersion"] == "1", marker["transactionID"] == planID.uuidString else {
            throw RegressionCoreError.unsafeLibraryState("La cuarentena del marcador tiene otra identidad")
        }
        try restoreQuarantinedLeaf(
            parent: parent,
            quarantineName: name,
            originalName: physicalCustodyStartedMarkerURL.lastPathComponent,
            role: "marcador"
        )
    }

    private func validatePhysicalCustodyReceipt(for plan: PhysicalLibraryCustodyPlan) throws {
        let receipt = try readPhysicalCustodyReceipt()
        guard receipt.transactionID == plan.planID,
              receipt.sourceSteamAppsURL == plan.sourceSteamAppsURL,
              receipt.destinationSteamAppsURL == plan.destinationSteamAppsURL,
              receipt.identity == expectedIdentity(of: plan),
              receipt.inventory == plan.inventory,
              receipt.validationEvidence == plan.validationEvidence,
              receipt.origin == nil else {
            throw RegressionCoreError.unsafeLibraryState("El recibo durable de custodia no coincide")
        }
    }

    private func writeDurableRegularFile(_ data: Data, to url: URL) throws {
        try PrivateStorage.ensureDirectory(at: url.deletingLastPathComponent(), fileManager: fileManager)
        try validateJournalParent()
        let parent = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el journal")
        }
        defer { close(parent) }
        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = openat(parent, temporaryName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo crear el journal temporal")
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { _ = unlinkat(parent, temporaryName, 0) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw RegressionCoreError.unsafeLibraryState("No se pudo persistir el journal")
                }
                offset += count
            }
        }
        try fullSync(descriptor)
        guard renameat(parent, temporaryName, parent, url.lastPathComponent) == 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo publicar el journal atómicamente")
        }
        shouldUnlink = false
        try syncDirectory(parent)
    }

    private func fullSync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo sincronizar el estado durable")
        }
    }

    private func syncDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo sincronizar el directorio")
        }
    }

    private func unlinkExpectedSymlink(
        at url: URL,
        plan: PhysicalLibraryCustodyPlan
    ) throws {
        let parent = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo anclar el enlace de rollback"
            )
        }
        defer { close(parent) }
        guard try descriptorIdentity(parent) == destinationParentIdentity(of: plan) else {
            throw RegressionCoreError.unsafeLibraryState(
                "El padre del enlace de rollback fue sustituido"
            )
        }
        try custodyFault(.beforeFinalizeMarkerQuarantine)
        let quarantine = markerQuarantineName(planID: plan.planID)
        try quarantineLeaf(
            parent: parent,
            sourceName: url.lastPathComponent,
            quarantineName: quarantine,
            role: "enlace de rollback"
        )
        try custodyFault(.afterFinalizeMarkerQuarantine)
        do {
            guard try symbolicLinkIdentity(parent: parent, name: quarantine)
                    == regressionLinkIdentity(of: plan),
                  try readRawSymbolicLink(parent: parent, name: quarantine)
                    == plan.originalRegressionLinkTarget else {
                throw RegressionCoreError.unsafeLibraryState(
                    "El enlace de rollback fue sustituido y no se retirará"
                )
            }
        } catch {
            try restoreQuarantinedLeaf(
                parent: parent,
                quarantineName: quarantine,
                originalName: url.lastPathComponent,
                role: "enlace de rollback"
            )
            throw error
        }
        guard unlinkat(parent, quarantine, 0) == 0 else {
            try restoreQuarantinedLeaf(
                parent: parent,
                quarantineName: quarantine,
                originalName: url.lastPathComponent,
                role: "enlace de rollback"
            )
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo retirar el enlace de rollback en cuarentena"
            )
        }
        try syncDirectory(parent)
    }

    private func unlinkJournal(expectedPlan: PhysicalLibraryCustodyPlan) throws {
        try validateJournalParent()
        let parent = open(
            backupRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el directorio del journal")
        }
        defer { close(parent) }
        let journalName = physicalCustodyJournalURL.lastPathComponent
        var expectedMetadata = stat()
        guard fstatat(parent, journalName, &expectedMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              (expectedMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw RegressionCoreError.unsafeLibraryState("El journal de custodia no es un archivo regular")
        }
        beforeJournalUnlink()
        let quarantine = journalQuarantineName(planID: expectedPlan.planID)
        try quarantineLeaf(
            parent: parent,
            sourceName: journalName,
            quarantineName: quarantine,
            role: "journal de custodia"
        )
        try custodyFault(.afterJournalQuarantine)
        do {
            var quarantinedMetadata = stat()
            guard fstatat(parent, quarantine, &quarantinedMetadata, AT_SYMLINK_NOFOLLOW) == 0,
                  (quarantinedMetadata.st_mode & S_IFMT) == S_IFREG,
                  quarantinedMetadata.st_dev == expectedMetadata.st_dev,
                  quarantinedMetadata.st_ino == expectedMetadata.st_ino,
                  try readPhysicalCustodyPlan(parent: parent, name: quarantine) == expectedPlan else {
                throw RegressionCoreError.unsafeLibraryState(
                    "El journal de custodia fue sustituido y no se retirará"
                )
            }
        } catch {
            try restoreQuarantinedLeaf(
                parent: parent,
                quarantineName: quarantine,
                originalName: journalName,
                role: "journal de custodia"
            )
            throw error
        }
        guard unlinkat(parent, quarantine, 0) == 0 else {
            try restoreQuarantinedLeaf(
                parent: parent,
                quarantineName: quarantine,
                originalName: journalName,
                role: "journal de custodia"
            )
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo retirar el journal de custodia en cuarentena"
            )
        }
        try syncDirectory(parent)
    }

    private func quarantineLeaf(
        parent: Int32,
        sourceName: String,
        quarantineName: String,
        role: String
    ) throws {
        guard renameatx_np(
            parent,
            sourceName,
            parent,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo aislar \(role) antes de retirarlo: \(String(cString: strerror(errno)))"
            )
        }
        try syncDirectory(parent)
    }

    private func markerQuarantineName(planID: UUID) -> String {
        ".regression-custody-marker-\(planID.uuidString).quarantine"
    }

    private func journalQuarantineName(planID: UUID) -> String {
        ".physical-custody-journal-\(planID.uuidString).quarantine"
    }

    private func restoreQuarantinedLeaf(
        parent: Int32,
        quarantineName: String,
        originalName: String,
        role: String
    ) throws {
        guard renameatx_np(
            parent,
            quarantineName,
            parent,
            originalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "\(role.capitalized) quedó preservado en cuarentena; la ruta original fue ocupada"
            )
        }
        try syncDirectory(parent)
    }

    private func recoverDeterministicMarkerQuarantine(
        plan: PhysicalLibraryCustodyPlan
    ) throws {
        let marker = plan.stagedRegressionLinkURL
        let quarantineURL = marker.deletingLastPathComponent().appendingPathComponent(
            markerQuarantineName(planID: plan.planID)
        )
        guard pathExistsWithoutFollowingSymbolicLinks(quarantineURL) else { return }
        let parent = open(
            marker.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar la cuarentena del marcador")
        }
        defer { close(parent) }
        let quarantineName = quarantineURL.lastPathComponent
        guard try symbolicLinkIdentity(parent: parent, name: quarantineName)
                == regressionLinkIdentity(of: plan),
              try readRawSymbolicLink(parent: parent, name: quarantineName)
                == plan.originalRegressionLinkTarget else {
            throw RegressionCoreError.unsafeLibraryState(
                "La cuarentena del enlace de rollback fue sustituida"
            )
        }
        guard pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptURL),
              pathExistsWithoutFollowingSymbolicLinks(physicalCustodyReceiptMirrorURL) else {
            try restoreQuarantinedLeaf(
                parent: parent,
                quarantineName: quarantineName,
                originalName: marker.lastPathComponent,
                role: "enlace de rollback"
            )
            return
        }
        guard unlinkat(parent, quarantineName, 0) == 0 else {
            throw RegressionCoreError.unsafeLibraryState(
                "No se pudo retirar la cuarentena validada del marcador"
            )
        }
        try syncDirectory(parent)
    }

    private func recoverDeterministicJournalQuarantine() throws -> PhysicalLibraryCustodyPlan? {
        guard fileManager.fileExists(atPath: backupRootURL.path) else { return nil }
        let candidates = try fileManager.contentsOfDirectory(
            at: backupRootURL,
            includingPropertiesForKeys: nil,
            options: []
        ).filter {
            $0.lastPathComponent.hasPrefix(".physical-custody-journal-")
                && $0.lastPathComponent.hasSuffix(".quarantine")
        }
        guard candidates.count <= 1 else {
            throw RegressionCoreError.unsafeLibraryState("Hay múltiples journals en cuarentena")
        }
        guard let candidate = candidates.first else { return nil }
        let parent = open(
            backupRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("No se pudo anclar el journal en cuarentena")
        }
        defer { close(parent) }
        let plan = try readPhysicalCustodyPlan(parent: parent, name: candidate.lastPathComponent)
        guard candidate.lastPathComponent == journalQuarantineName(planID: plan.planID) else {
            throw RegressionCoreError.unsafeLibraryState("El journal en cuarentena tiene otra identidad")
        }
        if plan.phase == .rolledBack || plan.phase == .completed {
            guard unlinkat(parent, candidate.lastPathComponent, 0) == 0 else {
                throw RegressionCoreError.unsafeLibraryState(
                    "No se pudo retirar el journal terminal en cuarentena"
                )
            }
            try syncDirectory(parent)
            return nil
        }
        try restoreQuarantinedLeaf(
            parent: parent,
            quarantineName: candidate.lastPathComponent,
            originalName: physicalCustodyJournalURL.lastPathComponent,
            role: "journal de custodia"
        )
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

    private func readBoundedRegularFile(at url: URL, maxBytes: Int, role: String) throws -> Data {
        guard maxBytes >= 0 else {
            throw RegressionCoreError.unsafeLibraryState("El límite de \(role) no es válido")
        }
        let descriptor = open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC
        )
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
