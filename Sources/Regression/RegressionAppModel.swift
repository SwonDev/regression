import AppKit
import Observation
import OSLog
import RegressionCore
import SwiftUI
import UserNotifications

enum AppOperation: Equatable {
    case discovering
    case ready
    case preparing(String)
    case running(BackendKind)
    case switching(BackendKind)
    case error

    var isBusy: Bool {
        switch self {
        case .discovering, .preparing, .switching: true
        case .ready, .running, .error: false
        }
    }
}

struct UserFacingFailure: Equatable {
    enum Recovery: Equatable {
        case refresh
    }

    let title: String
    let message: String
    let recovery: Recovery
}

enum PublicCatalogOperation: Equatable {
    case disabled
    case idle
    case syncing(current: Int, total: Int, gameName: String)
    case upToDate(Date?)
    case completedWithIssues(Int)

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

@MainActor
@Observable
final class RegressionAppModel {
    var selectedBackend: BackendKind
    var operation: AppOperation = .discovering
    var installations: InstallationSnapshot?
    var runningState = RunningBackendState()
    var games: [SteamGame] = []
    var recentRuns: [RunSummary] = []
    var profiles: [CompatibilityProfile] = []
    var engineProfiles: [EngineProfile] = []
    var certifications: [VerifiedGameCertification] = VerifiedGameCatalog.all
    var runtimeTechnologies: [RuntimeTechnology] = RuntimeTechnologyCatalog.all
    var activeRuntimeCandidateCount = 0
    var activeResearchCaseCount = 0
    var activeResearchExperimentCount = 0
    var externalCatalogEntries: [String: ExternalCompatibilityEntry] = [:]
    var compatibilityComparisons: [CompatibilityComparison] = []
    var databaseHealth: CompatibilityDatabaseHealth?
    var publicCatalogOperation: PublicCatalogOperation = .idle
    var publicCatalogEnabled: Bool
    var sharedLibraryAssessment: SharedLibraryAssessment?
    /// Error de biblioteca propagado desde una operación que la modificaba. No se infiere de
    /// texto de UI: evita presentar una biblioteca como lista tras un fallo de custodia/enlace.
    var libraryFailureDetail: String?
    var windowsMediaHealth: ComponentHealthReport?
    var windowsMediaHealthIsRefreshing = false
    /// Resultado de una inspección explícita de la biblioteca heredada. Esta evaluación nunca
    /// prepara ni ejecuta una transferencia; solo hace visible si sería segura en el futuro.
    var physicalLibraryCustodyAssessment: PhysicalLibraryCustodyAssessment?
    var physicalLibraryCustodyAssessmentIsRunning = false
    var physicalLibraryCustodyAssessmentNotice: String?
    var libraryIndependenceState: LibraryIndependenceState = .preparing
    var testReadiness: GameTestPreflightReport?
    var readinessIsRefreshing = false
    var regressionReleaseStatus: RegressionReleaseUpdateStatus = .checking
    var failure: UserFacingFailure?
    var statusDetail = "Preparando el motor y la biblioteca de Steam…"
    var autoLaunchEnabled: Bool
    var automaticRegressionUpdatesEnabled: Bool
    private(set) var shutdownIsComplete = false

    @ObservationIgnored private let processRunner: ProcessRunner
    @ObservationIgnored private let processLauncher: ProcessLauncher
    @ObservationIgnored private let inspector: ProcessInspector
    @ObservationIgnored private let discovery: InstallationDiscovery
    @ObservationIgnored private let coordinator: BackendCoordinator
    @ObservationIgnored private let repository: CompatibilityRepository
    @ObservationIgnored private let telemetry: TelemetryCoordinator
    @ObservationIgnored private let preflight: GameTestPreflight
    @ObservationIgnored private let externalCatalog: ExternalCatalogSynchronizer
    @ObservationIgnored private let sharedLibrary: SharedSteamLibraryManager
    @ObservationIgnored private let libraryScanner = SteamLibraryScanner()
    @ObservationIgnored private let configurationCollector = ConfigurationSnapshotCollector()
    @ObservationIgnored private let processLogReader = ProcessLogReader()
    @ObservationIgnored private let regressionReleaseService = RegressionReleaseUpdateService()
    @ObservationIgnored private let applicationSupportURL: URL
    @ObservationIgnored private let logger = Logger(
        subsystem: "local.regression.launcher",
        category: "lifecycle"
    )
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var externalCatalogTask: Task<Void, Never>?
    @ObservationIgnored private var regressionUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRegressionUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var physicalLibraryCustodyAssessmentTask: Task<Void, Never>?
    @ObservationIgnored private var physicalLibraryCustodyProgressTask: Task<Void, Never>?
    @ObservationIgnored private var physicalLibraryCustodyAssessmentID: UUID?
    @ObservationIgnored private var physicalLibraryCustodyValidationLease:
        PhysicalLibraryCustodyValidationLease?
    @ObservationIgnored private var externalCatalogSyncID: UUID?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var periodicRefreshCount = 0
    @ObservationIgnored private let regressionUpdateCheckCycle = 10_800
    @ObservationIgnored private let lastAttemptedRegressionReleaseKey =
        "lastAttemptedRegressionRelease"
    @ObservationIgnored private var profilesByAppID: [String: [CompatibilityProfile]] = [:]
    @ObservationIgnored private var certificationsByAppID = Dictionary(
        grouping: VerifiedGameCatalog.all,
        by: \.appID
    )
    @ObservationIgnored private var regressionGames: [SteamGame] = []

    init() {
        let defaults = UserDefaults.standard
        selectedBackend = .regression
        defaults.set(BackendKind.regression.rawValue, forKey: "selectedBackend")
        if defaults.object(forKey: "autoLaunchEnabled") == nil {
            defaults.set(true, forKey: "autoLaunchEnabled")
        }
        autoLaunchEnabled = defaults.bool(forKey: "autoLaunchEnabled")
        if defaults.object(forKey: "automaticRegressionUpdatesEnabled") == nil {
            defaults.set(true, forKey: "automaticRegressionUpdatesEnabled")
        }
        automaticRegressionUpdatesEnabled = defaults.bool(
            forKey: "automaticRegressionUpdatesEnabled"
        )
        if defaults.object(forKey: "publicCatalogEnabled") == nil {
            defaults.set(true, forKey: "publicCatalogEnabled")
        }
        let isPublicCatalogEnabled = defaults.bool(forKey: "publicCatalogEnabled")
        publicCatalogEnabled = isPublicCatalogEnabled
        publicCatalogOperation = isPublicCatalogEnabled ? .idle : .disabled

        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Regression", isDirectory: true)
        applicationSupportURL = applicationSupport
        processRunner = ProcessRunner()
        processLauncher = ProcessLauncher()
        inspector = ProcessInspector(runner: processRunner)
        discovery = InstallationDiscovery(runner: processRunner)
        let custodyManager = SharedSteamLibraryManager(
            backupRootURL: applicationSupport.appendingPathComponent(
                "Backups/SharedLibrary",
                isDirectory: true
            )
        )
        sharedLibrary = custodyManager
        coordinator = BackendCoordinator(
            processRunner: processRunner,
            processLauncher: processLauncher,
            inspector: inspector,
            logDirectoryURL: applicationSupport.appendingPathComponent("Logs/Launcher", isDirectory: true),
            custodyInterlock: custodyManager
        )
        repository = CompatibilityRepository(
            databaseURL: applicationSupport.appendingPathComponent("Compatibility/compatibility.sqlite")
        )
        telemetry = TelemetryCoordinator(
            repository: repository,
            monitor: SteamLogMonitor(),
            artifactCleaner: GameSessionArtifactCleaner(runner: processRunner)
        )
        preflight = GameTestPreflight(
            runner: processRunner,
            applicationSupportURL: applicationSupport
        )
        externalCatalog = ExternalCatalogSynchronizer(repository: repository)
    }

