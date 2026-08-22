import Foundation

public struct SteamCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public enum BackendCommandFactory {
    public static func regression(
        installation: RegressionInstallation,
        steamArguments: [String]
    ) -> SteamCommand {
        SteamCommand(
            executableURL: installation.engineLauncherURL,
            arguments: steamArguments
        )
    }
}

/// Regla única para las rutas operativas que todavía aceptan un backend explícito.
/// La ausencia de opción significa Regression, incluso si un Steam heredado sigue vivo.
public enum BackendLaunchPolicy {
    public static func cliSelection(
        requestedRawValue: String?,
        activeBackend _: BackendKind?
    ) throws -> BackendKind {
        guard let requestedRawValue else { return .regression }
        guard let backend = BackendKind(rawValue: requestedRawValue), backend == .regression else {
            throw RegressionCoreError.launchFailed("Usa --backend regression")
        }
        return backend
    }
}

public struct PhysicalLibraryCustodyValidationRequest: Equatable, Sendable {
    public let appID: String
    public let runID: UUID

    public init(appID: String, runID: UUID) {
        self.appID = appID
        self.runID = runID
    }
}

public enum PhysicalLibraryCustodyCommandPolicy {
    public static func authorizeMigration(arguments: [String]) throws {
        let required = [
            "--confirm-single-library",
            "--confirm-crossover-games-removed",
        ]
        guard required.allSatisfy(arguments.contains) else {
            throw RegressionCoreError.unsafeLibraryState(
                "Confirma el traslado único con --confirm-single-library "
                    + "--confirm-crossover-games-removed"
            )
        }
    }

    public static func authorizeRollback(arguments: [String]) throws {
        guard arguments.contains("--confirm-rollback") else {
            throw RegressionCoreError.unsafeLibraryState(
                "Confirma la restauración con --confirm-rollback"
            )
        }
    }

    public static func validationRequest(
        arguments: [String]
    ) throws -> PhysicalLibraryCustodyValidationRequest {
        guard arguments.count == 4,
              arguments.first == "validate-library",
              arguments[2] == "--run",
              let appID = SteamAppID.normalized(arguments[1]),
              let runID = UUID(uuidString: arguments[3]) else {
            throw RegressionCoreError.launchFailed(
                "Usa validate-library APP_ID --run RUN_ID"
            )
        }
        return PhysicalLibraryCustodyValidationRequest(appID: appID, runID: runID)
    }

}

public enum RegressionLaunchComponentGate {
    public static func evaluate(
        installation: RegressionInstallation
    ) -> ComponentHealthReport {
        let applicationURL = installation.applicationURL.standardizedFileURL
        let bundle = Bundle(url: applicationURL)
        let version = bundle?.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "desconocida"
        let build = bundle?.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "desconocida"
        let isCanonicalPublicBuild = applicationURL.path == "/Applications/Regression.app"
            && version == TrustedComponentCatalog.supportedApplicationVersion
            && build == TrustedComponentCatalog.supportedBuildIdentifier
        let descriptor = TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
            applicationVersion: version,
            buildIdentifier: build,
            variant: isCanonicalPublicBuild ? .publicInstalled : .development,
            wineRootURL: applicationURL.appendingPathComponent(
                "Contents/SharedSupport/wine-root",
                isDirectory: true
            )
        )
        return ComponentHealthService.evaluate(descriptor)
    }

    public static func requireReady(_ report: ComponentHealthReport) throws {
        guard report.identity.componentID
                == TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
              report.identity.componentVersion
                == TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
              report.identity.buildIdentifier
                == TrustedComponentCatalog.supportedBuildIdentifier,
              report.identity.variant == .publicInstalled,
              report.status == .ready else {
            throw RegressionCoreError.unsafeLibraryState(
                "El runtime sellado de Wine/VC++/UCRT no supera ComponentHealth; "
                    + "Regression no abrirá Steam ni juegos"
            )
        }
    }
}

