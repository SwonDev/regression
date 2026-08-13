import AppKit
import CryptoKit
import Observation
import OSLog
import RegressionCore
import SwiftUI
import UniformTypeIdentifiers
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
        case repairRegression
        case prepareAppleGPTK
        case reviewProtectedAppleGPTK
        case reinstallRegression
    }

    let title: String
    let message: String
    let recovery: Recovery
}

enum AppleGPTKLicenseReviewSource: Equatable {
    case diskImage(descriptor: AppleGPTKInspectionDescriptor, sourceURL: URL)
    case protectedExisting(descriptor: AppleGPTKExistingComponentInspectionDescriptor)

    var version: String {
        switch self {
        case .diskImage(let descriptor, _): descriptor.version
        case .protectedExisting(let descriptor): descriptor.version
        }
    }

    var confirmationValue: String {
        switch self {
        case .diskImage: AppleGPTKAuthorizationToken.confirmationValue
        case .protectedExisting: AppleGPTKExistingComponentAuthorizationToken.confirmationValue
        }
    }

    var sourceDescription: String {
        switch self {
        case .diskImage(_, let sourceURL):
            "Documento exacto extraído del DMG verificado · \(sourceURL.lastPathComponent)"
        case .protectedExisting:
            "Documento exacto del componente protegido que ya custodia Regression"
        }
    }

    var isProtectedExisting: Bool {
        if case .protectedExisting = self { return true }
        return false
    }
}

struct AppleGPTKLicenseReview: Identifiable, Equatable {
    let id: UUID
    let source: AppleGPTKLicenseReviewSource
    let inspectionDirectoryURL: URL
    let licenseRTFData: Data
}

enum ProtectedAppleGPTKAuthorizationState: Equatable {
    case checking
    case ready
    case requiresAuthorization
    case authorizing
    case unavailable(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .authorizing: true
        case .ready, .requiresAuthorization, .unavailable, .failed: false
        }
    }
}

/// Shim inerte para fixtures visuales heredados. La UI y el ciclo de vida no exponen ni
/// sincronizan ningún catálogo de terceros.
enum PublicCatalogOperation: Equatable {
    case disabled
}

private enum AppleGPTKNativeError: LocalizedError {
    case installerMissing
    case invalidStatus
    case inspectionFailed(String)
    case invalidInspection
    case privateFileCreation

    var errorDescription: String? {
        switch self {
        case .installerMissing:
            "Falta el instalador protegido de Apple GPTK en esta instalación de Regression."
        case .invalidStatus:
            "El instalador de Apple GPTK devolvió un estado no reconocido."
        case .inspectionFailed(let detail):
            detail
        case .invalidInspection:
            "La inspección no produjo un descriptor y una licencia válidos."
        case .privateFileCreation:
            "No se pudo crear el token privado de autorización."
        }
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
    var databaseHealth: CompatibilityDatabaseHealth?
    var publicCatalogOperation: PublicCatalogOperation = .disabled
    var publicCatalogEnabled = false
    var sharedLibraryAssessment: SharedLibraryAssessment?
    /// Error de biblioteca propagado desde una operación que la modificaba. No se infiere de
    /// texto de UI: evita presentar una biblioteca como lista tras un fallo de custodia/enlace.
    var libraryFailureDetail: String?
    var windowsMediaHealth: ComponentHealthReport?
    var windowsMediaHealthIsRefreshing = false
    var steamRuntimePrerequisitesHealth: ComponentHealthReport?
    var steamRuntimePrerequisitesHealthIsRefreshing = false
    var protectedAppleGPTKHealth: ComponentHealthReport?
    var protectedAppleGPTKAuthorizationState: ProtectedAppleGPTKAuthorizationState = .checking
    var appleGPTKOnboarding = AppleGPTKOnboarding(
        inputs: .init(
            platformSupport: .supported,
            componentHealth: .missing,
            dmgSelection: .notDownloaded,
            licenseConfirmation: .notReviewed,
            operation: .verifying
        )
    )
    var appleGPTKLicenseReview: AppleGPTKLicenseReview?
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
    @ObservationIgnored private var regressionUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRegressionUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var physicalLibraryCustodyAssessmentTask: Task<Void, Never>?
    @ObservationIgnored private var physicalLibraryCustodyProgressTask: Task<Void, Never>?
    @ObservationIgnored private var physicalLibraryCustodyAssessmentID: UUID?
    @ObservationIgnored private var appleGPTKStatusRefreshInFlight = false
    @ObservationIgnored private var protectedAppleGPTKStatusRefreshInFlight = false
    @ObservationIgnored private var appleGPTKCriticalTask: Task<Void, Never>?
    @ObservationIgnored private var appleGPTKCriticalOperationID: UUID?
    @ObservationIgnored private var shutdownWasRequested = false
    @ObservationIgnored private var physicalLibraryCustodyValidationLease:
        PhysicalLibraryCustodyValidationLease?
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
            databaseURL: applicationSupport.appendingPathComponent("Compatibility/compatibility.sqlite"),
            legacyCompiledRepairBottleURL: applicationSupport.appendingPathComponent(
                "Bottles/Steam",
                isDirectory: true
            )
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
    }

    var statusTitle: String {
        switch operation {
        case .discovering: "Preparando Regression"
        case .ready: "Listo"
        case let .preparing(label): label
        case let .running(backend):
            backend == .regression ? "Steam de Regression activo" : "Otro Steam está abierto"
        case .switching: "Preparando Steam de Regression"
        case .error: failure?.title ?? "Necesita atención"
        }
    }

    var primaryActionTitle: String {
        runningState.activeBackend == .regression ? "Mostrar Steam" : "Abrir Steam"
    }

    var selectedInstallationDetail: String {
        guard let installations else { return "Detectando…" }
        return installations.regression.healthDetail
    }

