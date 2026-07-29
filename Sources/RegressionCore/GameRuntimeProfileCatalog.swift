import Foundation

/// Identidad compilada de un perfil de ejecución aislado por juego.
///
/// Este catálogo solo describe recetas que forman parte del código firmado de Regression. No
/// interpreta comandos ni variables procedentes de SQLite, de modo que el aprendizaje local no
/// puede convertirse en una vía de ejecución arbitraria.
public struct CompiledGameRuntimeProfile: Equatable, Sendable {
    public let appID: String
    public let identifier: String
    public let revision: Int
    public let executable: String
    public let configurationValues: [String: String]

    public init(
        appID: String,
        identifier: String,
        revision: Int,
        executable: String,
        configurationValues: [String: String]
    ) {
        self.appID = appID
        self.identifier = identifier
        self.revision = revision
        self.executable = executable
        self.configurationValues = configurationValues
    }
}

public enum GameRuntimeProfileCatalog {
    public static let revision = "2026-07-29.1"

    public static let all: [CompiledGameRuntimeProfile] = [
        CompiledGameRuntimeProfile(
            appID: "619820",
            identifier: "heroes-hammerwatch-2.opengl-forward-compatible",
            revision: 1,
            executable: "hwr2.exe",
            configurationValues: [
                "profile.id": "heroes-hammerwatch-2.opengl-forward-compatible",
                "profile.revision": "1",
                "profile.scope": "exact-process",
                "profile.executable": "hwr2.exe",
                "profile.runtime-root": "lib/profiles/heroes-hammerwatch-2",
                "profile.graphics.api": "opengl",
                "profile.opengl.forward-compatible": "1"
            ]
        )
    ]

    public static func profile(
        for appID: String,
        backend: BackendKind
    ) -> CompiledGameRuntimeProfile? {
        guard backend == .regression,
              let normalized = SteamAppID.normalized(appID) else {
            return nil
        }
        return all.first { $0.appID == normalized }
    }

    public static func configurationValues(
        for appID: String,
        backend: BackendKind
    ) -> [String: String] {
        profile(for: appID, backend: backend)?.configurationValues ?? [:]
    }
}
