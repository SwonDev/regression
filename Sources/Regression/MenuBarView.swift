import AppKit
import RegressionCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: RegressionAppModel

    @State private var gamesAreExpanded = true
    @State private var learningIsExpanded = false
    @State private var maintenanceIsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusCard
                primaryActions
                backendAndLibrarySection
                overviewMetrics
                gamesSection
                dataSection
                maintenanceSection
                footer
            }
            .padding(16)
        }
        .frame(width: 390, height: 620)
    }

    private var header: some View {
        HStack(spacing: 11) {
            RegressionMenuBarIcon(
                state: RegressionMenuBarIconState(operation: model.operation),
                size: 30
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Regression")
                    .font(.headline)
                Text("Steam para Windows en macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            RegressionStatusBadge(
                title: statusBadgeTitle,
                systemImage: statusBadgeSymbol,
                color: statusColor
            )
        }
    }

    private var statusCard: some View {
        RegressionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(model.statusTitle)
                        .font(.headline)
                    Spacer()
                    if model.operation.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Operación en curso")
                    }
                }

                Text(model.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure = model.failure {
                    Divider()
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(recoveryTitle(failure.recovery)) {
                        Task { await model.recover(failure.recovery) }
                    }
                }
            }
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.startSteam() }
            } label: {
                Label(
                    model.primaryActionTitle,
                    systemImage: model.runningState.activeBackend == nil
                        ? "play.fill"
                        : "macwindow"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.operation.isBusy)

            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Actualizar estado")
            .accessibilityHint("Vuelve a detectar instalaciones, biblioteca y perfiles locales")
            .help("Actualizar estado")
            .disabled(model.operation.isBusy)

            if model.runningState.activeBackend != nil {
                Button {
                    Task { await model.stopSteam() }
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cerrar Steam")
                .accessibilityHint("Solicita un cierre normal de la instancia activa de Steam")
                .help("Cerrar Steam…")
                .disabled(model.operation.isBusy)
            }

            Spacer()
        }
    }

    private var backendAndLibrarySection: some View {
        RegressionCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Motor y biblioteca", systemImage: "gearshape.2")

                Picker("Motor", selection: Binding(
                    get: { model.selectedBackend },
                    set: { backend in Task { await model.selectBackend(backend) } }
                )) {
                    ForEach(BackendKind.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.operation.isBusy)

                Text(model.selectedInstallationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: libraryIsReady ? "checkmark.circle.fill" : "externaldrive.badge.plus")
                        .foregroundStyle(libraryIsReady ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(libraryStatusText)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if !libraryIsReady, model.installations?.crossOver != nil {
                            Button("Unificar instalaciones…") {
                                Task { await model.configureSharedLibrary() }
                            }
                            .disabled(model.operation.isBusy)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var overviewMetrics: some View {
        HStack(spacing: 8) {
            RegressionMetric(
                value: model.games.count,
                label: "juegos",
                systemImage: "gamecontroller"
            )
            RegressionMetric(
                value: verifiedGameCount,
                label: "verificados",
                systemImage: "checkmark.seal"
            )
            RegressionMetric(
                value: model.engineProfiles.count,
                label: "motores",
                systemImage: "gearshape.2"
            )
        }
    }

    private var gamesSection: some View {
        RegressionCard {
            DisclosureGroup(isExpanded: $gamesAreExpanded) {
                Group {
                    if model.games.isEmpty {
                        Label(
                            model.operation == .discovering
                                ? "Buscando juegos instalados…"
                                : "No se detectaron juegos en la biblioteca de Steam.",
                            systemImage: "magnifyingglass"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.games) { game in
                                gameRow(game)
                                if game.id != model.games.last?.id { Divider() }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            } label: {
                HStack {
                    Label("Juegos instalados", systemImage: "gamecontroller")
                        .font(.headline)
                    Spacer()
                    Text(model.games.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func gameRow(_ game: SteamGame) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .lineLimit(1)
                Text("App ID \(game.appID) · \(game.sourceBackend.displayName)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let learned = model.learnedSummary(for: game) {
                    Label {
                        Text(learned)
                    } icon: {
                        if learned.hasPrefix("Verificado perfecto") {
                            Image(systemName: "checkmark.seal.fill")
                        }
                    }
                    .font(.caption2.weight(learned.hasPrefix("Verificado perfecto") ? .semibold : .regular))
                    .foregroundStyle(learned.hasPrefix("Verificado perfecto") ? .green : .secondary)
                }
                if let external = model.externalSummary(for: game) {
                    Button {
                        model.openExternalCompatibility(for: game)
                    } label: {
                        Label(
                            external,
                            systemImage: model.externalURL(for: game) == nil
                                ? "globe.europe.africa"
                                : "arrow.up.right.square"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            model.externalURL(for: game) == nil ? Color.secondary : Color.blue
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.publicCatalogOperation.isSyncing && model.externalURL(for: game) == nil)
                    .accessibilityHint("Abre la ficha pública de compatibilidad de CodeWeavers")
                    .help("Consultar en CodeWeavers")
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.launchGame(game) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Iniciar \(game.name)")
            .accessibilityHint("Solicita a Steam que abra el juego con \(model.selectedBackend.displayName)")
            .help("Iniciar \(game.name)")
            .disabled(model.operation.isBusy)
        }
        .padding(.vertical, 7)
    }

    private var dataSection: some View {
        RegressionCard {
            DisclosureGroup(isExpanded: $learningIsExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("\(model.recentRuns.count) ejecuciones recientes · \(model.profiles.count) perfiles · \(model.engineProfiles.count) motores normalizados")
                        .font(.callout)
                    Text("Los registros permanecen en este Mac. No se guardan credenciales ni datos de la cuenta de Steam.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack(spacing: 8) {
                        Label("Blindados activos", systemImage: "checkmark.shield.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Text(model.certifications.count, format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("Los blindados manuales conservan el motor y la configuración exactos que el usuario confirmó. Persisten tras reiniciar y también se incluyen en la exportación.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.certifications) { certification in
                        certificationRow(certification)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Label("Referencia pública", systemImage: "globe.europe.africa")
                            .font(.callout.weight(.medium))
                        Spacer()
                        if model.publicCatalogOperation.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Comparando con CodeWeavers")
                        }
                    }

                    Toggle("Comparar con CodeWeavers", isOn: Binding(
                        get: { model.publicCatalogEnabled },
                        set: { model.togglePublicCatalog($0) }
                    ))
                    .toggleStyle(.switch)

                    Text(model.publicCatalogStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("La consulta usa únicamente el nombre público del juego, respeta la cadencia publicada por CodeWeavers y conserva solo metadatos normalizados. Sus valoraciones nunca certifican ni reconfiguran Regression.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Actualizar referencia") { model.refreshPublicCatalog() }
                            .disabled(!model.publicCatalogEnabled || model.publicCatalogOperation.isSyncing)
                        Button("Abrir CodeWeavers") { model.openPublicCatalog() }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Label("Evolución tecnológica", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(researchTechnologies.count) tecnologías · \(model.activeRuntimeCandidateCount) experimentos")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("Un juego perfecto conserva su baseline. Las versiones nuevas se miden en perfiles aislados y solo pueden promocionarse con rollback, matriz completa y mejora demostrada.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(researchTechnologies.prefix(5)) { technology in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(technology.displayName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(technology.stableVersion ?? "sin baseline") → \(technology.latestKnownVersion ?? "por revisar")")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Label(
                        "Rosetta seguirá siendo válida hasta macOS 27; la ruta nativa sin Rosetta ya figura como prioridad de I+D.",
                        systemImage: "apple.intelligence"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("Regression observa y recomienda: todavía no descarga, repara ni cambia motores automáticamente.")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    if let health = model.databaseHealth {
                        Divider()
                        Label {
                            Text(
                                health.isHealthy
                                    ? "Base íntegra · esquema v\(health.schemaVersion)"
                                    : "La base local necesita revisión"
                            )
                        } icon: {
                            Image(systemName: health.isHealthy ? "checkmark.shield" : "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundStyle(health.isHealthy ? Color.secondary : Color.red)
                    }

                    HStack {
                        Button("Exportar JSON…") {
                            Task { await model.exportCompatibilityData() }
                        }
                        Button("Mostrar datos") { model.openDataFolder() }
                    }

                    if !model.recentRuns.isEmpty {
                        Divider()
                        recentRuns
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Aprendizaje local", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }
        }
    }

    private var recentRuns: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.recentRuns.prefix(5))) { run in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.gameName).lineLimit(1)
                        Text("\(run.backend.displayName) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: verificationSymbol(for: run))
                        .foregroundStyle(verificationColor(for: run))
                        .accessibilityLabel(verificationLabel(for: run))
                    Menu {
                        Button("Confirmar funcionamiento perfecto") {
                            Task { await model.verifyRun(run, verdict: .perfect) }
                        }
                        .disabled(run.processID == nil || run.result == .preparing)
                        Button("Funciona con incidencias…") {
                            Task { await model.verifyRun(run, verdict: .playableWithIssues) }
                        }
                        Button("No funciona…") {
                            Task { await model.verifyRun(run, verdict: .failed) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Verificar la ejecución de \(run.gameName)")
                    .help("Verificar esta ejecución")
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var maintenanceSection: some View {
        RegressionCard {
            DisclosureGroup(isExpanded: $maintenanceIsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Abrir Steam al iniciar Regression", isOn: Binding(
                        get: { model.autoLaunchEnabled },
                        set: { model.toggleAutoLaunch($0) }
                    ))

                    if let update = model.updateStatus {
                        HStack {
                            Text("CrossOver \(update.installedVersion)")
                            Spacer()
                            Text(updateStatusText(update))
                                .foregroundStyle(update.updateAvailable ? .orange : .secondary)
                        }
                        .font(.caption)
                        Text(update.automaticChecksEnabled && update.automaticInstallationEnabled
                             ? "CrossOver gestiona sus actualizaciones automáticamente."
                             : "Revisa las preferencias de actualización de CrossOver.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Abrir CrossOver para actualizar o reparar") {
                        model.openCrossOver()
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Mantenimiento", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
            }
        }
    }

    private func certificationRow(_ certification: VerifiedGameCertification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(certification.gameName)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(certification.backend.displayName) · \(certificationSourceText(certification))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let fingerprint = certification.engineFingerprint {
                    Text("Motor \(fingerprint.prefix(10))…")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Text(versionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Salir de Regression") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private var statusBadgeTitle: String {
        switch model.operation {
        case .ready: "Listo"
        case .running: "Activo"
        case .discovering, .preparing, .switching: "Preparando"
        case .error: "Atención"
        }
    }

    private var statusBadgeSymbol: String {
        switch model.operation {
        case .ready: "checkmark"
        case .running: "play.fill"
        case .discovering, .preparing, .switching: "ellipsis"
        case .error: "exclamationmark"
        }
    }

    private var statusColor: Color {
        switch model.operation {
        case .error: .red
        case .running: .green
        case .discovering, .preparing, .switching: .blue
        case .ready: .secondary
        }
    }

    private var verifiedGameCount: Int {
        model.games.filter {
            model.learnedSummary(for: $0)?.hasPrefix("Verificado perfecto") == true
        }.count
    }

    private var researchTechnologies: [RuntimeTechnology] {
        model.runtimeTechnologies.filter(\.hasResearchCandidate)
    }

    private func certificationSourceText(_ certification: VerifiedGameCertification) -> String {
        switch certification.origin {
        case .localVerification: "verificación manual persistente"
        case .embeddedCatalog:
            certification.sourceRunID != nil || certification.sourceObservationID != nil
                ? "catálogo protegido · evidencia local"
                : "catálogo protegido"
        }
    }

    private var libraryIsReady: Bool {
        guard let assessment = model.sharedLibraryAssessment else { return false }
        if case .ready = assessment.status { return true }
        return false
    }

    private var libraryStatusText: String {
        guard let assessment = model.sharedLibraryAssessment else {
            return "Disponible cuando CrossOver y Steam estén configurados."
        }
        switch assessment.status {
        case .ready:
            return "CrossOver y Regression usan los mismos archivos de juego."
        case .notConfigured:
            return "CrossOver conserva la biblioteca canónica; aún no está enlazada a Regression."
        case let .blocked(reason):
            return "No disponible: \(reason)"
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "desarrollo"
        return "Regression \(version) · datos locales"
    }

    private func recoveryTitle(_ recovery: UserFacingFailure.Recovery) -> String {
        switch recovery {
        case .openCrossOver: "Abrir CrossOver"
        case .chooseRegression: "Usar Regression"
        case .refresh: "Reintentar"
        }
    }

    private func verificationSymbol(for run: RunSummary) -> String {
        switch run.verification?.verdict {
        case .perfect: "checkmark.circle.fill"
        case .playableWithIssues: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .invalidated: "slash.circle"
        case nil: run.result == .crashed ? "bolt.trianglebadge.exclamationmark.fill" : "clock"
        }
    }

    private func verificationColor(for run: RunSummary) -> Color {
        switch run.verification?.verdict {
        case .perfect: .green
        case .playableWithIssues: .orange
        case .failed: .red
        case .invalidated: .secondary
        case nil: run.result == .crashed ? .red : .secondary
        }
    }

    private func verificationLabel(for run: RunSummary) -> String {
        if let verdict = run.verification?.verdict {
            return verdict.displayName
        }
        return run.result == .crashed ? "Cierre inesperado" : "Pendiente de verificación"
    }

    private func updateStatusText(_ update: CrossOverUpdateStatus) -> String {
        guard let availableVersion = update.availableVersion else {
            return "Versión no comprobada"
        }
        return update.updateAvailable
            ? "Disponible: \(availableVersion)"
            : "Actualizado"
    }
}
