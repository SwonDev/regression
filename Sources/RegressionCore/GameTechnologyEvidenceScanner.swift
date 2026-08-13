import Foundation

public enum GameTechnologyFamily: String, Codable, CaseIterable, Sendable {
    case gameMaker = "game-maker"
    case monoGame = "monogame"
    case unity
    case unrealEngine = "unreal-engine"
    case xna
}

public enum GameTechnologyConfidence: String, Codable, Sendable {
    case high
}

public enum GameTechnologyEvidenceMarker: String, Codable, CaseIterable, Sendable {
    case directXSetupLibrary = "directx-setup-library"
    case directXSetupProgram = "directx-setup-program"
    case gameMakerDataArchive = "gamemaker-data-archive"
    case monoGameFrameworkAssembly = "monogame-framework-assembly"
    case unityDataManifest = "unity-data-manifest"
    case unityPlayerLibrary = "unity-player-library"
    case unrealEngineBinaries = "unreal-engine-binaries"
    case unrealEngineContent = "unreal-engine-content"
    case unrealShippingExecutable = "unreal-shipping-executable"
    case visualCppRedistributable = "visual-cpp-redistributable"
    case windowsExecutable = "windows-executable"
    case xnaFrameworkAssembly = "xna-framework-assembly"
    case xnaGameAssembly = "xna-game-assembly"
}

/// Evidencia local de inventario. La ruta siempre es relativa y sus componentes no seguros
/// se redactan; nunca representa una ruta autorizada para ejecutar o modificar.
public struct GameTechnologyEvidence: Codable, Equatable, Hashable, Sendable {
    public let marker: GameTechnologyEvidenceMarker
    public let relativePath: String
}

public struct GameTechnologyDetection: Codable, Equatable, Sendable {
    public let family: GameTechnologyFamily
    public let confidence: GameTechnologyConfidence
    public let evidence: [GameTechnologyEvidence]
}

public enum GamePackagedRedistributableKind: String, Codable, CaseIterable, Sendable {
    case directXJune2010 = "directx-june-2010"
    case visualCppARM64 = "visual-cpp-arm64"
    case visualCppX64 = "visual-cpp-x64"
    case visualCppX86 = "visual-cpp-x86"
}

public struct GamePackagedRedistributable: Codable, Equatable, Sendable {
    public let kind: GamePackagedRedistributableKind
    public let evidence: [GameTechnologyEvidence]
}

public struct GameTechnologyEvidenceReport: Codable, Equatable, Sendable {
    public let technologies: [GameTechnologyDetection]
    public let packagedRedistributables: [GamePackagedRedistributable]
    public let runtimeRequirements: [GameRuntimeRequirement]
    public let scannedEntryCount: Int
    public let scannedMetadataBytes: Int

    public var evidence: [GameTechnologyEvidence] {
        let values = technologies.flatMap(\.evidence)
            + packagedRedistributables.flatMap(\.evidence)
        return Array(Set(values)).sorted {
            ($0.marker.rawValue, $0.relativePath) < ($1.marker.rawValue, $1.relativePath)
        }
    }

    /// Vincula las plantillas detectadas a un App ID procedente del catálogo fiable de Steam.
    /// La ruta del juego nunca se usa para inventar esa identidad.
    public func requirements(
        forAppID appID: String,
        observedAt: Date = Date()
    ) throws -> [GameRuntimeRequirement] {
        guard let canonicalAppID = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.invalidEvidence("el Steam App ID no es válido")
        }
        return runtimeRequirements.map {
            GameRuntimeRequirement(
                appID: canonicalAppID,
                kind: $0.kind,
                identifier: $0.identifier,
                versionConstraint: $0.versionConstraint,
                source: $0.source,
                notes: $0.notes,
                observedAt: observedAt
            )
        }
    }

    /// Consume los identificadores declarativos mediante el catálogo cerrado de Regression.
    /// El escáner sigue sin instalar ni ejecutar nada: un ID desconocido queda informativo.
    public func resolvedRequirements(
        forAppID appID: String,
        observedAt: Date = Date()
    ) throws -> [ResolvedGameRuntimeRequirement] {
        try requirements(forAppID: appID, observedAt: observedAt).map(
            GameRuntimeRequirementResolver.resolve
        )
    }
}

