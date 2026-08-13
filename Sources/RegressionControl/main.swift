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
        let custodyManager = SharedSteamLibraryManager(
            backupRootURL: support.appendingPathComponent(
                "Backups/SharedLibrary",
                isDirectory: true
            )
        )
        let coordinator = BackendCoordinator(
            processRunner: runner,
            processLauncher: launcher,
            inspector: inspector,
            logDirectoryURL: support.appendingPathComponent("Logs/Launcher", isDirectory: true),
            custodyInterlock: custodyManager
        )
        let databaseURL = ProcessInfo.processInfo.environment["REGRESSION_COMPATIBILITY_DATABASE_PATH"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("Compatibility/compatibility.sqlite")
        let repository = CompatibilityRepository(
            databaseURL: databaseURL,
            legacyCompiledRepairBottleURL: installations.regression.bottleURL
        )

        switch command {
        case "unreal-bootstrap-routes":
            let routes = try UnrealBootstrapRouteDetector.routes(
                in: installations.regression.steamRootURL
            )
            for route in routes {
                print("\(route.bootstrapExecutable)\t\(route.shippingURL.path)")
            }

        case "status":
            let running = await coordinator.runningState()
            let custody = await custodyManager.currentPhysicalLibraryCustodyInterlock()
            print("Custodia:", custodyStatusDescription(custody.status))
            print("Steam Regression:", running.regressionIsRunning ? "activo" : "cerrado")

        case "prepare-launch-state":
            let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
                in: installations.regression.bottleURL,
                prepareLedger: {
                    try await repository.prepare()
                },
                recordReceipt: { context in
                    if try await repository.repairReceipts(appID: "2617700").contains(
                        where: { $0.id == context.receiptID }
                    ) {
                        return
                    }
                    try await repository.recordRepairReceipt(RepairReceipt(
                        id: context.receiptID,
                        appID: "2617700",
                        backend: .regression,
                        recipeID: CompiledRepairRecipe.gameMakerRetinaFullscreen.rawValue,
                        recipeVersion: 1,
                        beforeFingerprint: context.beforeFingerprint,
                        afterFingerprint: context.afterFingerprint,
                        rollbackReference: PrivacySanitizer.normalizedPath(context.intentURL.path),
                        result: context.result,
                        notes: "Se corrigió únicamente fullscreen=0 con la resolución máxima de Tinkerlands en \(context.repairedFileCount) fichero(s)."
                    ))
                }
            )

            switch outcome {
            case .noOp:
                print("REGRESSION_REPAIR_STATE=no-op")
                print("Estado de lanzamiento: no necesita reparación")
            case let .committed(report):
                print("REGRESSION_REPAIR_STATE=committed")
                for entry in report.entries {
                    print(
                        "Estado de lanzamiento reparado:",
                        PrivacySanitizer.normalizedPath(entry.optionsURL.path)
                    )
                }
            case .rolledBack:
                print("REGRESSION_REPAIR_STATE=rolled-back")
                print("La reparación no pudo registrarse y se restauraron los bytes originales.")
            case let .unsafe(failure):
                print(
                    "REGRESSION_REPAIR_STATE=unsafe mutation=\(failure.mutationOccurred ? "yes" : "no")"
                )
                guard outcome.allowsLaunch else {
                    throw RegressionCoreError.invalidEvidence(failure.message)
                }
                print("Estado anterior conservado sin mutaciones: \(failure.message)")
            }

        case "library-status":
            let running = await coordinator.runningState()
            let assessment = await custodyManager.assessPhysicalCustody(
                regression: installations.regression,
                legacyIdentity: legacyPhysicalCustodyIdentity(
                    installations: installations,
                    homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
                ),
                runningState: running
            )
            print("Custodia:", custodyStatusDescription(assessment.status))
            print("Destino:", PrivacySanitizer.normalizedPath(assessment.destinationSteamAppsURL.path))
            print("Manifiestos:", assessment.inventory.manifestAppIDs.count)
            print("Archivos:", assessment.inventory.regularFileCount)
            print("Bytes:", assessment.inventory.totalRegularFileBytes)

        case "migrate-library":
            try PhysicalLibraryCustodyCommandPolicy.authorizeMigration(arguments: arguments)
            let identity = legacyPhysicalCustodyIdentity(
                installations: installations,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            let assessment = try await custodyManager.migratePhysicalCustody(
                regression: installations.regression,
                legacyIdentity: identity,
                runningStateProvider: { await coordinator.runningState() }
            )
            print("Custodia:", custodyStatusDescription(assessment.status))
            print(
                "La biblioteca física está en Regression; valida Steam y un juego antes de finalizar."
            )

        case "rollback-library":
            try PhysicalLibraryCustodyCommandPolicy.authorizeRollback(arguments: arguments)
            let assessment = try await custodyManager.rollbackPhysicalCustody(
                regression: installations.regression,
                legacyIdentity: legacyPhysicalCustodyIdentity(
                    installations: installations,
                    homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
                ),
                runningState: await coordinator.runningState()
            )
            print("Custodia:", custodyStatusDescription(assessment.status))

        case "finalize-library":
            throw RegressionCoreError.unsafeLibraryState(
                "finalize-library ya no acepta evidencia libre; "
                    + "usa validate-library APP_ID --run RUN_ID"
            )

        case "validate-library":
            let request = try PhysicalLibraryCustodyCommandPolicy.validationRequest(
                arguments: arguments
            )
            let identity = legacyPhysicalCustodyIdentity(
                installations: installations,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            let assessment = try await custodyManager.finalizePhysicalCustodyValidated(
                regression: installations.regression,
                legacyIdentity: identity,
                request: request,
                repository: repository,
                runningState: await coordinator.runningState()
            )
            print("Custodia:", custodyStatusDescription(assessment.status))
            print("Validación vinculada a App ID", request.appID, "y run", request.runID)

        case "share-library":
            throw RegressionCoreError.unsafeLibraryState(
                "share-library fue retirado: Regression ya no crea bibliotecas compartidas con CrossOver"
            )

        case "launch":
            guard let rawAppID = arguments.dropFirst().first,
                  let appID = SteamAppID.normalized(rawAppID) else {
                throw RegressionCoreError.launchFailed("Falta un Steam App ID válido")
            }
            var running = await coordinator.runningState()
            let backend = try BackendLaunchPolicy.cliSelection(
                requestedRawValue: option("--backend", in: arguments),
                activeBackend: running.activeBackend
            )
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
            if let backendName, backendName != BackendKind.regression.rawValue {
                fputs("ERROR: preflight solo admite --backend regression\n", stderr)
                exit(64)
            }
            let backend: BackendKind
            if let backendName {
                backend = try BackendLaunchPolicy.cliSelection(
                    requestedRawValue: backendName,
                    activeBackend: running.activeBackend
                )
            } else {
                backend = try BackendLaunchPolicy.cliSelection(
                    requestedRawValue: nil,
                    activeBackend: running.activeBackend
                )
            }
            try await coordinator.validateBackendAvailability(backend)
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
            guard arguments.dropFirst().first == BackendKind.regression.rawValue else {
                fputs("ERROR: switch solo admite regression\n", stderr)
                exit(64)
            }
            let target = BackendKind.regression
            let running = await coordinator.runningState()
            _ = try await coordinator.switchBackend(
                from: running.activeBackend,
                to: target,
                installations: installations
            )
            print("Cambio solicitado a", target.displayName)

        case "runs":
            try await repository.prepare()
            let runs = try await repository.recentRuns(limit: 50).filter {
                $0.backend == .regression
            }
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
            let regressionRunIDs = Set(try await repository.runDetails().filter {
                $0.backend == .regression
            }.map(\.id))
            let processes = try await repository.runProcesses(
                runID: requestedRunID,
                limit: requestedRunID == nil ? 1_000 : 10_000
            ).filter { regressionRunIDs.contains($0.runID) }
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
            let profiles = try await repository.compatibilityProfiles().filter {
                $0.backend == .regression
            }
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
            for engine in try await repository.engineProfiles().filter({
                $0.backend == .regression
            }) {
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
            for certification in try await repository.certifications().filter({
                $0.backend == .regression
            }) {
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
            for assessment in try await repository.optimizationAssessments().filter({
                $0.backend == .regression
            }) {
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
            for receipt in try await repository.repairReceipts().filter({
                $0.backend == .regression
            }) {
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
            let cases = try await repository.researchCases().filter {
                $0.referenceBackend == .regression
            }
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
            let installedGames = SteamManifestParser.games(
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
                expectedBehavior: expected,
                referenceBackend: .regression
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

        case "research-pause":
            guard arguments.count >= 2,
                  let caseID = UUID(uuidString: arguments[1]),
                  let blocker = option("--blocker", in: arguments) else {
                throw RegressionCoreError.launchFailed(
                    "Usa research-pause CASE_ID --blocker DEPENDENCIA_EXTERNA"
                )
            }
            try await repository.pauseResearch(caseID: caseID, externalBlocker: blocker)
            print("Expediente pausado por dependencia externa concreta.")

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
                    "Usa observe APP_ID perfect|playable|failed --backend regression --name NOMBRE [--note TEXTO]"
                )
            }
            let backendName = option("--backend", in: arguments) ?? "regression"
            guard backendName == BackendKind.regression.rawValue else {
                fputs("ERROR: observe solo admite --backend regression\n", stderr)
                exit(64)
            }
            let backend = BackendKind.regression
            let note = option("--note", in: arguments) ?? "Observación de compatibilidad importada"
            let bottleURL = installations.regression.bottleURL
            let steamRootURL = installations.regression.steamRootURL
            let providerVersion = "Regression"
            let game = SteamManifestParser.games(in: steamRootURL, backend: backend)
                .first { $0.appID == appID }
            let gameName = option("--name", in: arguments)
                ?? game?.name
                ?? SteamGameName.placeholder(for: appID)
            let configuration = ConfigurationCollector.snapshot(
                bottleURL: bottleURL,
                backend: backend,
                providerVersion: providerVersion,
                game: game,
                steamRootURL: steamRootURL
            )
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
            for observation in try await repository.observations().filter({
                $0.backend == .regression
            }) {
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
            print("Uso: regressionctl [status | library-status | migrate-library --confirm-single-library --confirm-crossover-games-removed | validate-library APP_ID --run RUN_ID | rollback-library --confirm-rollback | unreal-bootstrap-routes | preflight [APP_ID] [--backend regression] | launch APP_ID [--backend regression] | switch regression | runs | processes [RUN_ID] | profiles | engines | certifications | technologies | candidates | optimization | requirements | repair-receipts | research | research-protocol | research-open | research-hypothesis | research-stage | research-attach-run | research-gate | research-artifact | research-finish | research-pause | research-complete | database | verify RUN_ID perfect|playable|failed [--note TEXTO] | observe APP_ID perfect|playable|failed --backend regression --name NOMBRE [--note TEXTO] | observations | export RUTA]")
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
        guard backend == .regression else {
            throw RegressionCoreError.launchFailed(
                "El diagnóstico de lanzamiento solo admite Regression"
            )
        }
        let steamRootURL = installations.regression.steamRootURL

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

        let custodyManager = SharedSteamLibraryManager(
            backupRootURL: supportURL.appendingPathComponent(
                "Backups/SharedLibrary",
                isDirectory: true
            )
        )
        let custody = await custodyManager.currentPhysicalLibraryCustodyInterlock()
        let physicalCustodyAssessment: PhysicalLibraryCustodyAssessment?
        if custody.crossOverUnavailable || custody.mutationPolicy != .unrestricted {
            physicalCustodyAssessment = await custodyManager.assessPhysicalCustody(
                regression: installations.regression,
                legacyIdentity: legacyPhysicalCustodyIdentity(
                    installations: installations,
                    homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
                ),
                runningState: runningState
            )
        } else {
            physicalCustodyAssessment = nil
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
            sharedLibraryAssessment: nil,
            physicalCustodyAssessment: physicalCustodyAssessment,
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

    private static func custodyStatusDescription(_ status: PhysicalLibraryCustodyStatus) -> String {
        switch status {
        case .eligibleForTransfer: "lista para trasladar"
        case .preparing: "preparando traslado"
        case .preCutover: "preparada para el corte"
        case .cutover: "trasladando custodia"
        case .verifying: "verificando biblioteca"
        case .pendingValidation: "pendiente de validación en Regression"
        case .validating: "validando con Regression"
        case .rollingBack: "restaurando estado anterior"
        case .independent: "independiente"
        case let .blocked(reason): "bloqueada — \(reason)"
        }
    }

    private static func legacyPhysicalCustodyIdentity(
        installations: InstallationSnapshot,
        homeDirectoryURL: URL
    ) -> PhysicalLibraryCustodyIdentity {
        _ = installations
        let steamAppsURL = homeDirectoryURL.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps",
            isDirectory: true
        )
        return PhysicalLibraryCustodyIdentity(legacySteamAppsURL: steamAppsURL)
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