    func learnedSummary(for game: SteamGame) -> String? {
        if let certification = certificationsByAppID[game.appID]?.first
            ?? VerifiedGameCatalog.certification(for: game.appID) {
            return certification.backend == .regression ? "Verificado perfecto: Regression" : nil
        }

        let candidates = profilesByAppID[game.appID] ?? []
        guard !candidates.isEmpty else { return nil }
        if let verified = CompatibilityProfile.preferredValidated(
            from: candidates,
            selectedBackend: selectedBackend
        ) {
            if verified.perfectRuns > 0 {
                return verified.backend == .regression ? "Verificado perfecto: Regression" : nil
            }
            return verified.backend == .regression
                ? "Funciona con incidencias: Regression"
                : nil
        }
        let failures = candidates.reduce(0) { $0 + $1.failedRuns }
        return failures > 0 ? "\(failures) prueba(s) con incidencias" : "Pendiente de verificación visual"
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
            let reconciledRepairs = try await repository.reconcileInterruptedRepairAttempts()
            if !reconciledRepairs.isEmpty {
                logger.notice(
                    "Se reconciliaron \(reconciledRepairs.count) reparaciones interrumpidas"
                )
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
        logger.info("Detección terminada; fuente heredada disponible: \(self.installations?.crossOver != nil)")
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
        logger.info("Estado de procesos: externo=\(self.runningState.crossOverIsRunning), Regression=\(self.runningState.regressionIsRunning)")
        await refreshStoredData(includeHealth: true)
        await refreshComponentHealth()
        await refreshAppleGPTKStatus()
        await refreshTestReadiness()
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
            if active == .regression {
                operation = .running(.regression)
                statusDetail = "Se ha adoptado la instancia de Steam de Regression ya abierta."
            } else {
                presentExternalSteamConflict()
            }
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
        await refreshComponentHealth()
        await refreshAppleGPTKStatus()
        await refreshTestReadiness()
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

        let context = trustedComponentContext()
        let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
            applicationVersion: context.applicationVersion,
            buildIdentifier: context.buildIdentifier,
            variant: context.variant,
            applicationBundleURL: context.bundleURL,
            applicationSupportURL: applicationSupportURL
        )
        windowsMediaHealth = await Task.detached(priority: .utility) {
            ComponentHealthService.evaluate(descriptor)
        }.value
    }

    /// Comprueba fuera del actor principal los componentes sellados que la interfaz presenta.
    /// Los descriptores proceden del bundle descubierto y del catálogo compilado; ningún dato
    /// persistido puede elegir rutas, variantes ni hashes de confianza.
    func refreshComponentHealth() async {
        guard !windowsMediaHealthIsRefreshing,
              !steamRuntimePrerequisitesHealthIsRefreshing else { return }
        windowsMediaHealthIsRefreshing = true
        steamRuntimePrerequisitesHealthIsRefreshing = true
        defer {
            windowsMediaHealthIsRefreshing = false
            steamRuntimePrerequisitesHealthIsRefreshing = false
        }

        let context = trustedComponentContext()
        let mediaDescriptor = TrustedComponentCatalog.windowsMediaDescriptor(
            applicationVersion: context.applicationVersion,
            buildIdentifier: context.buildIdentifier,
            variant: context.variant,
            applicationBundleURL: context.bundleURL,
            applicationSupportURL: applicationSupportURL
        )
        let runtimeDescriptor = TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
            applicationVersion: context.applicationVersion,
            buildIdentifier: context.buildIdentifier,
            variant: context.variant,
            wineRootURL: context.bundleURL.appendingPathComponent(
                "Contents/SharedSupport/wine-root",
                isDirectory: true
            )
        )
        let protectedAppleGPTKRoot = applicationSupportURL
            .appendingPathComponent("Components/AppleGPTK/3.0", isDirectory: true)

