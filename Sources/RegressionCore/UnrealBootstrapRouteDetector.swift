import Foundation

public struct UnrealBootstrapRoute: Equatable, Sendable {
    public let bootstrapExecutable: String
    public let shippingExecutable: String
    public let shippingURL: URL

    public init(
        bootstrapExecutable: String,
        shippingExecutable: String,
        shippingURL: URL
    ) {
        self.bootstrapExecutable = bootstrapExecutable
        self.shippingExecutable = shippingExecutable
        self.shippingURL = shippingURL
    }
}

/// Detecta la familia moderna del bootstrap de Unreal que separa VC++ por arquitectura.
///
/// Esa familia muestra un falso negativo de VC++ bajo Wine aunque el runtime x64 ya esté sano.
/// La receta no acepta rutas aprendidas ni intenta adivinar proyectos: exige la identidad del
/// bootstrap y sus tres recursos de prerrequisitos exactos, un nombre seguro y un único Shipping
/// regular en la estructura canónica. Los bootstraps antiguos `UEPrereqSetup_x64` quedan fuera.
public enum UnrealBootstrapRouteDetector {
    private static let bootstrapMarker = Data(
        "BootstrapPackagedGame-Win64-Shipping.pdb".utf8
    )
    private static let splitVCResourceMarkers = [
        utf16LittleEndian("Microsoft Visual C++ 2015-2022 Redistributable"),
        utf16LittleEndian(#"Engine\Extras\Redist\en-us\vc_redist.arm64.exe"#),
        utf16LittleEndian(#"Engine\Extras\Redist\en-us\vc_redist.x64.exe"#)
    ]
    private static let maximumGames = 1_024
    private static let maximumProjectDirectories = 64
    private static let maximumRoutes = 16
    private static let maximumBootstrapBytes = 2 * 1_024 * 1_024

    public static func routes(in steamRootURL: URL) throws -> [UnrealBootstrapRoute] {
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
                "la biblioteca excede el límite del detector de bootstraps Unreal"
            )
        }

        var result: [UnrealBootstrapRoute] = []
        for discoveredGameURL in games {
            let gameURL = commonURL.appendingPathComponent(
                discoveredGameURL.lastPathComponent,
                isDirectory: true
            )
            let gameValues = try gameURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey
            ])
            guard gameValues.isDirectory == true, gameValues.isSymbolicLink != true else {
                continue
            }
            result.append(contentsOf: try routes(inGame: gameURL))
            guard result.count <= maximumRoutes else {
                throw RegressionCoreError.invalidEvidence(
                    "se detectaron demasiados bootstraps Unreal en una sola biblioteca"
                )
            }
        }
        let countsByExecutable = Dictionary(
            grouping: result,
            by: { $0.bootstrapExecutable.lowercased() }
        ).mapValues(\.count)
        return result.filter {
            countsByExecutable[$0.bootstrapExecutable.lowercased()] == 1
        }.sorted {
            ($0.bootstrapExecutable.lowercased(), $0.shippingURL.path)
                < ($1.bootstrapExecutable.lowercased(), $1.shippingURL.path)
        }
    }

    private static func routes(inGame gameURL: URL) throws -> [UnrealBootstrapRoute] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: gameURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ).sorted { $0.path < $1.path }

        var result: [UnrealBootstrapRoute] = []
        for discoveredBootstrapURL in entries
        where discoveredBootstrapURL.pathExtension.lowercased() == "exe" {
            let bootstrapURL = gameURL.appendingPathComponent(
                discoveredBootstrapURL.lastPathComponent
            )
            let values = try bootstrapURL.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            let size = values.fileSize ?? 0
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  size > 0,
                  size <= maximumBootstrapBytes,
                  try containsRepairableBootstrapSignature(bootstrapURL) else { continue }

            let stem = bootstrapURL.deletingPathExtension().lastPathComponent
            guard isSafeUnrealStem(stem) else { continue }
            let shippingExecutable = "\(stem)-Win64-Shipping.exe"
            let projectDirectories = entries.filter { discoveredURL in
                let logicalURL = gameURL.appendingPathComponent(
                    discoveredURL.lastPathComponent,
                    isDirectory: true
                )
                return (try? isRegularNonSymlink(logicalURL, directory: true)) == true
            }
            guard projectDirectories.count <= maximumProjectDirectories else { continue }
            let shippingCandidates: [URL] = try projectDirectories.compactMap {
                discoveredURL -> URL? in
                let projectURL = gameURL.appendingPathComponent(
                    discoveredURL.lastPathComponent,
                    isDirectory: true
                )
                let binariesURL = projectURL.appendingPathComponent("Binaries", isDirectory: true)
                let win64URL = binariesURL.appendingPathComponent("Win64", isDirectory: true)
                let shippingURL = win64URL.appendingPathComponent(shippingExecutable)
                guard try isRegularNonSymlink(binariesURL, directory: true),
                      try isRegularNonSymlink(win64URL, directory: true),
                      try isRegularNonSymlink(shippingURL, directory: false)
                else { return nil }
                return shippingURL
            }
            guard shippingCandidates.count == 1,
                  let shippingURL = shippingCandidates.first,
                  isSafeRoutePath(shippingURL.path),
                  ((try shippingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > size
            else { continue }

            result.append(UnrealBootstrapRoute(
                bootstrapExecutable: bootstrapURL.lastPathComponent,
                shippingExecutable: shippingExecutable,
                shippingURL: shippingURL
            ))
        }
        return result
    }

    private static func containsRepairableBootstrapSignature(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return data.range(of: bootstrapMarker) != nil
            && splitVCResourceMarkers.allSatisfy { data.range(of: $0) != nil }
    }

    private static func utf16LittleEndian(_ value: String) -> Data {
        value.data(using: .utf16LittleEndian) ?? Data()
    }

    private static func isRegularNonSymlink(_ url: URL, directory: Bool) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
        ])
        guard values.isSymbolicLink != true else { return false }
        return directory ? values.isDirectory == true : values.isRegularFile == true
    }

    private static func isSafeUnrealStem(_ stem: String) -> Bool {
        guard !stem.isEmpty, stem.utf8.count < 96 else { return false }
        return stem.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || byte == 0x2d || byte == 0x5f
        }
    }

    private static func isSafeRoutePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count < 1_000 && path.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f
        }
    }
}
