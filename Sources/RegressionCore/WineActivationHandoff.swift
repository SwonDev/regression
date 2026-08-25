import Foundation

/// Cesión cooperativa de la activación a un proceso de la botella propia.
///
/// macOS 14 dejó de permitir que una aplicación se ponga al frente por su cuenta: quien está
/// activo tiene que **cederle** la activación primero. Wine resuelve eso entre sus propios
/// procesos con una notificación distribuida —el juego la publica, las demás apps de Wine del
/// mismo prefijo ceden y solo entonces `NSApp.activate()` prospera—.
///
/// Regression no participaba en ese protocolo, y es justo la aplicación que suele estar al frente
/// cuando se pulsa «Jugar». El resultado reproducido: la ventana del juego aparecía a pantalla
/// completa y por delante de todo, pero su aplicación **no** quedaba activa, así que no recibía
/// ni teclado ni ratón hasta que el usuario hacía clic. No era un fallo del juego ni del motor
/// gráfico; era esta aplicación negándose a soltar la activación.
///
/// Este tipo contiene la decisión —pura y verificable—; el cableado con AppKit vive en la app.
public struct WineActivationRequest: Equatable, Sendable {
    public let processIdentifier: pid_t
    /// `WINEPREFIX` del proceso que pide la activación. Puede venir vacío.
    public let bottlePath: String
    /// `WINECONFIGDIR` del proceso que pide la activación. Puede venir vacío.
    public let configurationDirectory: String

    public init(processIdentifier: pid_t, bottlePath: String, configurationDirectory: String) {
        self.processIdentifier = processIdentifier
        self.bottlePath = bottlePath
        self.configurationDirectory = configurationDirectory
    }
}

public enum WineActivationHandoff {
    /// Nombre y claves los fija `winemac.drv`; no son configurables.
    public static let notificationName = "WineAppWillActivateNotification"
    public static let processIdentifierKey = "ActivatingAppPID"
    public static let bottleKey = "ActivatingAppPrefix"
    public static let configurationDirectoryKey = "ActivatingAppConfigDir"

    /// Traduce el `userInfo` de la notificación. Devuelve `nil` si no trae un PID utilizable:
    /// una notificación malformada no puede provocar una cesión.
    public static func request(from userInfo: [AnyHashable: Any]?) -> WineActivationRequest? {
        guard let userInfo else { return nil }
        let rawIdentifier = userInfo[processIdentifierKey]
        let identifier: pid_t
        if let number = rawIdentifier as? NSNumber {
            identifier = number.int32Value
        } else if let text = rawIdentifier as? String, let parsed = Int32(text) {
            identifier = parsed
        } else {
            return nil
        }
        guard identifier > 0 else { return nil }
        return WineActivationRequest(
            processIdentifier: identifier,
            bottlePath: (userInfo[bottleKey] as? String) ?? "",
            configurationDirectory: (userInfo[configurationDirectoryKey] as? String) ?? ""
        )
    }

    /// Solo se cede cuando la cesión sirve de algo y el proceso es de la botella propia.
    ///
    /// - No estar activo hace la cesión inútil (y `yieldActivation` sería ruido).
    /// - Un PID ajeno a la botella de Regression no recibe nada: la notificación es distribuida
    ///   y cualquier proceso del sistema puede publicarla.
    /// - Un prefijo vacío se acepta porque Wine también lo acepta: significa «no lo declaro»,
    ///   no «soy de otra botella».
    public static func shouldYield(
        to request: WineActivationRequest,
        applicationIsActive: Bool,
        ourProcessIdentifier: pid_t,
        bottle: URL
    ) -> Bool {
        guard applicationIsActive else { return false }
        guard request.processIdentifier != ourProcessIdentifier else { return false }
        guard !request.bottlePath.isEmpty else { return false }
        return isSameBottle(request.bottlePath, as: bottle)
    }

    private static func isSameBottle(_ path: String, as bottle: URL) -> Bool {
        let declared = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let ours = bottle.standardizedFileURL.resolvingSymlinksInPath()
        return declared.path == ours.path
    }
}
