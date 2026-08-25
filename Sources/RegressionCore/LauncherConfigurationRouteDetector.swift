import Foundation

public struct LauncherConfigurationRoute: Equatable, Sendable {
    /// Basename exacto del prelanzador que arranca Steam.
    public let launcherExecutable: String
    /// Basename exacto del ejecutable de juego elegido.
    public let targetExecutable: String
    public let targetURL: URL

    public init(launcherExecutable: String, targetExecutable: String, targetURL: URL) {
        self.launcherExecutable = launcherExecutable
        self.targetExecutable = targetExecutable
        self.targetURL = targetURL
    }
}

/// Detecta juegos cuyo prelanzador declara **en un archivo propio** qué ejecutables tiene y con
/// qué API gráfica, y elige el que este runtime sabe servir.
///
/// El caso reproducido es REDengine (The Witcher 3, Cyberpunk 2077): Steam arranca
/// `REDprelauncher.exe`, que abre una interfaz Qt WebEngine —Chromium embebido— para que elijas
/// entre DirectX 11 y DirectX 12. Esa interfaz **revienta** bajo Wine y, cuando lo hace, el
/// prelanzador lanza igualmente **la primera entrada de su configuración**, que es DirectX 12.
/// El juego responde entonces con «GPU does not meet minimal requirements. Support for DirectX 12
/// is required» y no arranca. El mismo juego en su binario DirectX 11 funciona perfectamente.
///
/// La detección es **por contenido**, no por App ID ni por lista de títulos: exige el archivo de
/// configuración del prelanzador y el propio prelanzador en la misma carpeta. La elección también
/// se hace por evidencia: se prefiere el ejecutable cuya ruta declarada **no** sea la variante
/// D3D12, porque D3D11 es la ruta que este runtime acredita (DXMT) y D3D12 solo se sirve por una
/// ruta a D3DMetal que estos binarios no tienen. Si algún día se acredita, esta preferencia es lo
/// que hay que revisar.
///
/// Nada de esto se aprende ni se almacena: se recalcula al arrancar, está acotado y solo puede
/// producir una redirección a un fichero regular dentro de la propia carpeta del juego.
public enum LauncherConfigurationRouteDetector {
    private static let configurationName = "launcher-configuration.json"
    /// El prelanzador de REDengine. Es un marcador **de formato**, igual que `hlboot.dat` lo es de
    /// HashLink: identifica a la familia, no a un juego.
    private static let launcherName = "REDprelauncher.exe"
    private static let maximumGames = 1_024
    private static let maximumConfigurationBytes = 1_024 * 1_024
    private static let maximumEntries = 8
    private static let maximumRoutes = 8
    private static let direct3D12Marker = "dx12"

    public static func routes(in steamRootURL: URL) throws -> [LauncherConfigurationRoute] {
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
                "la biblioteca excede el límite del detector de configuraciones de prelanzador"
            )
        }

        var result: [LauncherConfigurationRoute] = []
        for game in games {
            let gameURL = commonURL.appendingPathComponent(
                game.lastPathComponent,
                isDirectory: true
            )
            let values = try? gameURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if let route = try route(inGame: gameURL) { result.append(route) }
            guard result.count <= maximumRoutes else {
                throw RegressionCoreError.invalidEvidence(
                    "la biblioteca declara más prelanzadores con configuración de los admitidos"
                )
            }
        }
        return result
    }

    static func route(inGame gameURL: URL) throws -> LauncherConfigurationRoute? {
        let configurationURL = gameURL.appendingPathComponent(configurationName)
        let launcherURL = gameURL.appendingPathComponent(launcherName)
        guard isReadableRegularFile(configurationURL), isReadableRegularFile(launcherURL) else {
            return nil
        }

        let size = (try? configurationURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= maximumConfigurationBytes else { return nil }
        guard let data = try? Data(contentsOf: configurationURL, options: [.mappedIfSafe]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = root["executables"] as? [[String: Any]],
              !rawEntries.isEmpty, rawEntries.count <= maximumEntries else { return nil }

        var candidates: [(directoryPath: String, url: URL)] = []
        for entry in rawEntries {
            guard let executable = entry["executable"] as? [String: Any],
                  let fileName = executable["fileName"] as? String,
                  let directoryPath = executable["directoryPath"] as? String,
                  isSafeExecutableName(fileName),
                  let directory = resolvedDirectory(directoryPath, in: gameURL) else { continue }
            let target = directory.appendingPathComponent(fileName)
            guard isReadableRegularFile(target) else { continue }
            candidates.append((directoryPath: directoryPath.lowercased(), url: target))
        }
        guard !candidates.isEmpty else { return nil }

        // Se prefiere la variante que **no** es D3D12; si solo hay D3D12, no se redirige nada:
        // dejar que el prelanzador haga lo suyo es mejor que fingir una ruta que no existe.
        guard let chosen = candidates.first(where: { !$0.directoryPath.contains(direct3D12Marker) })
        else { return nil }

        // Una redirección de imagen sustituye el ejecutable **dentro del proceso ya creado**, así
        // que no puede cambiar de arquitectura: proponerlo hace que la creación del proceso falle
        // con `ERROR_NOT_SUPPORTED` y Steam lo reporte como `AppError_46`. Es exactamente lo que
        // ocurre con REDengine, cuyo prelanzador es de 32 bits y cuyo juego es de 64.
        guard let launcherMachine = try PortableExecutableReader.machine(at: launcherURL),
              let targetMachine = try PortableExecutableReader.machine(at: chosen.url),
              launcherMachine == targetMachine else { return nil }

        let targetName = chosen.url.lastPathComponent
        guard targetName.caseInsensitiveCompare(launcherName) != .orderedSame else { return nil }
        return LauncherConfigurationRoute(
            launcherExecutable: launcherName,
            targetExecutable: targetName,
            targetURL: chosen.url
        )
    }

    /// El directorio declarado es una ruta relativa de Windows. Se aceptan solo segmentos planos:
    /// ni rutas absolutas, ni `..`, ni enlaces simbólicos, ni salir de la carpeta del juego.
    private static func resolvedDirectory(_ declared: String, in gameURL: URL) -> URL? {
        let segments = declared.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard !segments.isEmpty, segments.count <= 4 else { return nil }
        var url = gameURL
        for segment in segments {
            guard isSafePathSegment(segment) else { return nil }
            url.appendPathComponent(segment, isDirectory: true)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
        }
        return url
    }

    private static func isSafePathSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment.count <= 64, segment != ".", segment != ".." else {
            return false
        }
        return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func isSafeExecutableName(_ name: String) -> Bool {
        guard name.count > 4, name.count <= 64,
              name.lowercased().hasSuffix(".exe") else { return false }
        let stem = String(name.dropLast(4))
        guard !stem.isEmpty else { return false }
        return stem.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func isReadableRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
