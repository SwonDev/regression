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
/// Se aceptan **dos formas de evidencia**, ambas del propio juego y ninguna inferida por App ID
/// o por nombre:
///
/// 1. El **Agility SDK** de Direct3D 12 (`D3D12Core.dll`) junto al Shipping de Unreal, en la
///    estructura canónica `<juego>/<proyecto>/Binaries/Win64/D3D12/`.
/// 2. El ejecutable declara `d3d12.dll` como **delay-load** en su propio PE.
///
/// La segunda existe porque la primera dejaba fuera a la mayoría. Unreal no enlaza `d3d12.dll`
/// de forma estática —el juego no arrancaría en máquinas sin D3D12—: lo declara como delay-load
/// y decide en tiempo de ejecución. Un título así, sin Agility SDK y con un ejecutable que no se
/// llama `*-Win64-Shipping.exe`, quedaba invisible para el detector y terminaba mostrando
/// «DX12 is not supported in your system», que es el juego rindiéndose, no el motor fallando.
///
/// El criterio se validó contra la biblioteca entera: lo acreditan exactamente los títulos que
/// necesitan D3D12 —incluido DragonSword, cuyo perfil compilado ya codificaba a mano esta misma
/// evidencia— y **ninguno** de los que funcionan sobre DXMT. Un ejecutable que no acredita
/// ninguna de las dos formas conserva exactamente el comportamiento anterior.
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
    private static let maximumExecutablesPerProject = 64
    private static let direct3D12Module = "d3d12.dll"

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
            guard try isRegularNonSymlink(win64URL, directory: true) else { continue }

            let agilityURL = win64URL
                .appendingPathComponent("D3D12", isDirectory: true)
                .appendingPathComponent(agilityCoreName)
            let hasAgilitySDK = try isRegularNonSymlink(agilityURL, directory: false)

            let executables = try FileManager.default.contentsOfDirectory(
                at: win64URL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.pathExtension.caseInsensitiveCompare("exe") == .orderedSame
            }.sorted { $0.path < $1.path }
            guard executables.count <= maximumExecutablesPerProject else { continue }

            var candidates: [URL] = []
            for discovered in executables {
                let executableURL = win64URL.appendingPathComponent(discovered.lastPathComponent)
                guard try isRegularNonSymlink(executableURL, directory: false),
                      isSafeRoutedExecutable(executableURL.lastPathComponent),
                      isSafeRoutePath(executableURL.path) else { continue }

                // Evidencia 1: el Shipping canónico de Unreal acompañado del Agility SDK.
                if hasAgilitySDK, executableURL.lastPathComponent.hasSuffix(shippingSuffix) {
                    candidates.append(executableURL)
                    continue
                }
                // Evidencia 2: el propio PE declara `d3d12.dll` como delay-load.
                if let imports = (try? PortableExecutableReader.imports(at: executableURL)) ?? nil,
                   imports.delayLoads(direct3D12Module) {
                    candidates.append(executableURL)
                }
            }

            // Un único candidato por proyecto: varios harían ambigua la decisión gráfica.
            guard candidates.count == 1, let shippingURL = candidates.first else { continue }

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
    /// Un basename enrutable solo puede contener letras, dígitos, guion y guion bajo antes de
    /// `.exe`. No se exige ya el sufijo `-Win64-Shipping`: la mayoría de los juegos Unreal que
    /// necesitan D3D12 nombran su ejecutable como el juego. La estrictez se conserva porque el
    /// basename viaja hasta el loader de Wine dentro de una variable de entorno.
    private static func isSafeRoutedExecutable(_ name: String) -> Bool {
        guard name.lowercased().hasSuffix(".exe"), name.utf8.count < 128 else { return false }
        let stem = String(name.dropLast(4))
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