    var statusTitle: String {
        switch operation {
        case .discovering: "Preparando Regression"
        case .ready: "Listo"
        case let .preparing(label): label
        case let .running(backend): "Steam activo con \(backend.displayName)"
        case let .switching(backend): "Cambiando a \(backend.displayName)"
        case .error: failure?.title ?? "Necesita atención"
        }
    }

    var primaryActionTitle: String {
        runningState.activeBackend == nil ? "Abrir Steam" : "Mostrar Steam"
    }

    var selectedInstallationDetail: String {
        guard let installations else { return "Detectando…" }
        return installations.regression.healthDetail
    }

    func learnedSummary(for game: SteamGame) -> String? {
        if let certification = certificationsByAppID[game.appID]?.first
            ?? VerifiedGameCatalog.certification(for: game.appID) {
            return "Verificado perfecto: \(certification.backend.displayName)"
        }

        let candidates = profilesByAppID[game.appID] ?? []
        guard !candidates.isEmpty else { return nil }
        if let verified = CompatibilityProfile.preferredValidated(
            from: candidates,
            selectedBackend: selectedBackend
        ) {
            if verified.perfectRuns > 0 {
                return "Verificado perfecto: \(verified.backend.displayName)"
            }
            return verified.backend == selectedBackend
                ? "Funciona con incidencias: \(verified.backend.displayName)"
                : "Mejor perfil observado: \(verified.backend.displayName)"
        }
        let failures = candidates.reduce(0) { $0 + $1.failedRuns }
        return failures > 0 ? "\(failures) prueba(s) con incidencias" : "Pendiente de verificación visual"
    }

    func externalSummary(for game: SteamGame) -> String? {
        guard publicCatalogEnabled else { return nil }
        guard let entry = externalCatalogEntries[game.appID] else {
            return publicCatalogOperation.isSyncing ? "CodeWeavers: consulta pendiente" : nil
        }
        if let record = entry.record {
            let rating = record.macOSRating.value.map { "\($0)/5" } ?? "sin valoración Mac"
            return "CodeWeavers: \(rating)"
        }
        switch entry.status {
        case .noMatch: return "CodeWeavers: sin coincidencia exacta"
        case .failed, .unavailable: return "CodeWeavers: consulta no disponible"
        case .pending: return "CodeWeavers: consulta pendiente"
        case .linked: return nil
        }
    }

    func externalURL(for game: SteamGame) -> URL? {
        externalCatalogEntries[game.appID]?.record?.canonicalURL
    }

    var publicCatalogStatusText: String {
        switch publicCatalogOperation {
        case .disabled:
            "Comparación pública desactivada"
        case .idle:
            "Preparado para comparar la biblioteca instalada"
        case let .syncing(current, total, gameName):
            "Comparando \(current) de \(total): \(gameName)"
        case let .upToDate(date):
            date.map {
                "Actualizado \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "Datos públicos al día"
        case let .completedWithIssues(count):
            "Comparación terminada con \(count) consulta(s) pendiente(s)"
        }
    }

    var regressionUpdateNeedsManualRetry: Bool {
        automaticRegressionUpdateDecision == .manualRetryRequired
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        LifecycleDiagnostics.write("Bootstrap iniciado")
        logger.info("Inicio de bootstrap")
        operation = .discovering
        failure = nil

        do {
            try await repository.prepare()
            let reconciled = try await repository.reconcileInterruptedRuns()
            if reconciled > 0 {
                logger.notice("Se cerraron \(reconciled) observaciones interrumpidas")
            }
        } catch {
            present(error)
        }

        // La detección de release empieza cuanto antes y corre en paralelo al bootstrap local.
        // Antes del autoarranque se concede una ventana corta para que una actualización ya
        // publicada tenga prioridad sobre abrir Steam, sin bloquear indefinidamente por red.
        scheduleRegressionReleaseCheck()
        await refreshDiscovery()
        LifecycleDiagnostics.write("Detección completada")
        logger.info("Detección terminada; CrossOver disponible: \(self.installations?.crossOver != nil)")
        await beginTelemetryMonitoring()
        await refreshRuntimeState()
        let custodyInterlock = await sharedLibrary.currentPhysicalLibraryCustodyInterlock()
        applyPhysicalLibraryCustodyStatus(custodyInterlock.status)
        if runningState.activeBackend == nil {
            await assessPhysicalLibraryCustody()
        }
        if libraryIndependenceState.requiresMigrationResume, let installations {
            await continuePhysicalLibraryCustodyMigration(
                installations: installations,
                legacyIdentity: PhysicalLibraryCustodyIdentity(
                    legacySteamAppsURL: inheritedSteamAppsURL(for: installations)
                )
            )
        } else if libraryIndependenceState == .rollingBack, let installations {
            await continuePhysicalLibraryCustodyRollback(installations: installations)
        }
        logger.info("Estado de procesos: CrossOver=\(self.runningState.crossOverIsRunning), Regression=\(self.runningState.regressionIsRunning)")
        await refreshStoredData(includeHealth: true)
        await refreshWindowsMediaHealth()
        await refreshTestReadiness()
        schedulePublicCatalogSync()

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.periodicRefresh()
            }
        }

        if runningState.hasConflict {
            logger.error("Conflicto: ambos backends están activos")
            present(RegressionCoreError.backendConflict)
        } else if let active = runningState.activeBackend {
            operation = .running(active)
            statusDetail = "Se ha adoptado la instancia de Steam que ya estaba abierta."
        } else if libraryIndependenceState.blocksNormalOperations {
            operation = .ready
            statusDetail = switch libraryIndependenceState {
            case .pendingValidation:
                "La biblioteca espera validación funcional con el Steam propio de Regression."
            case .validating:
                "La validación quedó pendiente. Reabre Steam desde la tarjeta de independencia."
            default:
                "Regression está recuperando la custodia de la biblioteca antes de abrir Steam."
            }
        } else if automaticRegressionUpdatesEnabled && isCanonicalApplicationInstallation {
            await waitBrieflyForInitialRegressionReleaseCheck()
            if case let .available(_, release) = regressionReleaseStatus,
               automaticRegressionUpdateDecision == .installNow {
                operation = .ready
                statusDetail = "Preparando la actualización automática a Regression \(release.version)…"
                scheduleAutomaticRegressionUpdateIfPossible()
                return
            }
            if autoLaunchEnabled {
                LifecycleDiagnostics.write("Inicio automático en ejecución")
                logger.info("Inicio automático solicitado con \(self.selectedBackend.rawValue)")
                await startSteam()
            } else if failure == nil {
                operation = .ready
                statusDetail = "El inicio automático está desactivado."
            }
        } else if autoLaunchEnabled {
            LifecycleDiagnostics.write("Inicio automático en ejecución")
            logger.info("Inicio automático solicitado con \(self.selectedBackend.rawValue)")
            await startSteam()
        } else if failure == nil {
            operation = .ready
            statusDetail = "El inicio automático está desactivado."
        }
    }

    func refreshDiscovery() async {
        let appURL: URL?
        if Bundle.main.bundleURL.pathExtension == "app" {
            appURL = Bundle.main.bundleURL
        } else {
            appURL = nil
        }
        installations = await discovery.discover(regressionApplicationURL: appURL)
        selectedBackend = .regression
        UserDefaults.standard.set(BackendKind.regression.rawValue, forKey: "selectedBackend")
        await refreshGames()
        await refreshSharedLibraryAssessment()
    }

