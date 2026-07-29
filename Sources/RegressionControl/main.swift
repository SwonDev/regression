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
            var running = await coordinator.runningState()
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
                try await coordinator.requestShutdown(
                    backend: active,
                    installations: installations
                )
                running = await coordinator.runningState()
            }
            let report = try await preflightReport(
                backend: backend,
                appID: appID,
                installations: installations,
                runningState: running,
                repository: repository,
                runner: runner,
                supportURL: support
            )
            printPreflight(report)
            guard report.status != .blocked else {
                throw RegressionCoreError.testEnvironmentBlocked(report.blockingSummary)
            }
            _ = try await coordinator.launchSteam(
                backend: backend,
                installations: installations,
                appID: appID
            )
            print("Solicitud enviada para App ID", appID, "con", backend.displayName)

        case "preflight":
            let rawAppID = arguments.dropFirst().first.flatMap { value in
                value.hasPrefix("--") ? nil : value
            }
            let appID: String?
            if let rawAppID {
                guard let normalized = SteamAppID.normalized(rawAppID) else {
                    throw RegressionCoreError.launchFailed("El Steam App ID no es válido")
                }
                appID = normalized
            } else {
                appID = nil
            }
            let running = await coordinator.runningState()
            let backendName = option("--backend", in: arguments)
            let backend: BackendKind
            if let backendName {
                guard let parsed = BackendKind(rawValue: backendName) else {
                    throw RegressionCoreError.launchFailed(
                        "Usa --backend crossOver o --backend regression"
                    )
                }
                backend = parsed
            } else {
                backend = running.activeBackend ?? .crossOver
            }
            let report = try await preflightReport(
                backend: backend,
                appID: appID,
                installations: installations,
                runningState: running,
                repository: repository,
                runner: runner,
                supportURL: support
            )
            printPreflight(report)
            if report.status == .blocked {
                throw RegressionCoreError.testEnvironmentBlocked(report.blockingSummary)
            }

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

        case "processes":
            try await repository.prepare()
            let requestedRunID: UUID?
            if let rawRunID = arguments.dropFirst().first {
                guard let parsed = UUID(uuidString: rawRunID) else {
                    throw RegressionCoreError.launchFailed("Usa processes [RUN_ID]")
                }
                requestedRunID = parsed
            } else {
                requestedRunID = nil
            }
            let processes = try await repository.runProcesses(
                runID: requestedRunID,
                limit: requestedRunID == nil ? 1_000 : 10_000
            )
            for process in processes {
                let lifecycle: String
                if let exitCode = process.exitCode {
                    lifecycle = "exit=\(exitCode)"
                } else if process.endedAt != nil {
                    lifecycle = "finalizado-sin-código"
                } else {
                    lifecycle = "activo"
                }
                print(
                    process.runID.uuidString,
                    "pid=\(process.processID)",
                    process.isRepresentative ? "representativo" : "secundario",
                    lifecycle,
                    process.executable
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

        case "reconcile-profile":
            guard arguments.count >= 2,
                  let runID = UUID(uuidString: arguments[1]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa reconcile-profile RUN_ID"
                )
            }
            try await repository.prepare()
            let reconciled = try await repository.reconcileCompiledRuntimeProfile(runID: runID)
            print("Perfil compilado reconciliado:", runID.uuidString)
            print("Configuración:", reconciled.configurationFingerprint)
            print("Motor:", reconciled.engineFingerprint)

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

        case "technologies":
            try await repository.prepare()
            for technology in try await repository.runtimeTechnologies() {
                print(
                    technology.id,
                    technology.displayName,
                    "estable=\(technology.stableVersion ?? "sin baseline")",
                    "observada=\(technology.latestKnownVersion ?? "sin revisar")",
                    "política=\(technology.updatePolicy.rawValue)",
                    technology.officialURL.absoluteString
                )
            }

        case "candidates":
            try await repository.prepare()
            for candidate in try await repository.runtimeCandidates() {
                print(
                    candidate.id.uuidString,
                    candidate.technologyID,
                    "app=\(candidate.appID ?? "global")",
                    "versión=\(candidate.targetVersion)",
                    "estado=\(candidate.state.rawValue)",
                    "aislado=\(candidate.isIsolated)"
                )
            }

        case "optimization":
            try await repository.prepare()
            for assessment in try await repository.optimizationAssessments() {
                let averageFPS = assessment.averageFPS.map { String($0) } ?? "n/a"
                let onePercentLow = assessment.onePercentLowFPS.map { String($0) } ?? "n/a"
                let frameTimeP95 = assessment.frameTimeP95Milliseconds.map { String($0) } ?? "n/a"
                print(
                    assessment.appID,
                    assessment.backend.displayName,
                    assessment.state.rawValue,
                    "fps=\(averageFPS)",
                    "1%=\(onePercentLow)",
                    "p95=\(frameTimeP95)",
                    "motor=\(assessment.engineFingerprint)"
                )
            }

        case "requirements":
            try await repository.prepare()
            for requirement in try await repository.runtimeRequirements() {
                print(
                    requirement.appID,
                    requirement.kind.rawValue,
                    requirement.identifier,
                    requirement.versionConstraint ?? "sin restricción",
                    requirement.source.rawValue
                )
            }

        case "repair-receipts":
            try await repository.prepare()
            for receipt in try await repository.repairReceipts() {
                print(
                    receipt.appID,
                    receipt.backend.displayName,
                    "receta=\(receipt.recipeID)@\(receipt.recipeVersion)",
                    "resultado=\(receipt.result.rawValue)",
                    "rollback=\(receipt.rollbackReference)"
                )
            }

        case "research":
            try await repository.prepare()
            let cases = try await repository.researchCases()
            if cases.isEmpty {
                print("No hay expedientes de I+D abiertos ni históricos.")
            }
            for researchCase in cases {
                let experiments = try await repository.researchExperiments(
                    caseID: researchCase.id
                )
                print(
                    researchCase.id.uuidString,
                    researchCase.appID,
                    researchCase.gameName,
                    "estado=\(researchCase.state.rawValue)",
                    "pruebas=\(experiments.count)",
                    researchCase.symptom
                )
            }

        case "research-protocol":
            print("Protocolo de I+D: revisión", CompatibilityResearchProtocol.revision)
            print("Puertas obligatorias:")
            for gate in CompatibilityResearchProtocol.mandatoryGates {
                print("-", gate.rawValue)
            }
            print("Evidencias obligatorias:")
            for artifact in CompatibilityResearchProtocol.mandatoryArtifacts {
                print("-", artifact.rawValue)
            }
            print(
                "El cierre exige una ejecución perfecta exacta de Regression, aislamiento, rollback y huellas distintas."
            )

        case "research-open":
            guard arguments.count >= 2,
                  let appID = SteamAppID.normalized(arguments[1]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-open APP_ID --symptom TEXTO --expected TEXTO [--name NOMBRE]"
                )
            }
            guard let symptom = option("--symptom", in: arguments),
                  let expected = option("--expected", in: arguments) else {
                throw RegressionCoreError.launchFailed(
                    "Faltan --symptom y --expected con criterios concretos"
                )
            }
            let installedGames = (installations.crossOver.map {
                SteamManifestParser.games(in: $0.steamRootURL, backend: .crossOver)
            } ?? []) + SteamManifestParser.games(
                in: installations.regression.steamRootURL,
                backend: .regression
            )
            let name = option("--name", in: arguments)
                ?? installedGames.first(where: { $0.appID == appID })?.name
                ?? SteamGameName.placeholder(for: appID)
            let researchCase = CompatibilityResearchCase(
                appID: appID,
                gameName: name,
                symptom: symptom,
                expectedBehavior: expected
            )
            try await repository.registerResearchCase(researchCase)
            print("Expediente abierto:", researchCase.id.uuidString, name)

        case "research-hypothesis":
            guard arguments.count >= 2,
                  let caseID = UUID(uuidString: arguments[1]),
                  let rankText = option("--rank", in: arguments),
                  let rank = Int(rankText),
                  let statement = option("--statement", in: arguments),
                  let prediction = option("--prediction", in: arguments) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-hypothesis CASE_ID --rank N --statement TEXTO --prediction TEXTO"
                )
            }
            let hypothesis = ResearchHypothesis(
                caseID: caseID,
                rank: rank,
                statement: statement,
                prediction: prediction
            )
            try await repository.registerResearchHypothesis(hypothesis)
            print("Hipótesis registrada:", hypothesis.id.uuidString)

        case "research-stage":
            guard arguments.count >= 2,
                  let caseID = UUID(uuidString: arguments[1]),
                  let dimensionName = option("--dimension", in: arguments),
                  let dimension = ResearchExperimentDimension(rawValue: dimensionName),
                  let change = option("--change", in: arguments),
                  let rollback = option("--rollback", in: arguments),
                  let baseline = option("--baseline", in: arguments) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-stage CASE_ID --dimension DIMENSIÓN --change TEXTO --rollback REFERENCIA --baseline HUELLA [--hypothesis UUID]"
                )
            }
            let hypothesisID: UUID?
            if let value = option("--hypothesis", in: arguments) {
                guard let parsed = UUID(uuidString: value) else {
                    throw RegressionCoreError.launchFailed("--hypothesis no contiene un UUID válido")
                }
                hypothesisID = parsed
            } else {
                hypothesisID = nil
            }
            let experiment = ResearchExperiment(
                caseID: caseID,
                hypothesisID: hypothesisID,
                dimension: dimension,
                changeSummary: change,
                state: .ready,
                isIsolated: true,
                rollbackReference: rollback,
                baselineEngineFingerprint: baseline
            )
            try await repository.registerResearchExperiment(experiment)
            try await repository.beginResearch(caseID: caseID)
            print("Experimento aislado preparado:", experiment.id.uuidString)

        case "research-attach-run":
            guard arguments.count >= 3,
                  let experimentID = UUID(uuidString: arguments[1]),
                  let runID = UUID(uuidString: arguments[2]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-attach-run EXPERIMENT_ID RUN_ID"
                )
            }
            try await repository.attachResearchRun(experimentID: experimentID, runID: runID)
            print("Ejecución exacta vinculada al experimento.")

        case "research-gate":
            guard arguments.count >= 4,
                  let experimentID = UUID(uuidString: arguments[1]),
                  let gate = ResearchValidationGate(rawValue: arguments[2]),
                  let status = ResearchGateStatus(rawValue: arguments[3]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-gate EXPERIMENT_ID PUERTA pending|passed|failed [--evidence REFERENCIA]"
                )
            }
            try await repository.recordResearchGate(ResearchGateResult(
                experimentID: experimentID,
                gate: gate,
                status: status,
                evidenceReference: option("--evidence", in: arguments) ?? ""
            ))
            print("Puerta registrada:", gate.rawValue, status.rawValue)

        case "research-artifact":
            guard arguments.count >= 3,
                  let experimentID = UUID(uuidString: arguments[1]),
                  let kind = ResearchArtifactKind(rawValue: arguments[2]),
                  let reference = option("--reference", in: arguments) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-artifact EXPERIMENT_ID TIPO --reference RUTA --fingerprint HUELLA"
                )
            }
            try await repository.recordResearchArtifact(ResearchArtifact(
                experimentID: experimentID,
                kind: kind,
                reference: reference,
                fingerprint: option("--fingerprint", in: arguments)
            ))
            print("Evidencia registrada:", kind.rawValue)

        case "research-finish":
            guard arguments.count >= 3,
                  let experimentID = UUID(uuidString: arguments[1]) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-finish EXPERIMENT_ID failed|rolledBack [--note TEXTO]"
                )
            }
            let state: ResearchExperimentState
            switch arguments[2] {
            case "failed": state = .failed
            case "rolledBack": state = .rolledBack
            default:
                throw RegressionCoreError.launchFailed(
                    "El resultado debe ser failed o rolledBack"
                )
            }
            try await repository.finishResearchExperiment(
                id: experimentID,
                state: state,
                notes: option("--note", in: arguments) ?? "Resultado conservado para comparación"
            )
            print("Experimento cerrado:", state.rawValue)

        case "research-complete":
            guard arguments.count >= 3,
                  let caseID = UUID(uuidString: arguments[1]),
                  let experimentID = UUID(uuidString: arguments[2]),
                  let resolution = option("--resolution", in: arguments) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-complete CASE_ID EXPERIMENT_ID --resolution TEXTO"
                )
            }
            try await repository.completeResearchCase(
                caseID: caseID,
                experimentID: experimentID,
                resolution: resolution
            )
            print("Expediente verificado y cerrado con evidencia reproducible.")

        case "database":
            try await repository.prepare()
            let health = try await repository.databaseHealth()
            print("Esquema:", health.schemaVersion)
            print("Integridad:", health.integrity)
            print("Referencias huérfanas:", health.foreignKeyViolations)
            print("Juegos:", health.gameCount)
            print("Ejecuciones:", health.runCount)
            print("Procesos observados:", health.processCount)
            print("Verificaciones:", health.verifiedRunCount)
            print("Observaciones:", health.observationCount)
            print("Certificaciones activas:", health.certificationCount)
            print("Fichas públicas:", health.externalRecordCount)
            print("Motores normalizados:", health.engineSnapshotCount)
            print("Tecnologías inventariadas:", health.runtimeTechnologyCount)
            print("Candidatos aislados:", health.runtimeCandidateCount)
            print("Mediciones de rendimiento:", health.optimizationAssessmentCount)
            print("Requisitos declarativos:", health.runtimeRequirementCount)
            print("Recibos de reparación:", health.repairReceiptCount)
            print("Expedientes de I+D:", health.researchCaseCount)
            print("Hipótesis de I+D:", health.researchHypothesisCount)
            print("Experimentos de I+D:", health.researchExperimentCount)
            print("Puertas de validación:", health.researchGateCount)
            print("Evidencias de I+D:", health.researchArtifactCount)
            print("Diagnósticos previos:", health.preflightReportCount)
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
            let evidence = VerificationEvidence.manualDefault(for: verdict)
            try await repository.verifyRun(RunVerification(
                runID: runID,
                verdict: verdict,
                rendering: evidence.rendering,
                inputPrecision: evidence.inputPrecision,
                graphicsSettings: evidence.graphicsSettings,
                gameplay: evidence.gameplay,
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
            let gameName = option("--name", in: arguments)
                ?? game?.name
                ?? SteamGameName.placeholder(for: appID)
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
            let evidence = VerificationEvidence.manualDefault(for: verdict)
            try await repository.recordObservation(CompatibilityObservation(
                appID: appID,
                gameName: gameName,
                backend: backend,
                providerVersion: providerVersion,
                verdict: verdict,
                rendering: evidence.rendering,
                inputPrecision: evidence.inputPrecision,
                graphicsSettings: evidence.graphicsSettings,
                gameplay: evidence.gameplay,
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
            print("Uso: regressionctl [status | preflight [APP_ID] [--backend crossOver|regression] | share-library --shutdown [--restart] | launch APP_ID [--backend crossOver|regression] | switch crossOver|regression | runs | processes [RUN_ID] | profiles | engines | certifications | technologies | candidates | optimization | requirements | repair-receipts | research | research-protocol | research-open | research-hypothesis | research-stage | research-attach-run | research-gate | research-artifact | research-finish | research-complete | database | catalog | catalog-sync APP_ID [--force] | comparisons | verify RUN_ID perfect|playable|failed [--note TEXTO] | observe APP_ID perfect|playable|failed --backend MOTOR --name NOMBRE [--note TEXTO] | observations | export RUTA]")
            exit(64)
        }
    }

    private static func preflightReport(
        backend: BackendKind,
        appID: String?,
        installations: InstallationSnapshot,
        runningState: RunningBackendState,
        repository: CompatibilityRepository,
        runner: any ProcessRunning,
        supportURL: URL
    ) async throws -> GameTestPreflightReport {
        let steamRootURL: URL
        switch backend {
        case .crossOver:
            guard let crossOver = installations.crossOver else {
                throw RegressionCoreError.crossOverNotInstalled
            }
            steamRootURL = crossOver.steamRootURL
        case .regression:
            steamRootURL = installations.regression.steamRootURL
        }

        let installedGames = SteamManifestParser.games(in: steamRootURL, backend: backend)
        let game: SteamGame?
        if let appID {
            game = installedGames.first(where: { $0.appID == appID }) ?? SteamGame(
                appID: appID,
                name: SteamGameName.placeholder(for: appID),
                installDirectory: "juego-no-detectado-\(appID)",
                manifestURL: steamRootURL.appendingPathComponent(
                    "steamapps/appmanifest_\(appID).acf"
                ),
                sourceBackend: backend
            )
        } else {
            game = nil
        }

        let sharedAssessment: SharedLibraryAssessment?
        if let crossOver = installations.crossOver {
            sharedAssessment = await SharedSteamLibraryManager(
                backupRootURL: supportURL.appendingPathComponent(
                    "Backups/SharedLibrary",
                    isDirectory: true
                )
            ).assess(
                regression: installations.regression,
                crossOver: crossOver
            )
        } else {
            sharedAssessment = nil
        }

        try await repository.prepare()
        let health = try await repository.databaseHealth()
        return await GameTestPreflight(
            runner: runner,
            applicationSupportURL: supportURL
        ).evaluate(
            backend: backend,
            installations: installations,
            runningState: runningState,
            databaseHealth: health,
            sharedLibraryAssessment: sharedAssessment,
            game: game
        )
    }

    private static func printPreflight(_ report: GameTestPreflightReport) {
        print("Preparación:", report.status.displayName)
        print("Backend:", report.backend.displayName)
        print("Captura:", report.capturePhase.displayName)
        if let delay = report.captureDelayMilliseconds {
            print("Latencia de observación:", "\(delay) ms")
        }
        if let appID = report.appID, let gameName = report.gameName {
            print("Juego:", gameName, "(App ID \(appID))")
        }
        for check in report.checks {
            print("[\(check.status.rawValue)]", check.title + ":", check.detail)
            if let recovery = check.recoveryAction, check.status != .ready {
                print("  Acción:", recovery)
            }
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
