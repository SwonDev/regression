import Foundation

public struct D3D12MetalRoute: Equatable, Sendable {
    public let shippingExecutable: String
    public let shippingURL: URL

    public init(shippingExecutable: String, shippingURL: URL) {
        self.shippingExecutable = shippingExecutable
        self.shippingURL = shippingURL
    }
}

/// Detecta por evidencia los juegos que renderizan con Direct3D 12 y necesitan D3DMetal.
///
/// Un título D3D12 sin ruta a D3DMetal no falla: cae al `d3d12` propio de Wine sobre
/// vkd3d/MoltenVK y **renderiza de menos**. Terreno, personajes, partículas y HUD siguen
/// pintando mientras desaparece la geometría estática del entorno, así que el usuario ve un
/// juego que "funciona" y nadie abre una incidencia. Ese fallo silencioso es la razón de este
/// detector: hasta ahora cada título había que añadirlo a mano a una lista de ejecutables.
///
/// La evidencia aceptada es una sola y es del propio juego: el **Agility SDK** de Direct3D 12
/// (`D3D12Core.dll`) junto al Shipping de Unreal, en la estructura canónica
/// `<juego>/<proyecto>/Binaries/Win64/D3D12/`. No se infiere por App ID, ni por nombre, ni por
/// nada que el juego pueda declarar sin traer el runtime. Un ejecutable que no acredita esa
/// estructura no obtiene ruta y conserva exactamente el comportamiento anterior.
///
/// El detector **solo propone basenames**. La generación de GPTK, la verificación del componente
/// y la decisión final siguen siendo del lanzador, y las rutas compiladas tienen precedencia:
/// un juego ya fijado a una generación concreta no se reasigna desde aquí.
public enum D3D12MetalRouteDetector {
    private static let agilityCoreName = "D3D12Core.dll"
    private static let shippingSuffix = "-Win64-Shipping.exe"
    private static let maximumGames = 1_024
    private static let maximumProjectDirectories = 64
    private static let maximumRoutes = 16

    public static func routes(in steamRootURL: URL) throws -> [D3D12MetalRoute] {
        let commonURL = steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("common", isDirectory: true)
        guard FileManager.default.fileExists(atPath: commonURL.path) else { return [] }

        let games = try FileManager.default.contentsOfDirectory(
            at: commonURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.path < $1.path }
        guard games.count <= maximumGames else {
            throw RegressionCoreError.invalidEvidence(
                "la biblioteca excede el límite del detector de rutas D3D12"
            )
        }

        var result: [D3D12MetalRoute] = []
        for discoveredGameURL in games {
            let gameURL = commonURL.appendingPathComponent(
                discoveredGameURL.lastPathComponent,
                isDirectory: true
            )
            guard try isRegularNonSymlink(gameURL, directory: true) else { continue }
            result.append(contentsOf: try routes(inGame: gameURL))
            guard result.count <= maximumRoutes else {
                throw RegressionCoreError.invalidEvidence(
                    "la biblioteca excede el número de rutas D3D12 admitidas"
                )
            }
        }

        // Un basename ambiguo no se enruta: dos juegos distintos con el mismo ejecutable
        // recibirían la misma decisión gráfica sin poder distinguirlos.
        var countsByExecutable: [String: Int] = [:]
        for route in result {
            countsByExecutable[route.shippingExecutable.lowercased(), default: 0] += 1
        }
        return result.filter {
            countsByExecutable[$0.shippingExecutable.lowercased()] == 1
        }.sorted {
            ($0.shippingExecutable.lowercased(), $0.shippingURL.path)
                < ($1.shippingExecutable.lowercased(), $1.shippingURL.path)
        }
    }

    private static func routes(inGame gameURL: URL) throws -> [D3D12MetalRoute] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: gameURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.path < $1.path }
        guard entries.count <= maximumProjectDirectories else { return [] }

        var result: [D3D12MetalRoute] = []
        for discoveredProjectURL in entries {
            let projectURL = gameURL.appendingPathComponent(
                discoveredProjectURL.lastPathComponent,
                isDirectory: true
            )
            guard try isRegularNonSymlink(projectURL, directory: true) else { continue }

            let win64URL = projectURL
                .appendingPathComponent("Binaries", isDirectory: true)
                .appendingPathComponent("Win64", isDirectory: true)
            let agilityURL = win64URL
                .appendingPathComponent("D3D12", isDirectory: true)
                .appendingPathComponent(agilityCoreName)
            guard try isRegularNonSymlink(win64URL, directory: true),
                  try isRegularNonSymlink(agilityURL, directory: false) else { continue }

            let shippingCandidates = try FileManager.default.contentsOfDirectory(
                at: win64URL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.lastPathComponent.hasSuffix(shippingSuffix)
            }.sorted { $0.path < $1.path }

            // Un único Shipping por proyecto: varios harían ambigua la decisión.
            guard shippingCandidates.count == 1,
                  let discoveredShippingURL = shippingCandidates.first else { continue }
            let shippingURL = win64URL.appendingPathComponent(
                discoveredShippingURL.lastPathComponent
            )
            guard try isRegularNonSymlink(shippingURL, directory: false),
                  isSafeShippingExecutable(shippingURL.lastPathComponent),
                  isSafeRoutePath(shippingURL.path) else { continue }

            result.append(D3D12MetalRoute(
                shippingExecutable: shippingURL.lastPathComponent,
                shippingURL: shippingURL
            ))
        }
        return result
    }

    private static func isRegularNonSymlink(_ url: URL, directory: Bool) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true else { return false }
        return directory ? values.isDirectory == true : values.isRegularFile == true
    }

    /// El basename viaja a Wine por entorno, así que se acota a lo que el loader acepta:
    /// sin rutas, sin separadores y sin caracteres que puedan alterar la comparación.
    private static func isSafeShippingExecutable(_ name: String) -> Bool {
        guard name.hasSuffix(shippingSuffix), name.utf8.count < 128 else { return false }
        let stem = String(name.dropLast(shippingSuffix.utf8.count))
        guard !stem.isEmpty else { return false }
        return stem.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || byte == 0x2d
                || byte == 0x5f
        }
    }

    private static func isSafeRoutePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count < 1_000 && path.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f
        }
    }
}
