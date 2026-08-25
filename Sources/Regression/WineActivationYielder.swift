import AppKit
import RegressionCore

/// Observa la notificación de activación de `winemac.drv` y cede el primer plano al juego.
///
/// Ver `WineActivationHandoff` para el porqué. Aquí solo está el cableado con AppKit: la decisión
/// —si toca ceder y a quién— es del núcleo y se prueba aparte.
@MainActor
final class WineActivationYielder {
    private let bottle: URL
    private var observer: NSObjectProtocol?

    init(bottle: URL) {
        self.bottle = bottle
    }

    func start() {
        guard observer == nil else { return }
        let bottle = bottle
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(WineActivationHandoff.notificationName),
            object: nil,
            queue: .main
        ) { notification in
            // La notificación no cruza el límite de aislamiento: se traduce aquí mismo a un
            // valor `Sendable` y solo eso viaja al actor principal.
            guard let request = WineActivationHandoff.request(from: notification.userInfo) else { return }
            // La cola es la principal, así que el aislamiento ya se cumple.
            MainActor.assumeIsolated {
                WineActivationYielder.yieldIfNeeded(to: request, bottle: bottle)
            }
        }
    }

    func stop() {
        guard let observer else { return }
        DistributedNotificationCenter.default().removeObserver(observer)
        self.observer = nil
    }

    private static func yieldIfNeeded(to request: WineActivationRequest, bottle: URL) {
        guard WineActivationHandoff.shouldYield(
            to: request,
            applicationIsActive: NSApplication.shared.isActive,
            ourProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            bottle: bottle
        ) else { return }
        guard let target = NSRunningApplication(processIdentifier: request.processIdentifier) else { return }

        NSApplication.shared.yieldActivation(to: target)
        // Las notificaciones distribuidas son asíncronas: puede que el juego ya haya llamado a
        // `activate` antes de que cediéramos. Reactivarlo desde aquí cierra esa carrera y es
        // inocuo si no se produjo.
        _ = target.activate(from: .current, options: [])
    }
}
