import OSLog
import SwiftUI

enum LifecycleDiagnostics {
    private static let logger = Logger(
        subsystem: "com.swon.regression",
        category: "lifecycle"
    )

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .private)")
    }
}

@main
struct RegressionApp: App {
    @State private var model: RegressionAppModel

    init() {
        LifecycleDiagnostics.write("RegressionApp.init")
        let model = RegressionAppModel()
        _model = State(initialValue: model)
        Task { @MainActor in
            LifecycleDiagnostics.write("Bootstrap solicitado")
            await model.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Regression: \(model.statusTitle)")
        }
        .menuBarExtraStyle(.window)
    }
}
