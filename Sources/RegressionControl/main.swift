import Darwin
import Foundation
import RegressionCore

@main
enum RegressionControl {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "status"
        let runner = ProcessRunner()
        let launcher = ProcessLauncher()
        let inspector = ProcessInspector(runner: runner)
        let discovery = InstallationDiscovery(runner: runner)
        let applicationURL = regressionApplicationURL(
            environment: ProcessInfo.processInfo.environment,
            executablePath: CommandLine.arguments[0],
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )
        let installations = await discovery.discover(regressionApplicationURL: applicationURL)
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Regression", isDirectory: true)
        let coordinator = BackendCoordinator(
            processRunner: runner,
            processLauncher: launcher,
            inspector: inspector,
            logDirectoryURL: support.appendingPathComponent("Logs/Launcher", isDirectory: true)
        )
        let databaseURL = ProcessInfo.processInfo.environment["REGRESSION_COMPATIBILITY_DATABASE_PATH"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("Compatibility/compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)

        switch command {
        case "status":
            let running = await coordinator.runningState()
            print("CrossOver:", installations.crossOver?.version ?? "no disponible")
            print("Botella:", installations.crossOver?.bottleName ?? "no encontrada")
            print("Steam CrossOver:", running.crossOverIsRunning ? "activo" : "cerrado")
            print("Steam Regression:", running.regressionIsRunning ? "activo" : "cerrado")
            if let crossOver = installations.crossOver {
                let manager = SharedSteamLibraryManager(
                    backupRootURL: support.appendingPathComponent("Backups/SharedLibrary", isDirectory: true)
                )
                let assessment = await manager.assess(
                    regression: installations.regression,
                    crossOver: crossOver
                )
                if case .ready = assessment.status {
                    print("Biblioteca compartida: lista")
                } else if case let .blocked(reason) = assessment.status {
                    print("Biblioteca compartida: bloqueada —", reason)
                } else {
                    print("Biblioteca compartida: pendiente")
                }
            }

        case "share-library":
            guard let crossOver = installations.crossOver else {
                throw RegressionCoreError.crossOverNotInstalled
            }
            var running = await coordinator.runningState()
            let previouslyActive = running.activeBackend
            guard !running.hasConflict else { throw RegressionCoreError.backendConflict }

            if let active = previouslyActive {
                guard arguments.contains("--shutdown") else {
                    throw RegressionCoreError.unsafeLibraryState(
                        "Steam está activo; repite con --shutdown para cerrarlo limpiamente"
                    )
                }
                print("Cerrando Steam con", active.displayName + "…")
                try await coordinator.requestShutdown(
                    backend: active,
                    installations: installations
                )
                running = await coordinator.runningState()
            }

            let manager = SharedSteamLibraryManager(
                backupRootURL: support.appendingPathComponent("Backups/SharedLibrary", isDirectory: true)
            )
            let assessment = await manager.assess(
                regression: installations.regression,
                crossOver: crossOver
            )
            if !assessment.onlyInRegression.isEmpty {
                throw RegressionCoreError.unsafeLibraryState(
                    "Juegos exclusivos de Regression: \(assessment.onlyInRegression.joined(separator: ", "))"
                )
            }
            let link = try await manager.configure(
                regression: installations.regression,
                crossOver: crossOver,
                runningState: running
            )
            print("Biblioteca compartida:", PrivacySanitizer.normalizedPath(link.path))

            if arguments.contains("--restart") {
                let restartBackend = previouslyActive ?? .crossOver
                print("Reabriendo Steam con", restartBackend.displayName + "…")
                _ = try await coordinator.launchSteam(
                    backend: restartBackend,
                    installations: installations
                )
            }

        case "launch":
            guard let rawAppID = arguments.dropFirst().first,
                  let appID = SteamAppID.normalized(rawAppID) else {
                throw RegressionCoreError.launchFailed("Falta un Steam App ID válido")
            }
            let running = await coordinator.runningState()
            let requestedBackend: BackendKind?
            if let index = arguments.firstIndex(of: "--backend"), arguments.indices.contains(index + 1) {
                requestedBackend = BackendKind(rawValue: arguments[index + 1])
                guard requestedBackend != nil else {
                    throw RegressionCoreError.launchFailed("Usa --backend crossOver o --backend regression")
                }
            } else {
                requestedBackend = nil
            }
            let backend = requestedBackend ?? running.activeBackend ?? .crossOver
            if let active = running.activeBackend, active != backend {
                _ = try await coordinator.switchBackend(
                    from: active,
                    to: backend,
                    installations: installations
                )
            }
            _ = try await coordinator.launchSteam(
                backend: backend,
                installations: installations,
                appID: appID
            )
            print("Solicitud enviada para App ID", appID, "con", backend.displayName)

        case "switch":
            guard let name = arguments.dropFirst().first,
                  let target = BackendKind(rawValue: name) else {
                throw RegressionCoreError.launchFailed("Usa crossOver o regression")
            }
            let running = await coordinator.runningState()
            _ = try await coordinator.switchBackend(
                from: running.activeBackend,
                to: target,
                installations: installations
            )
            print("Cambio solicitado a", target.displayName)

        case "runs":
            try await repository.prepare()
            let runs = try await repository.recentRuns(limit: 50)
            for run in runs {
                let verification = run.verification?.verdict.displayName ?? "sin verificar"
                print(
                    run.id.uuidString,
                    run.appID,
                    run.gameName,
                    run.backend.displayName,
                    run.result.rawValue,
                    verification
                )
            }

        case "profiles":
            try await repository.prepare()
            let profiles = try await repository.compatibilityProfiles()
            for profile in profiles {
                print(
                    profile.appID,
                    profile.gameName,
                    profile.backend.displayName,
                    "perfectas=\(profile.perfectRuns)",
                    "con-incidencias=\(profile.playableRuns)",
                    "fallidas=\(profile.failedRuns)",
                    "sin-verificar=\(profile.unverifiedRuns)",
                    "config=\(profile.configurationFingerprint)"
                )
            }

        case "engines":
            try await repository.prepare()
            for engine in try await repository.engineProfiles() {
                print(
                    engine.backend.displayName,
                    engine.providerVersion,
                    "juegos=\(engine.gameCount)",
                    "perfectas=\(engine.perfectRuns)",
                    "con-incidencias=\(engine.playableRuns)",
                    "fallidas=\(engine.failedRuns)",
                    "sin-verificar=\(engine.unverifiedRuns)",
                    "motor=\(engine.fingerprint)"
                )
            }

        case "certifications":
            try await repository.prepare()
            for certification in try await repository.certifications() {
                print(
                    certification.appID,
                    certification.gameName,
                    certification.backend.displayName,
                    certification.verifiedAt,
                    "origen=\(certification.origin.rawValue)",
                    "config=\(certification.configurationFingerprint ?? "histórica")",
                    "motor=\(certification.engineFingerprint ?? "histórico")",
                    certification.evidence
                )
            }

        case "database":
            try await repository.prepare()
            let health = try await repository.databaseHealth()
            print("Esquema:", health.schemaVersion)
            print("Integridad:", health.integrity)
            print("Referencias huérfanas:", health.foreignKeyViolations)
            print("Juegos:", health.gameCount)
            print("Ejecuciones:", health.runCount)
            print("Verificaciones:", health.verifiedRunCount)
            print("Observaciones:", health.observationCount)
            print("Certificaciones activas:", health.certificationCount)
            print("Fichas públicas:", health.externalRecordCount)
            print("Motores normalizados:", health.engineSnapshotCount)
            if let backup = await repository.lastMigrationBackup() {
                print("Backup de migración:", PrivacySanitizer.normalizedPath(backup.path))
            }

        case "catalog":
            try await repository.prepare()
            let entries = try await repository.externalEntries()
            if entries.isEmpty {
                print("Todavía no hay referencias públicas almacenadas.")
            }
            for entry in entries {
                let rating = entry.record?.macOSRating.value.map(String.init) ?? "sin valorar"
                let version = entry.record?.macOSRating.testedCrossOverVersion ?? "n/a"
                print(
                    entry.appID,
                    entry.gameName,
                    entry.sourceID,
                    entry.status.rawValue,
                    "mac=\(rating)",
                    "crossover=\(version)",
                    entry.record?.canonicalURL.absoluteString ?? "sin-ficha"
                )
            }

        case "comparisons":
            try await repository.prepare()
            for comparison in try await repository.compatibilityComparisons() {
                print(
                    comparison.appID,
                    comparison.gameName,
                    "local=\(comparison.localState.rawValue)",
                    "public=\(comparison.publicMacRating.map(String.init) ?? "n/a")",
                    "alineación=\(comparison.alignment.rawValue)"
                )
            }

        case "catalog-sync":
            guard let rawAppID = arguments.dropFirst().first,
                  let appID = SteamAppID.normalized(rawAppID) else {
                throw RegressionCoreError.launchFailed("Usa catalog-sync APP_ID")
            }
            try await repository.prepare()
            let allGames = (installations.crossOver.map {
                SteamManifestParser.games(in: $0.steamRootURL, backend: .crossOver)
            } ?? []) + SteamManifestParser.games(
                in: installations.regression.steamRootURL,
                backend: .regression
            )
            guard let game = allGames.first(where: { $0.appID == appID }) else {
                throw RegressionCoreError.launchFailed("El juego no está instalado en la biblioteca detectada")
            }
            print("Consultando CodeWeavers con su cadencia pública…")
            let synchronizer = ExternalCatalogSynchronizer(repository: repository)
            let outcome = await synchronizer.refresh(
                game: game,
                force: arguments.contains("--force")
            )
            switch outcome {
            case .freshCache: print("La referencia almacenada sigue vigente.")
            case let .updated(entry):
                print("Ficha actualizada:", entry.record?.canonicalURL.absoluteString ?? entry.status.rawValue)
            case .noMatch: print("No se encontró una coincidencia exacta.")
            case let .failed(detail): throw RegressionCoreError.externalCatalog(detail)
            case .cancelled: throw CancellationError()
            }

        case "verify":
            guard arguments.count >= 3,
                  let runID = UUID(uuidString: arguments[1]),
                  let verdict = verificationVerdict(arguments[2]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa verify RUN_ID perfect|playable|failed [--note TEXTO]"
                )
            }
            let note: String
            if let index = arguments.firstIndex(of: "--note"), arguments.indices.contains(index + 1) {
                note = arguments[index + 1]
            } else {
                note = "Verificación visual local"
            }
            let dimensions: (
                VerificationDimension,
                VerificationDimension,
                VerificationDimension,
                VerificationDimension
            )
            switch verdict {
            case .perfect: dimensions = (.passed, .passed, .passed, .passed)
            case .playableWithIssues:
                dimensions = (.notTested, .notTested, .notTested, .notTested)
            case .failed: dimensions = (.failed, .notTested, .notTested, .notTested)
            case .invalidated: dimensions = (.notTested, .notTested, .notTested, .notTested)
            }
            try await repository.verifyRun(RunVerification(
                runID: runID,
                verdict: verdict,
                rendering: dimensions.0,
                inputPrecision: dimensions.1,
                graphicsSettings: dimensions.2,
                gameplay: dimensions.3,
                source: .visualInspection,
                notes: note
            ))
            print("Verificación guardada:", verdict.displayName)

        case "observe":
            guard arguments.count >= 3,
                  let appID = SteamAppID.normalized(arguments[1]),
                  let verdict = verificationVerdict(arguments[2]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa observe APP_ID perfect|playable|failed --backend crossOver|regression --name NOMBRE [--note TEXTO]"
                )
            }
            let backendName = option("--backend", in: arguments) ?? "crossOver"
            guard let backend = BackendKind(rawValue: backendName) else {
                throw RegressionCoreError.launchFailed("Usa --backend crossOver o --backend regression")
            }
            let gameName = option("--name", in: arguments) ?? "Steam App \(appID)"
            let note = option("--note", in: arguments) ?? "Observación de compatibilidad importada"
            let bottleURL: URL
            let steamRootURL: URL
            let providerVersion: String
            switch backend {
            case .crossOver:
                guard let crossOver = installations.crossOver else {
                    throw RegressionCoreError.crossOverNotInstalled
                }
                bottleURL = crossOver.bottleURL
                steamRootURL = crossOver.steamRootURL
                providerVersion = crossOver.version
            case .regression:
                bottleURL = installations.regression.bottleURL
                steamRootURL = installations.regression.steamRootURL
                providerVersion = "Regression"
            }
            let game = SteamManifestParser.games(in: steamRootURL, backend: backend)
                .first { $0.appID == appID }
            var configuration = ConfigurationCollector.snapshot(
                bottleURL: bottleURL,
                backend: backend,
                providerVersion: providerVersion,
                game: game,
                steamRootURL: steamRootURL
            )
            if backend == .crossOver, let graphics = installations.crossOver?.defaultGraphicsBackend {
                configuration["graphics.crossover.default_probe"] = graphics
            }
            let dimensions: (
                VerificationDimension,
                VerificationDimension,
                VerificationDimension,
                VerificationDimension
            )
            switch verdict {
            case .perfect: dimensions = (.passed, .passed, .passed, .passed)
            case .playableWithIssues:
                dimensions = (.notTested, .notTested, .notTested, .notTested)
            case .failed: dimensions = (.failed, .notTested, .notTested, .notTested)
            case .invalidated: dimensions = (.notTested, .notTested, .notTested, .notTested)
            }
            try await repository.recordObservation(CompatibilityObservation(
                appID: appID,
                gameName: gameName,
                backend: backend,
                providerVersion: providerVersion,
                verdict: verdict,
                rendering: dimensions.0,
                inputPrecision: dimensions.1,
                graphicsSettings: dimensions.2,
                gameplay: dimensions.3,
                configurationFingerprint: ConfigurationCollector.fingerprint(configuration),
                configuration: configuration,
                source: .imported,
                notes: note
            ))
            print("Observación guardada para", gameName, "con", backend.displayName)

        case "observations":
            try await repository.prepare()
            for observation in try await repository.observations() {
                print(
                    observation.id.uuidString,
                    observation.appID,
                    observation.gameName,
                    observation.backend.displayName,
                    observation.verdict.displayName,
                    observation.notes
                )
            }

        case "export":
            guard let path = arguments.dropFirst().first else {
                throw RegressionCoreError.launchFailed("Falta la ruta de exportación")
            }
            try await repository.prepare()
            try await repository.exportJSON(to: URL(fileURLWithPath: path))
            print("Exportación guardada en", PrivacySanitizer.normalizedPath(path))

        default:
            print("Uso: regressionctl [status | share-library --shutdown [--restart] | launch APP_ID [--backend crossOver|regression] | switch crossOver|regression | runs | profiles | engines | certifications | database | catalog | catalog-sync APP_ID [--force] | comparisons | verify RUN_ID perfect|playable|failed [--note TEXTO] | observe APP_ID perfect|playable|failed --backend MOTOR --name NOMBRE [--note TEXTO] | observations | export RUTA]")
            exit(64)
        }
    }

    private static func verificationVerdict(_ value: String) -> VerificationVerdict? {
        switch value.lowercased() {
        case "perfect": .perfect
        case "playable": .playableWithIssues
        case "failed": .failed
        default: nil
        }
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func regressionApplicationURL(
        environment: [String: String],
        executablePath: String,
        currentDirectoryURL: URL
    ) -> URL {
        if let override = environment["REGRESSION_APP_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }

        let executableURL: URL
        if executablePath.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: executablePath)
        } else {
            executableURL = currentDirectoryURL.appendingPathComponent(executablePath)
        }
        let bundledCandidate = executableURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if bundledCandidate.pathExtension == "app",
           FileManager.default.fileExists(
               atPath: bundledCandidate.appendingPathComponent("Contents/Info.plist").path
           ) {
            return bundledCandidate
        }

        return currentDirectoryURL.appendingPathComponent("Regression.app", isDirectory: true)
    }
}
