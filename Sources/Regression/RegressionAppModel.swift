import AppKit
import Observation
import OSLog
import RegressionCore
import SwiftUI

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
        case openCrossOver
        case chooseRegression
        case refresh
    }

    let title: String
    let message: String
    let recovery: Recovery
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
    var sharedLibraryAssessment: SharedLibraryAssessment?
    var updateStatus: CrossOverUpdateStatus?
    var failure: UserFacingFailure?
    var statusDetail = "Buscando CrossOver y las botellas de Steam…"
    var autoLaunchEnabled: Bool

    @ObservationIgnored private let processRunner: ProcessRunner
    @ObservationIgnored private let processLauncher: ProcessLauncher
    @ObservationIgnored private let inspector: ProcessInspector
    @ObservationIgnored private let discovery: InstallationDiscovery
    @ObservationIgnored private let coordinator: BackendCoordinator
    @ObservationIgnored private let repository: CompatibilityRepository
    @ObservationIgnored private let telemetry: TelemetryCoordinator
    @ObservationIgnored private let sharedLibrary: SharedSteamLibraryManager
    @ObservationIgnored private let updateChecker = CrossOverUpdateChecker()
    @ObservationIgnored private let logger = Logger(
        subsystem: "local.regression.launcher",
        category: "lifecycle"
    )
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var periodicRefreshCount = 0

    init() {
        let defaults = UserDefaults.standard
        selectedBackend = BackendKind(
            rawValue: defaults.string(forKey: "selectedBackend") ?? ""
        ) ?? .crossOver
        if defaults.object(forKey: "autoLaunchEnabled") == nil {
            defaults.set(true, forKey: "autoLaunchEnabled")
        }
        autoLaunchEnabled = defaults.bool(forKey: "autoLaunchEnabled")

        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Regression", isDirectory: true)
        processRunner = ProcessRunner()
        processLauncher = ProcessLauncher()
        inspector = ProcessInspector(runner: processRunner)
        discovery = InstallationDiscovery(runner: processRunner)
        coordinator = BackendCoordinator(
            processRunner: processRunner,
            processLauncher: processLauncher,
            inspector: inspector,
            logDirectoryURL: applicationSupport.appendingPathComponent("Logs/Launcher", isDirectory: true)
        )
        repository = CompatibilityRepository(
            databaseURL: applicationSupport.appendingPathComponent("Compatibility/compatibility.sqlite")
        )
        telemetry = TelemetryCoordinator(
            repository: repository,
            monitor: SteamLogMonitor()
        )
        sharedLibrary = SharedSteamLibraryManager(
            backupRootURL: applicationSupport.appendingPathComponent("Backups/SharedLibrary", isDirectory: true)
        )

    }

    var menuBarSymbol: String {
        switch operation {
        case .error: "exclamationmark.triangle.fill"
        case .discovering, .preparing, .switching: "arrow.triangle.2.circlepath"
        case .running: "play.circle.fill"
        case .ready: "rectangle.connected.to.line.below"
        }
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
        switch selectedBackend {
        case .crossOver:
            if let crossOver = installations.crossOver {
                let graphics = crossOver.defaultGraphicsBackend.map { " · gráfico \($0)" } ?? ""
                return "CrossOver \(crossOver.version) · botella \(crossOver.bottleName)\(graphics)"
            }
            return installations.crossOverIssue?.message ?? "CrossOver no disponible"
        case .regression:
            return installations.regression.healthDetail
        }
    }

    func learnedSummary(for game: SteamGame) -> String? {
        if let certification = VerifiedGameCatalog.certification(for: game.appID) {
            return "Verificado perfecto: \(certification.backend.displayName)"
        }

        let candidates = profiles.filter { $0.appID == game.appID }
        guard !candidates.isEmpty else { return nil }
        if let verified = candidates
            .filter({ $0.perfectRuns > 0 || $0.playableRuns > 0 })
            .sorted(by: {
                if $0.perfectRuns != $1.perfectRuns { return $0.perfectRuns > $1.perfectRuns }
                if $0.playableRuns != $1.playableRuns { return $0.playableRuns > $1.playableRuns }
                return $0.failedRuns < $1.failedRuns
            })
            .first {
            return verified.perfectRuns > 0
                ? "Verificado perfecto: \(verified.backend.displayName)"
                : "Mejor perfil observado: \(verified.backend.displayName)"
        }
        let failures = candidates.reduce(0) { $0 + $1.failedRuns }
        return failures > 0 ? "\(failures) prueba(s) con incidencias" : "Pendiente de verificación visual"
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
        } catch {
            present(error)
        }

        await refreshDiscovery()
        LifecycleDiagnostics.write("Detección completada")
        logger.info("Detección terminada; CrossOver disponible: \(self.installations?.crossOver != nil)")
        await beginTelemetryMonitoring()
        await refreshRuntimeState()
        logger.info("Estado de procesos: CrossOver=\(self.runningState.crossOverIsRunning), Regression=\(self.runningState.regressionIsRunning)")
        await refreshStoredData()

        // La red nunca debe retrasar la función principal de la aplicación.
        // CrossOver sigue gestionando sus propias actualizaciones; esta consulta
        // solo enriquece el estado que mostramos en segundo plano.
        Task { [weak self] in
            await self?.refreshUpdateStatus()
        }

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
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
        refreshGames()
        await refreshSharedLibraryAssessment()
    }

    func refreshAll() async {
        failure = nil
        operation = .discovering
        statusDetail = "Actualizando instalaciones y estado…"
        await refreshDiscovery()
        await refreshRuntimeState()
        await refreshStoredData()
        await refreshUpdateStatus()
        if failure == nil {
            operation = runningState.activeBackend.map(AppOperation.running) ?? .ready
            statusDetail = "Estado actualizado."
        }
    }

    func startSteam() async {
        guard let installations else { return }
        LifecycleDiagnostics.write("startSteam invocado")
        logger.info("startSteam con \(self.selectedBackend.rawValue)")
        failure = nil
        if runningState.activeBackend != nil {
            showSteam()
            return
        }
        operation = .preparing("Iniciando Steam con \(selectedBackend.displayName)")
        statusDetail = "CrossOver puede actualizar la botella automáticamente antes de abrir Steam."
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

    func selectBackend(_ backend: BackendKind) async {
        guard backend != selectedBackend, let installations else { return }
        failure = nil
        operation = .switching(backend)
        statusDetail = "Cerrando de forma segura el Steam actual antes de cambiar de motor…"
        let previous = selectedBackend
        do {
            let launch = try await coordinator.switchBackend(
                from: runningState.activeBackend,
                to: backend,
                installations: installations
            )
            selectedBackend = backend
            UserDefaults.standard.set(backend.rawValue, forKey: "selectedBackend")
            try await confirmSteamLaunch(launch)
            refreshGames()
        } catch {
            selectedBackend = previous
            presentLaunchError(error)
        }
    }

    func launchGame(_ game: SteamGame) async {
        guard let installations else { return }
        failure = nil
        operation = .preparing("Iniciando \(game.name)")
        statusDetail = "Registrando la configuración de compatibilidad antes del lanzamiento…"
        do {
            if let active = runningState.activeBackend, active != selectedBackend {
                let steamLaunch = try await coordinator.switchBackend(
                    from: active,
                    to: selectedBackend,
                    installations: installations
                )
                try await confirmSteamLaunch(steamLaunch)
            }

            let launch = try await coordinator.launchSteam(
                backend: selectedBackend,
                installations: installations,
                appID: game.appID
            )
            let metadata = backendMetadata(installations: installations, backend: selectedBackend)
            var configuration = ConfigurationCollector.snapshot(
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
            let context = RunContext(
                appID: game.appID,
                gameName: game.name,
                backend: selectedBackend,
                bottleName: metadata.bottleName,
                providerVersion: metadata.providerVersion,
                command: launch.command,
                arguments: launch.arguments,
                system: currentSystemSnapshot(),
                configuration: configuration,
                configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
            )
            try await telemetry.registerLaunchIntent(context: context, bottleURL: metadata.bottleURL)
            operation = .running(selectedBackend)
            statusDetail = "Solicitud enviada a Steam. Regression observará el resultado localmente."
        } catch {
            presentLaunchError(error)
        }
    }

    func configureSharedLibrary() async {
        guard let installations, let crossOver = installations.crossOver else {
            present(RegressionCoreError.crossOverNotInstalled)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Unificar las instalaciones de los juegos"
        alert.informativeText = "Steam se cerrará, la carpeta steamapps actual de Regression se moverá a una copia recuperable y Regression apuntará a la biblioteca existente de CrossOver. CrossOver y sus juegos no se modificarán. Nunca podrán ejecutarse ambos Steam a la vez."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cerrar Steam y unificar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        operation = .preparing("Unificando la biblioteca")
        statusDetail = "Creando una copia recuperable antes de enlazar steamapps…"
        do {
            let previouslyActive = runningState.activeBackend
            if let previouslyActive {
                try await coordinator.requestShutdown(
                    backend: previouslyActive,
                    installations: installations
                )
            }
            runningState = await coordinator.runningState()
            _ = try await sharedLibrary.configure(
                regression: installations.regression,
                crossOver: crossOver,
                runningState: runningState
            )
            await refreshSharedLibraryAssessment()
            refreshGames()
            statusDetail = "Ambos motores usan ahora una única carpeta de juegos."
            if let previouslyActive {
                let launch = try await coordinator.launchSteam(
                    backend: previouslyActive,
                    installations: installations
                )
                try await confirmSteamLaunch(launch)
            } else {
                operation = .ready
            }
        } catch {
            present(error)
        }
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
            let alert = NSAlert()
            alert.messageText = "¿Confirmar que \(run.gameName) funciona perfectamente?"
            alert.informativeText = "Guarda esta certificación solo después de comprobar visualmente el render, la precisión de entrada, las opciones gráficas y el gameplay con \(run.backend.displayName)."
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

        let verification: RunVerification
        switch verdict {
        case .perfect:
            verification = RunVerification(
                runID: run.id,
                verdict: verdict,
                rendering: .passed,
                inputPrecision: .passed,
                graphicsSettings: .passed,
                source: .user,
                notes: "Verificación manual completa"
            )
        case .playableWithIssues:
            verification = RunVerification(
                runID: run.id,
                verdict: verdict,
                source: .user,
                notes: notes
            )
        case .failed:
            verification = RunVerification(
                runID: run.id,
                verdict: verdict,
                rendering: .failed,
                source: .user,
                notes: notes
            )
        }

        do {
            try await repository.verifyRun(verification)
            await refreshStoredData()
            statusDetail = "La verificación de \(run.gameName) quedó guardada localmente."
        } catch {
            present(error)
        }
    }

    func toggleAutoLaunch(_ enabled: Bool) {
        autoLaunchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "autoLaunchEnabled")
    }

    func openCrossOver() {
        guard let url = installations?.crossOver?.applicationURL else {
            if let website = URL(string: "https://www.codeweavers.com/crossover") {
                NSWorkspace.shared.open(website)
            }
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
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
        if let application = candidates.first {
            application.activate(options: [.activateAllWindows])
        } else {
            Task { await startSteam() }
        }
    }

    func recover(_ recovery: UserFacingFailure.Recovery) async {
        switch recovery {
        case .openCrossOver: openCrossOver()
        case .chooseRegression: await selectBackend(.regression)
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
        let log = (try? String(contentsOf: launch.logURL, encoding: .utf8)) ?? ""
        let excerpt = PrivacySanitizer.redactedLogExcerpt(log)
        throw RegressionCoreError.launchFailed(excerpt.isEmpty ? "Steam no apareció tras 30 segundos" : excerpt)
    }

    private func periodicRefresh() async {
        periodicRefreshCount += 1
        await refreshRuntimeState()
        await pollTelemetry()
        await processLauncher.reapFinishedProcesses()
        if periodicRefreshCount.isMultiple(of: 5) {
            await refreshSharedLibraryAssessment()
            await refreshStoredData()
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
    }

    private func refreshGames() {
        guard let installations else {
            games = []
            return
        }
        var byID: [String: SteamGame] = [:]
        if let crossOver = installations.crossOver {
            for game in SteamManifestParser.games(in: crossOver.steamRootURL, backend: .crossOver) {
                byID[game.appID] = game
            }
        }
        for game in SteamManifestParser.games(in: installations.regression.steamRootURL, backend: .regression) {
            if byID[game.appID] == nil || selectedBackend == .regression {
                byID[game.appID] = game
            }
        }
        games = byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func beginTelemetryMonitoring() async {
        guard let installations else { return }
        if let crossOver = installations.crossOver {
            await telemetry.beginMonitoring(
                logURL: crossOver.steamRootURL.appendingPathComponent("logs/gameprocess_log.txt")
            )
        }
        await telemetry.beginMonitoring(
            logURL: installations.regression.steamRootURL.appendingPathComponent("logs/gameprocess_log.txt")
        )
    }

    private func pollTelemetry() async {
        guard let installations else { return }
        let system = currentSystemSnapshot()
        if let crossOver = installations.crossOver {
            let crossGames = SteamManifestParser.games(in: crossOver.steamRootURL, backend: .crossOver)
            await telemetry.poll(
                backend: .crossOver,
                logURL: crossOver.steamRootURL.appendingPathComponent("logs/gameprocess_log.txt"),
                games: crossGames,
                system: system,
                steamRootURL: crossOver.steamRootURL,
                bottleURL: crossOver.bottleURL,
                bottleName: crossOver.bottleName,
                providerVersion: crossOver.version,
                configurationOverrides: configurationOverrides(
                    installations: installations,
                    backend: .crossOver
                )
            )
        }
        let regression = installations.regression
        let ownGames = SteamManifestParser.games(in: regression.steamRootURL, backend: .regression)
        await telemetry.poll(
            backend: .regression,
            logURL: regression.steamRootURL.appendingPathComponent("logs/gameprocess_log.txt"),
            games: ownGames,
            system: system,
            steamRootURL: regression.steamRootURL,
            bottleURL: regression.bottleURL,
            bottleName: "Steam",
            providerVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )
    }

    private func refreshStoredData() async {
        recentRuns = (try? await repository.recentRuns()) ?? []
        profiles = (try? await repository.compatibilityProfiles()) ?? []
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

    private func refreshUpdateStatus() async {
        guard let crossOver = installations?.crossOver else {
            updateStatus = nil
            return
        }
        updateStatus = await updateChecker.check(crossOver)
    }

    private func backendMetadata(
        installations: InstallationSnapshot,
        backend: BackendKind
    ) -> (bottleURL: URL, bottleName: String, providerVersion: String) {
        switch backend {
        case .crossOver:
            let crossOver = installations.crossOver!
            return (crossOver.bottleURL, crossOver.bottleName, crossOver.version)
        case .regression:
            return (
                installations.regression.bottleURL,
                "Steam",
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
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
        let raw = error.localizedDescription
        let lowercased = raw.lowercased()
        if lowercased.contains("license") || lowercased.contains("licencia")
            || lowercased.contains("trial") || lowercased.contains("expired") {
            failure = UserFacingFailure(
                title: "CrossOver necesita revisar la licencia",
                message: "Abre CrossOver para renovar o validar la licencia y vuelve a intentarlo.",
                recovery: .openCrossOver
            )
            operation = .error
        } else {
            present(error)
        }
    }

    private func present(_ error: Error) {
        logger.error("Error presentado: \(error.localizedDescription, privacy: .public)")
        let recovery: UserFacingFailure.Recovery
        if selectedBackend == .crossOver {
            recovery = installations?.regression.health == .ready ? .chooseRegression : .openCrossOver
        } else {
            recovery = .refresh
        }
        failure = UserFacingFailure(
            title: "No se pudo completar la operación",
            message: error.localizedDescription,
            recovery: recovery
        )
        operation = .error
        statusDetail = error.localizedDescription
    }
}
