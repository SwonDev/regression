import AppKit
import RegressionCore
import SwiftUI

struct MenuBarView: View {
  private enum ComponentSlot {
    case steamRuntime
    case windowsMedia
  }

  private static let gamePageSize = 24
  private static let certificationPageSize = 8

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: RegressionAppModel

  @State private var gamesAreExpanded = true
  @State private var errorDetailsAreExpanded = false
  @State private var learningIsExpanded = false
  @State private var maintenanceIsExpanded = false
  @State private var gameSearchText = ""
  @State private var visibleGameCount = Self.gamePageSize
  @State private var visibleCertificationCount = Self.certificationPageSize

  init(model: RegressionAppModel) {
    self.model = model
    #if DEBUG
      _maintenanceIsExpanded = State(
        initialValue: RegressionVisualFixtureState.requested?.expandsMaintenance == true
      )
    #endif
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        operationalHeader
        primaryActions
        libraryIndependenceSection
        backendAndLibrarySection
        gamesSection
        dataSection
        maintenanceSection
        footer
      }
      .padding(16)
      .regressionFont(.callout)
      .controlSize(dynamicTypeSize.isAccessibilitySize ? .large : .regular)
    }
    .frame(width: 390, height: 620)
    .onChange(of: model.steamRuntimePrerequisitesHealth?.status) { _, status in
      if let status, status != .ready {
        maintenanceIsExpanded = true
      }
    }
    .onChange(of: model.windowsMediaHealth?.status) { _, status in
      if let status, status != .ready {
        maintenanceIsExpanded = true
      }
    }
    .onChange(of: model.appleGPTKState) { _, state in
      if state != .ready {
        maintenanceIsExpanded = true
      }
    }
    .sheet(item: $model.appleGPTKLicenseReview) { review in
      let sheet = AppleGPTKLicenseSheet(model: model, review: review)
      #if DEBUG
        // Las sheets macOS se alojan en otra frontera de presentación y no heredan de forma
        // fiable el entorno artificial del fixture raíz. Reinyectarlo aquí mantiene la captura
        // determinista; en producción la hoja recibe exclusivamente el entorno real del sistema.
        sheet.modifier(RegressionVisualFixtureEnvironment())
      #else
        sheet
      #endif
    }
  }

  private var operationalHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        RegressionMenuBarIcon(
          state: RegressionMenuBarIconState(operation: model.operation),
          size: 18
        )
        .accessibilityHidden(true)

        Text("Regression")
          .regressionFont(.callout.weight(.semibold))

        Spacer(minLength: 8)

        if model.operation.isBusy && !model.libraryIndependenceState.isBusy {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Operación en curso")
        } else {
          RegressionStatusBadge(
            title: statusBadgeTitle,
            systemImage: statusBadgeSymbol,
            color: statusColor
          )
        }
      }

      Text(operationalTitle)
        .regressionFont(.headline)
        .accessibilityAddTraits(.isHeader)

      if let failure = model.failure {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(failure.message)
            .foregroundStyle(Color.primary)
        }
        .regressionFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
        Button {
          errorDetailsAreExpanded.toggle()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: errorDetailsAreExpanded ? "chevron.down" : "chevron.right")
              .accessibilityHidden(true)
            Text("Detalles técnicos")
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .regressionFont(.caption.weight(.medium))
        .frame(minHeight: 32, alignment: .leading)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityValue(errorDetailsAreExpanded ? "Expandido" : "Contraído")
        .accessibilityHint("Muestra la causa técnica sin ejecutar ninguna acción")

        if errorDetailsAreExpanded {
          Text(model.statusDetail)
            .regressionFont(.caption)
            .foregroundStyle(.regressionSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
      } else if model.steamRuntimeBlocksLaunch || appleGPTKNeedsAttention {
        Text(operationalBlockingDetail)
          .regressionFont(.callout)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(model.statusDetail)
          .regressionFont(.callout)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var primaryActions: some View {
    HStack(spacing: 8) {
      if let failure = model.failure {
        Button(recoveryTitle(failure.recovery)) {
          Task { await model.recover(failure.recovery) }
        }
        .buttonStyle(.borderedProminent)
        .regressionAccessibleControl()
        .disabled(model.operation.isBusy)
        .accessibilityHint("Aplica la recuperación recomendada antes de volver a iniciar Steam")
      } else if model.steamRuntimeBlocksLaunch {
        Button("Reparar Regression") {
          Task { await model.repairRegressionInstallation() }
        }
        .buttonStyle(.borderedProminent)
        .regressionAccessibleControl()
        .accessibilityHint(
          "Restaura VC++ y UCRT desde la release oficial sin borrar la botella ni los juegos"
        )
      } else if appleGPTKNeedsAttention {
        appleGPTKPrimaryAction
      } else if model.protectedAppleGPTKAuthorizationState == .authorizing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .small)
            .accessibilityHidden(true)
          Text("Autorizando Apple GPTK 3.0…")
            .regressionFont(.callout.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Autorizando Apple GPTK 3.0")
      } else {
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
        .regressionAccessibleControl()
        .disabled(
          model.operation.isBusy
            || model.libraryIndependenceState.blocksNormalOperations
            || (
              model.runningState.activeBackend == nil
                && model.steamRuntimeBlocksLaunch
            )
        )
        .accessibilityHint(
          model.steamRuntimeBlocksLaunch
            ? "Steam permanece bloqueado hasta restaurar y verificar VC++ y UCRT"
            : "Abre el Steam de Windows gestionado por Regression"
        )
      }

      if model.failure == nil
        && model.protectedAppleGPTKAuthorizationState != .authorizing
      {
        Button {
          Task { await model.refreshAll() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .regressionAccessibleControl()
        .accessibilityLabel("Actualizar estado")
        .accessibilityHint("Vuelve a detectar instalaciones, biblioteca y perfiles locales")
        .help("Actualizar estado")
        .disabled(model.operation.isBusy || model.libraryIndependenceState.isBusy)
      }

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
        sectionTitle("Motor", systemImage: "gearshape.2")

        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "bolt.horizontal.circle.fill")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(activeEngineTitle)
              .regressionFont(.callout.weight(.medium))
            Text(model.selectedInstallationDetail)
              .regressionFont(.caption)
              .foregroundStyle(.regressionSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 4)
        }

        Text("Steam y los juegos se ejecutan únicamente con el motor propio de Regression.")
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var libraryIndependenceSection: some View {
    RegressionCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: libraryIndependenceSymbol)
            .foregroundStyle(libraryIndependenceColor)
      Text(libraryIndependenceTitle)
            .regressionFont(.headline)
            .foregroundStyle(Color.primary)
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 8)
          if model.libraryIndependenceState.isBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(model.libraryIndependenceState.accessibilityValue)
          }
        }

        Text(libraryIndependenceDetail)
          .regressionFont(.callout)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

        RegressionCustodyProgress(state: model.libraryIndependenceState)

        if let assessment = model.physicalLibraryCustodyAssessment,
           !assessment.inventory.manifestAppIDs.isEmpty {
          Text(inventorySummary(assessment.inventory))
            .regressionFont(.caption.monospacedDigit())
            .foregroundStyle(.regressionSecondary)
        }

        libraryIndependenceActions
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Independencia de la biblioteca")
      .accessibilityValue(model.libraryIndependenceState.accessibilityValue)
      .accessibilityAddTraits(.updatesFrequently)
    }
  }

  @ViewBuilder
  private var libraryIndependenceActions: some View {
    switch model.libraryIndependenceState {
    case .eligible:
      Button("Revisar y trasladar…") {
        Task { await model.startPhysicalLibraryCustodyMigration() }
      }
      .buttonStyle(.borderedProminent)
      .regressionAccessibleControl()
      .disabled(model.operation.isBusy)
      .keyboardShortcut(.defaultAction)
      .accessibilityHint(
        "Confirma un traslado sin copia que dejará la instalación heredada sin juegos"
      )
    case .preparing:
      if model.physicalLibraryCustodyAssessmentIsRunning {
        Button("Cancelar inventario") {
          model.cancelPhysicalLibraryCustodyAssessment()
        }
        .regressionAccessibleControl()
        .accessibilityHint("Cancela antes de que comience el traslado")
      } else {
        Text("Mantén Regression abierta mientras asegura el punto de recuperación.")
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .preCutover:
      Text("Confirma el traslado en el diálogo del sistema.")
        .regressionFont(.caption)
        .foregroundStyle(.regressionSecondary)
    case .cutover, .verifying:
      Text("Mantén Regression abierta. Esta fase no se puede interrumpir con seguridad.")
        .regressionFont(.caption)
        .foregroundStyle(.regressionSecondary)
        .fixedSize(horizontal: false, vertical: true)
    case .pendingValidation:
      HStack(spacing: 8) {
        Button("Validar con Steam") {
          Task { await model.beginPhysicalLibraryCustodyValidation() }
        }
        .buttonStyle(.borderedProminent)
        .regressionAccessibleControl()
        .disabled(model.steamRuntimeBlocksLaunch)
        .keyboardShortcut(.defaultAction)
        Button("Restaurar") {
          Task { await model.rollbackPhysicalLibraryCustody() }
        }
        .regressionAccessibleControl()
        .disabled(model.runningState.activeBackend != nil)
        .accessibilityHint("Cierra Steam antes de restaurar la ubicación anterior")
      }
    case .validating:
      HStack(spacing: 8) {
        if model.runningState.regressionIsRunning {
          Button("Confirmar validación…") {
            Task { await model.finalizePhysicalLibraryCustodyValidation() }
          }
          .buttonStyle(.borderedProminent)
          .regressionAccessibleControl()
        } else {
          Button("Reabrir Steam") {
            Task { await model.beginPhysicalLibraryCustodyValidation() }
          }
          .buttonStyle(.borderedProminent)
          .regressionAccessibleControl()
          .disabled(model.steamRuntimeBlocksLaunch)
        }
        Button("Restaurar") {
          Task { await model.rollbackPhysicalLibraryCustody() }
        }
        .regressionAccessibleControl()
        .disabled(model.runningState.activeBackend != nil)
        .accessibilityHint("Cierra Steam antes de restaurar la ubicación anterior")
      }
    case .rollingBack:
      Text("Restaurando la ruta anterior y comprobando su identidad…")
        .regressionFont(.caption)
        .foregroundStyle(.regressionSecondary)
    case .error:
      if model.failure == nil {
        Button("Crear o reparar biblioteca propia") {
          Task { await model.assessPhysicalLibraryCustody() }
        }
        .buttonStyle(.borderedProminent)
        .regressionAccessibleControl()
        .accessibilityHint(
          "Crea o adopta la carpeta física de juegos de Regression y vuelve a verificar su identidad"
        )
      }
    case .independent:
      HStack(spacing: 6) {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
        Text("Biblioteca propia validada")
          .foregroundStyle(Color.primary)
      }
        .regressionFont(.caption.weight(.semibold))
    }
  }

  private var gamesSection: some View {
    RegressionCard {
      DisclosureGroup(isExpanded: $gamesAreExpanded) {
        Group {
          if model.games.isEmpty, model.operation == .discovering {
            HStack(alignment: .top, spacing: 9) {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Buscando juegos instalados")
              VStack(alignment: .leading, spacing: 3) {
                Text("Buscando juegos instalados…")
                  .regressionFont(.callout.weight(.medium))
                Text("Regression está revisando la biblioteca de Steam.")
                  .regressionFont(.caption)
                  .foregroundStyle(.regressionSecondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
          } else if model.games.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Label("No hay juegos detectados", systemImage: "gamecontroller")
                .regressionFont(.callout.weight(.medium))
              Text(
                "Actualiza la biblioteca para buscar instalaciones de Steam disponibles en este Mac."
              )
              .regressionFont(.caption)
              .foregroundStyle(.regressionSecondary)
              .fixedSize(horizontal: false, vertical: true)
              Button("Actualizar biblioteca") {
                Task { await model.refreshAll() }
              }
              .disabled(model.operation.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
          } else {
            VStack(alignment: .leading, spacing: 8) {
              TextField(
                "",
                text: $gameSearchText,
                prompt: Text("Buscar por nombre o App ID")
                  .foregroundStyle(.regressionSecondary)
              )
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Buscar juegos instalados")
              .accessibilityHint("Filtra por nombre o Steam App ID")
              .onChange(of: gameSearchText) { _, _ in
                visibleGameCount = Self.gamePageSize
              }

              let filtered = filteredGames
              if filtered.isEmpty {
                Label(
                  "No hay juegos que coincidan con la búsqueda.",
                  systemImage: "magnifyingglass"
                )
                .regressionFont(.callout)
                .foregroundStyle(.regressionSecondary)
                .padding(.vertical, 6)
              } else {
                let visible = Array(filtered.prefix(visibleGameCount))
                let remaining = max(0, filtered.count - visible.count)
                VStack(spacing: 0) {
                  ForEach(visible) { game in
                    gameRow(game)
                    if game.id != visible.last?.id { Divider() }
                  }
                }

                if remaining > 0 {
                  Button("Mostrar \(min(Self.gamePageSize, remaining)) más") {
                    visibleGameCount += Self.gamePageSize
                  }
                  .frame(maxWidth: .infinity, alignment: .center)
                  .accessibilityHint(
                    "Amplía la lista sin cargar toda la biblioteca a la vez"
                  )
                }
              }
            }
            .padding(.top, 8)
          }
        }
      } label: {
        gamesDisclosureLabel
      }
    }
  }

  @ViewBuilder
  private var gamesDisclosureLabel: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 3) {
        Label("Juegos instalados", systemImage: "gamecontroller")
          .regressionFont(.headline)
        Text(gamesSummaryText)
          .regressionFont(.caption.monospacedDigit())
          .foregroundStyle(.regressionSecondary)
      }
    } else {
      HStack {
        Label("Juegos instalados", systemImage: "gamecontroller")
          .regressionFont(.headline)
        Spacer()
        Text(gamesSummaryText)
          .regressionFont(.caption.monospacedDigit())
          .foregroundStyle(.regressionSecondary)
      }
    }
  }

  private func gameRow(_ game: SteamGame) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(game.name)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Text("App ID \(game.appID)")
          .regressionFont(.caption.monospacedDigit())
          .foregroundStyle(.regressionSecondary)
        if let learned = model.learnedSummary(for: game) {
          HStack(spacing: 5) {
            if learned.hasPrefix("Verificado perfecto") {
              Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            }
            Text(learned)
              .foregroundStyle(Color.primary)
          }
          .regressionFont(
            .caption2.weight(learned.hasPrefix("Verificado perfecto") ? .semibold : .regular)
          )
          .accessibilityElement(children: .combine)
        }
      }
      Spacer(minLength: 8)
      Button {
        Task { await model.launchGame(game) }
      } label: {
        Image(systemName: "play.fill")
          .frame(minWidth: 32, minHeight: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Iniciar \(game.name)")
      .accessibilityHint(gameLaunchAvailabilityHint(game))
      .help(gameLaunchHelp(game))
      .disabled(
        model.operation.isBusy
          || model.failure != nil
          || model.steamRuntimeBlocksLaunch
          || (
            model.libraryIndependenceState.blocksNormalOperations
              && !model.libraryIndependenceState.allowsValidationGameLaunch
          )
      )
      .padding(.top, 2)
    }
    .padding(.vertical, 7)
  }

  private var dataSection: some View {
    RegressionCard {
      DisclosureGroup(isExpanded: $learningIsExpanded) {
        VStack(alignment: .leading, spacing: 9) {
          Text(
            "\(model.recentRuns.count) ejecuciones recientes · \(model.profiles.count) perfiles · \(model.engineProfiles.count) motores normalizados"
          )
          .regressionFont(.callout)
          Text(
            "Los registros permanecen en este Mac. No se guardan credenciales ni datos de la cuenta de Steam."
          )
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

          Divider()

          HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
              .foregroundStyle(.green)
            Text("Blindados activos")
              .regressionFont(.callout.weight(.medium))
              .foregroundStyle(Color.primary)
            Spacer()
            Text(model.certifications.count, format: .number)
              .regressionFont(.caption.monospacedDigit())
              .foregroundStyle(.regressionSecondary)
          }

          Text(
            "Los blindados manuales conservan el motor y la configuración exactos que el usuario confirmó. Persisten tras reiniciar y también se incluyen en la exportación."
          )
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

          let certifications = visibleCertifications
          let remainingCertifications = max(
            0,
            sortedCertifications.count - certifications.count
          )
          ForEach(certifications) { certification in
            certificationRow(certification)
          }

          if remainingCertifications > 0 {
            Button(
              "Mostrar \(min(Self.certificationPageSize, remainingCertifications)) blindados más"
            ) {
              visibleCertificationCount += Self.certificationPageSize
            }
            .regressionFont(.caption)
          }

          Divider()

          HStack(spacing: 8) {
            Label("Evolución tecnológica", systemImage: "gauge.with.dots.needle.67percent")
              .regressionFont(.callout.weight(.medium))
            Spacer()
            Text(
              "\(researchTechnologies.count) tecnologías · \(model.activeRuntimeCandidateCount) candidatos"
            )
            .regressionFont(.caption.monospacedDigit())
            .foregroundStyle(.regressionSecondary)
          }

          Text(
            "Un juego perfecto conserva su baseline. Las versiones nuevas se miden en perfiles aislados y solo pueden promocionarse con rollback, matriz completa y mejora demostrada."
          )
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

          ForEach(researchTechnologies.prefix(5)) { technology in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(technology.displayName)
                .regressionFont(.caption)
                .lineLimit(1)
              Spacer()
              Text(
                "\(technology.stableVersion ?? "sin baseline") → \(technology.latestKnownVersion ?? "por revisar")"
              )
              .regressionFont(.caption2.monospacedDigit())
              .foregroundStyle(.regressionSecondary)
              .lineLimit(1)
            }
          }

          Label(
            "Rosetta seguirá siendo válida hasta macOS 27; la ruta nativa sin Rosetta ya figura como prioridad de I+D.",
            systemImage: "apple.intelligence"
          )
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
              .foregroundStyle(.orange)
            Text(
              "Regression observa y recomienda: todavía no descarga, repara ni cambia motores automáticamente."
            )
            .foregroundStyle(Color.primary)
          }
          .regressionFont(.caption2.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)

          Divider()

          HStack(spacing: 8) {
            Label("I+D verificable", systemImage: "checklist.checked")
              .regressionFont(.callout.weight(.medium))
            Spacer()
            Text(
              "\(model.activeResearchCaseCount) casos · \(model.activeResearchExperimentCount) pruebas"
            )
            .regressionFont(.caption.monospacedDigit())
            .foregroundStyle(.regressionSecondary)
          }

          Text(
            "Cada caso conserva su referencia técnica, hipótesis ordenadas, una sola variable por prueba, rollback y la matriz visual completa. Ningún expediente puede cerrarse sin un blindado exacto de Regression."
          )
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

          if let health = model.databaseHealth {
            Divider()
            HStack(spacing: 6) {
              Image(
                systemName: health.isHealthy ? "checkmark.shield" : "exclamationmark.triangle"
              )
              .foregroundStyle(health.isHealthy ? Color.secondary : Color.red)
              Text(
                health.isHealthy
                  ? "Base íntegra · esquema v\(health.schemaVersion)"
                  : "La base local necesita revisión"
              )
              .foregroundStyle(Color.primary)
              Spacer()
              Text("\(health.processCount) procesos · \(health.preflightReportCount) diagnósticos")
                .regressionFont(.caption2.monospacedDigit())
                .foregroundStyle(.regressionSecondary)
            }
            .regressionFont(.caption)
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
          .regressionFont(.headline)
      }
    }
  }

  private var recentRuns: some View {
    VStack(spacing: 0) {
      ForEach(Array(model.recentRuns.prefix(5))) { run in
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 1) {
            Text(run.gameName).lineLimit(1)
            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
            .regressionFont(.caption)
            .foregroundStyle(.regressionSecondary)
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
          HStack(spacing: 8) {
            Image(systemName: readinessSymbol)
              .foregroundStyle(readinessColor)
            Text("Preparación para pruebas")
              .regressionFont(.callout.weight(.medium))
              .foregroundStyle(Color.primary)
            Spacer()
            if model.readinessIsRefreshing {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Comprobando el entorno")
            }
          }

          if let readiness = model.testReadiness {
            Text(readinessSummary(readiness))
              .regressionFont(.caption)
              .foregroundStyle(Color.primary)
              .fixedSize(horizontal: false, vertical: true)

            let issues = readiness.checks.filter { $0.status != .ready }
            if !issues.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { check in
                  VStack(alignment: .leading, spacing: 1) {
                    Text(check.title)
                      .regressionFont(.caption.weight(.medium))
                    Text(check.detail)
                      .regressionFont(.caption2)
                      .foregroundStyle(.regressionSecondary)
                      .fixedSize(horizontal: false, vertical: true)
                    if let action = check.recoveryAction {
                      Text(action)
                        .regressionFont(.caption2)
                        .foregroundStyle(.regressionSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                  }
                }
              }
            }
          } else {
            Text("Todavía no se ha comprobado el entorno de pruebas.")
              .regressionFont(.caption)
              .foregroundStyle(.regressionSecondary)
          }

          Button("Comprobar entorno") {
            Task { await model.refreshTestReadiness() }
          }
          .regressionAccessibleControl()
          .disabled(model.readinessIsRefreshing || model.operation.isBusy)

          Divider()

          RegressionComponentHealthView(
            title: "Runtime de juegos",
            systemImage: steamRuntimeSymbol,
            color: steamRuntimeColor,
            summary: steamRuntimeSummary,
            detail: steamRuntimeDetail,
            isRefreshing: model.steamRuntimePrerequisitesHealthIsRefreshing,
            refreshingAccessibilityLabel: "Verificando VC++ y UCRT"
          ) {
            componentRecoveryButton(for: .steamRuntime)
          }

          Divider()

          RegressionComponentHealthView(
            title: "Componente multimedia",
            systemImage: windowsMediaSymbol,
            color: windowsMediaColor,
            summary: windowsMediaSummary,
            detail: windowsMediaDetail,
            isRefreshing: model.windowsMediaHealthIsRefreshing,
            refreshingAccessibilityLabel: "Verificando Windows Media"
          ) {
            componentRecoveryButton(for: .windowsMedia)
          }

          Divider()

          RegressionComponentHealthView(
            title: "Apple GPTK 4.0b2",
            systemImage: appleGPTKSymbol,
            color: appleGPTKColor,
            summary: appleGPTKSummary,
            detail: appleGPTKDetail,
            isRefreshing: model.appleGPTKIsBusy,
            refreshingAccessibilityLabel: "Verificando Apple GPTK"
          ) {
            appleGPTKActions
          }

          Divider()

          RegressionComponentHealthView(
            title: "Apple GPTK 3.0 protegido",
            systemImage: protectedAppleGPTKSymbol,
            color: protectedAppleGPTKColor,
            summary: protectedAppleGPTKSummary,
            detail: protectedAppleGPTKDetail,
            isRefreshing: model.protectedAppleGPTKAuthorizationState.isBusy,
            refreshingAccessibilityLabel: "Verificando Apple GPTK 3.0"
          ) {
            protectedAppleGPTKActions
          }

          Divider()

          Toggle(
            "Abrir Steam al iniciar Regression",
            isOn: Binding(
              get: { model.autoLaunchEnabled },
              set: { model.toggleAutoLaunch($0) }
            ))
          .regressionAccessibleControl()

          Divider()

          Toggle(
            "Actualizar Regression automáticamente",
            isOn: Binding(
              get: { model.automaticRegressionUpdatesEnabled },
              set: { model.toggleAutomaticRegressionUpdates($0) }
            ))
          .regressionAccessibleControl()
          Text(
            model.automaticRegressionUpdatesEnabled
              ? "Regression comprueba GitHub al iniciar y cada seis horas; instala en reposo y reinicia sola."
              : "Las nuevas versiones se detectan, pero esperan tu confirmación dentro de Regression."
          )
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)

          regressionUpdateSection

        }
        .padding(.top, 8)
      } label: {
        Label("Mantenimiento", systemImage: "wrench.and.screwdriver")
          .regressionFont(.headline)
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
          .regressionFont(.callout)
          .lineLimit(1)
        Text(certificationSourceText(certification))
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
        if let fingerprint = certification.engineFingerprint {
          Text("Motor \(fingerprint.prefix(10))…")
            .regressionFont(.caption2.monospacedDigit())
            .foregroundStyle(.regressionSecondary)
        }
      }
      Spacer(minLength: 4)
    }
    .accessibilityElement(children: .combine)
  }

  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        footerVersion
        Spacer()
        footerExitButton
      }
      VStack(alignment: .leading, spacing: 6) {
        footerVersion
        footerExitButton
      }
    }
  }

  private var footerVersion: some View {
    Text(versionText)
      .regressionFont(.caption.monospacedDigit())
      .foregroundStyle(.regressionSecondary)
  }

  private var footerExitButton: some View {
    Button("Salir de Regression") { NSApplication.shared.terminate(nil) }
      .buttonStyle(.borderless)
      .regressionAccessibleControl()
      .keyboardShortcut("q")
  }

  @ViewBuilder
  private var regressionUpdateSection: some View {
    switch model.regressionReleaseStatus {
    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Buscando actualizaciones de Regression…")
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
      }
    case .upToDate(let installedVersion, let checkedAt):
      HStack {
        Label("Regression \(installedVersion)", systemImage: "checkmark.circle")
        Spacer()
        Button("Comprobar") { model.refreshRegressionReleaseStatus() }
          .buttonStyle(.borderless)
          .regressionAccessibleControl()
      }
      .regressionFont(.caption)
      Text("Actualizado · comprobado \(checkedAt.formatted(date: .omitted, time: .shortened))")
        .regressionFont(.caption2)
        .foregroundStyle(.regressionSecondary)
    case .available(let installedVersion, let release):
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.circle.fill")
            .foregroundStyle(.blue)
          Text("Regression \(release.version) disponible")
            .foregroundStyle(Color.primary)
        }
        .regressionFont(.callout.weight(.medium))
        Text("Instalada: \(installedVersion). La botella, los juegos y el GPTK local se conservan.")
          .regressionFont(.caption)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
        if model.automaticRegressionUpdatesEnabled && model.runningState.regressionIsRunning {
          Text("La actualización se instalará automáticamente al cerrar Steam de Regression.")
            .regressionFont(.caption2)
            .foregroundStyle(.regressionSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.automaticRegressionUpdatesEnabled && model.regressionUpdateNeedsManualRetry {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
              .foregroundStyle(.orange)
            Text("El último intento no terminó; Regression no repetirá el ciclo automáticamente.")
              .foregroundStyle(Color.primary)
          }
            .regressionFont(.caption2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button("Actualizar y reiniciar") {
          Task { await model.installAvailableRegressionUpdate() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          model.operation.isBusy
            || model.runningState.regressionIsRunning
            || model.libraryIndependenceState.blocksNormalOperations
        )
        .help(
          model.libraryIndependenceState.blocksNormalOperations
            ? "Termina la custodia o el rollback de la biblioteca antes de actualizar"
            : model.runningState.regressionIsRunning
              ? "Cierra Steam del motor Regression antes de actualizar"
              : "Descarga, verifica e instala Regression \(release.version)"
        )
      }
    case .downloading(let version):
      updateProgress("Descargando el instalador verificado de Regression \(version)…")
    case .installing(let version):
      updateProgress("Instalando Regression \(version) y reiniciando…")
    case .failed(let message):
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Text("No se pudo comprobar o preparar la actualización")
            .foregroundStyle(Color.primary)
        }
        .regressionFont(.caption.weight(.medium))
        Text(message)
          .regressionFont(.caption2)
          .foregroundStyle(.regressionSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Reintentar") { model.refreshRegressionReleaseStatus() }
          .buttonStyle(.borderless)
      }
    }
  }

  private func updateProgress(_ title: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(title)
        .regressionFont(.caption)
        .foregroundStyle(.regressionSecondary)
    }
  }

  private var readinessSymbol: String {
    switch model.testReadiness?.status {
    case .ready: "checkmark.shield.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .blocked: "xmark.shield.fill"
    case nil: "shield.lefthalf.filled"
    }
  }

  private var readinessColor: Color {
    switch model.testReadiness?.status {
    case .ready: .green
    case .warning: .orange
    case .blocked: .red
    case nil: .secondary
    }
  }

  private func readinessSummary(_ report: GameTestPreflightReport) -> String {
    switch report.status {
    case .ready:
      "Entorno limpio para probar con Regression."
    case .warning:
      "Puede probarse con \(report.warningCount) aviso(s) que quedarán registrados."
    case .blocked:
      "Hay \(report.blockerCount) condición(es) que podrían producir un falso fallo."
    }
  }

  private func sectionTitle(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .regressionFont(.headline)
      .accessibilityAddTraits(.isHeader)
  }

  private func gameLaunchAvailabilityHint(_ game: SteamGame) -> String {
    if model.failure != nil {
      return "Resuelve primero el estado que necesita atención"
    }
    if model.libraryIndependenceState.allowsValidationGameLaunch {
      return "Inicia el juego con Regression como parte de la validación de independencia"
    }
    if model.libraryIndependenceState.blocksNormalOperations {
      return "Completa primero el traslado o la validación de la biblioteca"
    }
    if model.steamRuntimeBlocksLaunch {
      return "Reinstala la release verificada para restaurar VC++ y UCRT"
    }
    return "Solicita a Steam que abra el juego con Regression"
  }

  private func gameLaunchHelp(_ game: SteamGame) -> String {
    if model.failure != nil {
      return "No disponible hasta resolver el estado actual"
    }
    if model.steamRuntimeBlocksLaunch {
      return "No disponible hasta verificar VC++ y UCRT"
    }
    return model.libraryIndependenceState.blocksNormalOperations
      && !model.libraryIndependenceState.allowsValidationGameLaunch
      ? "No disponible durante el traslado o su validación"
      : "Iniciar \(game.name) con Regression"
  }

  private var statusBadgeTitle: String {
    if model.failure == nil, model.steamRuntimeBlocksLaunch || appleGPTKNeedsAttention {
      return "Atención"
    }
    return switch model.operation {
    case .ready: "Listo"
    case .running: "Activo"
    case .discovering, .preparing, .switching: "Preparando"
    case .error: "Atención"
    }
  }

  private var statusBadgeSymbol: String {
    if model.failure == nil, model.steamRuntimeBlocksLaunch || appleGPTKNeedsAttention {
      return "exclamationmark"
    }
    return switch model.operation {
    case .ready: "checkmark"
    case .running: "play.fill"
    case .discovering, .preparing, .switching: "ellipsis"
    case .error: "exclamationmark"
    }
  }

  private var statusColor: Color {
    if model.failure == nil, model.steamRuntimeBlocksLaunch || appleGPTKNeedsAttention {
      return .red
    }
    return switch model.operation {
    case .error: .red
    case .running: .green
    case .discovering, .preparing, .switching: .blue
    case .ready: .secondary
    }
  }

  private var activeEngineTitle: String {
    "Regression"
  }

  private var libraryIndependenceTitle: String {
    switch model.libraryIndependenceState {
    case .eligible: "Biblioteca lista para trasladar"
    case .preparing: "Comprobando la biblioteca"
    case .preCutover: "Todo listo para el traslado"
    case .cutover: "Trasladando a Regression"
    case .verifying: "Verificando la integridad"
    case .pendingValidation: "Falta validar Steam"
    case .validating: "Validando con Regression"
    case .rollingBack: "Restaurando la biblioteca"
    case .error: "La biblioteca necesita atención"
    case .independent: "Regression es independiente"
    }
  }

  private var libraryIndependenceDetail: String {
    switch model.libraryIndependenceState {
    case .eligible:
      "Los juegos se trasladarán a la botella propia de Regression. No se copiarán 110 GB y la instalación anterior quedará sin juegos. Las botellas no se compartirán."
    case .preparing:
      "Se están inventariando manifiestos, rutas e identidad del volumen. Todavía no se ha movido ningún juego."
    case .preCutover:
      "Steam está cerrado y el traslado puede hacerse mediante un renombrado en el mismo volumen, sin duplicar los juegos."
    case .cutover:
      "Regression está tomando custodia de la única carpeta física de juegos. Ninguna otra instalación conservará una copia ni un enlace."
    case .verifying:
      "La carpeta ya está en Regression. Se comprueban el mismo inode, los manifiestos y el inventario estructural."
    case .pendingValidation:
      "Los archivos ya pertenecen a Regression. Abre Steam desde esta tarjeta para validar tienda, biblioteca y un juego antes de finalizar."
    case .validating:
      "Steam se ejecuta exclusivamente con Regression. Comprueba la tienda, la biblioteca y un juego protegido; después confirma el resultado."
    case .rollingBack:
      "La validación no se ha aceptado. Regression restaura la ubicación anterior sin crear una segunda biblioteca."
    case let .error(detail):
      detail
    case .independent:
      "La biblioteca física vive en la botella de Regression y su ejecución se ha validado. Todo se gestiona de forma independiente."
    }
  }

  private var libraryIndependenceSymbol: String {
    switch model.libraryIndependenceState {
    case .eligible: "externaldrive.badge.plus"
    case .preparing, .preCutover: "checklist"
    case .cutover: "arrow.right.circle.fill"
    case .verifying: "checkmark.shield"
    case .pendingValidation, .validating: "play.circle"
    case .rollingBack: "arrow.uturn.backward.circle"
    case .error: "exclamationmark.triangle.fill"
    case .independent: "checkmark.seal.fill"
    }
  }

  private var libraryIndependenceColor: Color {
    switch model.libraryIndependenceState {
    case .error: .red
    case .rollingBack: .orange
    case .independent: .green
    case .cutover, .verifying, .pendingValidation, .validating: .accentColor
    case .eligible, .preparing, .preCutover: Color.primary
    }
  }

  private var operationalTitle: String {
    if model.failure == nil, model.steamRuntimeBlocksLaunch {
      return "Runtime incompleto"
    }
    if model.failure == nil, appleGPTKNeedsAttention {
      return switch model.appleGPTKState {
      case .verifying: "Verificando Apple GPTK"
      case .installing: "Instalando Apple GPTK"
      case .requiresLicense: "Licencia de Apple pendiente"
      case .requiresSelection: "Selecciona el DMG oficial"
      case .requiresDownload: "Apple GPTK no está preparado"
      case .unsupported, .failed: "Apple GPTK necesita atención"
      case .ready: model.statusTitle
      }
    }
    return switch model.operation {
    case .ready: "Motor preparado"
    case .running: model.statusTitle
    case .discovering: "Preparando el motor"
    case .preparing, .switching, .error: model.statusTitle
    }
  }

  private var appleGPTKNeedsAttention: Bool {
    model.appleGPTKState != .ready
  }

  private var operationalBlockingDetail: String {
    model.steamRuntimeBlocksLaunch ? steamRuntimeOperationalDetail : appleGPTKSummary
  }

  @ViewBuilder
  private var appleGPTKPrimaryAction: some View {
    switch model.appleGPTKState {
    case .requiresDownload:
      HStack(spacing: 8) {
        Button("Descargar GPTK…") { model.openOfficialAppleGPTKDownload() }
          .buttonStyle(.borderedProminent)
          .regressionAccessibleControl()
        openSteamWithoutAppleGPTKButton
      }
    case .requiresSelection:
      HStack(spacing: 8) {
        Button("Seleccionar DMG…") { model.beginSelectAndInspectAppleGPTKDMG() }
          .buttonStyle(.borderedProminent)
          .regressionAccessibleControl()
        openSteamWithoutAppleGPTKButton
      }
    case .requiresLicense:
      HStack(spacing: 8) {
        Button("Revisar licencia…") { model.presentAppleGPTKLicenseReview() }
          .buttonStyle(.borderedProminent)
          .regressionAccessibleControl()
        openSteamWithoutAppleGPTKButton
      }
    case .failed:
      Button("Comprobar Apple GPTK") { Task { await model.refreshAppleGPTKStatus() } }
        .buttonStyle(.borderedProminent)
        .regressionAccessibleControl()
    case .verifying, .installing:
      ProgressView().controlSize(.small).accessibilityLabel(appleGPTKSummary)
    case .unsupported:
      Button("Ver requisitos") { model.openOfficialAppleGPTKDownload() }
        .regressionAccessibleControl()
    case .ready:
      EmptyView()
    }
  }

  private var openSteamWithoutAppleGPTKButton: some View {
    Button("Abrir Steam") { Task { await model.startSteam() } }
      .regressionAccessibleControl()
      .accessibilityHint(
        "Abre Steam; los juegos que exigen Apple GPTK seguirán bloqueados hasta completar la preparación"
      )
  }

  private var steamRuntimeOperationalDetail: String {
    switch model.steamRuntimePrerequisitesHealth?.status {
    case .missing:
      "Faltan componentes protegidos de VC++ o UCRT. Steam no se abrirá hasta restaurarlos."
    case .drifted:
      "VC++ o UCRT no coincide con esta release. Steam no se abrirá hasta restaurar el runtime."
    case .unsupportedVariant:
      "Esta compilación no permite verificar VC++ y UCRT. Instala una release oficial compatible."
    case .brokenLink, .repairable, .requiresUserSource:
      "El runtime de juegos no supera la verificación. Steam permanece bloqueado para evitar fallos."
    case .ready:
      "VC++ y UCRT están verificados."
    case nil:
      "VC++ y UCRT todavía no se han podido verificar. Steam permanece bloqueado por seguridad."
    }
  }

  private var verifiedGameCount: Int {
    model.games.filter {
      model.learnedSummary(for: $0)?.hasPrefix("Verificado perfecto") == true
    }.count
  }

  private var gamesSummaryText: String {
    let gameLabel = model.games.count == 1 ? "juego" : "juegos"
    let verifiedLabel = verifiedGameCount == 1 ? "verificado" : "verificados"
    return "\(model.games.count) \(gameLabel) · \(verifiedGameCount) \(verifiedLabel)"
  }

  private var researchTechnologies: [RuntimeTechnology] {
    model.runtimeTechnologies.filter(\.hasResearchCandidate)
  }

  private var filteredGames: [SteamGame] {
    let query = gameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.games }
    return model.games.filter {
      $0.name.localizedCaseInsensitiveContains(query) || $0.appID.contains(query)
    }
  }

  private var sortedCertifications: [VerifiedGameCertification] {
    model.certifications.sorted {
      if $0.verifiedAt != $1.verifiedAt { return $0.verifiedAt > $1.verifiedAt }
      return $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending
    }
  }

  private var visibleCertifications: [VerifiedGameCertification] {
    Array(sortedCertifications.prefix(visibleCertificationCount))
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

  private func pluralized(_ value: Int, singular: String, plural: String) -> String {
    "\(value.formatted()) \(value == 1 ? singular : plural)"
  }

  private func inventorySummary(_ inventory: PhysicalLibraryInventory) -> String {
    "Inventario observado: "
      + pluralized(inventory.manifestAppIDs.count, singular: "juego", plural: "juegos")
      + " · "
      + pluralized(inventory.regularFileCount, singular: "archivo", plural: "archivos")
      + "."
  }

  private var windowsMediaSummary: String {
    guard let report = model.windowsMediaHealth else {
      return model.windowsMediaHealthIsRefreshing
        ? "Verificando el componente incluido…"
        : "La comprobación del componente todavía no se ha ejecutado."
    }
    switch report.status {
    case .ready:
      return "Windows Media verificado para esta instalación."
    case .unsupportedVariant:
      return "Verificación no disponible para esta compilación."
    case .repairable:
      return "Windows Media está presente, pero necesita restaurar su enlace local."
    case .missing:
      return "Falta el payload incluido de Windows Media."
    case .drifted:
      return "La integridad de Windows Media necesita atención."
    case .brokenLink:
      return "El enlace local de Windows Media no coincide con el componente verificado."
    case .requiresUserSource:
      return "Windows Media necesita una fuente aprobada por el usuario."
    }
  }

  private var windowsMediaDetail: String? {
    guard let report = model.windowsMediaHealth else { return nil }
    switch report.status {
    case .ready:
      return "WMA, WMV y ASF se activan únicamente para juegos cuyo contenido lo exige."
    case .repairable, .brokenLink:
      return "La reparación crea un backup y restaura solo el enlace al payload verificado."
    case .missing, .drifted:
      return "Reinstala la release oficial para restaurar el payload sellado; la botella y los juegos se conservan."
    case .unsupportedVariant:
      return "Instala una compilación publicada y compatible para verificar este componente."
    case .requiresUserSource:
      return "Regression no utilizará una fuente no aprobada ni descargará contenido sin autorización."
    }
  }

  private var steamRuntimeSummary: String {
    guard let report = model.steamRuntimePrerequisitesHealth else {
      return model.steamRuntimePrerequisitesHealthIsRefreshing
        ? "Verificando VC++ y UCRT x86/x64…"
        : "VC++ y UCRT todavía no se han comprobado."
    }
    switch report.status {
    case .ready:
      return "VC++ y UCRT x86/x64 verificados para esta release."
    case .missing:
      return "Faltan archivos obligatorios de VC++ o UCRT."
    case .drifted:
      return "VC++ o UCRT no coincide con la identidad sellada de esta release."
    case .unsupportedVariant:
      return "Esta compilación no tiene un contrato verificable de VC++/UCRT."
    case .brokenLink, .repairable, .requiresUserSource:
      return "El runtime de juegos necesita una release oficial compatible."
    }
  }

  private var steamRuntimeDetail: String? {
    guard let report = model.steamRuntimePrerequisitesHealth else { return nil }
    switch report.status {
    case .ready:
      return "Steam y los juegos pueden usar los redistribuibles protegidos."
    case .missing, .drifted, .unsupportedVariant, .brokenLink, .repairable, .requiresUserSource:
      return "El lanzamiento queda bloqueado. Reinstalar Regression conserva la botella y la biblioteca."
    }
  }

  private var appleGPTKSummary: String {
    switch model.appleGPTKState {
    case .ready:
      "Componente local verificado y listo para los perfiles que fijan D3DMetal."
    case .requiresDownload:
      "Apple GPTK no está instalado. La descarga requiere iniciar sesión en Apple Developer."
    case .requiresSelection:
      "Selecciona explícitamente el DMG oficial que acabas de descargar."
    case .requiresLicense:
      "El DMG está verificado. Revisa la licencia exacta antes de autorizar la instalación."
    case .unsupported(let reason):
      reason
    case .verifying:
      "Verificando plataforma, hashes, payload y firmas sin instalar nada…"
    case .installing:
      "Instalando con staging, verificación final y rollback protegido…"
    case .failed:
      "Apple GPTK necesita atención; no se instaló contenido no verificado."
    }
  }

  private var appleGPTKDetail: String? {
    switch model.appleGPTKState {
    case .ready:
      "Regression conserva el DMG autorizado y un recibo privado para futuras reparaciones exactas."
    case .requiresDownload:
      "Regression solo abre la página oficial de Apple; nunca descarga desde una CDN ni utiliza cookies."
    case .requiresSelection:
      "No se buscarán DMG automáticamente en Descargas ni en cachés."
    case .requiresLicense:
      "La instalación solo continúa tras una confirmación humana explícita y un token privado de un solo uso."
    case .unsupported:
      "Apple GPTK 4.0b2 requiere Apple Silicon y macOS 15 o posterior."
    case .verifying, .installing:
      "Steam y los juegos deben permanecer cerrados durante esta operación."
    case .failed(let message):
      message
    }
  }

  private var appleGPTKSymbol: String {
    switch model.appleGPTKState {
    case .ready: "checkmark.shield"
    case .requiresDownload: "arrow.down.circle"
    case .requiresSelection: "externaldrive"
    case .requiresLicense: "doc.text"
    case .unsupported: "nosign"
    case .verifying: "checkmark.shield"
    case .installing: "shippingbox"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var appleGPTKColor: Color {
    switch model.appleGPTKState {
    case .ready: .green
    case .requiresDownload, .requiresSelection, .requiresLicense: .orange
    case .unsupported, .verifying, .installing: .secondary
    case .failed: .red
    }
  }

  @ViewBuilder
  private var appleGPTKActions: some View {
    switch model.appleGPTKState {
    case .requiresDownload:
      Button("Abrir descarga oficial…") {
        model.openOfficialAppleGPTKDownload()
      }
      .regressionAccessibleControl()
      .accessibilityHint("Abre únicamente la página oficial de Apple Developer")
    case .requiresSelection:
      HStack(spacing: 8) {
        Button("Seleccionar DMG…") {
          model.beginSelectAndInspectAppleGPTKDMG()
        }
        .buttonStyle(.borderedProminent)
        .regressionAccessibleControl()
        .disabled(model.operation.isBusy || model.runningState.activeBackend != nil)

        Button("Apple Developer") {
          model.openOfficialAppleGPTKDownload()
        }
        .regressionAccessibleControl()
      }
    case .requiresLicense:
      Button("Revisar licencia…") {
        model.presentAppleGPTKLicenseReview()
      }
      .regressionAccessibleControl()
    case .failed:
      Button("Comprobar de nuevo") {
        Task { await model.refreshAppleGPTKStatus() }
      }
      .regressionAccessibleControl()
      .disabled(model.operation.isBusy)
    case .ready, .unsupported, .verifying, .installing:
      EmptyView()
    }
  }

  private var protectedAppleGPTKSummary: String {
    switch model.protectedAppleGPTKAuthorizationState {
    case .checking:
      "Verificando el payload exacto, sus enlaces y el recibo local…"
    case .ready:
      "Componente exacto autorizado para los perfiles históricos blindados."
    case .requiresAuthorization:
      "El componente coincide, pero su licencia aún necesita aceptación local."
    case .authorizing:
      "Registrando la aceptación y verificando de nuevo sin modificar el payload…"
    case .unavailable:
      "El componente protegido exacto no está disponible."
    case .failed:
      "Apple GPTK 3.0 necesita atención; no se registró ninguna autorización."
    }
  }

  private var protectedAppleGPTKDetail: String? {
    switch model.protectedAppleGPTKAuthorizationState {
    case .checking, .authorizing:
      "Steam y los juegos deben permanecer cerrados durante esta operación."
    case .ready:
      "Regression conserva únicamente un recibo privado; no sustituye 3.0 por 4.0b2."
    case .requiresAuthorization:
      "No necesitas elegir un DMG: Regression mostrará la licencia incluida en el componente exacto que ya custodia."
    case .unavailable(let message), .failed(let message):
      message
    }
  }

  private var protectedAppleGPTKSymbol: String {
    switch model.protectedAppleGPTKAuthorizationState {
    case .ready: "checkmark.shield"
    case .requiresAuthorization: "doc.text"
    case .checking: "checkmark.shield"
    case .authorizing: "lock.shield"
    case .unavailable: "nosign"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var protectedAppleGPTKColor: Color {
    switch model.protectedAppleGPTKAuthorizationState {
    case .ready: .green
    case .requiresAuthorization: .orange
    case .checking, .authorizing, .unavailable: .secondary
    case .failed: .red
    }
  }

  @ViewBuilder
  private var protectedAppleGPTKActions: some View {
    switch model.protectedAppleGPTKAuthorizationState {
    case .requiresAuthorization:
      Button("Revisar licencia de GPTK 3.0…") {
        model.beginInspectExistingProtectedAppleGPTK()
      }
      .buttonStyle(.borderedProminent)
      .regressionAccessibleControl()
      .disabled(model.operation.isBusy || model.runningState.activeBackend != nil)
      .accessibilityHint(
        "Inspecciona la licencia del componente exacto existente sin abrir un selector de DMG"
      )
    case .failed:
      Button("Comprobar GPTK 3.0") {
        Task { await model.refreshProtectedAppleGPTKAuthorizationStatus() }
      }
      .regressionAccessibleControl()
      .disabled(model.operation.isBusy)
    case .checking, .ready, .authorizing, .unavailable:
      EmptyView()
    }
  }

  private var steamRuntimeSymbol: String {
    guard let report = model.steamRuntimePrerequisitesHealth else {
      return model.steamRuntimePrerequisitesHealthIsRefreshing
        ? "arrow.triangle.2.circlepath"
        : "shippingbox"
    }
    return report.status == .ready ? "checkmark.shield" : "exclamationmark.triangle"
  }

  private var steamRuntimeColor: Color {
    guard let report = model.steamRuntimePrerequisitesHealth else { return .secondary }
    switch report.status {
    case .ready: return .green
    case .unsupportedVariant: return .orange
    case .missing, .drifted, .brokenLink, .repairable, .requiresUserSource: return .red
    }
  }

  @ViewBuilder
  private func componentRecoveryButton(for slot: ComponentSlot) -> some View {
    let report = switch slot {
    case .steamRuntime: model.steamRuntimePrerequisitesHealth
    case .windowsMedia: model.windowsMediaHealth
    }
    if let report, report.status != .ready {
      switch (slot, report.recovery) {
      case (.windowsMedia, .createExternalLink),
           (.windowsMedia, .restoreExternalLinkAfterBackup):
        Button("Reparar componente") {
          Task { await model.repairWindowsMediaComponent() }
        }
        .regressionAccessibleControl()
        .disabled(
          model.operation.isBusy
            || model.windowsMediaHealthIsRefreshing
            || model.runningState.activeBackend != nil
        )
        .accessibilityHint("Crea un backup y restaura el enlace al componente verificado")
        .help(
          model.runningState.activeBackend == nil
            ? "Reparar el enlace local con backup y verificación final"
            : "Cierra Steam y los juegos antes de reparar Windows Media"
        )
      default:
        Button("Reparar Regression") {
          Task { await model.repairRegressionInstallation() }
        }
        .regressionAccessibleControl()
        .accessibilityHint("Abre la release oficial; conserva la botella y los juegos")
      }
    }
  }

  private var windowsMediaSymbol: String {
    guard let report = model.windowsMediaHealth else {
      return model.windowsMediaHealthIsRefreshing ? "arrow.triangle.2.circlepath" : "waveform"
    }
    switch report.status {
    case .ready: return "checkmark.circle"
    case .unsupportedVariant: return "info.circle"
    case .repairable: return "wrench.and.screwdriver"
    case .missing, .drifted, .brokenLink, .requiresUserSource: return "exclamationmark.triangle"
    }
  }

  private var windowsMediaColor: Color {
    guard let report = model.windowsMediaHealth else { return .secondary }
    switch report.status {
    case .ready: return .green
    case .unsupportedVariant: return .secondary
    case .repairable: return .orange
    case .missing, .drifted, .brokenLink, .requiresUserSource: return .red
    }
  }

  private var versionText: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "desarrollo"
    return "Regression \(version) · datos locales"
  }

  private func recoveryTitle(_ recovery: UserFacingFailure.Recovery) -> String {
    switch recovery {
    case .refresh:
      model.libraryFailureDetail == nil ? "Reintentar" : "Crear o reparar biblioteca propia"
    case .repairRegression: "Reparar Regression"
    case .prepareAppleGPTK: "Preparar Apple GPTK"
    case .reviewProtectedAppleGPTK: "Ver requisito GPTK 3.0…"
    case .reinstallRegression: "Reinstalar Regression…"
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

}