struct GameTechnologyScanLimits: Equatable, Sendable {
    static let standard = Self(
        maximumDepth: 8,
        maximumEntries: 8_192,
        maximumMetadataBytes: 512 * 1_024
    )

    let maximumDepth: Int
    let maximumEntries: Int
    let maximumMetadataBytes: Int
}

/// Inventaría marcadores canónicos sin abrir binarios, seguir enlaces ni aplicar reparaciones.
///
/// El presupuesto de bytes cubre los metadatos de ruta inspeccionados. El scanner no lee el
/// contenido de los ficheros y sus requisitos solo contienen identificadores cerrados conocidos.
public enum GameTechnologyEvidenceScanner {
    public static func scan(gameRootURL: URL) throws -> GameTechnologyEvidenceReport {
        try scan(gameRootURL: gameRootURL, limits: .standard)
    }

    static func scan(
        gameRootURL: URL,
        limits: GameTechnologyScanLimits
    ) throws -> GameTechnologyEvidenceReport {
        guard limits.maximumDepth >= 1,
              limits.maximumEntries >= 1,
              limits.maximumMetadataBytes >= 1 else {
            throw RegressionCoreError.invalidEvidence(
                "los límites del inventario tecnológico no son válidos"
            )
        }

        let fileManager = FileManager.default
        let rootURL = gameRootURL.standardizedFileURL
        let rootValues = try rootURL.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw RegressionCoreError.invalidEvidence(
                "la raíz del inventario tecnológico debe ser un directorio regular"
            )
        }

