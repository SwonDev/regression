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
        case "durable-sync":
            let paths = Array(arguments.dropFirst())
            guard !paths.isEmpty else {
                throw RegressionCoreError.invalidEvidence(
                    "durable-sync requiere al menos una ruta administrada"
                )
            }
            let managedRoot = support.standardizedFileURL.path + "/"
            for path in paths {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.path.hasPrefix(managedRoot) else {
                    throw RegressionCoreError.invalidEvidence(
                        "durable-sync solo acepta rutas bajo Application Support de Regression"
                    )
                }
                let descriptor = try anchoredDescriptor(forAbsolutePath: url.path)
                defer { Darwin.close(descriptor) }
                guard Darwin.fsync(descriptor) == 0 else {
                    throw RegressionCoreError.invalidEvidence(
                        "no se pudo sincronizar una ruta administrada"
                    )
                }
            }

        case "unreal-bootstrap-routes":
            let routes = try UnrealBootstrapRouteDetector.routes(
                in: installations.regression.steamRootURL
            )
            for route in routes {
                print("\(route.bootstrapExecutable)\t\(route.shippingURL.path)")
            }

        case "d3d12-metal-routes":
            let routes = try D3D12MetalRouteDetector.routes(
                in: installations.regression.steamRootURL
            )
            for route in routes {
                print("\(route.shippingExecutable)\t\(route.shippingURL.path)")
            }

        case "windows-media-repair-plan":
            guard arguments.count == 4,
                  let appID = SteamAppID.normalized(arguments[1]),
                  appID == arguments[1],
                  arguments[2] == "--owner-pid",
                  let ownerPID = Int32(arguments[3]),
                  ownerPID == getppid(),
                  let authorization = WindowsMediaComponentRepairAuthorization(
                    explicitAppID: appID
                  ) else {
                throw RegressionCoreError.invalidEvidence(
                    "windows-media-repair-plan requiere un Steam App ID canónico"
                )
            }
            try await repository.prepare()
            let projection = try await GameTechnologyEvidenceScanner.refreshProjection(
                appID: appID,
                steamRootURL: installations.regression.steamRootURL,
                repository: repository
            )
            let applicationBundle = Bundle(url: applicationURL) ?? .main
            let version = applicationBundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "desconocida"
            let build = applicationBundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "desconocido"
            let variant: ComponentArtifactVariant = applicationURL.standardizedFileURL.path
                == "/Applications/Regression.app"
                ? .publicInstalled : .development
            let health = ComponentHealthService.evaluate(
                TrustedComponentCatalog.windowsMediaDescriptor(
                    applicationVersion: version,
                    buildIdentifier: build,
                    variant: variant,
                    applicationBundleURL: applicationURL,
                    applicationSupportURL: support
                )
            )
            let runtime = await coordinator.runningState()
            switch WindowsMediaComponentRepairPlanner.plan(
                projection: projection,
                health: health,
                authorization: authorization,
                runtimeIsIdle: runtime.activeBackend == nil
            ) {
            case .notRequired:
                print("REGRESSION_WINDOWS_MEDIA_PLAN=not-required")
            case .repair:
                let lease = try WindowsMediaRepairInterlock.issueRepairLease(
                    appID: appID,
                    ownerPID: ownerPID,
                    applicationSupportURL: support,
                    runtimeIsIdle: runtime.activeBackend == nil
                )
                print("REGRESSION_WINDOWS_MEDIA_PLAN=repair")
                print("REGRESSION_WINDOWS_MEDIA_LEASE=\(lease.token)")
            case .blocked(let blocker):
                print("REGRESSION_WINDOWS_MEDIA_PLAN=blocked")
                print("REGRESSION_WINDOWS_MEDIA_BLOCKER=\(blocker.rawValue)")
            }

        case "windows-media-pending-recovery-app-id":
            guard arguments.count == 3, arguments[1] == "--owner-pid",
                  let ownerPID = Int32(arguments[2]), ownerPID == getppid() else {
                throw RegressionCoreError.invalidEvidence("consulta WAL Windows Media no válida")
            }
            let intentURL = support.appendingPathComponent(
                "Transactions/WindowsMedia/1-link-repair.intent",
                isDirectory: false
            )
            let intentExists = FileManager.default.fileExists(atPath: intentURL.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: intentURL.path)) != nil
            guard intentExists else {
                print("REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none")
                break
            }
            guard let text = String(
                data: try WindowsMediaAnchoredPrivateFileStore.read(
                    .intent,
                    applicationSupportURL: support
                ),
                encoding: .utf8
            ) else {
                throw RegressionCoreError.invalidEvidence("WAL Windows Media no legible")
            }
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let separator = line.firstIndex(of: "=") else {
                    throw RegressionCoreError.invalidEvidence("WAL Windows Media malformado")
                }
                let key = String(line[..<separator])
                guard fields[key] == nil else {
                    throw RegressionCoreError.invalidEvidence("WAL Windows Media ambiguo")
                }
                fields[key] = String(line[line.index(after: separator)...])
            }
            guard fields.count == 11,
                  fields["schema"] == "1",
                  fields["kind"] == "trusted-component-link-repair-intent",
                  fields["component_id"] == TrustedComponentCatalog.windowsMediaComponentID,
                  fields["component_version"] == TrustedComponentCatalog.windowsMediaComponentVersion,
                  let rawAppID = fields["app_id"],
                  let appID = SteamAppID.normalized(rawAppID), appID == rawAppID else {
                throw RegressionCoreError.invalidEvidence("WAL Windows Media sin autoridad cerrada")
            }
            print("REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=\(appID)")

        case "consume-windows-media-repair-lease":
            guard arguments.count == 6,
                  let appID = SteamAppID.normalized(arguments[1]), appID == arguments[1],
                  UUID(uuidString: arguments[2]) != nil,
                  arguments[3] == "--owner-pid",
                  let ownerPID = Int32(arguments[4]),
                  arguments[5] == "--revalidate-idle" else {
                throw RegressionCoreError.invalidEvidence("lease Windows Media no válida")
            }
            let runtime = await coordinator.runningState()
            try WindowsMediaRepairInterlock.consumeRepairLease(
                appID: appID,
                token: arguments[2],
                ownerPID: ownerPID,
                applicationSupportURL: support,
                runtimeIsIdle: runtime.activeBackend == nil
            )

        case "release-windows-media-lease":
            guard arguments.count == 5,
                  UUID(uuidString: arguments[1]) != nil,
                  arguments[2] == "--owner-pid",
                  let ownerPID = Int32(arguments[3]),
                  arguments[4] == "--consumed" else {
                throw RegressionCoreError.invalidEvidence("lease Windows Media no válida")
            }
            try WindowsMediaRepairInterlock.release(
                token: arguments[1],
                ownerPID: ownerPID,
                applicationSupportURL: support
            )

        case "acquire-windows-media-runtime-lease":
            let joinExistingGameRuntime = arguments.count == 6
                && arguments[3] == "--app-id"
                && SteamAppID.normalized(arguments[4]) == arguments[4]
                && arguments[5] == "--join-existing-regression-runtime"
            let joinExistingControlRuntime = arguments.count == 4
                && arguments[3] == "--join-existing-regression-runtime-control"
            guard (arguments.count == 3 || joinExistingGameRuntime || joinExistingControlRuntime),
                  arguments[1] == "--owner-pid",
                  let ownerPID = Int32(arguments[2]), ownerPID == getppid() else {
                throw RegressionCoreError.invalidEvidence("interlock de runtime no válido")
            }

            func joinObservedRegressionRuntime() async throws -> WindowsMediaRepairLease {
                let snapshot = try WindowsMediaRepairInterlock.snapshotExistingRuntimeLease(
                    applicationSupportURL: support
                )
                let runtimeBeforeJoin = await coordinator.runningState()
                let observedOwners = snapshot.liveOwnerPIDs.intersection(
                    Set(runtimeBeforeJoin.regressionPIDs)
                )
                guard runtimeBeforeJoin.activeBackend == .regression, !observedOwners.isEmpty else {
                    throw RegressionCoreError.invalidEvidence(
                        "la lease activa no pertenece a un Steam de Regression observable"
                    )
                }
                let joinedLease = try WindowsMediaRepairInterlock.joinExistingRuntimeLease(
                    ownerPID: ownerPID,
                    expectedToken: snapshot.token,
                    expectedRuntimeOwnerPIDs: observedOwners,
                    applicationSupportURL: support
                )
                let runtimeAfterJoin = await coordinator.runningState()
                guard runtimeAfterJoin.activeBackend == .regression,
                      !observedOwners.isDisjoint(with: Set(runtimeAfterJoin.regressionPIDs)) else {
                    try? WindowsMediaRepairInterlock.release(
                        token: joinedLease.token,
                        ownerPID: ownerPID,
                        applicationSupportURL: support
                    )
                    throw RegressionCoreError.invalidEvidence(
                        "Steam de Regression cambió durante la unión al runtime"
                    )
                }
                return joinedLease
            }

            let lease: WindowsMediaRepairLease
            var acquisitionState = "issued"
            if joinExistingControlRuntime {
                lease = try await joinObservedRegressionRuntime()
                acquisitionState = "joined"
            } else {
                do {
                    lease = try WindowsMediaRepairInterlock.issueRuntimeLease(
                        ownerPID: ownerPID,
                        applicationSupportURL: support
                    )
                } catch WindowsMediaRepairInterlockError.leaseActive where joinExistingGameRuntime {
                    lease = try await joinObservedRegressionRuntime()
                    acquisitionState = "joined"
                }
            }
            print("REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=\(lease.token)")
            print("REGRESSION_WINDOWS_MEDIA_RUNTIME_STATE=\(acquisitionState)")

        case "windows-media-anchored-link":
            let authorizationStart = arguments.count - 6
            guard authorizationStart >= 2,
                  arguments[authorizationStart] == "--app-id",
                  arguments[authorizationStart + 2] == "--lease-token",
                  arguments[authorizationStart + 4] == "--owner-pid",
                  let appID = SteamAppID.normalized(arguments[authorizationStart + 1]),
                  appID == arguments[authorizationStart + 1],
                  UUID(uuidString: arguments[authorizationStart + 3]) != nil,
                  let ownerPID = Int32(arguments[authorizationStart + 5]) else {
                throw RegressionCoreError.invalidEvidence("mutación anclada Windows Media no válida")
            }
            let operationArguments = Array(arguments[1..<authorizationStart])
            let runtime = await coordinator.runningState()
            try WindowsMediaRepairInterlock.consumeRepairLease(
                appID: appID,
                token: arguments[authorizationStart + 3],
                ownerPID: ownerPID,
                applicationSupportURL: support,
                runtimeIsIdle: runtime.activeBackend == nil
            )
            let payload = applicationURL.appendingPathComponent(
                "Contents/SharedSupport/components/windows-media/1",
                isDirectory: true
            )
            let mutation: WindowsMediaAnchoredLinkMutation
            switch (operationArguments.first, Array(operationArguments.dropFirst())) {
            case ("create-stage", let values) where values.count == 1:
                mutation = .createStage(stageName: values[0], targetURL: payload)
            case ("backup-current", let values) where values.count == 1:
                mutation = .backupCurrent(backupName: values[0])
            case ("commit-stage", let values) where values.count == 1:
                mutation = .commitStage(stageName: values[0])
            case ("restore-backup", let values) where values.count == 1:
                mutation = .restoreBackup(backupName: values[0])
            case ("remove-stage", let values) where values.count == 1:
                mutation = .removeStage(stageName: values[0])
            case ("remove-current", let values) where values.isEmpty:
                mutation = .removeCurrent
            default:
                throw RegressionCoreError.invalidEvidence("mutación anclada Windows Media no válida")
            }
            try WindowsMediaAnchoredLinkMutator.apply(
                mutation,
                applicationSupportURL: support,
                authorizedPayloadURL: payload
            )

        case "windows-media-private-file":
            let authorizationStart = arguments.count - 6
            guard authorizationStart == 3,
                  arguments[authorizationStart] == "--app-id",
                  arguments[authorizationStart + 2] == "--lease-token",
                  arguments[authorizationStart + 4] == "--owner-pid",
                  let appID = SteamAppID.normalized(arguments[authorizationStart + 1]),
                  appID == arguments[authorizationStart + 1],
                  UUID(uuidString: arguments[authorizationStart + 3]) != nil,
                  let ownerPID = Int32(arguments[authorizationStart + 5]),
                  let file = WindowsMediaAnchoredPrivateFile(rawValue: arguments[2]) else {
                throw RegressionCoreError.invalidEvidence("fichero privado Windows Media no válido")
            }
            let runtime = await coordinator.runningState()
            try WindowsMediaRepairInterlock.consumeRepairLease(
                appID: appID,
                token: arguments[authorizationStart + 3],
                ownerPID: ownerPID,
                applicationSupportURL: support,
                runtimeIsIdle: runtime.activeBackend == nil
            )
            switch arguments[1] {
            case "prepare":
                try WindowsMediaAnchoredPrivateFileStore.prepare(
                    applicationSupportURL: support
                )
            case "read":
                FileHandle.standardOutput.write(try WindowsMediaAnchoredPrivateFileStore.read(
                    file,
                    applicationSupportURL: support
                ))
            case "write":
                try WindowsMediaAnchoredPrivateFileStore.write(
                    FileHandle.standardInput.readDataToEndOfFile(),
                    to: file,
                    applicationSupportURL: support
                )
            case "remove":
                try WindowsMediaAnchoredPrivateFileStore.remove(
                    file,
                    applicationSupportURL: support
                )
            default:
                throw RegressionCoreError.invalidEvidence("operación privada Windows Media no válida")
            }

        case "status":
            let running = await coordinator.runningState()
            let custody = await custodyManager.currentPhysicalLibraryCustodyInterlock()
            print("Custodia:", custodyStatusDescription(custody.status))
            print("Steam Regression:", running.regressionIsRunning ? "activo" : "cerrado")

        case "prepare-launch-state":
            guard arguments.count == 4,
                  arguments[1] == "2617700",
                  arguments[2] == "--owner-pid",
                  let ownerPID = Int32(arguments[3]),
                  ownerPID == getppid() else {
                throw RegressionCoreError.invalidEvidence(
                    "prepare-launch-state solo admite el App ID compilado 2617700 y su launcher padre"
                )
            }
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
            let game = SteamManifestParser.games(
                in: installations.regression.steamRootURL,
                backend: .regression
            ).first(where: { $0.appID == appID }) ?? SteamGame(
                appID: appID,
                name: SteamGameName.placeholder(for: appID),
                installDirectory: "juego-no-detectado-\(appID)",
                manifestURL: installations.regression.steamRootURL.appendingPathComponent(
                    "steamapps/appmanifest_\(appID).acf"
                ),
                sourceBackend: .regression
            )
            let launchContext = regressionLaunchContext(
                appID: appID,
                game: game,
                installation: installations.regression,
                applicationURL: applicationURL
            )
            try await repository.beginRun(launchContext)
            var envelopeID: UUID?
            var launchSubmitted = false
            do {
                try await repository.recordPreflight(report, forRunID: launchContext.id)
                let requirementProjection = try await GameTechnologyEvidenceScanner.refreshProjection(
                    appID: appID,
                    steamRootURL: installations.regression.steamRootURL,
                    repository: repository
                )
                let componentHealth = regressionLaunchComponentHealth(
                    installation: installations.regression,
                    applicationURL: applicationURL,
                    applicationSupportURL: support
                )
                try RendererLaunchGate.validate(
                    installation: installations.regression,
                    appID: appID
                )
                let envelope = try LaunchEnvelopeService().prepare(
                    LaunchEnvelopeRequest(
                        appID: appID,
                        backend: backend,
                        runID: launchContext.id,
                        preflight: report,
                        requirements: requirementProjection,
                        componentHealth: componentHealth,
                        rendererIsEligible: true
                    )
                )
                try await repository.recordLaunchEnvelope(envelope)
                envelopeID = envelope.id
                try await repository.authorizeLaunchEnvelopeSpawn(id: envelope.id)
                let spawnAuthority = try await repository.gameLaunchSpawnAuthority(for: envelope.id)
                _ = try await coordinator.launchGame(
                    backend: backend,
                    installations: installations,
                    spawnAuthority: spawnAuthority
                )
                launchSubmitted = true
                try await repository.advanceLaunchEnvelopeWithReceipt(
                    id: envelope.id,
                    to: .awaitingTelemetry,
                    result: .awaitingTelemetry
                )
            } catch {
                var durablePreSpawnClosed = false
                if let envelopeID {
                    durablePreSpawnClosed = try await reconcileFailedLaunchEnvelope(
                        id: envelopeID,
                        repository: repository
                    )
                }
                let spawnStarted = if let envelopeID,
                    let envelope = try? await repository.launchEnvelope(id: envelopeID) {
                    switch envelope.phase {
                    case .spawnStarted, .awaitingTelemetry, .awaitingVerification, .completed,
                         .rollbackPending, .rolledBack:
                        true
                    case .intentDurable, .spawnAuthorized, .failedBeforeSpawn:
                        false
                    }
                } else {
                    false
                }
                if !launchSubmitted && !spawnStarted && envelopeID == nil {
                    try? await repository.failRunBeforeLaunch(
                        id: launchContext.id,
                        reason: error.localizedDescription
                    )
                }
                if envelopeID != nil, !durablePreSpawnClosed, !spawnStarted {
                    throw RegressionCoreError.database(
                        "El lanzamiento falló y no se pudo cerrar atómicamente su envelope; se conserva para recuperación: \(error.localizedDescription)"
                    )
                }
                throw error
            }
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
            print("Envelopes de lanzamiento:", health.launchEnvelopeCount ?? 0)
            print("Eventos de envelope:", health.launchEnvelopeEventCount ?? 0)
            print("Recibos de envelope:", health.launchEnvelopeReceiptCount ?? 0)
            print("Violaciones de envelope:", health.launchEnvelopeViolationCount ?? 0)
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
            _ = try await repository.verifyRunAndCompleteEnvelope(RunVerification(
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

    private static func anchoredDescriptor(forAbsolutePath path: String) throws -> Int32 {
        let components = Array(URL(fileURLWithPath: path).pathComponents.dropFirst())
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RegressionCoreError.invalidEvidence(
                "no se pudo abrir una ruta para persistencia durable"
            )
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RegressionCoreError.invalidEvidence(
                "no se pudo abrir una ruta para persistencia durable"
            )
        }
        for (index, component) in components.enumerated() {
            let isFinal = index == components.index(before: components.endIndex)
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isFinal ? 0 : O_DIRECTORY)
            let next = component.withCString { Darwin.openat(descriptor, $0, flags) }
            guard next >= 0 else {
                Darwin.close(descriptor)
                throw RegressionCoreError.invalidEvidence(
                    "no se pudo abrir una ruta para persistencia durable"
                )
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func regressionLaunchContext(
        appID: String,
        game: SteamGame,
        installation: RegressionInstallation,
        applicationURL: URL
    ) -> RunContext {
        let bundle = Bundle(url: applicationURL) ?? .main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "desconocida"
        let configuration = ConfigurationCollector.snapshot(
            bottleURL: installation.bottleURL,
            backend: .regression,
            providerVersion: version,
            game: game,
            steamRootURL: installation.steamRootURL
        )
        return RunContext(
            appID: appID,
            gameName: game.name,
            backend: .regression,
            bottleName: "Steam",
            providerVersion: version,
            command: "regression-engine",
            arguments: ["-applaunch", appID],
            system: SystemSnapshot(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: SystemInformation.architecture,
                deviceModel: SystemInformation.deviceModel(),
                displayWidth: 0,
                displayHeight: 0,
                displayScale: 1
            ),
            configuration: configuration,
            configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
        )
    }

    private static func regressionLaunchComponentHealth(
        installation: RegressionInstallation,
        applicationURL: URL,
        applicationSupportURL: URL
    ) -> LaunchEnvelopeComponentHealth {
        let bundle = Bundle(url: applicationURL) ?? .main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "desconocida"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "desconocida"
        let variant: ComponentArtifactVariant = applicationURL.standardizedFileURL.path
            == "/Applications/Regression.app" ? .publicInstalled : .development
        let windowsMedia = ComponentHealthService.evaluate(
            TrustedComponentCatalog.windowsMediaDescriptor(
                applicationVersion: version,
                buildIdentifier: build,
                variant: variant,
                applicationBundleURL: applicationURL,
                applicationSupportURL: applicationSupportURL
            )
        )
        return LaunchEnvelopeComponentHealth(
            runtime: RegressionLaunchComponentGate.evaluate(installation: installation),
            windowsMedia: windowsMedia
        )
    }

    /// Nunca convierte una excepción de CLI en una ejecución verificada. Si Steam ya recibió la
    /// solicitud, el envelope permanece pendiente de telemetría; si no, se cierra como fallo
    /// previo al spawn y deja un recibo explícito.
    private static func reconcileFailedLaunchEnvelope(
        id: UUID,
        repository: CompatibilityRepository
    ) async throws -> Bool {
        guard let envelope = try await repository.launchEnvelope(id: id) else { return false }
        switch envelope.phase {
        case .intentDurable, .spawnAuthorized:
            try await repository.failLaunchEnvelopeBeforeSpawn(id: id)
            return true
        case .spawnStarted:
            try await repository.advanceLaunchEnvelopeWithReceipt(
                id: id,
                to: .awaitingTelemetry,
                result: .awaitingTelemetry
            )
            return false
        case .awaitingTelemetry, .awaitingVerification, .completed, .failedBeforeSpawn,
             .rollbackPending, .rolledBack:
            return envelope.phase == .failedBeforeSpawn
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
