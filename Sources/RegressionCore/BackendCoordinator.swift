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
    private static let crossOverSteamPath = #"C:\Program Files (x86)\Steam\steam.exe"#

    public static func crossOver(
        installation: CrossOverInstallation,
        steamArguments: [String]
    ) -> SteamCommand {
        SteamCommand(
            executableURL: installation.wineCLIURL,
            arguments: [
                "--bottle", installation.bottleName,
                "--cx-app", crossOverSteamPath
            ] + steamArguments
        )
    }

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

    public static func authorizeFinalization(arguments: [String]) throws -> String {
        guard arguments.contains("--validated"),
              let evidenceIndex = arguments.firstIndex(of: "--evidence"),
              arguments.indices.contains(evidenceIndex + 1) else {
            throw RegressionCoreError.unsafeLibraryState(
                "Finalizar exige --validated --evidence REFERENCIA"
            )
        }
        let evidence = arguments[evidenceIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty, evidence.count <= 2_048 else {
            throw RegressionCoreError.unsafeLibraryState(
                "La referencia de evidencia no es válida"
            )
        }
        return evidence
    }

    public static func authorizeRollback(arguments: [String]) throws {
        guard arguments.contains("--confirm-rollback") else {
            throw RegressionCoreError.unsafeLibraryState(
                "Confirma la restauración con --confirm-rollback"
            )
        }
    }

    public static func validationAppID(arguments: [String]) throws -> String? {
        guard arguments.count <= 2 else {
            throw RegressionCoreError.launchFailed("Usa validate-library [APP_ID]")
        }
        guard let rawValue = arguments.dropFirst().first else { return nil }
        guard let appID = SteamAppID.normalized(rawValue) else {
            throw RegressionCoreError.launchFailed("Usa validate-library [APP_ID]")
        }
        return appID
    }
}

public actor BackendCoordinator {
    private let processRunner: any ProcessRunning
    private let processLauncher: any ProcessLaunching
    private let inspector: any ProcessInspecting
    private let logDirectoryURL: URL
    private let custodyInterlock: (any PhysicalLibraryCustodyInterlocking)?

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
    }

    public func runningState() async -> RunningBackendState {
        await inspector.runningBackends()
    }

    public func launchSteam(
        backend: BackendKind,
        installations: InstallationSnapshot,
        appID: String? = nil,
        custodyValidationLease: PhysicalLibraryCustodyValidationLease? = nil
    ) async throws -> BackendLaunch {
        let custodyPermit = try await acquireOperationalPermit(
            backend,
            custodyValidationLease: custodyValidationLease
        )
        defer { custodyPermit?.release() }
        let running = await inspector.runningBackends()
        if running.hasConflict {
            throw RegressionCoreError.backendConflict
        }
        if let active = running.activeBackend, active != backend {
            throw RegressionCoreError.backendAlreadyRunning(active)
        }
        if appID == nil, running.activeBackend == backend {
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
        if let appID {
            guard let normalized = SteamAppID.normalized(appID) else {
                throw RegressionCoreError.launchFailed("El Steam App ID no es válido")
            }
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
                custodyValidationLease: custodyValidationLease,
                launchIntent: launchIntent
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
        launchMayHaveOccurred = true
        let launch = try await processLauncher.launch(
            backend: backend,
            executableURL: command.executableURL,
            arguments: command.arguments,
            logDirectoryURL: logDirectoryURL
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
        custodyValidationLease: PhysicalLibraryCustodyValidationLease?,
        launchIntent: PhysicalLibraryCustodyLaunchIntent?
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
        try await validateOperationalSelection(
            backend,
            custodyValidationLease: custodyValidationLease
        )
        let bootstrapLaunch = try await processLauncher.launch(
            backend: backend,
            executableURL: steamCommand.executableURL,
            arguments: steamCommand.arguments,
            logDirectoryURL: logDirectoryURL
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
        return try await launchSteam(
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
        guard let custodyInterlock else { return nil }
        try await validateBackendAvailability(backend)
        return try await custodyInterlock.acquirePhysicalLibraryCustodyMutationPermit(
            backend: backend,
            validationLease: custodyValidationLease
        )
    }

    /// Los diagnósticos de solo lectura siguen disponibles durante una transacción, pero jamás
    /// vuelven a presentar CrossOver como destino después del cutover físico.
    public func validateBackendAvailability(_ backend: BackendKind) async throws {
        guard backend == .crossOver else { return }
        if let custodyInterlock {
            _ = await custodyInterlock.currentPhysicalLibraryCustodyInterlock()
        }
        throw RegressionCoreError.unsafeLibraryState(
            "CrossOver ya no es un backend operativo; usa Regression"
        )
    }

    private func waitUntilLaunchIsObservable(_ launch: BackendLaunch) async throws -> Bool {
        for sample in 0..<5 {
            let running = await inspector.runningBackends()
            if running.hasConflict {
                throw RegressionCoreError.backendConflict
            }
            let pids = launch.backend == .regression ? running.regressionPIDs : running.crossOverPIDs
            if pids.contains(launch.processID) || !pids.isEmpty { return true }
            guard sample < 4 else { break }
            try await Task.sleep(for: .milliseconds(500))
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
            guard let crossOver = installations.crossOver else {
                switch installations.crossOverIssue?.code {
                case .crossOverNotInstalled:
                    throw RegressionCoreError.crossOverNotInstalled
                case .steamBottleNotFound:
                    throw RegressionCoreError.bottleNotFound
                case .steamNotInstalled:
                    throw RegressionCoreError.steamNotInstalled
                case .bottleDamaged:
                    throw RegressionCoreError.bottleDamaged(installations.crossOverIssue?.message ?? "Estado desconocido")
                case nil:
                    throw RegressionCoreError.crossOverNotInstalled
                }
            }
            if crossOver.health == .damaged {
                throw RegressionCoreError.bottleDamaged(crossOver.healthDetail)
            }
            return BackendCommandFactory.crossOver(
                installation: crossOver,
                steamArguments: steamArguments
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
