#if DEBUG
  import AppKit
  import Foundation
  import RegressionCore
  import SwiftUI

  enum RegressionVisualFixtureAppearance: String {
    case light
    case highContrastLight = "high-contrast-light"
    case highContrastDark = "high-contrast-dark"

    private static let argumentPrefix = "--regression-visual-appearance="

    static var requested: RegressionVisualFixtureAppearance? {
      CommandLine.arguments.lazy
        .first(where: { $0.hasPrefix(argumentPrefix) })
        .map({ String($0.dropFirst(argumentPrefix.count)) })
        .flatMap(RegressionVisualFixtureAppearance.init(rawValue:))
    }

    @MainActor
    static func applyRequested() {
      guard let appearance = requested else { return }
      let name: NSAppearance.Name =
        switch appearance {
        case .light: .aqua
        case .highContrastLight: .accessibilityHighContrastAqua
        case .highContrastDark: .accessibilityHighContrastDarkAqua
        }
      NSApplication.shared.appearance = NSAppearance(named: name)
    }
  }

  struct RegressionVisualFixtureEnvironment: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
      if RegressionVisualFixtureState.requested == nil {
        content
      } else {
        let appearance = RegressionVisualFixtureAppearance.requested
        let sizedContent =
          content
          .dynamicTypeSize(
            RegressionVisualFixtureTextSize.requested?.dynamicTypeSize ?? .large
          )
          .environment(
            \.sizeCategory,
            RegressionVisualFixtureTextSize.requested?.contentSizeCategory ?? .large
          )
          // `NSAppearance` no propaga siempre su contraste al entorno SwiftUI en una app
          // LSUIElement aislada. Esta clave escribible existe precisamente para pruebas;
          // producción sigue leyendo únicamente `colorSchemeContrast` del sistema.
          .environment(
            \._colorSchemeContrast,
            appearance == .highContrastLight || appearance == .highContrastDark
              ? .increased
              : .standard
          )
        switch appearance {
        case .light:
          sizedContent.preferredColorScheme(.light)
        case .highContrastLight, .highContrastDark:
          // La apariencia accesible se fija en NSApplication. Forzar además el esquema
          // desde SwiftUI lo degradaba a Aqua/Dark Aqua normal y anulaba el fixture.
          sizedContent
        case nil:
          sizedContent.preferredColorScheme(.dark)
        }
      }
    }
  }

  enum RegressionVisualFixtureTextSize: String {
    case accessibility
    case accessibility3
    case accessibility5

    private static let argumentPrefix = "--regression-visual-text-size="

    static var requested: Self? {
      CommandLine.arguments.lazy
        .first { $0.hasPrefix(argumentPrefix) }
        .map { String($0.dropFirst(argumentPrefix.count)) }
        .flatMap(Self.init(rawValue:))
    }

    var dynamicTypeSize: DynamicTypeSize {
      switch self {
      case .accessibility: .accessibility2
      case .accessibility3: .accessibility3
      case .accessibility5: .accessibility5
      }
    }

    var contentSizeCategory: ContentSizeCategory {
      switch self {
      case .accessibility: .accessibilityExtraExtraLarge
      case .accessibility3: .accessibilityExtraExtraExtraLarge
      case .accessibility5: .accessibilityExtraExtraExtraLarge
      }
    }
  }

  enum RegressionVisualFixtureState: String {
    case ready
    case working
    case empty
    case error
    case runtimeReady = "runtime-ready"
    case runtimeMissing = "runtime-missing"
    case runtimeDrifted = "runtime-drifted"
    case mediaRepairable = "media-repairable"
    case mediaMissing = "media-missing"
    case gptkReady = "gptk-ready"
    case gptkDownload = "gptk-download"
    case gptkLicense = "gptk-license"
    case gptkInstalling = "gptk-installing"
    case gptk3Blocked = "gptk3-blocked"
    case gptk3License = "gptk3-license"
    case gptk3Authorizing = "gptk3-authorizing"
    case preflightWarning = "preflight-warning"
    case preflightBlocked = "preflight-blocked"
    case updaterAvailable = "updater-available"
    case updaterFailed = "updater-failed"
    case custodyEligible = "custody-eligible"
    case custodyPreparing = "custody-preparing"
    case custodyPreCutover = "custody-pre-cutover"
    case custodyCutover = "custody-cutover"
    case custodyVerifying = "custody-verifying"
    case custodyPendingValidation = "custody-pending-validation"
    case custodyValidating = "custody-validating"
    case custodyRollingBack = "custody-rolling-back"
    case custodyIndependent = "custody-independent"

    private static let argumentPrefix = "--regression-visual-fixture="

    static var requested: RegressionVisualFixtureState? {
      CommandLine.arguments.lazy
        .first { $0.hasPrefix(argumentPrefix) }
        .map { String($0.dropFirst(argumentPrefix.count)) }
        .flatMap(RegressionVisualFixtureState.init(rawValue:))
    }

    var expandsMaintenance: Bool {
      switch self {
      case .runtimeReady, .runtimeMissing, .runtimeDrifted, .mediaRepairable, .mediaMissing,
           .gptkReady, .gptkDownload, .gptkLicense, .gptkInstalling, .gptk3Blocked,
           .gptk3License, .gptk3Authorizing, .preflightWarning, .preflightBlocked,
           .updaterAvailable, .updaterFailed:
        true
      case .ready, .working, .empty, .error, .custodyEligible, .custodyPreparing,
           .custodyPreCutover, .custodyCutover, .custodyVerifying, .custodyPendingValidation,
           .custodyValidating, .custodyRollingBack, .custodyIndependent:
        false
      }
    }
  }

  @MainActor
  extension RegressionAppModel {
    func applyVisualFixture(_ state: RegressionVisualFixtureState) {
      let root = URL(fileURLWithPath: "/private/tmp/regression-visual-fixture", isDirectory: true)
      let regressionSteam = root.appendingPathComponent("Regression/Steam", isDirectory: true)
      let regressionInstallation = RegressionInstallation(
        applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
        bottleURL: root.appendingPathComponent("Regression/Bottle", isDirectory: true),
        steamExecutableURL: regressionSteam.appendingPathComponent("Steam.exe"),
        engineLauncherURL: root.appendingPathComponent("Regression/regression-engine"),
        health: .ready,
        healthDetail: "Wine 11 · DXMT y componentes verificados"
      )
      selectedBackend = .regression
      installations = InstallationSnapshot(
        crossOver: nil,
        regression: regressionInstallation
      )
      runningState = RunningBackendState()
      sharedLibraryAssessment = nil
      publicCatalogEnabled = false
      publicCatalogOperation = .disabled
      automaticRegressionUpdatesEnabled = false
      autoLaunchEnabled = false
      regressionReleaseStatus = .upToDate(installedVersion: "1.10.1", checkedAt: Date())
      failure = nil
      libraryIndependenceState = .independent
      steamRuntimePrerequisitesHealth = fixtureComponentHealth(
        componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
        status: .ready,
        recovery: .none
      )
      windowsMediaHealth = fixtureComponentHealth(
        componentID: TrustedComponentCatalog.windowsMediaComponentID,
        status: .ready,
        recovery: .none
      )
      appleGPTKOnboarding = AppleGPTKOnboarding(
        inputs: .init(
          platformSupport: .supported,
          componentHealth: .ready,
          dmgSelection: .notDownloaded,
          licenseConfirmation: .notReviewed,
          operation: .idle
        )
      )
      appleGPTKLicenseReview = nil
      protectedAppleGPTKHealth = fixtureComponentHealth(
        componentID: AppleGPTKComponentCatalog.protectedProfilesComponentID,
        status: .ready,
        recovery: .none
      )
      protectedAppleGPTKAuthorizationState = .ready

      switch state {
      case .ready:
        operation = .ready
        statusDetail =
          "Motor propio preparado. Steam está cerrado y no se iniciará en este fixture."
        games = fixtureGames()
      case .working:
        operation = .discovering
        statusDetail = "Comprobando el motor y la biblioteca de Steam…"
        games = []
      case .empty:
        operation = .ready
        statusDetail = "Motor propio preparado. No se detectaron juegos instalados."
        games = []
      case .error:
        operation = .error
        statusDetail = "El enlace de la biblioteca no coincide con la ruta protegida esperada."
        sharedLibraryAssessment = SharedLibraryAssessment(
          status: .blocked("El enlace no coincide con la ruta protegida esperada."),
          regressionSteamAppsURL: regressionSteam.appendingPathComponent("steamapps"),
          crossOverSteamAppsURL: root.appendingPathComponent("Legacy/steamapps"),
          onlyInRegression: [],
          onlyInCrossOver: []
        )
        failure = UserFacingFailure(
          title: "La biblioteca necesita atención",
          message: "Regression no modificó ningún archivo.",
          recovery: .refresh
        )
        games = fixtureGames()
        libraryIndependenceState = .error(
          "El enlace no coincide con la ruta protegida esperada. No se ha movido ningún archivo."
        )
      case .runtimeReady:
        applyReadyVisualFixture()
      case .runtimeMissing:
        applyReadyVisualFixture()
        steamRuntimePrerequisitesHealth = fixtureComponentHealth(
          componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
          status: .missing,
          recovery: .reinstallTrustedArtifact,
          issue: .payloadEntryMissing("lib/wine/i386-windows/ucrtbase.dll")
        )
      case .runtimeDrifted:
        applyReadyVisualFixture()
        steamRuntimePrerequisitesHealth = fixtureComponentHealth(
          componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
          status: .drifted,
          recovery: .reinstallTrustedArtifact,
          issue: .payloadDigestMismatch("lib/wine/x86_64-windows/vcruntime140.dll")
        )
      case .mediaRepairable:
        applyReadyVisualFixture()
        windowsMediaHealth = fixtureComponentHealth(
          componentID: TrustedComponentCatalog.windowsMediaComponentID,
          status: .repairable,
          recovery: .createExternalLink(
            linkURL: root.appendingPathComponent("Components/WindowsMedia/1"),
            targetURL: root.appendingPathComponent("Regression.app/Contents/SharedSupport/components/windows-media/1")
          ),
          issue: .externalLinkMissing
        )
      case .mediaMissing:
        applyReadyVisualFixture()
        windowsMediaHealth = fixtureComponentHealth(
          componentID: TrustedComponentCatalog.windowsMediaComponentID,
          status: .missing,
          recovery: .reinstallTrustedArtifact,
          issue: .payloadMissing
        )
      case .gptkReady:
        applyReadyVisualFixture()
      case .gptkDownload:
        applyReadyVisualFixture()
        appleGPTKOnboarding = fixtureAppleGPTKOnboarding(
          componentHealth: .missing,
          dmgSelection: .notDownloaded
        )
      case .gptkLicense:
        applyReadyVisualFixture()
        let sourceDMG = root.appendingPathComponent(
          "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg"
        )
        let inspectionDirectory = root.appendingPathComponent(
          "gptk-inspection",
          isDirectory: true
        )
        let descriptor = AppleGPTKInspectionDescriptor(
          schema: 1,
          version: "4.0b2",
          dmgSHA256: String(repeating: "a", count: 64),
          licenseSHA256: String(repeating: "b", count: 64),
          sourceDMG: sourceDMG.path
        )
        appleGPTKOnboarding = fixtureAppleGPTKOnboarding(
          componentHealth: .missing,
          dmgSelection: .selected(sourceDMG)
        )
        appleGPTKLicenseReview = AppleGPTKLicenseReview(
          id: UUID(),
          source: .diskImage(descriptor: descriptor, sourceURL: sourceDMG),
          inspectionDirectoryURL: inspectionDirectory,
          licenseRTFData: Data(
            "{\\rtf1\\ansi\\ansicpg1252\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 Apple GPTK 4.0b2 \\u8212? License fixture\\par This fixture displays the exact reviewed RTF surface without mounting a DMG.}"
              .utf8
          )
        )
      case .gptkInstalling:
        applyReadyVisualFixture()
        let sourceDMG = root.appendingPathComponent(
          "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg"
        )
        appleGPTKOnboarding = fixtureAppleGPTKOnboarding(
          componentHealth: .missing,
          dmgSelection: .selected(sourceDMG),
          licenseConfirmation: .confirmed,
          operation: .installing
        )
      case .gptk3Blocked:
        applyReadyVisualFixture()
        protectedAppleGPTKAuthorizationState = .requiresAuthorization
        failure = UserFacingFailure(
          title: "Apple GPTK 3.0 necesita autorización",
          message: "El componente exacto está protegido, pero todavía falta aceptar su licencia local.",
          recovery: .reviewProtectedAppleGPTK
        )
        operation = .error
        statusDetail = "Los bytes y enlaces coinciden; falta un recibo local verificable de licencia."
      case .gptk3License:
        applyReadyVisualFixture()
        let sourceComponent = root.appendingPathComponent(
          "Components/AppleGPTK/3.0",
          isDirectory: true
        )
        let inspectionDirectory = root.appendingPathComponent(
          "gptk3-inspection",
          isDirectory: true
        )
        let descriptor = AppleGPTKExistingComponentInspectionDescriptor(
          schema: 1,
          version: "3.0",
          sourceKind: AppleGPTKExistingComponentInspectionDescriptor.sourceKind,
          catalogID: AppleGPTKComponentCatalog.protectedProfilesComponentID,
          payloadFingerprint: AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint,
          licenseSHA256: String(repeating: "c", count: 64),
          sourceComponent: sourceComponent.path
        )
        protectedAppleGPTKAuthorizationState = .requiresAuthorization
        appleGPTKLicenseReview = AppleGPTKLicenseReview(
          id: UUID(),
          source: .protectedExisting(descriptor: descriptor),
          inspectionDirectoryURL: inspectionDirectory,
          licenseRTFData: Data(
            "{\\rtf1\\ansi\\ansicpg1252\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 Apple GPTK 3.0 \\u8212? License fixture\\par This fixture displays the exact protected-component RTF surface without choosing or mounting a DMG.}"
              .utf8
          )
        )
      case .gptk3Authorizing:
        applyReadyVisualFixture()
        protectedAppleGPTKAuthorizationState = .authorizing
        operation = .preparing("Autorizando Apple GPTK 3.0")
        statusDetail = "Volviendo a verificar el componente exacto sin copiar ni modificar su payload."
      case .preflightWarning:
        applyReadyVisualFixture()
        testReadiness = fixturePreflight(status: .warning)
      case .preflightBlocked:
        applyReadyVisualFixture()
        testReadiness = fixturePreflight(status: .blocked)
      case .updaterAvailable:
        applyReadyVisualFixture()
        regressionReleaseStatus = .available(
          installedVersion: "1.10.1",
          release: RegressionRelease(
            version: "1.10.2",
            pageURL: URL(string: "https://github.com/SwonDev/regression/releases/tag/v1.10.2")
              ?? root,
            installerURL: URL(string: "https://github.com/SwonDev/regression/releases/download/v1.10.2/install_regression.sh")
              ?? root,
            installerSHA256: String(repeating: "a", count: 64),
            installerSize: 64_000
          )
        )
      case .updaterFailed:
        applyReadyVisualFixture()
        regressionReleaseStatus = .failed(
          message: "No se pudo verificar el digest del instalador oficial."
        )
      case .custodyEligible:
        operation = .ready
        statusDetail = "Regression está listo para tomar custodia de la biblioteca."
        libraryIndependenceState = .eligible
        games = fixtureGames()
      case .custodyPreparing:
        operation = .preparing("Comprobando la biblioteca")
        statusDetail = "Inventariando sin modificar los juegos."
        libraryIndependenceState = .preparing
        games = fixtureGames()
      case .custodyPreCutover:
        operation = .ready
        statusDetail = "Esperando confirmación antes del traslado."
        libraryIndependenceState = .preCutover
        games = fixtureGames()
      case .custodyCutover:
        operation = .preparing("Trasladando la biblioteca")
        statusDetail = "El traslado atómico está en curso."
        libraryIndependenceState = .cutover
        games = fixtureGames()
      case .custodyVerifying:
        operation = .preparing("Verificando la integridad")
        statusDetail = "Comprobando manifiestos e identidad física."
        libraryIndependenceState = .verifying
        games = fixtureGames()
      case .custodyPendingValidation:
        operation = .ready
        statusDetail = "La biblioteca espera su validación funcional."
        libraryIndependenceState = .pendingValidation
        games = fixtureGames()
      case .custodyValidating:
        operation = .running(.regression)
        runningState = RunningBackendState(regressionPIDs: [42])
        statusDetail = "Steam está abierto únicamente con Regression."
        libraryIndependenceState = .validating
        games = fixtureGames()
      case .custodyRollingBack:
        operation = .preparing("Restaurando la biblioteca")
        statusDetail = "Regression está recuperando el estado anterior."
        libraryIndependenceState = .rollingBack
        games = fixtureGames()
      case .custodyIndependent:
        operation = .ready
        statusDetail = "Motor y biblioteca propios preparados."
        libraryIndependenceState = .independent
        games = fixtureGames()
      }
    }

    private func applyReadyVisualFixture() {
      operation = .ready
      statusDetail = "Motor propio preparado. Steam está cerrado y no se iniciará en este fixture."
      games = fixtureGames()
    }

    private func fixtureComponentHealth(
      componentID: String,
      status: ComponentHealthStatus,
      recovery: ComponentRecoveryAction,
      issue: ComponentHealthIssue? = nil
    ) -> ComponentHealthReport {
      ComponentHealthReport(
        identity: ComponentIdentity(
          componentID: componentID,
          componentVersion: "1",
          variant: .development,
          buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
        ),
        status: status,
        recovery: recovery,
        issue: issue
      )
    }

    private func fixtureAppleGPTKOnboarding(
      componentHealth: AppleGPTKComponentHealth,
      dmgSelection: AppleGPTKDMGSelection,
      licenseConfirmation: AppleGPTKLicenseConfirmation = .notReviewed,
      operation: AppleGPTKOnboardingOperation = .idle
    ) -> AppleGPTKOnboarding {
      AppleGPTKOnboarding(
        inputs: .init(
          platformSupport: .supported,
          componentHealth: componentHealth,
          dmgSelection: dmgSelection,
          licenseConfirmation: licenseConfirmation,
          operation: operation
        )
      )
    }

    private func fixturePreflight(
      status: GameTestReadinessStatus
    ) -> GameTestPreflightReport {
      GameTestPreflightReport(
        appID: nil,
        gameName: nil,
        backend: .regression,
        checks: [
          GameTestPreflightCheck(
            checkID: status == .blocked ? .wineRuntimeIsolation : .storageCapacity,
            status: status,
            title: status == .blocked ? "Otro runtime Wine está activo" : "Espacio disponible ajustado",
            detail: status == .blocked
              ? "La sesión ajena puede producir un falso fallo y bloquea esta prueba."
              : "La prueba puede continuar; el aviso quedará unido a la ejecución.",
            recoveryAction: status == .blocked
              ? "Cierra el otro runtime y vuelve a comprobar el entorno."
              : nil
          )
        ]
      )
    }

    private func fixtureGames() -> [SteamGame] {
      var seen: Set<String> = []
      return
        certifications
        .filter { $0.backend == .regression && seen.insert($0.appID).inserted }
        .prefix(5)
        .map { certification in
          SteamGame(
            appID: certification.appID,
            name: certification.gameName,
            installDirectory: certification.gameName,
            manifestURL: URL(
              fileURLWithPath: "/private/tmp/regression-visual-fixture/"
                + "appmanifest_\(certification.appID).acf"
            ),
            sourceBackend: .regression
          )
        }
    }
  }
#endif