        let inventory = try inventory(
            rootURL: rootURL,
            limits: limits,
            fileManager: fileManager
        )
        let technologies = technologyDetections(in: inventory.entries)
        let redistributables = redistributableDetections(in: inventory.entries)
        let requirements = runtimeRequirements(
            for: technologies,
            redistributables: redistributables
        )
        return GameTechnologyEvidenceReport(
            technologies: technologies,
            packagedRedistributables: redistributables,
            runtimeRequirements: requirements,
            scannedEntryCount: inventory.entryCount,
            scannedMetadataBytes: inventory.metadataBytes
        )
    }

    private struct Inventory {
        let entries: [Entry]
        let entryCount: Int
        let metadataBytes: Int
    }

    private struct Entry {
        let components: [String]
        let lowercaseComponents: [String]
        let relativePath: String
        let isDirectory: Bool
        let isRegularFile: Bool

        var lowercaseName: String { lowercaseComponents.last ?? "" }
        var depth: Int { components.count }
        var parentComponents: [String] { Array(lowercaseComponents.dropLast()) }
    }

    private static func inventory(
        rootURL: URL,
        limits: GameTechnologyScanLimits,
        fileManager: FileManager
    ) throws -> Inventory {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
        ]
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw RegressionCoreError.invalidEvidence(
                "no se pudo abrir el inventario tecnológico"
            )
        }

        let rootComponents = rootURL.pathComponents
        var entries: [Entry] = []
        var entryCount = 0
        var metadataBytes = 0

        while let discoveredURL = enumerator.nextObject() as? URL {
            let standardizedURL = discoveredURL.standardizedFileURL
            let pathComponents = standardizedURL.pathComponents
            guard pathComponents.starts(with: rootComponents) else {
                enumerator.skipDescendants()
                continue
            }
            let components = Array(pathComponents.dropFirst(rootComponents.count))
            guard !components.isEmpty else { continue }
            if components.count > limits.maximumDepth {
                enumerator.skipDescendants()
                continue
            }

            entryCount += 1
            guard entryCount <= limits.maximumEntries else {
                throw RegressionCoreError.invalidEvidence(
                    "el inventario tecnológico excede el límite de entradas"
                )
            }
            metadataBytes += components.reduce(0) { $0 + $1.utf8.count + 1 }
            guard metadataBytes <= limits.maximumMetadataBytes else {
                throw RegressionCoreError.invalidEvidence(
                    "el inventario tecnológico excede el límite de metadatos"
                )
            }

            let values = try standardizedURL.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = values.isDirectory == true
            if isDirectory, components.count == limits.maximumDepth {
                enumerator.skipDescendants()
            }
            entries.append(Entry(
                components: components,
                lowercaseComponents: components.map { $0.lowercased() },
                relativePath: sanitizedRelativePath(components),
                isDirectory: isDirectory,
                isRegularFile: values.isRegularFile == true
            ))
        }
        if let traversalError { throw traversalError }
        return Inventory(
            entries: entries.sorted { $0.lowercaseComponents.lexicographicallyPrecedes($1.lowercaseComponents) },
            entryCount: entryCount,
            metadataBytes: metadataBytes
        )
    }

    private static func technologyDetections(in entries: [Entry]) -> [GameTechnologyDetection] {
        var detections: [GameTechnologyDetection] = []
        if let detection = unityDetection(in: entries) { detections.append(detection) }
        if let detection = unrealDetection(in: entries) { detections.append(detection) }
        if let detection = gameMakerDetection(in: entries) { detections.append(detection) }
        if let detection = xnaDetection(in: entries) { detections.append(detection) }
        if let detection = monoGameDetection(in: entries) { detections.append(detection) }
        return detections.sorted { $0.family.rawValue < $1.family.rawValue }
    }

    private static func unityDetection(in entries: [Entry]) -> GameTechnologyDetection? {
        guard let player = regularFile(named: "unityplayer.dll", atRootOf: entries) else {
            return nil
        }
        let executables = rootExecutables(in: entries)
        for executable in executables {
            let stem = String(executable.components[0].dropLast(4))
            guard isSafeStem(stem) else { continue }
            let manifestComponents = ["\(stem.lowercased())_data", "globalgamemanagers"]
            guard let manifest = entries.first(where: {
                $0.isRegularFile && $0.lowercaseComponents == manifestComponents
            }) else { continue }
            return detection(.unity, evidence: [
                evidence(.unityDataManifest, manifest),
                evidence(.unityPlayerLibrary, player),
                evidence(.windowsExecutable, executable)
            ])
        }
        return nil
    }

    private static func unrealDetection(in entries: [Entry]) -> GameTechnologyDetection? {
        guard let binaries = entries.first(where: {
            $0.isDirectory && $0.lowercaseComponents == ["engine", "binaries"]
        }), let content = entries.first(where: {
            $0.isDirectory && $0.lowercaseComponents == ["engine", "content"]
        }) else { return nil }

        guard let shipping = entries.first(where: { entry in
            guard entry.isRegularFile, entry.depth >= 4 else { return false }
            let suffix = Array(entry.lowercaseComponents.suffix(4))
            let project = suffix[0]
            return isSafeStem(project)
                && suffix[1] == "binaries"
                && suffix[2] == "win64"
                && suffix[3] == "\(project)-win64-shipping.exe"
        }) else { return nil }
        return detection(.unrealEngine, evidence: [
            evidence(.unrealEngineBinaries, binaries),
            evidence(.unrealEngineContent, content),
            evidence(.unrealShippingExecutable, shipping)
        ])
    }

    private static func gameMakerDetection(in entries: [Entry]) -> GameTechnologyDetection? {
        guard let archive = regularFile(named: "data.win", atRootOf: entries),
              let executable = rootExecutables(in: entries).first else { return nil }
        return detection(.gameMaker, evidence: [
            evidence(.gameMakerDataArchive, archive),
            evidence(.windowsExecutable, executable)
        ])
    }

    private static func xnaDetection(in entries: [Entry]) -> GameTechnologyDetection? {
        guard let framework = regularFile(named: "microsoft.xna.framework.dll", atRootOf: entries),
              let game = regularFile(named: "microsoft.xna.framework.game.dll", atRootOf: entries),
              let executable = rootExecutables(in: entries).first else { return nil }
        return detection(.xna, evidence: [
            evidence(.windowsExecutable, executable),
            evidence(.xnaFrameworkAssembly, framework),
            evidence(.xnaGameAssembly, game)
        ])
    }

    private static func monoGameDetection(in entries: [Entry]) -> GameTechnologyDetection? {
        guard let framework = regularFile(named: "monogame.framework.dll", atRootOf: entries),
              let executable = rootExecutables(in: entries).first else { return nil }
        return detection(.monoGame, evidence: [
            evidence(.monoGameFrameworkAssembly, framework),
            evidence(.windowsExecutable, executable)
        ])
    }

    private static func redistributableDetections(
        in entries: [Entry]
    ) -> [GamePackagedRedistributable] {
        var detections: [GamePackagedRedistributable] = []
        for (name, kind) in [
            ("vc_redist.arm64.exe", GamePackagedRedistributableKind.visualCppARM64),
            ("vc_redist.x64.exe", .visualCppX64),
            ("vc_redist.x86.exe", .visualCppX86)
        ] {
            if let entry = entries.first(where: {
                $0.isRegularFile && $0.lowercaseName == name
            }) {
                detections.append(GamePackagedRedistributable(
                    kind: kind,
                    evidence: [evidence(.visualCppRedistributable, entry)]
                ))
            }
        }

        let setupPrograms = entries.filter {
            $0.isRegularFile && $0.lowercaseName == "dxsetup.exe"
        }
        for setup in setupPrograms {
            if let library = entries.first(where: {
                $0.isRegularFile
                    && $0.lowercaseName == "dsetup.dll"
                    && $0.parentComponents == setup.parentComponents
            }) {
                detections.append(GamePackagedRedistributable(
                    kind: .directXJune2010,
                    evidence: [
                        evidence(.directXSetupLibrary, library),
                        evidence(.directXSetupProgram, setup)
                    ]
                ))
                break
            }
        }
        return detections.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private static func runtimeRequirements(
        for technologies: [GameTechnologyDetection],
        redistributables: [GamePackagedRedistributable]
    ) -> [GameRuntimeRequirement] {
        var descriptors: [(RuntimeRequirementKind, String)] = technologies.map {
            switch $0.family {
            case .unity: (.dependency, "unity-player")
            case .unrealEngine: (.dependency, "unreal-engine")
            case .gameMaker: (.dependency, "gamemaker-runner")
            case .xna: (.runtimeComponent, "microsoft-xna-framework")
            case .monoGame: (.dependency, "monogame-framework")
            }
        }
        descriptors.append(contentsOf: redistributables.map {
            switch $0.kind {
            case .directXJune2010: (.runtimeComponent, "directx-june-2010-runtime")
            case .visualCppARM64: (.runtimeComponent, "microsoft-vc-runtime-arm64")
            case .visualCppX64: (.runtimeComponent, "microsoft-vc-runtime-x64")
            case .visualCppX86: (.runtimeComponent, "microsoft-vc-runtime-x86")
            }
        })
        return descriptors.sorted { $0.1 < $1.1 }.map { kind, identifier in
            GameRuntimeRequirement(
                appID: "",
                kind: kind,
                identifier: identifier,
                source: .automatic,
                notes: "Detectado mediante inventario local de solo lectura.",
                observedAt: Date(timeIntervalSince1970: 0)
            )
        }
    }

    private static func detection(
        _ family: GameTechnologyFamily,
        evidence: [GameTechnologyEvidence]
    ) -> GameTechnologyDetection {
        GameTechnologyDetection(
            family: family,
            confidence: .high,
            evidence: evidence.sorted {
                ($0.marker.rawValue, $0.relativePath) < ($1.marker.rawValue, $1.relativePath)
            }
        )
    }

    private static func evidence(
        _ marker: GameTechnologyEvidenceMarker,
        _ entry: Entry
    ) -> GameTechnologyEvidence {
        GameTechnologyEvidence(marker: marker, relativePath: entry.relativePath)
    }

    private static func regularFile(named name: String, atRootOf entries: [Entry]) -> Entry? {
        entries.first {
            $0.isRegularFile && $0.depth == 1 && $0.lowercaseName == name
        }
    }

    private static func rootExecutables(in entries: [Entry]) -> [Entry] {
        entries.filter {
            guard $0.isRegularFile, $0.depth == 1, $0.lowercaseName.hasSuffix(".exe") else {
                return false
            }
            return isSafeStem(String($0.components[0].dropLast(4)))
        }
    }

    private static func isSafeStem(_ stem: String) -> Bool {
        guard !stem.isEmpty, stem.utf8.count <= 96 else { return false }
        return stem.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || byte == 0x2d || byte == 0x5f
        }
    }

    private static func sanitizedRelativePath(_ components: [String]) -> String {
        components.map(sanitizedComponent).joined(separator: "/")
    }

    private static func sanitizedComponent(_ component: String) -> String {
        guard component != ".", component != "..", component.utf8.count <= 96,
              component.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x41...0x5a).contains(byte)
                      || (0x61...0x7a).contains(byte)
                      || byte == 0x20 || byte == 0x2d || byte == 0x2e || byte == 0x5f
              }) else {
            return "<componente-redactado>"
        }
        return component
    }
}
