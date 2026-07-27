import AppKit
import RegressionCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: RegressionAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                primaryActions
                backendSection
                gamesSection
                librarySection
                dataSection
                maintenanceSection
                footer
            }
            .padding(16)
        }
        .frame(width: 390, height: 620)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Regression")
                    .font(.headline)
                Text("Steam para Windows en macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        Image(systemName: model.menuBarSymbol)
            .foregroundStyle(statusColor)
            .accessibilityLabel(model.statusTitle)
    }

    private var statusColor: Color {
        switch model.operation {
        case .error: .red
        case .running: .green
        case .discovering, .preparing, .switching: .blue
        case .ready: .secondary
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.statusTitle)
                    .font(.headline)
                Spacer()
                if model.operation.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(model.statusDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure = model.failure {
                Divider()
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button(recoveryTitle(failure.recovery)) {
                    Task { await model.recover(failure.recovery) }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var primaryActions: some View {
        HStack {
            Button(model.primaryActionTitle) {
                Task { await model.startSteam() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.operation.isBusy)

            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Actualizar estado")
            .disabled(model.operation.isBusy)
        }
    }

    private var backendSection: some View {
        GroupBox("Motor de ejecución") {
            VStack(alignment: .leading, spacing: 8) {
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
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var gamesSection: some View {
        if !model.games.isEmpty {
            GroupBox("Juegos instalados") {
                VStack(spacing: 0) {
                    ForEach(model.games) { game in
                        HStack(spacing: 10) {
                            Image(systemName: "gamecontroller")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(game.name)
                                    .lineLimit(1)
                                Text("App ID \(game.appID) · \(game.sourceBackend.displayName)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if let learned = model.learnedSummary(for: game) {
                                    Text(learned)
                                        .font(.caption2)
                                        .foregroundStyle(learned.hasPrefix("Verificado perfecto") ? .green : .secondary)
                                }
                            }
                            Spacer()
                            Button {
                                Task { await model.launchGame(game) }
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Iniciar \(game.name)")
                            .disabled(model.operation.isBusy)
                        }
                        .padding(.vertical, 7)
                        if game.id != model.games.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var librarySection: some View {
        GroupBox("Biblioteca compartida") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: libraryIsReady ? "checkmark.circle.fill" : "externaldrive.badge.plus")
                    .foregroundStyle(libraryIsReady ? .green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(libraryStatusText)
                        .font(.callout)
                    if !libraryIsReady, model.installations?.crossOver != nil {
                        Button("Unificar instalaciones…") {
                            Task { await model.configureSharedLibrary() }
                        }
                        .disabled(model.operation.isBusy)
                    }
                }
                Spacer()
            }
            .padding(.top, 4)
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

    private var dataSection: some View {
        GroupBox("Aprendizaje local") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(model.recentRuns.count) ejecuciones", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(model.profiles.count) perfiles")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Text("Los registros se normalizan y permanecen en este Mac. No se guardan credenciales ni datos de cuenta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Exportar JSON…") {
                        Task { await model.exportCompatibilityData() }
                    }
                    Button("Mostrar datos") { model.openDataFolder() }
                }

                if !model.recentRuns.isEmpty {
                    DisclosureGroup("Ejecuciones recientes") {
                        VStack(spacing: 0) {
                            ForEach(Array(model.recentRuns.prefix(5))) { run in
                                HStack {
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
                                    .help("Verificar esta ejecución")
                                }
                                .padding(.vertical, 5)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        }
    }

    private var maintenanceSection: some View {
        DisclosureGroup("Mantenimiento") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Abrir Steam al iniciar Regression", isOn: Binding(
                    get: { model.autoLaunchEnabled },
                    set: { model.toggleAutoLaunch($0) }
                ))

                if let update = model.updateStatus {
                    HStack {
                        Text("CrossOver \(update.installedVersion)")
                        Spacer()
                        Text(update.updateAvailable ? "Actualización disponible" : "Actualizado")
                            .foregroundStyle(update.updateAvailable ? .orange : .secondary)
                    }
                    .font(.caption)
                    Text(update.automaticChecksEnabled && update.automaticInstallationEnabled
                         ? "Las actualizaciones automáticas de CrossOver están activadas."
                         : "Revisa las preferencias de actualización en CrossOver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Abrir CrossOver para actualizar o reparar") {
                    model.openCrossOver()
                }
            }
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack {
            Text("Motor propio conservado para desarrollo futuro")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Salir") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
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
        case nil: run.result == .crashed ? "bolt.trianglebadge.exclamationmark.fill" : "clock"
        }
    }

    private func verificationColor(for run: RunSummary) -> Color {
        switch run.verification?.verdict {
        case .perfect: .green
        case .playableWithIssues: .orange
        case .failed: .red
        case nil: run.result == .crashed ? .red : .secondary
        }
    }

    private func verificationLabel(for run: RunSummary) -> String {
        if let verdict = run.verification?.verdict {
            return verdict.displayName
        }
        return run.result == .crashed ? "Cierre inesperado" : "Pendiente de verificación"
    }
}