        let reports = await Task.detached(priority: .utility) {
            (
                media: ComponentHealthService.evaluate(mediaDescriptor),
                runtime: ComponentHealthService.evaluate(runtimeDescriptor),
                protectedAppleGPTK: AppleGPTKComponentCatalog.protectedProfilesHealth(
                    rootURL: protectedAppleGPTKRoot
                )
            )
        }.value
        windowsMediaHealth = reports.media
        steamRuntimePrerequisitesHealth = reports.runtime
        protectedAppleGPTKHealth = reports.protectedAppleGPTK
        await refreshProtectedAppleGPTKAuthorizationStatus()
    }

    var steamRuntimeBlocksLaunch: Bool {
        guard let report = steamRuntimePrerequisitesHealth else { return true }
        return report.status != .ready
    }

    func repairWindowsMediaComponent() async {
        guard let report = windowsMediaHealth else { return }
        switch report.recovery {
        case .createExternalLink, .restoreExternalLinkAfterBackup:
            break
        case .none, .reinstallTrustedArtifact, .provideUserSource,
             .installSupportedApplicationBuild:
            openOfficialRegressionRelease()
            return
        }
        guard runningState.activeBackend == nil else {
            presentComponentFailure(
                title: "Cierra Steam antes de reparar Windows Media",
                message: "Regression no cambiará el enlace multimedia mientras Steam o un juego estén activos.",
                recovery: .refresh
            )
            return
        }
        guard let installation = installations?.regression else { return }
        let installerURL = installation.applicationURL.appendingPathComponent(
            "Contents/SharedSupport/bin/install-windows-media-component",
            isDirectory: false
        )
        guard FileManager.default.isExecutableFile(atPath: installerURL.path) else {
            presentComponentFailure(
                title: "No se pudo reparar Windows Media",
                message: "Falta el reparador firmado de esta instalación.",
                recovery: .repairRegression
            )
            return
        }

        operation = .preparing("Reparando Windows Media")
        statusDetail = "Regression está restaurando el enlace local con backup y verificación final."
        let result: ProcessResult
        do {
            result = try await processRunner.run(executableURL: installerURL)
        } catch {
            presentComponentFailure(
                title: "No se pudo reparar Windows Media",
                message: error.localizedDescription,
                recovery: .refresh
            )
            return
        }
        guard result.exitCode == 0 else {
            let detail = [result.standardError, result.standardOutput]
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { PrivacySanitizer.redactedLogExcerpt($0) }
                ?? "El reparador terminó con código \(result.exitCode)."
            presentComponentFailure(
                title: "No se pudo reparar Windows Media",
                message: detail,
                recovery: .refresh
            )
            return
        }
        await refreshWindowsMediaHealth()
        operation = runningState.activeBackend.map(AppOperation.running) ?? .ready
        statusDetail = "Windows Media se reparó y verificó correctamente."
    }

    func openOfficialRegressionRelease() {
        guard let url = URL(string: "https://github.com/SwonDev/regression/releases/latest") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    var appleGPTKState: AppleGPTKOnboardingState {
        appleGPTKOnboarding.state
    }

    var appleGPTKIsBusy: Bool {
        switch appleGPTKState {
        case .verifying, .installing: true
        case .ready, .requiresDownload, .requiresSelection, .requiresLicense,
             .unsupported, .failed: false
        }
    }

    var appleGPTKLicenseAuthorizationIsBusy: Bool {
        appleGPTKIsBusy || protectedAppleGPTKAuthorizationState.isBusy
    }

    func refreshProtectedAppleGPTKAuthorizationStatus() async {
        guard !protectedAppleGPTKStatusRefreshInFlight,
              protectedAppleGPTKAuthorizationState != .authorizing else { return }
        guard protectedAppleGPTKHealth?.status == .ready else {
            protectedAppleGPTKAuthorizationState = .unavailable(
                "El payload exacto de Apple GPTK 3.0 no está disponible o no supera su catálogo protegido."
            )
            return
        }

        protectedAppleGPTKStatusRefreshInFlight = true
        protectedAppleGPTKAuthorizationState = .checking
        defer { protectedAppleGPTKStatusRefreshInFlight = false }

        do {
            let installerURL = try appleGPTKInstallerURL()
            let result = try await processRunner.run(
                executableURL: installerURL,
                arguments: ["--component", "3.0", "--verify-only"],
                environment: nil
            )
            protectedAppleGPTKAuthorizationState = result.exitCode == 0
                ? .ready
                : .requiresAuthorization
        } catch {
            protectedAppleGPTKAuthorizationState = .failed(error.localizedDescription)
        }
    }

    /// Verifica el componente con el instalador incluido. `ProcessRunner` es un actor propio,
    /// por lo que `hdiutil`, hashes y firmas nunca bloquean el actor principal de la interfaz.
    func refreshAppleGPTKStatus() async {
        if let appleGPTKCriticalTask {
            await appleGPTKCriticalTask.value
            return
        }
        let task = startAppleGPTKCriticalOperation { [weak self] in
            await self?.performAppleGPTKStatusRefresh()
        }
        await task?.value
    }

    private func performAppleGPTKStatusRefresh() async {
        guard !appleGPTKStatusRefreshInFlight,
              appleGPTKOnboarding.inputs.operation != .installing else { return }
        appleGPTKStatusRefreshInFlight = true
        defer { appleGPTKStatusRefreshInFlight = false }
        updateAppleGPTK(operation: .verifying)
        do {
            let installerURL = try appleGPTKInstallerURL()
            let result = try await processRunner.run(
                executableURL: installerURL,
                arguments: ["--status"],
                environment: nil
            )
            guard result.exitCode == 0,
                  let status = AppleGPTKInstallerStatus(output: result.standardOutput) else {
                throw AppleGPTKNativeError.invalidStatus
            }
            switch status {
            case .ready:
                appleGPTKOnboarding = AppleGPTKOnboarding(
                    inputs: .init(
                        platformSupport: .supported,
                        componentHealth: .ready,
                        dmgSelection: .notDownloaded,
                        licenseConfirmation: .notReviewed,
                        operation: .idle
                    )
                )
            case .requiresDownload:
                // Una autorización anterior permite reparar sin repetir selección ni licencia.
                // Si no existe caché/recibo válido, el instalador falla cerrado y se presenta el
                // onboarding oficial normal sin convertir esa ausencia esperada en un error.
                let repair = if runningState.activeBackend == nil {
                    try await processRunner.run(
                        executableURL: installerURL,
                        arguments: ["--repair-from-cache"],
                        environment: nil
                    )
                } else {
                    ProcessResult(
                        exitCode: 1,
                        standardOutput: "",
                        standardError: "Steam está activo"
                    )
                }
                if repair.exitCode == 0 {
                    let verification = try await processRunner.run(
                        executableURL: installerURL,
                        arguments: ["--status"],
                        environment: nil
                    )
                    guard verification.exitCode == 0,
                          AppleGPTKInstallerStatus(output: verification.standardOutput) == .ready
                    else { throw AppleGPTKNativeError.invalidStatus }
                    appleGPTKOnboarding = AppleGPTKOnboarding(
                        inputs: .init(
                            platformSupport: .supported,
                            componentHealth: .ready,
                            dmgSelection: .notDownloaded,
                            licenseConfirmation: .notReviewed,
                            operation: .idle
                        )
                    )
                } else {
                    appleGPTKOnboarding = AppleGPTKOnboarding(
                        inputs: .init(
                            platformSupport: .supported,
                            componentHealth: .missing,
                            dmgSelection: .notDownloaded,
                            licenseConfirmation: .notReviewed,
                            operation: .idle
                        )
                    )
                }
            case .unsupported(let reason):
                appleGPTKOnboarding = AppleGPTKOnboarding(
                    inputs: .init(
                        platformSupport: .unsupported(reason: reason),
                        componentHealth: .missing,
                        dmgSelection: .notDownloaded,
                        licenseConfirmation: .notReviewed,
                        operation: .idle
                    )
                )
            }
        } catch {
            failAppleGPTK(error.localizedDescription)
        }
    }

    func openOfficialAppleGPTKDownload() {
        let url = AppleGPTKOnboarding.officialDownloadURL
        guard url.host == "developer.apple.com", NSWorkspace.shared.open(url) else {
            failAppleGPTK("No se pudo abrir la página oficial de Apple Developer.")
            return
        }
        appleGPTKOnboarding = AppleGPTKOnboarding(
            inputs: .init(
                platformSupport: .supported,
                componentHealth: .missing,
                dmgSelection: .availableForSelection,
                licenseConfirmation: .notReviewed,
                operation: .idle
            )
        )
    }

    func beginSelectAndInspectAppleGPTKDMG() {
        startAppleGPTKCriticalOperation { [weak self] in
            await self?.selectAndInspectAppleGPTKDMG()
        }
    }

    private func selectAndInspectAppleGPTKDMG() async {
        guard !operation.isBusy, !appleGPTKIsBusy, runningState.activeBackend == nil else {
            failAppleGPTK(
                "Cierra Steam y espera a que termine la operación actual antes de inspeccionar Apple GPTK."
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Seleccionar el DMG oficial de Apple GPTK 4.0b2"
        panel.message = "Regression verificará el hash, el payload y las firmas antes de mostrar la licencia."
        panel.prompt = "Inspeccionar"
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        await inspectAppleGPTKDMG(at: sourceURL)
    }

    func beginInspectExistingProtectedAppleGPTK() {
        startAppleGPTKCriticalOperation { [weak self] in
            await self?.inspectExistingProtectedAppleGPTK()
        }
    }

    private func inspectExistingProtectedAppleGPTK() async {
        guard !operation.isBusy,
              !protectedAppleGPTKAuthorizationState.isBusy,
              runningState.activeBackend == nil else {
            presentComponentFailure(
                title: "Apple GPTK 3.0 no se puede inspeccionar todavía",
                message: "Cierra Steam y espera a que termine la operación actual.",
                recovery: .reviewProtectedAppleGPTK
            )
            return
        }

        let inspectionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "regression-gptk3-inspection-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try createPrivateInspectionDirectory(at: inspectionDirectory)
            protectedAppleGPTKAuthorizationState = .checking
            operation = .preparing("Verificando Apple GPTK 3.0")
            statusDetail = "Comprobando el componente protegido y su licencia sin copiar ni modificar el payload."

            let installerURL = try appleGPTKInstallerURL()
            let result = try await processRunner.run(
                executableURL: installerURL,
                arguments: [
                    "--component", "3.0",
                    "--inspect-existing",
                    "--output-dir", inspectionDirectory.path,
                ],
                environment: nil
            )
            guard result.exitCode == 0 else {
                throw AppleGPTKNativeError.inspectionFailed(processFailureDetail(result))
            }

            let descriptorURL = inspectionDirectory.appendingPathComponent(
                "apple-gptk-existing-inspection.json",
                isDirectory: false
            )
            let licenseURL = inspectionDirectory.appendingPathComponent(
                "License.rtf",
                isDirectory: false
            )
            let descriptor = try JSONDecoder().decode(
                AppleGPTKExistingComponentInspectionDescriptor.self,
                from: Data(contentsOf: descriptorURL)
            )
            let licenseData = try Data(contentsOf: licenseURL, options: .mappedIfSafe)
            let displayedLicenseSHA256 = SHA256.hash(data: licenseData)
                .map { String(format: "%02x", $0) }
                .joined()
            let expectedComponentPath = applicationSupportURL
                .appendingPathComponent("Components/AppleGPTK/3.0", isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            let inspectedComponentPath = URL(
                fileURLWithPath: descriptor.sourceComponent,
                isDirectory: true
            )
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
            guard descriptor.schema == 1,
                  descriptor.version == AppleGPTKComponentCatalog.protectedProfiles.version,
                  descriptor.sourceKind
                    == AppleGPTKExistingComponentInspectionDescriptor.sourceKind,
                  descriptor.catalogID == AppleGPTKComponentCatalog.protectedProfilesComponentID,
                  descriptor.payloadFingerprint
                    == AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint,
                  descriptor.licenseSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
                  descriptor.sourceComponent.hasPrefix("/"),
                  inspectedComponentPath == expectedComponentPath,
                  displayedLicenseSHA256 == descriptor.licenseSHA256,
                  !licenseData.isEmpty,
                  licenseData.count <= 10 * 1_024 * 1_024 else {
                throw AppleGPTKNativeError.invalidInspection
            }

            appleGPTKLicenseReview = AppleGPTKLicenseReview(
                id: UUID(),
                source: .protectedExisting(descriptor: descriptor),
                inspectionDirectoryURL: inspectionDirectory,
                licenseRTFData: licenseData
            )
            failure = nil
            operation = .ready
            protectedAppleGPTKAuthorizationState = .requiresAuthorization
            statusDetail = "Apple GPTK 3.0 está verificado. Revisa su licencia exacta antes de autorizarlo."
        } catch {
            try? FileManager.default.removeItem(at: inspectionDirectory)
            protectedAppleGPTKAuthorizationState = .failed(error.localizedDescription)
            presentComponentFailure(
                title: "No se pudo inspeccionar Apple GPTK 3.0",
                message: error.localizedDescription,
                recovery: .reviewProtectedAppleGPTK
            )
        }
    }

    func presentAppleGPTKLicenseReview() {
        guard let review = appleGPTKLicenseReview else { return }
        appleGPTKLicenseReview = review
    }

    func cancelAppleGPTKLicenseReview() {
        if let review = appleGPTKLicenseReview {
            try? FileManager.default.removeItem(at: review.inspectionDirectoryURL)
        }
        let cancelledProtectedReview = appleGPTKLicenseReview?.source.isProtectedExisting == true
        appleGPTKLicenseReview = nil
        if cancelledProtectedReview {
            protectedAppleGPTKAuthorizationState = .requiresAuthorization
            operation = .ready
            statusDetail = "Apple GPTK 3.0 sigue pendiente de autorización; no se modificó el componente."
            return
        }
        appleGPTKOnboarding = AppleGPTKOnboarding(
            inputs: .init(
                platformSupport: .supported,
                componentHealth: .missing,
                dmgSelection: .availableForSelection,
                licenseConfirmation: .notReviewed,
                operation: .idle
            )
        )
    }

    func beginAppleGPTKAuthorization(
        _ review: AppleGPTKLicenseReview,
        explicitConfirmation: String
    ) {
        startAppleGPTKCriticalOperation { [weak self] in
            await self?.authorizeAndInstallAppleGPTK(
                review,
                explicitConfirmation: explicitConfirmation
            )
        }
    }

    private func authorizeAndInstallAppleGPTK(
        _ review: AppleGPTKLicenseReview,
        explicitConfirmation: String
    ) async {
        guard appleGPTKLicenseReview?.id == review.id,
              explicitConfirmation == review.source.confirmationValue,
              runningState.activeBackend == nil,
              !operation.isBusy else {
            failAppleGPTK("La autorización ya no corresponde a la inspección activa.")
            return
        }

        switch review.source {
        case .protectedExisting(let descriptor):
            await authorizeExistingProtectedAppleGPTK(review, descriptor: descriptor)
        case .diskImage(let descriptor, let sourceURL):
            await authorizeAppleGPTKDMG(
                review,
                descriptor: descriptor,
                sourceURL: sourceURL
            )
        }
    }

    private func authorizeAppleGPTKDMG(
        _ review: AppleGPTKLicenseReview,
        descriptor: AppleGPTKInspectionDescriptor,
        sourceURL: URL
    ) async {

        appleGPTKOnboarding = AppleGPTKOnboarding(
            inputs: .init(
                platformSupport: .supported,
                componentHealth: .missing,
                dmgSelection: .selected(sourceURL),
                licenseConfirmation: .confirmed,
                operation: .installing
            )
        )
        operation = .preparing("Instalando Apple GPTK")
        statusDetail = "Volviendo a verificar el DMG antes de instalar el componente de forma transaccional."

        let authorizationURL = review.inspectionDirectoryURL
            .appendingPathComponent("apple-gptk-authorization.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: authorizationURL)
        }

        do {
            let token = AppleGPTKAuthorizationToken(
                authorizing: descriptor,
                at: Date(),
                nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "")
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writePrivateFile(encoder.encode(token), to: authorizationURL)

            let installerURL = try appleGPTKInstallerURL()
            let result = try await processRunner.run(
                executableURL: installerURL,
                arguments: [
                    "--install-authorized",
                    "--source-dmg", sourceURL.path,
                    "--authorization-file", authorizationURL.path,
                ],
                environment: nil
            )
            guard result.exitCode == 0 else {
                throw AppleGPTKNativeError.inspectionFailed(processFailureDetail(result))
            }

            appleGPTKLicenseReview = nil
            try? FileManager.default.removeItem(at: review.inspectionDirectoryURL)
            operation = .ready
            statusDetail = "Apple GPTK 4.0b2 se instaló y verificó correctamente."
            updateAppleGPTK(operation: .idle)
            await performAppleGPTKStatusRefresh()
        } catch {
            appleGPTKLicenseReview = nil
            try? FileManager.default.removeItem(at: review.inspectionDirectoryURL)
            operation = .ready
            failAppleGPTK(error.localizedDescription)
        }
    }

    private func authorizeExistingProtectedAppleGPTK(
        _ review: AppleGPTKLicenseReview,
        descriptor: AppleGPTKExistingComponentInspectionDescriptor
    ) async {
        protectedAppleGPTKAuthorizationState = .authorizing
        operation = .preparing("Autorizando Apple GPTK 3.0")
        statusDetail = "Volviendo a verificar el componente exacto antes de registrar la aceptación local."

        let authorizationURL = review.inspectionDirectoryURL.appendingPathComponent(
            "apple-gptk-existing-authorization.json",
            isDirectory: false
        )
        defer {
            try? FileManager.default.removeItem(at: authorizationURL)
        }

        do {
            let token = AppleGPTKExistingComponentAuthorizationToken(
                authorizing: descriptor,
                at: Date(),
                nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "")
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writePrivateFile(encoder.encode(token), to: authorizationURL)

            let installerURL = try appleGPTKInstallerURL()
            let result = try await processRunner.run(
                executableURL: installerURL,
                arguments: [
                    "--component", "3.0",
                    "--authorize-existing",
                    "--authorization-file", authorizationURL.path,
                ],
                environment: nil
            )
            guard result.exitCode == 0 else {
                throw AppleGPTKNativeError.inspectionFailed(processFailureDetail(result))
            }

            let verification = try await processRunner.run(
                executableURL: installerURL,
                arguments: ["--component", "3.0", "--verify-only"],
                environment: nil
            )
            guard verification.exitCode == 0 else {
                throw AppleGPTKNativeError.inspectionFailed(processFailureDetail(verification))
            }

            appleGPTKLicenseReview = nil
            try? FileManager.default.removeItem(at: review.inspectionDirectoryURL)
            failure = nil
            operation = .ready
            protectedAppleGPTKAuthorizationState = .ready
            statusDetail = "Apple GPTK 3.0 se autorizó y verificó sin copiar ni modificar su payload."
        } catch {
            appleGPTKLicenseReview = nil
            try? FileManager.default.removeItem(at: review.inspectionDirectoryURL)
            protectedAppleGPTKAuthorizationState = .failed(error.localizedDescription)
            presentComponentFailure(
                title: "No se pudo autorizar Apple GPTK 3.0",
                message: error.localizedDescription,
                recovery: .reviewProtectedAppleGPTK
            )
        }
    }

    private func inspectAppleGPTKDMG(at sourceURL: URL) async {
        let inspectionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-gptk-inspection-\(UUID().uuidString)", isDirectory: true)
        do {
            try createPrivateInspectionDirectory(at: inspectionDirectory)
            updateAppleGPTK(
                selection: .selected(sourceURL),
                confirmation: .notReviewed,
                operation: .verifying
            )
            operation = .preparing("Verificando Apple GPTK")
            statusDetail = "Comprobando el DMG oficial, su payload y sus firmas sin instalar nada."

            let installerURL = try appleGPTKInstallerURL()
            let result = try await processRunner.run(
                executableURL: installerURL,
                arguments: [
                    "--inspect",
                    "--source-dmg", sourceURL.path,
                    "--output-dir", inspectionDirectory.path,
                ],
                environment: nil
            )
            guard result.exitCode == 0 else {
                throw AppleGPTKNativeError.inspectionFailed(processFailureDetail(result))
            }

            let descriptorURL = inspectionDirectory
                .appendingPathComponent("apple-gptk-inspection.json", isDirectory: false)
            let licenseURL = inspectionDirectory
                .appendingPathComponent("License.rtf", isDirectory: false)
            let descriptor = try JSONDecoder().decode(
                AppleGPTKInspectionDescriptor.self,
                from: Data(contentsOf: descriptorURL)
            )
            let licenseData = try Data(contentsOf: licenseURL, options: .mappedIfSafe)
            let displayedLicenseSHA256 = SHA256.hash(data: licenseData)
                .map { String(format: "%02x", $0) }
                .joined()
            let canonicalSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard descriptor.schema == 1,
                  descriptor.version == "4.0b2",
                  descriptor.sourceDMG == canonicalSource,
                  descriptor.dmgSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
                  descriptor.licenseSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
                  displayedLicenseSHA256 == descriptor.licenseSHA256,
                  !licenseData.isEmpty,
                  licenseData.count <= 10 * 1_024 * 1_024 else {
                throw AppleGPTKNativeError.invalidInspection
            }

            appleGPTKLicenseReview = AppleGPTKLicenseReview(
                id: UUID(),
                source: .diskImage(
                    descriptor: descriptor,
                    sourceURL: URL(fileURLWithPath: descriptor.sourceDMG)
                ),
                inspectionDirectoryURL: inspectionDirectory,
                licenseRTFData: licenseData
            )
            updateAppleGPTK(
                selection: .selected(URL(fileURLWithPath: descriptor.sourceDMG)),
                confirmation: .notReviewed,
                operation: .idle
            )
            operation = .ready
            statusDetail = "Apple GPTK 4.0b2 está verificado. Revisa la licencia exacta antes de instalar."
        } catch {
            try? FileManager.default.removeItem(at: inspectionDirectory)
            operation = .ready
            failAppleGPTK(error.localizedDescription)
        }
    }

    private func appleGPTKInstallerURL() throws -> URL {
        let installerURL = trustedComponentContext().bundleURL.appendingPathComponent(
            "Contents/SharedSupport/bin/install-apple-gptk-component",
            isDirectory: false
        )
        guard FileManager.default.isExecutableFile(atPath: installerURL.path) else {
            throw AppleGPTKNativeError.installerMissing
        }
        return installerURL
    }

    private func createPrivateInspectionDirectory(at inspectionDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: inspectionDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: inspectionDirectory.path
        )
    }

    @discardableResult
    private func startAppleGPTKCriticalOperation(
        _ work: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard appleGPTKCriticalTask == nil, !shutdownWasRequested else { return nil }
        let operationID = UUID()
        appleGPTKCriticalOperationID = operationID
        let task = Task { @MainActor [weak self] in
            await work()
            guard self?.appleGPTKCriticalOperationID == operationID else { return }
            self?.appleGPTKCriticalTask = nil
            self?.appleGPTKCriticalOperationID = nil
        }
        appleGPTKCriticalTask = task
        return task
    }

    private func updateAppleGPTK(
        selection: AppleGPTKDMGSelection? = nil,
        confirmation: AppleGPTKLicenseConfirmation? = nil,
        operation: AppleGPTKOnboardingOperation
    ) {
        let current = appleGPTKOnboarding.inputs
        appleGPTKOnboarding = AppleGPTKOnboarding(
            inputs: .init(
                platformSupport: current.platformSupport,
                componentHealth: current.componentHealth,
                dmgSelection: selection ?? current.dmgSelection,
                licenseConfirmation: confirmation ?? current.licenseConfirmation,
                operation: operation
            )
        )
    }

    private func failAppleGPTK(_ message: String) {
        updateAppleGPTK(operation: .failed(message: message))
    }

    private func processFailureDetail(_ result: ProcessResult) -> String {
        [result.standardError, result.standardOutput]
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { PrivacySanitizer.redactedLogExcerpt($0) }
            ?? "El instalador terminó con código \(result.exitCode)."
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
              ) else {
            throw AppleGPTKNativeError.privateFileCreation
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func startSteam() async {
        guard let installations else { return }
        if runningState.activeBackend == .regression {
            showSteam()
            return
        }
        if runningState.activeBackend != nil {
            presentExternalSteamConflict()
            return
        }
        guard await ensureSteamRuntimeReadyForLaunch() else { return }
        invalidatePhysicalLibraryCustodyAssessment(
            notice: "La evaluación se descartó porque Steam se está iniciando. Repítela cuando Steam esté cerrado."
        )
        LifecycleDiagnostics.write("startSteam invocado")
        logger.info("startSteam con \(self.selectedBackend.rawValue)")
        failure = nil
        libraryFailureDetail = nil
        operation = .preparing("Iniciando Steam de Regression")
        statusDetail = "Regression está verificando el runtime y la botella antes de abrir Steam."
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
        guard activeBackend == .regression else {
            presentExternalSteamConflict()
            return
        }

        let alert = NSAlert()
        alert.messageText = "¿Cerrar Steam?"
        alert.informativeText = "Regression solicitará un cierre normal de Steam. Los juegos que sigan abiertos también deben cerrarse primero."
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
        guard await ensureSteamRuntimeReadyForLaunch() else { return }
        guard await ensureAppleGPTKReadyForLaunch(appID: game.appID) else { return }
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
            if let active = runningState.activeBackend, active != .regression {
                presentExternalSteamConflict()
                return
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
            let configuration = await configurationCollector.snapshot(
                bottleURL: metadata.bottleURL,
                backend: selectedBackend,
                providerVersion: metadata.providerVersion,
                game: game,
                steamRootURL: installations.regression.steamRootURL
            )

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
        guard await ensureSteamRuntimeReadyForLaunch() else { return }
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
        alert.messageText = "¿Ya verificaste una ejecución perfecta?"
        alert.informativeText =
            "Finaliza solo después de cerrar un juego ejecutado con Regression y marcar esa "
            + "ejecución como Verificado perfecto: render, entrada, opciones y gameplay. "
            + "Regression comprobará el registro exacto antes de aceptar la custodia."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Finalizar con ejecución perfecta")
        alert.addButton(withTitle: "Restaurar biblioteca")
        alert.addButton(withTitle: "Seguir comprobando")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let shouldFinalize = response == .alertFirstButtonReturn

        operation = .preparing(
            shouldFinalize ? "Verificando la ejecución perfecta" : "Restaurando la biblioteca"
        )
        libraryIndependenceState = shouldFinalize ? .verifying : .rollingBack
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
            let assessment: PhysicalLibraryCustodyAssessment
            if shouldFinalize {
                statusDetail =
                    "Buscando una ejecución perfecta, finalizada y posterior al traslado…"
                let request = try await physicalLibraryCustodyValidationRequest()
                assessment = try await sharedLibrary.finalizePhysicalCustodyValidated(
                    regression: installations.regression,
                    legacyIdentity: identity,
                    request: request,
                    repository: repository,
                    runningState: runningState
                )
            } else {
                assessment = try await sharedLibrary.rollbackPhysicalCustody(
                    regression: installations.regression,
                    legacyIdentity: identity,
                    runningState: runningState
                )
            }
            physicalLibraryCustodyValidationLease = nil
            physicalLibraryCustodyAssessment = assessment
            applyPhysicalLibraryCustodyStatus(assessment.status)
            operation = .ready
            statusDetail = shouldFinalize
                ? "Regression es independiente y conserva la única instalación de los juegos."
                : "La biblioteca anterior se restauró sin duplicar los juegos."
            await refreshGames()
        } catch {
            libraryIndependenceState = .validating
            if shouldFinalize, case .invalidEvidence = error as? RegressionCoreError {
                presentComponentFailure(
                    title: "Falta una ejecución perfecta",
                    message:
                        "La biblioteca no se finalizó. Ejecuta un juego con Regression, "
                        + "comprueba render, entrada, opciones y gameplay, ciérralo y márcalo "
                        + "como Verificado perfecto antes de volver a confirmar.",
                    technicalDetail: error.localizedDescription,
                    recovery: .refresh
                )
            } else {
                statusDetail =
                    "No se pudo finalizar la validación: \(error.localizedDescription)"
                present(error)
            }
        }
    }

    /// El modelo solo selecciona la identidad de un candidato perfecto. RegressionCore recarga
    /// esa ejecución exacta desde SQLite y valida bajo el lock de custodia todos sus hechos,
    /// incluida la frontera temporal durable, antes de finalizar el traslado.
    private func physicalLibraryCustodyValidationRequest() async throws
        -> PhysicalLibraryCustodyValidationRequest
    {
        try await repository.prepare()
        let candidates = try await repository.recentRuns(limit: 1_000)
        for run in candidates where run.backend == .regression {
            guard run.endedAt != nil,
                  run.result == .succeeded,
                  run.processID != nil,
                  let verification = run.verification,
                  verification.runID == run.id,
                  verification.verdict == .perfect,
                  verification.rendering == .passed,
                  verification.inputPrecision == .passed,
                  verification.graphicsSettings == .passed,
                  verification.gameplay == .passed,
                  verification.source == .user || verification.source == .visualInspection else {
                continue
            }
            return PhysicalLibraryCustodyValidationRequest(
                appID: run.appID,
                runID: run.id
            )
        }
        throw RegressionCoreError.invalidEvidence(
            "No existe una ejecución perfecta de Regression posterior al inicio de esta "
                + "validación de custodia"
        )
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
            alert.informativeText = "Esto crea un blindado persistente para esta ejecución exacta de Regression. Confirma solo después de comprobar visualmente render, precisión de entrada, opciones gráficas y gameplay. El blindado garantiza funcionamiento reproducible, no que sea todavía la opción de mayor rendimiento."
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
                ? "\(run.gameName) quedó blindado de forma persistente con Regression."
                : "La verificación de \(run.gameName) quedó guardada localmente."
        } catch {
            present(error)
        }
    }

    func toggleAutoLaunch(_ enabled: Bool) {
        autoLaunchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoLaunchEnabled")
    }

    func shutdown() async {
        guard !shutdownIsComplete else { return }
        shutdownWasRequested = true
        logger.notice("Cancelando tareas de monitorización")
        cancelPhysicalLibraryCustodyAssessment()
        while physicalLibraryCustodyProgressTask != nil {
            statusDetail =
                "Terminando el punto seguro de custodia antes de cerrar Regression…"
            try? await Task.sleep(for: .milliseconds(100))
        }
        let monitoring = monitoringTask
        monitoringTask = nil
        monitoring?.cancel()

        regressionUpdateTask?.cancel()
        regressionUpdateTask = nil
        automaticRegressionUpdateTask?.cancel()
        automaticRegressionUpdateTask = nil

        // Las inspecciones y autorizaciones de Apple GPTK invocan procesos que protegen su
        // propia transacción con lock y rollback. `ProcessRunner` no abandona el hijo al
        // cancelar una Task; por eso el modelo conserva la tarea y espera su único punto seguro
        // antes de permitir que AppKit cierre. Así ni 3.0 ni 4.0b2 pueden seguir mutando tras el
        // cierre de la app, y una hoja SwiftUI nunca es dueña de la operación crítica.
        if let appleGPTKCriticalTask {
            statusDetail = "Terminando el punto seguro de Apple GPTK antes de cerrar Regression…"
            await appleGPTKCriticalTask.value
            self.appleGPTKCriticalTask = nil
        }

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

    /// Reinstala incluso la release vigente a través del mismo canal oficial, digest y rollback
    /// del actualizador. Conserva la botella, la biblioteca y el GPTK autorizado.
    func repairRegressionInstallation() async {
        guard isCanonicalApplicationInstallation else {
            openOfficialRegressionRelease()
            return
        }
        guard !libraryIndependenceState.blocksNormalOperations,
              !operation.isBusy,
              runningState.activeBackend == nil else {
            presentComponentFailure(
                title: "Regression no se puede reparar todavía",
                message: "Cierra Steam y termina cualquier operación crítica antes de reparar.",
                recovery: .refresh
            )
            return
        }
        operation = .preparing("Preparando la reparación")
        statusDetail = "Buscando el instalador oficial verificado de esta release…"
        do {
            let installedVersion = trustedComponentContext().applicationVersion
            let release = try await regressionReleaseService.latestRelease(
                clientVersion: installedVersion
            )
            regressionReleaseStatus = .available(
                installedVersion: installedVersion,
                release: release
            )
            operation = .ready
            let decision = await RegressionManualRepairPolicy.runIfAuthorized(
                installedVersion: installedVersion,
                releaseVersion: release.version
            ) { [weak self] in
                await self?.installAvailableRegressionUpdate()
            }
            switch decision {
            case .repairNow:
                break
            case .newerUpdateAvailable:
                statusDetail =
                    "Hay una versión posterior disponible. Confirma Actualizar para instalarla."
            case .rejectDowngrade:
                let message =
                    "El canal estable ofrece una versión anterior a la instalada; la reparación se bloqueó para evitar un downgrade."
                regressionReleaseStatus = .failed(message: message)
                presentComponentFailure(
                    title: "Regression no se puede reparar con una versión anterior",
                    message: message,
                    recovery: .refresh
                )
            }
        } catch {
            operation = .ready
            regressionReleaseStatus = .failed(message: error.localizedDescription)
            presentComponentFailure(
                title: "No se pudo reparar Regression",
                message: error.localizedDescription,
                recovery: .refresh
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
            return name.contains("steam") && path.contains("regression")
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
        case .repairRegression: await repairRegressionInstallation()
        case .prepareAppleGPTK:
            switch appleGPTKState {
            case .requiresDownload:
                openOfficialAppleGPTKDownload()
            case .requiresSelection, .failed:
                beginSelectAndInspectAppleGPTKDMG()
            case .requiresLicense:
                presentAppleGPTKLicenseReview()
            case .ready, .verifying, .installing, .unsupported:
                await refreshAppleGPTKStatus()
            }
        case .reviewProtectedAppleGPTK:
            beginInspectExistingProtectedAppleGPTK()
        case .reinstallRegression: openOfficialRegressionRelease()
        }
    }

    private func ensureAppleGPTKReadyForLaunch(appID: String) async -> Bool {
        guard let requiredVersion = GameRuntimeProfileCatalog.requiredAppleGPTKVersion(
            for: appID,
            backend: selectedBackend
        ) else { return true }

        if requiredVersion == .version3 {
            if protectedAppleGPTKHealth == nil {
                await refreshComponentHealth()
            }
            guard protectedAppleGPTKHealth?.status == .ready else {
                presentComponentFailure(
                    title: "Este juego necesita Apple GPTK 3.0",
                    message: "Regression no inició el juego porque falta su generación D3DMetal exacta. Apple GPTK 4.0b2 no es intercambiable con el perfil blindado.",
                    technicalDetail: "El payload protegido 3.0 no supera su catálogo compilado de archivos y enlaces.",
                    recovery: .reviewProtectedAppleGPTK
                )
                return false
            }

            await refreshProtectedAppleGPTKAuthorizationStatus()
            guard protectedAppleGPTKAuthorizationState == .ready else {
                presentComponentFailure(
                    title: "Apple GPTK 3.0 necesita autorización",
                    message: "Los bytes coinciden, pero Regression no ejecutará este componente de Apple sin un recibo local verificable de licencia.",
                    technicalDetail: "Revisa la licencia exacta del componente protegido antes de autorizarlo.",
                    recovery: .reviewProtectedAppleGPTK
                )
                return false
            }
            return true
        }

        if appleGPTKState == .ready { return true }
        await refreshAppleGPTKStatus()
        guard appleGPTKState == .ready else {
            presentComponentFailure(
                title: "Este juego necesita Apple GPTK",
                message: "Regression no inició el juego porque su perfil D3DMetal aún no está preparado. La app te guiará por la descarga oficial y la licencia de Apple.",
                recovery: .prepareAppleGPTK
            )
            return false
        }
        return true
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
            if active == .regression {
                if !operation.isBusy { operation = .running(.regression) }
            } else if !operation.isBusy {
                presentExternalSteamConflict()
            }
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
            await refreshGameTechnologyEvidence(
                games: games,
                steamRootURL: snapshot.regression.steamRootURL
            )
        } catch {
            logger.error(
                "No se pudieron reconciliar los nombres públicos: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Inventaría solo marcadores conocidos dentro de cada instalación y persiste requisitos
    /// declarativos. Un hallazgo nunca ejecuta el redistribuible incluido por un juego.
    private func refreshGameTechnologyEvidence(
        games: [SteamGame],
        steamRootURL: URL
    ) async {
        let commonURL = steamRootURL
            .appendingPathComponent("steamapps/common", isDirectory: true)
            .standardizedFileURL
        let discovered = await Task.detached(priority: .utility) {
            games.map { game -> (String, Date, Result<[GameRuntimeRequirement], Error>) in
                let attemptedAt = Date()
                do {
                    let directory = game.installDirectory
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !directory.isEmpty,
                          directory != ".", directory != "..",
                          !directory.contains("/"), !directory.contains("\\"),
                          !directory.unicodeScalars.contains(where: { $0.value == 0 }) else {
                        throw RegressionCoreError.invalidEvidence(
                            "el directorio de instalación del juego no es seguro"
                        )
                    }
                    let gameURL = commonURL.appendingPathComponent(
                        directory,
                        isDirectory: true
                    )
                    let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: gameURL)
                    return (
                        game.appID,
                        attemptedAt,
                        .success(try report.requirements(
                            forAppID: game.appID,
                            observedAt: attemptedAt
                        ))
                    )
                } catch {
                    return (game.appID, attemptedAt, .failure(error))
                }
            }
        }.value
        for (appID, attemptedAt, result) in discovered {
            do {
                switch result {
                case .success(let requirements):
                    try await repository.recordSuccessfulGameTechnologyScan(
                        appID: appID,
                        requirements: requirements,
                        scannedAt: attemptedAt
                    )
                case .failure(let error):
                    try await repository.recordFailedGameTechnologyScan(
                        appID: appID,
                        error: error.localizedDescription,
                        attemptedAt: attemptedAt
                    )
                }
            } catch {
                logger.error(
                    "No se pudo reconciliar la evidencia automática de \(appID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
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
            let refreshedHealth = includeHealth ? try await repository.databaseHealth() : nil
            recentRuns = refreshedRuns.filter { $0.backend == .regression }
            profiles = refreshedProfiles.filter { $0.backend == .regression }
            engineProfiles = refreshedEngines
            certifications = refreshedCertifications.filter { $0.backend == .regression }
            runtimeTechnologies = refreshedTechnologies
            activeRuntimeCandidateCount = refreshedActiveCandidateCount
            activeResearchCaseCount = refreshedActiveResearchCaseCount
            activeResearchExperimentCount = refreshedActiveResearchExperimentCount
            profilesByAppID = Dictionary(
                grouping: refreshedProfiles.filter { $0.backend == .regression },
                by: \.appID
            )
            certificationsByAppID = Dictionary(
                grouping: refreshedCertifications.filter { $0.backend == .regression },
                by: \.appID
            )
            if let refreshedHealth { databaseHealth = refreshedHealth }
        } catch {
            // Una lectura transitoria no debe borrar en pantalla el último estado válido.
            logger.error(
                "No se pudieron actualizar los datos locales: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        guard backend == .regression else {
            throw RegressionCoreError.launchFailed(
                "Regression solo permite iniciar juegos con su motor propio"
            )
        }
        return (
            installations.regression.bottleURL,
            "Steam",
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )
    }

    private func gameLaunchCommand(
        installations: InstallationSnapshot,
        backend: BackendKind,
        appID: String
    ) throws -> SteamCommand {
        guard let normalizedAppID = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.launchFailed("El Steam App ID no es válido")
        }
        guard backend == .regression else {
            throw RegressionCoreError.launchFailed(
                "Regression solo permite iniciar juegos con su motor propio"
            )
        }
        let arguments = ["-applaunch", normalizedAppID]
        return BackendCommandFactory.regression(
            installation: installations.regression,
            steamArguments: arguments
        )
    }

    private func steamActivationScore(_ application: NSRunningApplication) -> Int {
        let name = application.localizedName?.lowercased() ?? ""
        let path = application.executableURL?.path.lowercased() ?? ""
        var score = 0
        if name == "steam" || name == "steam.exe" { score += 100 }
        if !name.contains("webhelper") && !name.contains("service") { score += 20 }
        if application.activationPolicy == .regular { score += 10 }
        if runningState.activeBackend == .regression, path.contains("regression") { score += 5 }
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

    private struct TrustedComponentContext {
        let applicationVersion: String
        let buildIdentifier: String
        let variant: ComponentArtifactVariant
        let bundleURL: URL
    }

    private func trustedComponentContext() -> TrustedComponentContext {
        let bundleURL = (installations?.regression.applicationURL ?? Bundle.main.bundleURL)
            .standardizedFileURL
        let applicationBundle = Bundle(url: bundleURL) ?? Bundle.main
        let applicationVersion = applicationBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "desconocida"
        let buildIdentifier = applicationBundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "desconocida"
        let isTrustedPublicInstallation = bundleURL.path == "/Applications/Regression.app"
            && applicationVersion == TrustedComponentCatalog.supportedApplicationVersion
            && buildIdentifier == TrustedComponentCatalog.supportedBuildIdentifier
        return TrustedComponentContext(
            applicationVersion: applicationVersion,
            buildIdentifier: buildIdentifier,
            variant: isTrustedPublicInstallation ? .publicInstalled : .development,
            bundleURL: bundleURL
        )
    }

    private func ensureSteamRuntimeReadyForLaunch() async -> Bool {
        if steamRuntimePrerequisitesHealth == nil {
            await refreshComponentHealth()
        }
        guard let report = steamRuntimePrerequisitesHealth,
              report.status == .ready else {
            let status = steamRuntimePrerequisitesHealth?.status.rawValue ?? "sin comprobar"
            let issue = steamRuntimePrerequisitesHealth?.issue.map(String.init(describing:))
                ?? "No existe un informe verificable."
            presentComponentFailure(
                title: "El runtime de juegos necesita atención",
                message: "VC++/UCRT no supera la verificación de esta release. Steam y los juegos no se iniciaron.",
                technicalDetail: "Estado: \(status). Diagnóstico: \(issue)",
                recovery: .repairRegression
            )
            return false
        }
        return true
    }

    private func presentComponentFailure(
        title: String,
        message: String,
        technicalDetail: String? = nil,
        recovery: UserFacingFailure.Recovery
    ) {
        failure = UserFacingFailure(title: title, message: message, recovery: recovery)
        operation = .error
        statusDetail = technicalDetail ?? message
    }

    private func presentExternalSteamConflict() {
        failure = UserFacingFailure(
            title: "Otro Steam de Windows está abierto",
            message: "Ciérralo desde la aplicación que lo inició antes de abrir el Steam propio de Regression.",
            recovery: .refresh
        )
        operation = .error
        statusDetail = "Regression no controlará ni cerrará clientes de Steam externos."
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