public actor BackendCoordinator {
    private let processRunner: any ProcessRunning
    private let processLauncher: any ProcessLaunching
    private let inspector: any ProcessInspecting
    private let logDirectoryURL: URL
    private let custodyInterlock: (any PhysicalLibraryCustodyInterlocking)?
    private let regressionComponentHealthProvider:
        @Sendable (RegressionInstallation) -> ComponentHealthReport
    private let rendererLaunchValidator:
        @Sendable (RegressionInstallation, String?) throws -> Void
    private let launchObservabilityInterval: Duration

    public init(
        processRunner: any ProcessRunning,
        processLauncher: any ProcessLaunching,
        inspector: any ProcessInspecting,
        logDirectoryURL: URL,
        custodyInterlock: (any PhysicalLibraryCustodyInterlocking)? = nil
    ) {
        self.processRunner = processRunner
        self.processLauncher = processLauncher
        self.inspector = inspector
        self.logDirectoryURL = logDirectoryURL
        self.custodyInterlock = custodyInterlock
        self.regressionComponentHealthProvider = RegressionLaunchComponentGate.evaluate
        self.rendererLaunchValidator = RendererLaunchGate.validate
        self.launchObservabilityInterval = Self.defaultLaunchObservabilityInterval
    }

    init(
        processRunner: any ProcessRunning,
        processLauncher: any ProcessLaunching,
        inspector: any ProcessInspecting,
        logDirectoryURL: URL,
        custodyInterlock: (any PhysicalLibraryCustodyInterlocking)? = nil,
        regressionComponentHealthProvider: @escaping @Sendable (
            RegressionInstallation
        ) -> ComponentHealthReport,
        rendererLaunchValidator: @escaping @Sendable (
            RegressionInstallation,
            String?
        ) throws -> Void = RendererLaunchGate.validate,
        launchObservabilityInterval: Duration = BackendCoordinator
            .defaultLaunchObservabilityInterval
    ) {
        self.processRunner = processRunner
        self.processLauncher = processLauncher
        self.inspector = inspector
        self.logDirectoryURL = logDirectoryURL
        self.custodyInterlock = custodyInterlock
        self.regressionComponentHealthProvider = regressionComponentHealthProvider
        self.rendererLaunchValidator = rendererLaunchValidator
        self.launchObservabilityInterval = launchObservabilityInterval
    }

    public func runningState() async -> RunningBackendState {
        await inspector.runningBackends()
    }

    /// Abre solo Steam. Esta superficie no acepta App ID ni autoridad de spawn de juego: usarla
    /// para un juego impediría registrar el envelope durable obligatorio.
    public func launchSteamGeneral(
        backend: BackendKind,
        installations: InstallationSnapshot,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease? = nil
    ) async throws -> BackendLaunch {
        try await launchSteam(
            backend: backend,
            installations: installations,
            normalizedAppID: nil,
            custodyValidationLease: custodyValidationLease,
            gameLaunchAuthority: nil
        )
    }

    /// Lanza un App ID únicamente con una capacidad opaca nacida de un envelope autorizado.
    /// No hay sobrecarga pública que admita un `String` App ID y un callback opcional.
    package func launchGame(
        backend: BackendKind,
        installations: InstallationSnapshot,
        spawnAuthority: CompatibilityRepository.GameLaunchSpawnAuthority,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease? = nil
    ) async throws -> BackendLaunch {
        let normalizedAppID = try spawnAuthority.appIDForBoundGameLaunch()
        return try await launchSteam(
            backend: backend,
            installations: installations,
            normalizedAppID: normalizedAppID,
            custodyValidationLease: custodyValidationLease,
            gameLaunchAuthority: spawnAuthority
        )
    }

    private func launchSteam(
        backend: BackendKind,
        installations: InstallationSnapshot,
        normalizedAppID: String?,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease?,
        gameLaunchAuthority: CompatibilityRepository.GameLaunchSpawnAuthority?
    ) async throws -> BackendLaunch {
        try requireRegressionBackend(backend)
        if normalizedAppID == nil, gameLaunchAuthority != nil {
            throw RegressionCoreError.invalidEvidence("Steam general no admite autoridad de juego")
        }
        if backend == .regression {
            try validateRegressionLaunchComponents(
                installations.regression,
                appID: normalizedAppID
            )
            try CompiledRepairActivationStore.validateLaunchSafety(
                in: installations.regression.bottleURL
            )
        }
        let custodyPermit = try await acquireOperationalPermit(
            backend,
            custodyValidationLease: custodyValidationLease
        )
        defer { custodyPermit?.release() }
        let bootstrapProcessLaunchAuthority = ProcessLaunchAuthority(
            regressionInstallation: backend == .regression ? installations.regression : nil,
            custodyPermit: custodyPermit,
            normalizedAppID: nil,
            regressionComponentHealthProvider: regressionComponentHealthProvider,
            rendererLaunchValidator: rendererLaunchValidator,
            gameLaunchAuthority: nil
        )
        let gameProcessLaunchAuthority: ProcessLaunchAuthority?
        if let normalizedAppID, let gameLaunchAuthority {
            gameProcessLaunchAuthority = ProcessLaunchAuthority(
                regressionInstallation: backend == .regression ? installations.regression : nil,
                custodyPermit: custodyPermit,
                normalizedAppID: normalizedAppID,
                regressionComponentHealthProvider: regressionComponentHealthProvider,
                rendererLaunchValidator: rendererLaunchValidator,
                gameLaunchAuthority: gameLaunchAuthority
            )
        } else {
            gameProcessLaunchAuthority = nil
        }
        let running = await inspector.runningBackends()
        if running.hasConflict {
            throw RegressionCoreError.backendConflict
        }
        if let active = running.activeBackend, active != backend {
            throw RegressionCoreError.backendAlreadyRunning(active)
        }
        if normalizedAppID == nil, running.activeBackend == backend {
            throw RegressionCoreError.backendAlreadyRunning(backend)
        }
        let launchIntent = try await custodyInterlock?.registerPhysicalLibraryLaunchIntent(
            backend: backend
        )
        var launchMayHaveOccurred = false
        defer {
            if let launchIntent, !launchMayHaveOccurred {
                Task { try? await self.custodyInterlock?.resolvePhysicalLibraryLaunchIntent(launchIntent) }
            }
        }

        let steamArguments: [String]
        if let normalized = normalizedAppID {
            let needsBootstrap = backend == .regression
                && running.activeBackend == nil
                && GameRuntimeProfileCatalog.profile(
                    for: normalized,
                    backend: backend
                )?.requiresActiveSteamClient == true
            if needsBootstrap { launchMayHaveOccurred = true }
            try await ensureSteamClientIsActiveIfRequired(
                backend: backend,
                appID: normalized,
                running: running,
                installations: installations,
                launchIntent: launchIntent,
                processLaunchAuthority: bootstrapProcessLaunchAuthority
            )
            steamArguments = ["-applaunch", normalized]
        } else {
            steamArguments = []
        }

        let command = try command(
            backend: backend,
            installations: installations,
            steamArguments: steamArguments
        )
        guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            throw RegressionCoreError.launcherMissing(command.executableURL)
        }
        if backend == .regression {
            try validateRegressionLaunchComponents(
                installations.regression,
                appID: normalizedAppID
            )
            try CompiledRepairActivationStore.validateLaunchSafety(
                in: installations.regression.bottleURL
            )
        }
        launchMayHaveOccurred = true
        let launch = try await processLauncher.launch(
            backend: backend,
            executableURL: command.executableURL,
            arguments: command.arguments,
            logDirectoryURL: logDirectoryURL,
            authority: gameProcessLaunchAuthority ?? bootstrapProcessLaunchAuthority
        )
        if let launchIntent {
            try await custodyInterlock?.attachPhysicalLibraryLaunch(launch, to: launchIntent)
            if try await waitUntilLaunchIsObservable(launch) {
                try await custodyInterlock?.resolvePhysicalLibraryLaunchIntent(launchIntent)
            }
        }
        return launch
    }

    private func ensureSteamClientIsActiveIfRequired(
        backend: BackendKind,
        appID: String,
        running: RunningBackendState,
        installations: InstallationSnapshot,
        launchIntent: PhysicalLibraryCustodyLaunchIntent?,
        processLaunchAuthority: ProcessLaunchAuthority
    ) async throws {
        guard backend == .regression,
              running.activeBackend == nil,
              GameRuntimeProfileCatalog.profile(
                  for: appID,
                  backend: backend
              )?.requiresActiveSteamClient == true else {
            return
        }

        let readinessLogURL = installations.regression.bottleURL
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/logs/connection_log.txt")
        let readinessOffset = Self.fileSize(at: readinessLogURL)
        let steamCommand = try command(
            backend: backend,
            installations: installations,
            steamArguments: []
        )
        guard FileManager.default.isExecutableFile(atPath: steamCommand.executableURL.path) else {
            throw RegressionCoreError.launcherMissing(steamCommand.executableURL)
        }
        // El permiso de custodia de este lanzamiento ya está tomado y se mantiene durante todo
        // el ámbito, así que aquí NO se vuelve a pedir: pedirlo otra vez se bloqueaba a sí mismo.
        // La intención de lanzamiento ya está registrada en este punto y el interlock bloquea
        // mientras exista, de modo que un juego que exige cliente activo nunca llegaba a
        // arrancar Steam con la biblioteca cerrada, y cada reintento renovaba la intención.
        try validateRegressionLaunchComponents(
            installations.regression,
            appID: appID
        )
        try CompiledRepairActivationStore.validateLaunchSafety(
            in: installations.regression.bottleURL
        )
        let bootstrapLaunch = try await processLauncher.launch(
            backend: backend,
            executableURL: steamCommand.executableURL,
            arguments: steamCommand.arguments,
            logDirectoryURL: logDirectoryURL,
            authority: processLaunchAuthority
        )
        if let launchIntent {
            try await custodyInterlock?.attachPhysicalLibraryLaunch(bootstrapLaunch, to: launchIntent)
        }

        var observedSteamProcess = false
        for _ in 0..<180 {
            let current = await inspector.runningBackends()
            if current.hasConflict {
                throw RegressionCoreError.backendConflict
            }
            if current.activeBackend == backend {
                observedSteamProcess = true
                if readinessOffset == nil || Self.steamClientBecameReady(
                    logURL: readinessLogURL,
                    afterOffset: readinessOffset ?? 0
                ) {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        if observedSteamProcess {
            throw RegressionCoreError.launchFailed(
                "Steam se inició, pero no completó su conexión antes de lanzar el App ID \(appID)"
            )
        }
        throw RegressionCoreError.launchFailed(
            "Steam no quedó disponible para la receta aislada del App ID \(appID)"
        )
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    private static func steamClientBecameReady(
        logURL: URL,
        afterOffset: UInt64
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return false
        }
        defer { try? handle.close() }

        do {
            let currentSize = try handle.seekToEnd()
            try handle.seek(toOffset: min(afterOffset, currentSize))
            let data = try handle.readToEnd() ?? Data()
            let appendedLog = String(decoding: data, as: UTF8.self)
            return appendedLog.contains(
                "RecvMsgClientLogOnResponse() : processing complete"
            )
        } catch {
            return false
        }
    }

    public func requestShutdown(
        backend: BackendKind,
        installations: InstallationSnapshot,
        timeoutSeconds: Double = 30,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease? = nil
    ) async throws {
        try requireRegressionBackend(backend)
        let custodyPermit = try await acquireOperationalPermit(
            backend,
            custodyValidationLease: custodyValidationLease
        )
        defer { custodyPermit?.release() }
        let command = try command(
            backend: backend,
            installations: installations,
            steamArguments: ["-shutdown"]
        )
        let result = try await processRunner.run(
            executableURL: command.executableURL,
            arguments: command.arguments,
            environment: nil
        )
        if result.exitCode != 0 {
            let detail = PrivacySanitizer.redactedLogExcerpt(
                result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
            throw RegressionCoreError.launchFailed(detail)
        }

        let attempts = max(1, Int(timeoutSeconds * 2))
        for _ in 0..<attempts {
            let running = await inspector.runningBackends()
            let stillRunning = backend == .crossOver ? running.crossOverIsRunning : running.regressionIsRunning
            if !stillRunning { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RegressionCoreError.shutdownTimedOut(backend)
    }

    public func switchBackend(
        from current: BackendKind?,
        to target: BackendKind,
        installations: InstallationSnapshot,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease? = nil
    ) async throws -> BackendLaunch {
        try requireRegressionBackend(target)
        if let current {
            try requireRegressionBackend(current)
        }
        try await validateOperationalSelection(
            target,
            custodyValidationLease: custodyValidationLease
        )
        if let current, current != target {
            try await requestShutdown(
                backend: current,
                installations: installations,
                custodyValidationLease: custodyValidationLease
            )
        }
        return try await launchSteamGeneral(
            backend: target,
            installations: installations,
            custodyValidationLease: custodyValidationLease
        )
    }

    /// Aplica la misma política de custodia a UI, CLI y lanzamientos internos. El único bypass
    /// posible es un lease opaco y vigente emitido por el gestor durante la validación física.
    public func validateOperationalSelection(
        _ backend: BackendKind,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease? = nil
    ) async throws {
        let permit = try await acquireOperationalPermit(
            backend,
            custodyValidationLease: custodyValidationLease
        )
        permit?.release()
    }

    private func acquireOperationalPermit(
        _ backend: BackendKind,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease?
    ) async throws -> PhysicalLibraryCustodyMutationPermit? {
        try requireRegressionBackend(backend)
        guard let custodyInterlock else { return nil }
        return try await custodyInterlock.acquirePhysicalLibraryCustodyMutationPermit(
            backend: backend,
            validationLease: custodyValidationLease
        )
    }

    private func validateRegressionLaunchComponents(
        _ installation: RegressionInstallation,
        appID: String?
    ) throws {
        try RegressionLaunchComponentGate.requireReady(
            regressionComponentHealthProvider(installation)
        )
        try rendererLaunchValidator(installation, appID)
    }

    /// Los diagnósticos de solo lectura siguen disponibles durante una transacción, pero jamás
    /// vuelven a presentar CrossOver como destino después del cutover físico.
    public func validateBackendAvailability(_ backend: BackendKind) async throws {
        guard backend == .crossOver else { return }
        if let custodyInterlock {
            _ = await custodyInterlock.currentPhysicalLibraryCustodyInterlock()
        }
        try requireRegressionBackend(backend)
    }

    private func requireRegressionBackend(_ backend: BackendKind) throws {
        guard backend == .regression else {
            throw RegressionCoreError.unsafeLibraryState(
                "CrossOver ya no es un backend operativo; usa Regression"
            )
        }
    }

    /// Espera a poder demostrar que el lanzamiento existe de verdad antes de resolver la
    /// intención de custodia.
    ///
    /// El muestreo tiene que cubrir un arranque en frío completo: el lanzador abre wine, wine
    /// levanta el servicio y solo después aparece `Steam.exe`, que es lo que el inspector sabe
    /// atribuir. Con una ventana de dos segundos ese arranque perdía siempre la carrera, la
    /// intención se quedaba en disco y la custodia permanecía bloqueada hasta matar Steam —con
    /// el agravante de que cada reintento renovaba la intención—. La ventana termina en cuanto
    /// hay evidencia, así que un arranque normal sigue resolviéndose en cuanto se ve el proceso.
    private static let launchObservabilitySamples = 40
    static let defaultLaunchObservabilityInterval = Duration.milliseconds(500)

    private func waitUntilLaunchIsObservable(_ launch: BackendLaunch) async throws -> Bool {
        for sample in 0..<Self.launchObservabilitySamples {
            let running = await inspector.runningBackends()
            if running.hasConflict {
                throw RegressionCoreError.backendConflict
            }
            let pids = launch.backend == .regression ? running.regressionPIDs : running.crossOverPIDs
            if pids.contains(launch.processID) || !pids.isEmpty { return true }
            guard sample < Self.launchObservabilitySamples - 1 else { break }
            try await Task.sleep(for: launchObservabilityInterval)
        }
        return false
    }

    private func command(
        backend: BackendKind,
        installations: InstallationSnapshot,
        steamArguments: [String]
    ) throws -> SteamCommand {
        switch backend {
        case .crossOver:
            try requireRegressionBackend(backend)
            throw RegressionCoreError.unsafeLibraryState(
                "CrossOver ya no es un backend operativo; usa Regression"
            )
        case .regression:
            guard installations.regression.health == .ready else {
                throw RegressionCoreError.launcherMissing(installations.regression.engineLauncherURL)
            }
            return BackendCommandFactory.regression(
                installation: installations.regression,
                steamArguments: steamArguments
            )
        }
    }
}