    func refreshAll() async {
        failure = nil
        libraryFailureDetail = nil
        operation = .discovering
        statusDetail = "Actualizando instalaciones y estado…"
        await refreshDiscovery()
        await refreshRuntimeState()
        let custodyInterlock = await sharedLibrary.currentPhysicalLibraryCustodyInterlock()
        applyPhysicalLibraryCustodyStatus(custodyInterlock.status)
        if runningState.activeBackend == nil {
            await assessPhysicalLibraryCustody()
        }
        if libraryIndependenceState.requiresMigrationResume, let installations {
            await continuePhysicalLibraryCustodyMigration(
                installations: installations,
                legacyIdentity: PhysicalLibraryCustodyIdentity(
                    legacySteamAppsURL: inheritedSteamAppsURL(for: installations)
                )
            )
        } else if libraryIndependenceState == .rollingBack, let installations {
            await continuePhysicalLibraryCustodyRollback(installations: installations)
        }
        await refreshStoredData(includeHealth: true)
        await refreshWindowsMediaHealth()
        await refreshTestReadiness()
        schedulePublicCatalogSync()
        if failure == nil {
            operation = runningState.activeBackend.map(AppOperation.running) ?? .ready
            statusDetail = switch libraryIndependenceState {
            case .pendingValidation:
                "La biblioteca espera su validación funcional con Regression."
            case .validating:
                "La validación funcional continúa pendiente."
            case .independent:
                "Motor y biblioteca propios verificados."
            default:
                "Estado actualizado."
            }
        }
    }

    func refreshTestReadiness() async {
        guard installations != nil, !readinessIsRefreshing else { return }
        readinessIsRefreshing = true
        defer { readinessIsRefreshing = false }
        do {
            testReadiness = try await collectTestReadiness(for: nil)
        } catch {
            logger.error(
                "No se pudo comprobar la preparación: \(error.localizedDescription, privacy: .public)"
            )
            testReadiness = nil
            statusDetail = "No se pudo completar la comprobación previa: \(error.localizedDescription)"
        }
    }

