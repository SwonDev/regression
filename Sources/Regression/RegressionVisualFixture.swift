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
    private static let accessibilityTextArgument =
      "--regression-visual-text-size=accessibility"

    @ViewBuilder
    func body(content: Content) -> some View {
      if RegressionVisualFixtureState.requested == nil {
        content
      } else {
        let appearance = RegressionVisualFixtureAppearance.requested
        let sizedContent =
          content
          .dynamicTypeSize(
            CommandLine.arguments.contains(Self.accessibilityTextArgument)
              ? .accessibility2
              : .large
          )
          .environment(
            \.sizeCategory,
            CommandLine.arguments.contains(Self.accessibilityTextArgument)
              ? .accessibilityExtraExtraLarge
              : .large
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

  enum RegressionVisualFixtureState: String {
    case ready
    case working
    case empty
    case error
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
  }

  @MainActor
  extension RegressionAppModel {
    func applyVisualFixture(_ state: RegressionVisualFixtureState) {
      let root = URL(fileURLWithPath: "/private/tmp/regression-visual-fixture", isDirectory: true)
      let regressionSteam = root.appendingPathComponent("Regression/Steam", isDirectory: true)
      let crossOverSteam = root.appendingPathComponent("CrossOver/Steam", isDirectory: true)
      let regressionInstallation = RegressionInstallation(
        applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
        bottleURL: root.appendingPathComponent("Regression/Bottle", isDirectory: true),
        steamExecutableURL: regressionSteam.appendingPathComponent("Steam.exe"),
        engineLauncherURL: root.appendingPathComponent("Regression/regression-engine"),
        health: .ready,
        healthDetail: "Wine 11 · DXMT y componentes verificados"
      )
      let crossOverInstallation = CrossOverInstallation(
        applicationURL: root.appendingPathComponent("CrossOver.app", isDirectory: true),
        version: "26.3.0",
        build: "100",
        bottleName: "Steam",
        bottleURL: root.appendingPathComponent("CrossOver/Bottle", isDirectory: true),
        steamExecutableURL: crossOverSteam.appendingPathComponent("Steam.exe"),
        wineCLIURL: root.appendingPathComponent("CrossOver/wine"),
        bottleCLIURL: root.appendingPathComponent("CrossOver/cxbottle"),
        feedURL: nil,
        defaultGraphicsBackend: "D3DMetal",
        health: .ready,
        healthDetail: "Comparador disponible"
      )

      selectedBackend = .regression
      installations = InstallationSnapshot(
        crossOver: crossOverInstallation,
        regression: regressionInstallation
      )
      runningState = RunningBackendState()
      sharedLibraryAssessment = SharedLibraryAssessment(
        status: .ready,
        regressionSteamAppsURL: regressionSteam.appendingPathComponent("steamapps"),
        crossOverSteamAppsURL: crossOverSteam.appendingPathComponent("steamapps"),
        onlyInRegression: [],
        onlyInCrossOver: []
      )
      publicCatalogEnabled = false
      publicCatalogOperation = .disabled
      automaticRegressionUpdatesEnabled = false
      autoLaunchEnabled = false
      regressionReleaseStatus = .upToDate(installedVersion: "1.10.1", checkedAt: Date())
      failure = nil
      libraryIndependenceState = .independent

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
          crossOverSteamAppsURL: crossOverSteam.appendingPathComponent("steamapps"),
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
