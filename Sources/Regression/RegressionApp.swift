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

    func applicationDidFinishLaunching(_ notification: Notification) {
        LifecycleDiagnostics.write("RegressionAppDelegate.applicationDidFinishLaunching")
        NSApplication.shared.setActivationPolicy(.accessory)

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
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(model: model)
        )

        let presenter = RegressionStatusItemPresenter(
            button: button,
            iconView: iconView,
            model: model
        )
        presenter.start()

        self.statusItem = statusItem
        self.popover = popover
        statusItemPresenter = presenter

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
            NSApplication.shared.activate()
        }
    }
}
