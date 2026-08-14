import AppKit
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
    @NSApplicationDelegateAdaptor(RegressionAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class RegressionAppDelegate: NSObject, NSApplicationDelegate {
    private let model = RegressionAppModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusItemPresenter: RegressionStatusItemPresenter?
    private var terminationTask: Task<Void, Never>?
    #if DEBUG
    private var visualFixtureWindow: NSWindow?

    private func writeVisualFixtureAXAudit(for window: NSWindow) {
        func identifiers(in element: Any, depth: Int = 0) -> [String] {
            guard depth < 12,
                  let accessible = element as? NSAccessibilityElementProtocol else { return [] }
            let ownIdentifier: [String]
            if let identifier = accessible.accessibilityIdentifier?() {
                ownIdentifier = [identifier]
            } else {
                ownIdentifier = []
            }
            let descendants: [Any] = if let view = element as? NSView {
                view.accessibilityChildren() ?? []
            } else if let accessibilityElement = element as? NSAccessibilityElement {
                accessibilityElement.accessibilityChildren() ?? []
            } else {
                []
            }
            return ownIdentifier + descendants.flatMap { identifiers(in: $0, depth: depth + 1) }
        }
        let identifiers = identifiers(in: window.contentView as Any)
        let focusedIdentifier = (NSApplication.shared.accessibilityApplicationFocusedUIElement()
            as? NSAccessibilityElementProtocol)?
            .accessibilityIdentifier?() ?? ""
        let audit =
            "REGRESSION_FIXTURE_AX identifiers=\(identifiers.sorted().joined(separator: ",")) focused=\(focusedIdentifier)\n"
        FileHandle.standardError.write(Data(audit.utf8))
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        LifecycleDiagnostics.write("RegressionAppDelegate.applicationDidFinishLaunching")
        NSApplication.shared.setActivationPolicy(.accessory)

        #if DEBUG
        RegressionVisualFixtureAppearance.applyRequested()
        let visualFixtureState = RegressionVisualFixtureState.requested
        if let visualFixtureState {
            // Un host regular es necesario para que AX exponga una ventana de prueba; el
            // producto mantiene `.accessory` y continúa viviendo solo en la barra de menús.
            NSApplication.shared.setActivationPolicy(.regular)
            model.applyVisualFixture(visualFixtureState)
        }
        #endif

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            LifecycleDiagnostics.write("No se pudo crear el botón de la barra de menús")
            return
        }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.image = nil
        button.title = ""

        let iconView = RegressionStatusIconView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        iconView.contentTintColor = .labelColor
        button.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconView.centerYAnchor.constraint(
                equalTo: button.centerYAnchor,
                constant: -0.5
            )
        ])

        let popover = NSPopover()
        #if DEBUG
        // Un fixture es una superficie de prueba estable, no un popover efímero que desaparece
        // cuando otra app conserva el foco. Producción mantiene el comportamiento de barra.
        popover.behavior = visualFixtureState == nil ? .transient : .applicationDefined
        #else
        popover.behavior = .transient
        #endif
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 620)
        #if DEBUG
        let rootView = MenuBarView(model: model)
            .modifier(RegressionVisualFixtureEnvironment())
        #else
        let rootView = MenuBarView(model: model)
        #endif
        popover.contentViewController = NSHostingController(rootView: rootView)

        let presenter = RegressionStatusItemPresenter(
            button: button,
            iconView: iconView,
            model: model
        )
        presenter.start()

        self.statusItem = statusItem
        self.popover = popover
        statusItemPresenter = presenter

        #if DEBUG
        if visualFixtureState != nil {
            // El popover real no siempre entra en el árbol AX de una app LSUIElement. La ventana
            // efímera contiene el mismo root SwiftUI y existe solo para que los snapshots y el
            // foco de teclado puedan comprobarse de forma automatizada.
            let fixtureRoot = MenuBarView(model: model)
                .modifier(RegressionVisualFixtureEnvironment())
            let fixtureWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 720),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            fixtureWindow.title = "Regression Visual Fixture"
            fixtureWindow.isReleasedWhenClosed = false
            fixtureWindow.level = .floating
            fixtureWindow.contentViewController = NSHostingController(rootView: fixtureRoot)
            visualFixtureWindow = fixtureWindow
            DispatchQueue.main.async {
                fixtureWindow.orderFrontRegardless()
                fixtureWindow.makeKey()
                NSRunningApplication.current.activate(options: [])
                // La activación de AppKit puede concluir después del primer layout. Auditamos
                // varios ciclos para registrar el elemento AX realmente enfocado, no un valor
                // de FocusState previo a que la ventana sea key/frontmost.
                for delay in [0.75, 1.25, 1.75] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak fixtureWindow] in
                        guard let self, let fixtureWindow else { return }
                        self.writeVisualFixtureAXAudit(for: fixtureWindow)
                    }
                }
            }
            return
        }
        #endif

        Task { @MainActor [model] in
            LifecycleDiagnostics.write("Bootstrap solicitado")
            await model.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LifecycleDiagnostics.write("RegressionAppDelegate.applicationWillTerminate")
        statusItemPresenter?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.shutdownIsComplete {
            LifecycleDiagnostics.write("Estado local ya cerrado; terminación inmediata autorizada")
            return .terminateNow
        }
        guard terminationTask == nil else {
            LifecycleDiagnostics.write("Terminación ya solicitada; esperando respuesta pendiente")
            return .terminateLater
        }
        LifecycleDiagnostics.write("Terminación limpia solicitada")
        statusItemPresenter?.stop()
        terminationTask = Task { @MainActor [model] in
            await model.shutdown()
            LifecycleDiagnostics.write("Estado local cerrado; autorizando terminación")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(
                relativeTo: sender.bounds,
                of: sender,
                preferredEdge: .minY
            )
            DispatchQueue.main.async {
                popover.contentViewController?.view.window?.makeFirstResponder(nil)
            }
            NSApplication.shared.activate()
        }
    }
}
