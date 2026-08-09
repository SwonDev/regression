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
    public let requiresActiveSteamClient: Bool
    public let configurationValues: [String: String]

    public init(
        appID: String,
        identifier: String,
        revision: Int,
        executable: String,
        requiresActiveSteamClient: Bool = false,
        configurationValues: [String: String]
    ) {
        self.appID = appID
        self.identifier = identifier
        self.revision = revision
        self.executable = executable
        self.requiresActiveSteamClient = requiresActiveSteamClient
        self.configurationValues = configurationValues
    }
}

public enum GameRuntimeProfileCatalog {
    public static let revision = "2026-08-08.12"

    public static let all: [CompiledGameRuntimeProfile] = [
        CompiledGameRuntimeProfile(
            appID: "347940",
            identifier: "windows-media-gstreamer-autodetect",
            revision: 1,
            executable: "forsakenisle.exe",
            configurationValues: [
                "profile.id": "windows-media-gstreamer-autodetect",
                "profile.revision": "1",
                "profile.scope": "steam-game-content-tree",
                "profile.executable": "forsakenisle.exe",
                "profile.media.extensions": "asf,wma,wmv",
                "profile.media.backend": "gstreamer-1.24.4",
                "profile.media.decoder": "ffmpeg-6.1.6-lgpl",
                "profile.router.contract": "compiled-bounded-content-scan-v1",
                "profile.launcher.entrypoints": "regression,steam",
                "profile.component.id": "windows-media-gstreamer",
                "profile.component.version": "1",
                "profile.component.repair": "signed-manifest-link"
            ]
        ),
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
        ),
        CompiledGameRuntimeProfile(
            appID: "1154030",
            identifier: "titan-quest-2.apple-gptk-4.0b2-steam-shipping",
            revision: 9,
            executable: "tq2-win64-shipping.exe",
            requiresActiveSteamClient: true,
            configurationValues: [
                "profile.id": "titan-quest-2.apple-gptk-4.0b2-steam-shipping",
                "profile.revision": "7",
                "profile.scope": "exact-app-process",
                "profile.executable": "tq2-win64-shipping.exe",
                "profile.runtime-root": "components/apple-gptk/4.0b2",
                "profile.graphics.api": "d3d12",
                "profile.graphics.backend": "d3dmetal",
                "profile.graphics.route": "complete",
                "profile.router.contract": "compiled-wineserver-startup-image-and-external-d3dmetal-v7",
                "profile.launcher": "steam-bootstrap",
                "profile.launcher.entrypoints": "regression,steam",
                "profile.bootstrap.executable": "tq2.exe",
                "profile.bootstrap.action": "redirect-to-shipping",
                "profile.component.id": "apple-gptk",
                "profile.component.version": "4.0b2",
                "profile.component.repair": "manifest-verified"
            ]
        ),
        CompiledGameRuntimeProfile(
            appID: "1374490",
            identifier: "unreal-d3d11-dual-overlay-isolation",
            revision: 1,
            executable: "rsdragonwilds-win64-shipping.exe",
            requiresActiveSteamClient: true,
            configurationValues: [
                "profile.id": "unreal-d3d11-dual-overlay-isolation",
                "profile.revision": "1",
                "profile.scope": "exact-process",
                "profile.executable": "rsdragonwilds-win64-shipping.exe",
                "profile.engine.family": "unreal",
                "profile.graphics.api": "d3d11",
                "profile.repair.id": CompiledRepairRecipe.unrealD3D11DualOverlayIsolation.rawValue,
                "profile.repair.detector": "strict-crash-stack-v1",
                "profile.repair.learning": "typed-executable-recipe-activation-v1",
                "profile.repair.rollback": "private-activation-snapshot",
                "profile.dll.disabled": "eosovh-win64-shipping",
                "profile.dll.policy": "disabled-only-in-matched-process",
                "profile.launcher.entrypoints": "regression,steam",
                "profile.router.contract": "compiled-process-scoped-dll-isolation-v1"
            ]
        ),
        CompiledGameRuntimeProfile(
            appID: "2617700",
            identifier: "gamemaker-retina-fullscreen-repair",
            revision: 1,
            executable: "tinkerlands.exe",
            configurationValues: [
                "profile.id": "gamemaker-retina-fullscreen-repair",
                "profile.revision": "1",
                "profile.scope": "bounded-user-options",
                "profile.executable": "tinkerlands.exe",
                "profile.engine.family": "gamemaker",
                "profile.repair.id": CompiledRepairRecipe.gameMakerRetinaFullscreen.rawValue,
                "profile.repair.condition": "fullscreen=0,resolution>=6",
                "profile.repair.rollback": "adjacent-first-write-backup",
                "profile.launcher.entrypoints": "regression,steam"
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