    /// Comprueba el payload compilado de Windows Media sin invocar su instalador ni modificar
    /// enlaces. La variante procede exclusivamente de la ubicación/versiones de esta app, nunca
    /// de un manifiesto observado.
    func refreshWindowsMediaHealth() async {
        guard !windowsMediaHealthIsRefreshing else { return }
        windowsMediaHealthIsRefreshing = true
        defer { windowsMediaHealthIsRefreshing = false }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let applicationVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "desconocida"
        let buildIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "desconocida"
        let isTrustedPublicInstallation = bundleURL.path == "/Applications/Regression.app"
            && applicationVersion == TrustedComponentCatalog.supportedApplicationVersion
            && buildIdentifier == TrustedComponentCatalog.supportedBuildIdentifier
        let variant: ComponentArtifactVariant = isTrustedPublicInstallation
            ? .publicInstalled
            : .development
        let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
            applicationVersion: applicationVersion,
            buildIdentifier: buildIdentifier,
            variant: variant,
            applicationBundleURL: bundleURL,
            applicationSupportURL: applicationSupportURL
        )
        windowsMediaHealth = await Task.detached(priority: .utility) {
            ComponentHealthService.evaluate(descriptor)
        }.value
    }

    func startSteam() async {
        guard let installations else { return }
        invalidatePhysicalLibraryCustodyAssessment(
            notice: "La evaluación se descartó porque Steam se está iniciando. Repítela cuando Steam esté cerrado."
        )
        LifecycleDiagnostics.write("startSteam invocado")
        logger.info("startSteam con \(self.selectedBackend.rawValue)")
        failure = nil
        libraryFailureDetail = nil
        if runningState.activeBackend != nil {
            showSteam()
            return
        }
        operation = .preparing("Iniciando Steam con \(selectedBackend.displayName)")
        statusDetail = selectedBackend == .regression
            ? "Regression está verificando el runtime y la botella antes de abrir Steam."
            : "El motor de comparación puede actualizar su botella antes de abrir Steam."
        do {
            let launch = try await coordinator.launchSteam(
                backend: selectedBackend,
                installations: installations
            )
            try await confirmSteamLaunch(launch)
            LifecycleDiagnostics.write("Steam confirmado")
            logger.info("Steam confirmado con \(launch.backend.rawValue)")
        } catch let RegressionCoreError.backendAlreadyRunning(backend) {
            runningState = await coordinator.runningState()
            operation = .running(backend)
            statusDetail = "Steam ya estaba abierto."
        } catch {
            LifecycleDiagnostics.write("Fallo: \(error.localizedDescription)")
            logger.error("Fallo al iniciar Steam: \(error.localizedDescription, privacy: .public)")
            presentLaunchError(error)
        }
    }

    func stopSteam() async {
        guard let installations, let activeBackend = runningState.activeBackend else { return }

        let alert = NSAlert()
        alert.messageText = "¿Cerrar Steam?"
        alert.informativeText = "Regression solicitará un cierre normal de Steam con \(activeBackend.displayName). Los juegos que sigan abiertos también deben cerrarse primero."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cerrar Steam")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        failure = nil
        libraryFailureDetail = nil
        operation = .preparing("Cerrando Steam")
        statusDetail = "Esperando a que Steam termine de forma segura…"
        do {
            try await coordinator.requestShutdown(
                backend: activeBackend,
                installations: installations,
                custodyValidationLease: activeBackend == .regression
                    ? physicalLibraryCustodyValidationLease
                    : nil
            )
            runningState = await coordinator.runningState()
            operation = .ready
            statusDetail = "Steam se cerró correctamente. Regression continúa disponible."
            await refreshStoredData()
        } catch {
            present(error)
        }
    }

    func launchGame(_ game: SteamGame) async {
        guard let installations else { return }
        let validationLease = libraryIndependenceState == .validating
            ? physicalLibraryCustodyValidationLease
            : nil
        if validationLease == nil {
            invalidatePhysicalLibraryCustodyAssessment(
                notice: "La evaluación se descartó porque se está iniciando un juego. Repítela con Steam cerrado."
            )
        }
        failure = nil
        libraryFailureDetail = nil
        operation = .preparing("Iniciando \(game.name)")
        statusDetail = "Registrando la configuración de compatibilidad antes del lanzamiento…"
        var registeredContext: RunContext?
        do {
            if let active = runningState.activeBackend, active != selectedBackend {
                let steamLaunch = try await coordinator.switchBackend(
                    from: active,
                    to: selectedBackend,
                    installations: installations,
                    custodyValidationLease: validationLease
                )
                try await confirmSteamLaunch(steamLaunch)
            }

            let metadata = try backendMetadata(
                installations: installations,
                backend: selectedBackend
            )
            let preparedCommand = try gameLaunchCommand(
                installations: installations,
                backend: selectedBackend,
                appID: game.appID
            )
            var configuration = await configurationCollector.snapshot(
                bottleURL: metadata.bottleURL,
                backend: selectedBackend,
                providerVersion: metadata.providerVersion,
                game: game,
                steamRootURL: selectedBackend == .crossOver
                    ? installations.crossOver?.steamRootURL
                    : installations.regression.steamRootURL
            )
            configuration.merge(
                configurationOverrides(installations: installations, backend: selectedBackend)
            ) { _, override in override }

            // Se ejecuta después de recopilar la configuración para que el diagnóstico refleje
            // el instante más cercano posible a la solicitud real de Steam.
            statusDetail = "Comprobando que el entorno de la prueba sea reproducible…"
            let preflightReport = try await collectTestReadiness(for: game)
            testReadiness = preflightReport
            guard preflightReport.status != .blocked else {
                throw RegressionCoreError.testEnvironmentBlocked(
                    preflightReport.blockingSummary
                )
            }

            let context = RunContext(
                appID: game.appID,
                gameName: game.name,
                backend: selectedBackend,
                bottleName: metadata.bottleName,
                providerVersion: metadata.providerVersion,
                command: PrivacySanitizer.normalizedPath(preparedCommand.executableURL.path),
                arguments: PrivacySanitizer.safeArguments(preparedCommand.arguments),
                system: currentSystemSnapshot(),
                configuration: configuration,
                configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
            )
            try await telemetry.registerLaunchIntent(context: context, bottleURL: metadata.bottleURL)
            registeredContext = context
            try await repository.recordPreflight(preflightReport, forRunID: context.id)
            _ = try await coordinator.launchSteam(
                backend: selectedBackend,
                installations: installations,
                appID: game.appID,
                custodyValidationLease: validationLease
            )
            operation = .running(selectedBackend)
            if validationLease != nil {
                libraryIndependenceState = .validating
            }
            statusDetail = preflightReport.warningCount == 0
                ? "Solicitud enviada a Steam. Regression observará el resultado localmente."
                : "Solicitud enviada con \(preflightReport.warningCount) aviso(s) documentados en el diagnóstico previo."
        } catch {
            if let registeredContext {
                do {
                    try await telemetry.cancelLaunchIntent(
                        context: registeredContext,
                        reason: error.localizedDescription
                    )
                } catch {
                    logger.error(
                        "No se pudo cerrar la intención fallida de telemetría: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            presentLaunchError(error)
        }
    }

    func startPhysicalLibraryCustodyMigration() async {
        guard let installations else { return }
        await refreshRuntimeState()
        guard runningState.activeBackend == nil else {
            libraryIndependenceState = .error(
                "Cierra Steam antes de trasladar la biblioteca."
            )
            return
        }

        libraryIndependenceState = .preCutover
        let alert = NSAlert()
        alert.messageText = "Trasladar los juegos a Regression"
        alert.informativeText =
            "La única carpeta física steamapps se trasladará a la botella propia de Regression. "
            + "No se copiarán 110 GB, las botellas no se compartirán y la instalación anterior "
            + "quedará sin juegos. El cambio se verificará antes de pedirte una prueba con Steam."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Trasladar sin duplicar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else {
            libraryIndependenceState = .eligible
            return
        }

        let legacyIdentity = PhysicalLibraryCustodyIdentity(
            legacySteamAppsURL: inheritedSteamAppsURL(for: installations)
        )
        await continuePhysicalLibraryCustodyMigration(
            installations: installations,
            legacyIdentity: legacyIdentity
        )
    }

    private func continuePhysicalLibraryCustodyMigration(
        installations: InstallationSnapshot,
        legacyIdentity: PhysicalLibraryCustodyIdentity
    ) async {
        failure = nil
        libraryFailureDetail = nil
        operation = .preparing("Trasladando la biblioteca")
        statusDetail = "Moviendo la única carpeta steamapps y conservando rollback verificable…"
        libraryIndependenceState = .preparing
        let manager = sharedLibrary
        physicalLibraryCustodyProgressTask?.cancel()
        physicalLibraryCustodyProgressTask = Task { [weak self, manager] in
            while !Task.isCancelled {
                let snapshot = await manager.currentPhysicalLibraryCustodyInterlock()
                guard !Task.isCancelled, let self else { return }
                self.applyPhysicalLibraryCustodyStatus(snapshot.status)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer {
            physicalLibraryCustodyProgressTask?.cancel()
            physicalLibraryCustodyProgressTask = nil
        }
        do {
            let assessment = try await manager.migratePhysicalCustody(
                regression: installations.regression,
                legacyIdentity: legacyIdentity,
                runningStateProvider: { [coordinator] in
                    await coordinator.runningState()
                }
            )
            physicalLibraryCustodyAssessment = assessment
            applyPhysicalLibraryCustodyStatus(assessment.status)
            operation = .ready
            statusDetail =
                "Traslado estructural verificado. Falta validar Steam y un juego con Regression."
            selectedBackend = .regression
            UserDefaults.standard.set(BackendKind.regression.rawValue, forKey: "selectedBackend")
            await refreshGames()
        } catch {
            libraryIndependenceState = .error(error.localizedDescription)
            present(error)
        }
    }

    func beginPhysicalLibraryCustodyValidation() async {
        guard let installations else { return }
        failure = nil
        libraryFailureDetail = nil
        await refreshRuntimeState()
        let identity = PhysicalLibraryCustodyIdentity(
            legacySteamAppsURL: inheritedSteamAppsURL(for: installations)
        )
        do {
            let lease = try await sharedLibrary.beginPhysicalCustodyValidation(
                regression: installations.regression,
                legacyIdentity: identity,
                runningState: runningState
            )
            physicalLibraryCustodyValidationLease = lease
            selectedBackend = .regression
            UserDefaults.standard.set(BackendKind.regression.rawValue, forKey: "selectedBackend")
            libraryIndependenceState = .validating
            operation = .preparing("Abriendo Steam para validar")
            statusDetail = "Iniciando exclusivamente el Steam de Regression…"
            let launch = try await coordinator.launchSteam(
                backend: .regression,
                installations: installations,
                custodyValidationLease: lease
            )
            try await confirmSteamLaunch(launch)
            libraryIndependenceState = .validating
            statusDetail =
                "Comprueba tienda, biblioteca y un juego protegido; después confirma la validación."
        } catch {
            if physicalLibraryCustodyValidationLease != nil {
                libraryIndependenceState = .validating
                statusDetail =
                    "Steam no se abrió para validar: \(error.localizedDescription)"
            } else {
                libraryIndependenceState = .error(error.localizedDescription)
            }
            present(error)
        }
    }

    func finalizePhysicalLibraryCustodyValidation() async {
        guard let installations, let lease = physicalLibraryCustodyValidationLease else {
            libraryIndependenceState = .error(
                "No existe una autorización activa para finalizar la validación."
            )
            return
        }
        failure = nil
        libraryFailureDetail = nil
        let alert = NSAlert()
        alert.messageText = "¿Regression funciona correctamente?"
        alert.informativeText =
            "Confirma solo después de comprobar visualmente la tienda de Steam, la biblioteca "
            + "instalada y gameplay real de un juego protegido. Si algo falla, Regression "
            + "restaurará la ubicación anterior."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Validación superada")
        alert.addButton(withTitle: "Restaurar biblioteca")
        alert.addButton(withTitle: "Seguir comprobando")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let validationPassed = response == .alertFirstButtonReturn

        operation = .preparing(
            validationPassed ? "Finalizando la independencia" : "Restaurando la biblioteca"
        )
        libraryIndependenceState = validationPassed ? .verifying : .rollingBack
        statusDetail = "Cerrando Steam antes de confirmar la topología física…"
        do {
            if runningState.regressionIsRunning {
                try await coordinator.requestShutdown(
                    backend: .regression,
                    installations: installations,
                    custodyValidationLease: lease
                )
            }
            runningState = await coordinator.runningState()
            let identity = PhysicalLibraryCustodyIdentity(
                legacySteamAppsURL: inheritedSteamAppsURL(for: installations)
            )
            let assessment = try await sharedLibrary.finalizePhysicalCustody(
                regression: installations.regression,
                legacyIdentity: identity,
                validationLease: lease,
                validationPassed: validationPassed,
                runningState: runningState
            )
            physicalLibraryCustodyValidationLease = nil
            physicalLibraryCustodyAssessment = assessment
            applyPhysicalLibraryCustodyStatus(assessment.status)
            operation = .ready
            statusDetail = validationPassed
                ? "Regression es independiente y conserva la única instalación de los juegos."
                : "La biblioteca anterior se restauró sin duplicar los juegos."
            await refreshGames()
        } catch {
            libraryIndependenceState = .validating
            statusDetail =
                "No se pudo finalizar la validación: \(error.localizedDescription)"
            present(error)
        }
    }

    func rollbackPhysicalLibraryCustody() async {
        guard let installations else { return }
        let alert = NSAlert()
        alert.messageText = "¿Restaurar la ubicación anterior?"
        alert.informativeText =
            "Steam debe estar cerrado. Regression moverá la misma carpeta física a su origen y "
            + "restaurará el enlace anterior; no creará una copia de los juegos."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restaurar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await refreshRuntimeState()
        guard runningState.activeBackend == nil else {
            libraryIndependenceState = .error("Cierra Steam antes de restaurar la biblioteca.")
            return
        }
        await continuePhysicalLibraryCustodyRollback(installations: installations)
    }

    private func continuePhysicalLibraryCustodyRollback(
        installations: InstallationSnapshot
    ) async {
        failure = nil
        libraryFailureDetail = nil
        libraryIndependenceState = .rollingBack
        operation = .preparing("Restaurando la biblioteca")
        do {
            let assessment = try await sharedLibrary.rollbackPhysicalCustody(
                regression: installations.regression,
                legacyIdentity: PhysicalLibraryCustodyIdentity(
                    legacySteamAppsURL: inheritedSteamAppsURL(for: installations)
                ),
                runningState: runningState
            )
            physicalLibraryCustodyValidationLease = nil
            physicalLibraryCustodyAssessment = assessment
            applyPhysicalLibraryCustodyStatus(assessment.status)
            operation = .ready
            statusDetail = "La ubicación anterior se restauró sin duplicar los juegos."
            await refreshGames()
        } catch {
            libraryIndependenceState = .error(error.localizedDescription)
            present(error)
        }
    }

    /// Inspecciona la topología sin modificarla. Core deriva el único destino válido dentro de
    /// la botella de Regression; la UI nunca puede inyectar una ruta alternativa.
    func assessPhysicalLibraryCustody() async {
        guard let installations, physicalLibraryCustodyAssessmentTask == nil else { return }

        failure = nil
        libraryFailureDetail = nil
        await refreshRuntimeState()
        guard runningState.activeBackend == nil else {
            physicalLibraryCustodyAssessment = nil
            physicalLibraryCustodyAssessmentNotice =
                "Cierra Steam antes de evaluar la custodia de la biblioteca."
            libraryIndependenceState = .error(
                "Cierra Steam antes de evaluar la custodia de la biblioteca."
            )
            return
        }

        let legacySteamAppsURL = inheritedSteamAppsURL(for: installations)
        let assessmentID = UUID()
        let manager = sharedLibrary
        let regression = installations.regression
        let currentRunningState = runningState

        physicalLibraryCustodyAssessment = nil
        physicalLibraryCustodyAssessmentNotice = nil
        physicalLibraryCustodyAssessmentIsRunning = true
        libraryIndependenceState = .preparing
        physicalLibraryCustodyAssessmentID = assessmentID
        physicalLibraryCustodyAssessmentTask = Task { [weak self, manager] in
            let assessment = await manager.assessPhysicalCustody(
                regression: regression,
                legacyIdentity: PhysicalLibraryCustodyIdentity(
                    legacySteamAppsURL: legacySteamAppsURL
                ),
                runningState: currentRunningState
            )

            guard !Task.isCancelled, let self,
                  self.physicalLibraryCustodyAssessmentID == assessmentID
            else { return }

            let latestRunningState = await self.coordinator.runningState()
            let currentLegacySteamAppsURL = self.installations.map(self.inheritedSteamAppsURL)
            guard latestRunningState.activeBackend == nil,
                  currentLegacySteamAppsURL?.standardizedFileURL == legacySteamAppsURL.standardizedFileURL
            else {
                self.physicalLibraryCustodyAssessment = nil
                self.physicalLibraryCustodyAssessmentNotice =
                    "La evaluación se descartó porque Steam o la ubicación de la biblioteca cambiaron."
                self.libraryIndependenceState = .error(
                    "Steam o la ubicación de la biblioteca cambiaron durante el inventario."
                )
                self.physicalLibraryCustodyAssessmentIsRunning = false
                self.physicalLibraryCustodyAssessmentTask = nil
                self.physicalLibraryCustodyAssessmentID = nil
                return
            }

            self.physicalLibraryCustodyAssessment = assessment
            self.applyPhysicalLibraryCustodyStatus(assessment.status)
            self.physicalLibraryCustodyAssessmentNotice = nil
            self.physicalLibraryCustodyAssessmentIsRunning = false
            self.physicalLibraryCustodyAssessmentTask = nil
            self.physicalLibraryCustodyAssessmentID = nil
        }
        await physicalLibraryCustodyAssessmentTask?.value
    }

    func cancelPhysicalLibraryCustodyAssessment() {
        guard physicalLibraryCustodyAssessmentTask != nil
                || physicalLibraryCustodyAssessment != nil
        else { return }
        invalidatePhysicalLibraryCustodyAssessment(notice: "Evaluación de custodia cancelada.")
        libraryIndependenceState = .eligible
    }

    private func invalidatePhysicalLibraryCustodyAssessment(notice: String) {
        physicalLibraryCustodyAssessmentTask?.cancel()
        physicalLibraryCustodyAssessmentTask = nil
        physicalLibraryCustodyAssessmentID = nil
        physicalLibraryCustodyAssessmentIsRunning = false
        physicalLibraryCustodyAssessment = nil
        physicalLibraryCustodyAssessmentNotice = notice
    }

    private func applyPhysicalLibraryCustodyStatus(_ status: PhysicalLibraryCustodyStatus) {
        let nextState: LibraryIndependenceState = switch status {
        case .eligibleForTransfer: .eligible
        case .preparing: .preparing
        case .preCutover: .preCutover
        case .cutover: .cutover
        case .verifying: .verifying
        case .pendingValidation: .pendingValidation
        case .validating: .validating
        case .rollingBack: .rollingBack
        case .independent: .independent
        case let .blocked(reason): .error(reason)
        }
        if libraryIndependenceState != nextState {
            libraryIndependenceState = nextState
        }
    }

    private func inheritedSteamAppsURL(for installations: InstallationSnapshot) -> URL {
        let regressionSteamAppsURL = installations.regression.steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: regressionSteamAppsURL.path
        ) {
            if destination.hasPrefix("/") {
                return URL(fileURLWithPath: destination, isDirectory: true)
            }
            return regressionSteamAppsURL.deletingLastPathComponent()
                .appendingPathComponent(destination, isDirectory: true)
        }
        if let observedSource = sharedLibraryAssessment?.crossOverSteamAppsURL,
           FileManager.default.fileExists(atPath: observedSource.path) {
            return observedSource
        }
        if let crossOver = installations.crossOver {
            return crossOver.steamRootURL.appendingPathComponent("steamapps", isDirectory: true)
        }

        // Último recurso para preservar una identidad heredada sin requerir la app comparadora.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps",
                isDirectory: true
            )
    }

    func exportCompatibilityData() async {
        let panel = NSSavePanel()
        panel.title = "Exportar perfiles de compatibilidad"
        panel.nameFieldStringValue = "regression-compatibilidad.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await repository.exportJSON(to: url)
            statusDetail = "Datos exportados sin credenciales ni identificadores de cuenta."
        } catch {
            present(error)
        }
    }

    func verifyRun(_ run: RunSummary, verdict: VerificationVerdict) async {
        var notes = ""
        if verdict == .perfect {
            guard run.processID != nil, run.result != .preparing else {
                statusDetail = "Esta ejecución no llegó a iniciarse y no puede crear un blindado."
                return
            }
            let alert = NSAlert()
            alert.messageText = "¿Confirmar que \(run.gameName) funciona perfectamente?"
            alert.informativeText = "Esto crea un blindado persistente para esta ejecución exacta de \(run.backend.displayName). Confirma solo después de comprobar visualmente render, precisión de entrada, opciones gráficas y gameplay. El blindado garantiza funcionamiento reproducible, no que sea todavía la opción de mayor rendimiento."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Guardar como perfecto")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else {
            let alert = NSAlert()
            alert.messageText = verdict == .failed
                ? "¿Qué impidió que funcionara?"
                : "¿Qué incidencia observaste?"
            alert.informativeText = "Este detalle ayuda a comparar configuraciones sin aplicar cambios automáticamente."
            alert.alertStyle = verdict == .failed ? .warning : .informational
            alert.addButton(withTitle: "Guardar")
            alert.addButton(withTitle: "Cancelar")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "Ej.: pantalla negra, clic desplazado o resolución incorrecta"
            alert.accessoryView = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            notes = field.stringValue
        }

        guard verdict != .invalidated else { return }
        let evidence = VerificationEvidence.manualDefault(for: verdict)
        let verification = RunVerification(
            runID: run.id,
            verdict: verdict,
            rendering: evidence.rendering,
            inputPrecision: evidence.inputPrecision,
            graphicsSettings: evidence.graphicsSettings,
            gameplay: evidence.gameplay,
            source: .user,
            notes: verdict == .perfect ? "Verificación manual completa" : notes
        )

        do {
            try await repository.verifyRun(verification)
            await refreshStoredData(includeHealth: true)
            statusDetail = verdict == .perfect
                ? "\(run.gameName) quedó blindado de forma persistente con \(run.backend.displayName)."
                : "La verificación de \(run.gameName) quedó guardada localmente."
        } catch {
            present(error)
        }
    }

    func toggleAutoLaunch(_ enabled: Bool) {
        autoLaunchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoLaunchEnabled")
    }

    func togglePublicCatalog(_ enabled: Bool) {
        publicCatalogEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "publicCatalogEnabled")
        if enabled {
            publicCatalogOperation = .idle
            schedulePublicCatalogSync()
        } else {
            externalCatalogTask?.cancel()
            externalCatalogTask = nil
            externalCatalogSyncID = nil
            publicCatalogOperation = .disabled
        }
    }

    func refreshPublicCatalog() {
        guard publicCatalogEnabled, externalCatalogTask == nil else { return }
        schedulePublicCatalogSync(force: true)
    }

    func shutdown() async {
        guard !shutdownIsComplete else { return }
        logger.notice("Cancelando tareas de monitorización y catálogo")
        cancelPhysicalLibraryCustodyAssessment()
        while physicalLibraryCustodyProgressTask != nil {
            statusDetail =
                "Terminando el punto seguro de custodia antes de cerrar Regression…"
            try? await Task.sleep(for: .milliseconds(100))
        }
        let monitoring = monitoringTask
        monitoringTask = nil
        monitoring?.cancel()

        let catalog = externalCatalogTask
        externalCatalogTask = nil
        externalCatalogSyncID = nil
        catalog?.cancel()

        regressionUpdateTask?.cancel()
        regressionUpdateTask = nil
        automaticRegressionUpdateTask?.cancel()
        automaticRegressionUpdateTask = nil

        // No esperar indefinidamente a tareas de red ya canceladas. Las operaciones SQLite
        // pendientes se serializan en el actor del repositorio antes del cierre; al terminar
        // esta función AppKit finalizará el proceso y no podrá aparecer trabajo nuevo.
        await Task.yield()
        do {
            try await repository.reconcileInterruptedRuns(
                reason: "Regression se cerró antes de recibir el cierre del proceso."
            )
            try await repository.close()
            logger.notice("Base local cerrada limpiamente")
        } catch {
            logger.error(
                "No se pudo cerrar limpiamente la base local: \(error.localizedDescription, privacy: .public)"
            )
        }
        shutdownIsComplete = true
    }

    func openPublicCatalog() {
        NSWorkspace.shared.open(CodeWeaversCompatibilityProvider.codeWeaversSource.baseURL)
    }

    func refreshRegressionReleaseStatus() {
        scheduleRegressionReleaseCheck(force: true)
    }

    func toggleAutomaticRegressionUpdates(_ enabled: Bool) {
        automaticRegressionUpdatesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticRegressionUpdatesEnabled")
        if enabled {
            scheduleAutomaticRegressionUpdateIfPossible()
        }
    }

    func installAvailableRegressionUpdate() async {
        guard case let .available(_, release) = regressionReleaseStatus else { return }
        guard !libraryIndependenceState.blocksNormalOperations else {
            regressionReleaseStatus = .failed(
                message: "Termina la custodia o el rollback de la biblioteca antes de actualizar Regression."
            )
            return
        }
        guard !operation.isBusy else {
            regressionReleaseStatus = .failed(
                message: "Espera a que termine la operación activa antes de actualizar Regression."
            )
            return
        }
        guard !runningState.regressionIsRunning else {
            regressionReleaseStatus = .failed(
                message: "Cierra Steam del motor Regression antes de actualizar la aplicación."
            )
            return
        }

        regressionReleaseStatus = .downloading(version: release.version)
        do {
            let updateDirectory = applicationSupportURL
                .appendingPathComponent("Updates", isDirectory: true)
                .appendingPathComponent("v\(release.version)", isDirectory: true)
            let installerURL = try await regressionReleaseService.downloadInstaller(
                for: release,
                to: updateDirectory
            )
            let logURL = updateDirectory.appendingPathComponent("install.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
            let log = try FileHandle(forWritingTo: logURL)
            try log.truncate(atOffset: 0)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [
                installerURL.path,
                "--yes",
                "--launch",
                "--wait-for-pid",
                String(ProcessInfo.processInfo.processIdentifier),
            ]
            process.standardOutput = log
            process.standardError = log
            UserDefaults.standard.set(release.version, forKey: lastAttemptedRegressionReleaseKey)
            do {
                try process.run()
            } catch {
                UserDefaults.standard.removeObject(forKey: lastAttemptedRegressionReleaseKey)
                try? log.close()
                throw error
            }
            try? log.close()
            regressionReleaseStatus = .installing(version: release.version)
            // AppKit no puede esperar una tarea MainActor de cierre mientras terminate(_:) se
            // ejecuta desde esta misma tarea. Cerramos el estado antes y el delegate puede
            // responder .terminateNow sin entrar en el ciclo reentrante de terminateLater.
            automaticRegressionUpdateTask = nil
            await shutdown()
            NSApplication.shared.terminate(nil)
        } catch {
            regressionReleaseStatus = .failed(message: error.localizedDescription)
        }
    }

    func openExternalCompatibility(for game: SteamGame) {
        if let url = externalURL(for: game) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(
                CodeWeaversCompatibilityProvider.publicSearchURL(for: game.name)
                    ?? CodeWeaversCompatibilityProvider.codeWeaversSource.baseURL
            )
        }
    }

    func openDataFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Regression", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    func showSteam() {
        let candidates = NSWorkspace.shared.runningApplications.filter { application in
            let name = application.localizedName?.lowercased() ?? ""
            let path = application.executableURL?.path.lowercased() ?? ""
            return name.contains("steam") && (path.contains("crossover") || path.contains("regression"))
        }
        .sorted { left, right in
            let leftScore = steamActivationScore(left)
            let rightScore = steamActivationScore(right)
            if leftScore != rightScore { return leftScore > rightScore }
            return left.processIdentifier < right.processIdentifier
        }
        if let application = candidates.first {
            application.activate(options: [.activateAllWindows])
        } else {
            Task { await startSteam() }
        }
    }

    func recover(_ recovery: UserFacingFailure.Recovery) async {
        switch recovery {
        case .refresh: await refreshAll()
        }
    }

    private func confirmSteamLaunch(_ launch: BackendLaunch) async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            runningState = await coordinator.runningState()
            if runningState.activeBackend == launch.backend {
                operation = .running(launch.backend)
                statusDetail = "Steam se inició mediante el backend oficial seleccionado."
                return
            }
            if runningState.hasConflict { throw RegressionCoreError.backendConflict }
        }
        let excerpt = await processLogReader.redactedExcerpt(at: launch.logURL)
        throw RegressionCoreError.launchFailed(excerpt.isEmpty ? "Steam no apareció tras 30 segundos" : excerpt)
    }

    private func periodicRefresh() async {
        periodicRefreshCount += 1
        await refreshRuntimeState()
        let telemetryChanged = await pollTelemetry()
        await processLauncher.reapFinishedProcesses()
        if periodicRefreshCount.isMultiple(of: 5) {
            await refreshSharedLibraryAssessment()
        }
        if periodicRefreshCount.isMultiple(of: 30) {
            let previousAppIDs = Set(games.map(\.appID))
            await refreshGames()
            if Set(games.map(\.appID)) != previousAppIDs {
                schedulePublicCatalogSync()
            }
        }
        if telemetryChanged || periodicRefreshCount.isMultiple(of: 15) {
            await refreshStoredData(includeHealth: periodicRefreshCount.isMultiple(of: 900))
        }
        if periodicRefreshCount.isMultiple(of: regressionUpdateCheckCycle) {
            scheduleRegressionReleaseCheck()
        }
    }

    private func refreshRuntimeState() async {
        runningState = await coordinator.runningState()
        if runningState.hasConflict {
            present(RegressionCoreError.backendConflict)
        } else if let active = runningState.activeBackend {
            if !operation.isBusy { operation = .running(active) }
        } else if case .running = operation {
            operation = .ready
            statusDetail = "Steam se ha cerrado. Regression permanece disponible en la barra de menús."
            await refreshStoredData()
        }
        scheduleAutomaticRegressionUpdateIfPossible()
    }

    private func refreshGames() async {
        guard let snapshot = installations else {
            regressionGames = []
            games = []
            return
        }
        let discoveredAt = snapshot.discoveredAt
        let refreshedRegressionGames = await libraryScanner.games(
            in: snapshot.regression.steamRootURL,
            backend: .regression
        )

        // Una detección más reciente tiene prioridad sobre esta lectura de disco ya iniciada.
        guard installations?.discoveredAt == discoveredAt else { return }
        regressionGames = refreshedRegressionGames
        games = regressionGames.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        do {
            try await repository.reconcileDiscoveredGames(games)
        } catch {
            logger.error(
                "No se pudieron reconciliar los nombres públicos: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func beginTelemetryMonitoring() async {
        guard let installations else { return }
        await telemetry.beginMonitoring(
            logURL: installations.regression.steamRootURL.appendingPathComponent("logs/gameprocess_log.txt")
        )
    }

    private func pollTelemetry() async -> Bool {
        guard let installations else { return false }
        let system = currentSystemSnapshot()
        var outcome = TelemetryPollOutcome()
        let regression = installations.regression
        outcome.merge(await telemetry.poll(
            backend: .regression,
            logURL: regression.steamRootURL.appendingPathComponent("logs/gameprocess_log.txt"),
            games: regressionGames,
            system: system,
            steamRootURL: regression.steamRootURL,
            bottleURL: regression.bottleURL,
            bottleName: "Steam",
            providerVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        ))

        for issue in outcome.issues {
            logger.error("Telemetría local: \(issue, privacy: .public)")
        }
        for start in outcome.unpreparedRunStarts {
            await recordObservedSteamPreflight(start)
        }
        return outcome.changed
    }

    /// El cliente completo de Steam permite pulsar «Jugar» sin pasar por el botón de Regression.
    /// No se finge un hook previo inexistente: la instantánea se toma en cuanto aparece el primer
    /// proceso y queda etiquetada con su fase y latencia exactas.
    private func recordObservedSteamPreflight(_ start: TelemetryObservedRunStart) async {
        let game = regressionGames.first { $0.appID == start.appID }
        do {
            let report = try await collectTestReadiness(
                for: game,
                backend: start.backend,
                targetAppID: start.appID,
                targetGameName: start.gameName,
                capturePhase: .processStartBoundary,
                processStartedAt: start.processStartedAt
            )
            try await repository.recordPreflight(report, forRunID: start.runID)
        } catch {
            logger.error(
                "No se pudo vincular el diagnóstico observado del App ID \(start.appID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func refreshStoredData(includeHealth: Bool = false) async {
        do {
            let refreshedRuns = try await repository.recentRuns()
            let refreshedProfiles = try await repository.compatibilityProfiles()
            let refreshedEngines = try await repository.engineProfiles()
            let refreshedCertifications = try await repository.certifications()
            let refreshedTechnologies = try await repository.runtimeTechnologies()
            let refreshedActiveCandidateCount = try await repository.runtimeCandidateCount(
                activeOnly: true
            )
            let refreshedActiveResearchCaseCount = try await repository.researchCaseCount(
                activeOnly: true
            )
            let refreshedActiveResearchExperimentCount = try await repository
                .researchExperimentCount(activeOnly: true)
            let refreshedExternalEntries = try await repository.externalEntries(
                sourceID: CodeWeaversCompatibilityProvider.codeWeaversSource.id
            )
            let refreshedComparisons = try await repository.compatibilityComparisons()
            let refreshedHealth = includeHealth ? try await repository.databaseHealth() : nil
            recentRuns = refreshedRuns
            profiles = refreshedProfiles
            engineProfiles = refreshedEngines
            certifications = refreshedCertifications
            runtimeTechnologies = refreshedTechnologies
            activeRuntimeCandidateCount = refreshedActiveCandidateCount
            activeResearchCaseCount = refreshedActiveResearchCaseCount
            activeResearchExperimentCount = refreshedActiveResearchExperimentCount
            profilesByAppID = Dictionary(grouping: refreshedProfiles, by: \.appID)
            certificationsByAppID = Dictionary(grouping: refreshedCertifications, by: \.appID)
            externalCatalogEntries = Dictionary(
                uniqueKeysWithValues: refreshedExternalEntries.map { ($0.appID, $0) }
            )
            compatibilityComparisons = refreshedComparisons
            if let refreshedHealth { databaseHealth = refreshedHealth }
        } catch {
            // Una lectura transitoria no debe borrar en pantalla el último estado válido.
            logger.error(
                "No se pudieron actualizar los datos locales: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func schedulePublicCatalogSync(force: Bool = false) {
        guard publicCatalogEnabled, externalCatalogTask == nil, !games.isEmpty else {
            if !publicCatalogEnabled { publicCatalogOperation = .disabled }
            return
        }
        let gamesToSync = games
        let syncID = UUID()
        externalCatalogSyncID = syncID
        externalCatalogTask = Task { [weak self] in
            guard let self else { return }
            await self.runPublicCatalogSync(games: gamesToSync, force: force, syncID: syncID)
        }
    }

    private func runPublicCatalogSync(games: [SteamGame], force: Bool, syncID: UUID) async {
        var failures = 0
        var lastSuccess: Date?
        for (offset, game) in games.enumerated() {
            guard !Task.isCancelled else { break }
            publicCatalogOperation = .syncing(
                current: offset + 1,
                total: games.count,
                gameName: game.name
            )
            switch await externalCatalog.refresh(game: game, force: force) {
            case .freshCache:
                break
            case .updated:
                lastSuccess = Date()
            case .noMatch:
                break
            case .failed:
                // Si la fuente no responde, insistir con el resto de la biblioteca solo
                // alargaría la espera y consumiría peticiones sin aportar información.
                failures += games.count - offset
                finishPublicCatalogSync(
                    syncID: syncID,
                    failures: failures,
                    lastSuccess: lastSuccess
                )
                return
            case .cancelled:
                finishPublicCatalogSync(syncID: syncID, failures: failures, lastSuccess: lastSuccess)
                return
            }
            await refreshStoredData()
        }
        finishPublicCatalogSync(syncID: syncID, failures: failures, lastSuccess: lastSuccess)
    }

    private func finishPublicCatalogSync(
        syncID: UUID,
        failures: Int,
        lastSuccess: Date?
    ) {
        // Una tarea cancelada no puede borrar ni reemplazar el estado de una
        // sincronización nueva que el usuario haya iniciado inmediatamente después.
        guard externalCatalogSyncID == syncID else { return }
        externalCatalogTask = nil
        externalCatalogSyncID = nil
        guard publicCatalogEnabled else {
            publicCatalogOperation = .disabled
            return
        }
        publicCatalogOperation = failures > 0
            ? .completedWithIssues(failures)
            : .upToDate(lastSuccess)
    }

    private func refreshSharedLibraryAssessment() async {
        guard let installations, let crossOver = installations.crossOver else {
            sharedLibraryAssessment = nil
            return
        }
        sharedLibraryAssessment = await sharedLibrary.assess(
            regression: installations.regression,
            crossOver: crossOver
        )
    }

    private func scheduleRegressionReleaseCheck(force: Bool = false) {
        guard regressionUpdateTask == nil || force else { return }
        regressionUpdateTask?.cancel()
        regressionReleaseStatus = .checking
        regressionUpdateTask = Task { [weak self] in
            guard let self else { return }
            let installedVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "1.7.4"
            do {
                let status = try await regressionReleaseService.check(
                    installedVersion: installedVersion
                )
                guard !Task.isCancelled else { return }
                regressionReleaseStatus = status
                if case let .available(_, release) = status {
                    let decision = automaticRegressionUpdateDecision
                    scheduleAutomaticRegressionUpdateIfPossible()
                    if decision != .installNow {
                        await notifyAboutAvailableRegressionRelease(
                            release,
                            automaticDecision: decision
                        )
                    }
                } else if case .upToDate = status {
                    UserDefaults.standard.removeObject(forKey: lastAttemptedRegressionReleaseKey)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                regressionReleaseStatus = .failed(message: error.localizedDescription)
            }
            regressionUpdateTask = nil
        }
    }

    private var automaticRegressionUpdateDecision: RegressionAutomaticUpdateDecision {
        RegressionAutomaticUpdatePolicy.decision(
            enabled: automaticRegressionUpdatesEnabled,
            canonicalInstallation: isCanonicalApplicationInstallation,
            regressionIsRunning: runningState.regressionIsRunning,
            applicationIsBusy: operation.isBusy
                || libraryIndependenceState.blocksNormalOperations,
            lastAttemptedVersion: UserDefaults.standard.string(
                forKey: lastAttemptedRegressionReleaseKey
            ),
            status: regressionReleaseStatus
        )
    }

    private var isCanonicalApplicationInstallation: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Regression.app"
    }

    private func scheduleAutomaticRegressionUpdateIfPossible() {
        guard automaticRegressionUpdateDecision == .installNow,
              automaticRegressionUpdateTask == nil else { return }
        automaticRegressionUpdateTask = Task { [weak self] in
            guard let self else { return }
            await installAvailableRegressionUpdate()
            automaticRegressionUpdateTask = nil
        }
    }

    private func waitBrieflyForInitialRegressionReleaseCheck() async {
        guard regressionUpdateTask != nil else { return }
        for _ in 0..<20 {
            guard regressionUpdateTask != nil,
                  case .checking = regressionReleaseStatus,
                  !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func notifyAboutAvailableRegressionRelease(
        _ release: RegressionRelease,
        automaticDecision: RegressionAutomaticUpdateDecision
    ) async {
        let defaultsKey = "lastNotifiedRegressionRelease"
        guard UserDefaults.standard.string(forKey: defaultsKey) != release.version else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied, .ephemeral:
            authorized = false
        @unknown default:
            authorized = false
        }
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Regression \(release.version) disponible"
        switch automaticDecision {
        case .waitForIdle:
            content.body = "Se instalará automáticamente cuando Steam de Regression quede en reposo."
        case .requiresCanonicalInstallation:
            content.body = "Abre la instalación canónica de Regression para completar la actualización."
        case .manualRetryRequired:
            content.body = "La actualización anterior no terminó. Reinténtala desde Mantenimiento."
        case .disabled, .noUpdate, .installNow:
            content.body = "Abre Regression para actualizar sin perder tu botella, juegos ni Switch2Bridge."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "regression-release-v\(release.version)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            UserDefaults.standard.set(release.version, forKey: defaultsKey)
        } catch {
            logger.error(
                "No se pudo mostrar la notificación de Regression \(release.version): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func collectTestReadiness(
        for game: SteamGame?,
        backend: BackendKind? = nil,
        targetAppID: String? = nil,
        targetGameName: String? = nil,
        capturePhase: GameTestPreflightCapturePhase = .preLaunch,
        processStartedAt: Date? = nil
    ) async throws -> GameTestPreflightReport {
        guard let installations else {
            throw RegressionCoreError.launchFailed("Las instalaciones aún no se han detectado")
        }
        let health = try await repository.databaseHealth()
        databaseHealth = health
        let evaluatedBackend = backend ?? selectedBackend
        return await preflight.evaluate(
            backend: evaluatedBackend,
            installations: installations,
            runningState: runningState,
            databaseHealth: health,
            sharedLibraryAssessment: sharedLibraryAssessment,
            physicalCustodyAssessment: physicalLibraryCustodyAssessment,
            game: game,
            targetAppID: targetAppID,
            targetGameName: targetGameName,
            capturePhase: capturePhase,
            processStartedAt: processStartedAt
        )
    }

    private func backendMetadata(
        installations: InstallationSnapshot,
        backend: BackendKind
    ) throws -> (bottleURL: URL, bottleName: String, providerVersion: String) {
        switch backend {
        case .crossOver:
            guard let crossOver = installations.crossOver else {
                throw RegressionCoreError.crossOverNotInstalled
            }
            return (crossOver.bottleURL, crossOver.bottleName, crossOver.version)
        case .regression:
            return (
                installations.regression.bottleURL,
                "Steam",
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            )
        }
    }

    private func gameLaunchCommand(
        installations: InstallationSnapshot,
        backend: BackendKind,
        appID: String
    ) throws -> SteamCommand {
        guard let normalizedAppID = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.launchFailed("El Steam App ID no es válido")
        }
        let arguments = ["-applaunch", normalizedAppID]
        switch backend {
        case .crossOver:
            guard let crossOver = installations.crossOver else {
                throw RegressionCoreError.crossOverNotInstalled
            }
            return BackendCommandFactory.crossOver(
                installation: crossOver,
                steamArguments: arguments
            )
        case .regression:
            return BackendCommandFactory.regression(
                installation: installations.regression,
                steamArguments: arguments
            )
        }
    }

    private func configurationOverrides(
        installations: InstallationSnapshot,
        backend: BackendKind
    ) -> [String: String] {
        guard backend == .crossOver,
              let value = installations.crossOver?.defaultGraphicsBackend else { return [:] }
        return ["graphics.crossover.default_probe": value]
    }

    private func steamActivationScore(_ application: NSRunningApplication) -> Int {
        let name = application.localizedName?.lowercased() ?? ""
        let path = application.executableURL?.path.lowercased() ?? ""
        var score = 0
        if name == "steam" || name == "steam.exe" { score += 100 }
        if !name.contains("webhelper") && !name.contains("service") { score += 20 }
        if application.activationPolicy == .regular { score += 10 }
        switch runningState.activeBackend {
        case .crossOver where path.contains("crossover"): score += 5
        case .regression where path.contains("regression"): score += 5
        default: break
        }
        return score
    }

    private func currentSystemSnapshot() -> SystemSnapshot {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 1
        let width = Int((screen?.frame.width ?? 0) * scale)
        let height = Int((screen?.frame.height ?? 0) * scale)
        return SystemSnapshot(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: SystemInformation.architecture,
            deviceModel: SystemInformation.deviceModel(),
            displayWidth: width,
            displayHeight: height,
            displayScale: scale
        )
    }

    private func presentLaunchError(_ error: Error) {
        present(error)
    }

    private func present(_ error: Error) {
        logger.error("Error presentado: \(error.localizedDescription, privacy: .public)")
        failure = UserFacingFailure(
            title: "No se pudo completar la operación",
            message: error.localizedDescription,
            recovery: .refresh
        )
        if case let .unsafeLibraryState(detail)? = error as? RegressionCoreError {
            libraryFailureDetail = detail
        } else {
            libraryFailureDetail = nil
        }
        operation = .error
        statusDetail = error.localizedDescription
    }
}
