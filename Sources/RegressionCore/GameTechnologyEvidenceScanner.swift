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
    case directXJune2010Payload = "directx-june-2010-payload"
    case directXSetupLibrary = "directx-setup-library"
    case directXSetupProgram = "directx-setup-program"
    case dotNetFrameworkRedistributable = "dotnet-framework-redistributable"
    case gameMakerDataArchive = "gamemaker-data-archive"
    case monoGameFrameworkAssembly = "monogame-framework-assembly"
    case unityDataManifest = "unity-data-manifest"
    case unityPlayerLibrary = "unity-player-library"
    case unrealEngineBinaries = "unreal-engine-binaries"
    case unrealEngineContent = "unreal-engine-content"
    case unrealShippingExecutable = "unreal-shipping-executable"
    case visualCppRedistributable = "visual-cpp-redistributable"
    case windowsExecutable = "windows-executable"
    case windowsMediaAsset = "windows-media-asset"
    case xnaFrameworkRedistributable = "xna-framework-redistributable"
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
    case directXRuntimeUnknown = "directx-runtime-unknown"
    case dotNetFramework40 = "dotnet-framework-4.0"
    case dotNetFramework45 = "dotnet-framework-4.5"
    case dotNetFramework48 = "dotnet-framework-4.8"
    case dotNetFrameworkUnknown = "dotnet-framework-unknown"
    case visualCppARM64 = "visual-cpp-arm64"
    case visualCppX64 = "visual-cpp-x64"
    case visualCppX86 = "visual-cpp-x86"
    case xnaFramework31 = "xna-framework-3.1"
    case xnaFramework40 = "xna-framework-4.0"
}

public struct GamePackagedRedistributable: Codable, Equatable, Sendable {
    public let kind: GamePackagedRedistributableKind
    public let evidence: [GameTechnologyEvidence]
}

public enum GameRuntimeComponentKind: String, Codable, CaseIterable, Sendable {
    case windowsMedia = "windows-media"
}

public struct GameRuntimeComponentDetection: Codable, Equatable, Sendable {
    public let kind: GameRuntimeComponentKind
    public let evidence: [GameTechnologyEvidence]
}

public struct GameTechnologyEvidenceReport: Codable, Equatable, Sendable {
    public let technologies: [GameTechnologyDetection]
    public let packagedRedistributables: [GamePackagedRedistributable]
    public let runtimeComponents: [GameRuntimeComponentDetection]
    public let runtimeRequirements: [GameRuntimeRequirement]
    public let scannedEntryCount: Int
    public let scannedMetadataBytes: Int

    public var evidence: [GameTechnologyEvidence] {
        let values = technologies.flatMap(\.evidence)
            + packagedRedistributables.flatMap(\.evidence)
            + runtimeComponents.flatMap(\.evidence)
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
        try requirements(forAppID: appID, observedAt: observedAt).map {
            GameRuntimeRequirementResolver.resolve($0)
        }
    }
}

struct GameTechnologyScanLimits: Equatable, Sendable {
    static let standard = Self(
        maximumDepth: 7,
        maximumEntries: 4_096,
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
    /// Actualiza una única proyección automática desde el manifest que acredita ese App ID.
    /// El manifest solo aporta el nombre de instalación; el inventario posterior queda anclado.
    public static func refreshProjection(
        appID: String,
        steamRootURL: URL,
        repository: CompatibilityRepository,
        observedAt: Date = Date()
    ) async throws -> GameTechnologyRequirementProjection {
        try await refreshProjection(
            appID: appID,
            steamRootURL: steamRootURL,
            repository: repository,
            observedAt: observedAt,
            onManifestValidated: nil
        )
    }

    static func refreshProjection(
        appID: String,
        steamRootURL: URL,
        repository: CompatibilityRepository,
        observedAt: Date = Date(),
        onManifestValidated: (() -> Void)?
    ) async throws -> GameTechnologyRequirementProjection {
        guard let canonicalAppID = SteamAppID.normalized(appID), canonicalAppID == appID else {
            throw RegressionCoreError.invalidEvidence(
                "el App ID solicitado no es canónico"
            )
        }
        do {
          let steamAppsURL = steamRootURL.appendingPathComponent(
            "steamapps",
            isDirectory: true
          ).standardizedFileURL
          guard let steamApps = AnchoredDirectory.open(steamAppsURL) else {
            throw RegressionCoreError.invalidEvidence(
                "la raíz steamapps no admite un anclaje seguro"
            )
          }
          let manifestName = "appmanifest_\(canonicalAppID).acf"
          let manifestData: Data
          do {
            manifestData = try steamApps.readRegularFile(
                relativePath: manifestName,
                maximumBytes: 4 * 1_024 * 1_024
            )
          } catch {
            throw RegressionCoreError.invalidEvidence(
                "no existe un manifest regular y acotado para el App ID solicitado"
            )
          }
          guard steamApps.isStillNamedBy(steamAppsURL),
              let manifest = String(data: manifestData, encoding: .utf8),
              let game = SteamManifestParser.parse(
                contents: manifest,
                manifestURL: steamAppsURL.appendingPathComponent(manifestName),
                backend: .regression
              ),
              game.appID == canonicalAppID,
              SteamManifestParser.installReadiness(in: manifest) != .inProgress else {
            throw RegressionCoreError.invalidEvidence(
                "el manifest anclado no acredita una instalación completa para el App ID"
            )
          }
          let directory = game.installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !directory.isEmpty, directory != ".", directory != "..",
              !directory.contains("/"), !directory.contains("\\"),
              !directory.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RegressionCoreError.invalidEvidence(
                "el directorio de instalación del juego no es seguro"
            )
          }
          onManifestValidated?()
          let root = steamAppsURL.appendingPathComponent(
            "common/\(directory)",
            isDirectory: true
          )
          let relativeGameRoot = "common/\(directory)"
          let anchoredGameRoot: AnchoredDirectory
          do {
            anchoredGameRoot = try steamApps.openSubdirectory(
              relativePath: relativeGameRoot
            )
          } catch {
            throw RegressionCoreError.invalidEvidence(
              "la raíz del juego no admite un anclaje seguro desde steamapps"
            )
          }
          let report = try scan(
            gameRootURL: root,
            anchoredRoot: anchoredGameRoot,
            rootIsStillNamed: {
              steamApps.stillNamesSubdirectory(
                relativePath: relativeGameRoot,
                as: anchoredGameRoot
              ) && steamApps.isStillNamedBy(steamAppsURL)
            }
          )
            let requirements = try report.requirements(
                forAppID: canonicalAppID,
                observedAt: observedAt
            )
            try await repository.recordSuccessfulGameTechnologyScan(
                appID: canonicalAppID,
                requirements: requirements,
                scannedAt: observedAt
            )
            return try await repository.gameTechnologyRequirementProjection(appID: canonicalAppID)
        } catch {
            try? await repository.recordFailedGameTechnologyScan(
                appID: canonicalAppID,
                error: error.localizedDescription,
                attemptedAt: observedAt
            )
            throw error
        }
    }

    public static func scan(gameRootURL: URL) throws -> GameTechnologyEvidenceReport {
        try scan(gameRootURL: gameRootURL, limits: .standard)
    }

    static func scan(
        gameRootURL: URL,
        limits: GameTechnologyScanLimits,
        onDirectoryOpened: ((String) -> Void)? = nil
    ) throws -> GameTechnologyEvidenceReport {
        guard limits.maximumDepth >= 1,
              limits.maximumEntries >= 1,
              limits.maximumMetadataBytes >= 1 else {
            throw RegressionCoreError.invalidEvidence(
                "los límites del inventario tecnológico no son válidos"
            )
        }

        let rootURL = gameRootURL.standardizedFileURL
        guard let root = AnchoredDirectory.open(rootURL) else {
            throw RegressionCoreError.invalidEvidence(
                "la raíz del inventario tecnológico debe ser un directorio regular"
            )
        }

        return try scan(
            gameRootURL: rootURL,
            anchoredRoot: root,
            limits: limits,
            onDirectoryOpened: onDirectoryOpened,
            rootIsStillNamed: { root.isStillNamedBy(rootURL) }
        )
    }

    private static func scan(
        gameRootURL: URL,
        anchoredRoot root: AnchoredDirectory,
        limits: GameTechnologyScanLimits = .standard,
        onDirectoryOpened: ((String) -> Void)? = nil,
        rootIsStillNamed: () -> Bool
    ) throws -> GameTechnologyEvidenceReport {
        let inventory = try inventory(
            rootURL: gameRootURL,
            root: root,
            limits: limits,
            onDirectoryOpened: onDirectoryOpened,
            rootIsStillNamed: rootIsStillNamed
        )
        let technologies = technologyDetections(in: inventory.entries)
        let redistributables = redistributableDetections(in: inventory.entries)
        let runtimeComponents = runtimeComponentDetections(in: inventory.entries)
        let requirements = runtimeRequirements(
            for: technologies,
            runtimeComponents: runtimeComponents
        )
        return GameTechnologyEvidenceReport(
            technologies: technologies,
            packagedRedistributables: redistributables,
            runtimeComponents: runtimeComponents,
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
        root: AnchoredDirectory,
        limits: GameTechnologyScanLimits,
        onDirectoryOpened: ((String) -> Void)?,
        rootIsStillNamed: () -> Bool
    ) throws -> Inventory {
        let anchored: AnchoredInventory
        do {
            anchored = try root.boundedInventory(
                maximumDepth: limits.maximumDepth,
                maximumEntries: limits.maximumEntries,
                maximumMetadataBytes: limits.maximumMetadataBytes,
                onDirectoryOpened: onDirectoryOpened
            )
        } catch AnchoredInventoryError.exceedsEntryBudget {
            throw RegressionCoreError.invalidEvidence(
                "el inventario tecnológico excede el límite de entradas"
            )
        } catch AnchoredInventoryError.exceedsMetadataBudget {
            throw RegressionCoreError.invalidEvidence(
                "el inventario tecnológico excede el límite de metadatos"
            )
        } catch {
            throw RegressionCoreError.invalidEvidence(
                "el inventario tecnológico cambió durante la inspección anclada"
            )
        }
        guard rootIsStillNamed() else {
            throw RegressionCoreError.invalidEvidence(
                "la raíz del inventario tecnológico cambió durante la inspección"
            )
        }
        let entries = anchored.entries.map { entry in
            Entry(
                components: entry.components,
                lowercaseComponents: entry.components.map { $0.lowercased() },
                relativePath: sanitizedRelativePath(entry.components),
                isDirectory: entry.isDirectory,
                isRegularFile: entry.isRegularFile
            )
        }
        return Inventory(
            entries: entries.sorted { $0.lowercaseComponents.lexicographicallyPrecedes($1.lowercaseComponents) },
            entryCount: anchored.entryCount,
            metadataBytes: anchored.metadataBytes
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
        var evidenceByKind: [GamePackagedRedistributableKind: Set<GameTechnologyEvidence>] = [:]
        func observe(_ kind: GamePackagedRedistributableKind, _ evidence: GameTechnologyEvidence) {
            evidenceByKind[kind, default: []].insert(evidence)
        }
        for (name, kind) in [
            ("vc_redist.arm64.exe", GamePackagedRedistributableKind.visualCppARM64),
            ("vc_redist.x64.exe", .visualCppX64),
            ("vc_redist.x86.exe", .visualCppX86)
        ] {
            if let entry = entries.first(where: {
                $0.isRegularFile && $0.lowercaseName == name
            }) {
                observe(kind, evidence(.visualCppRedistributable, entry))
            }
        }

        for (name, kind) in [
            ("xnafx31_redist.msi", GamePackagedRedistributableKind.xnaFramework31),
            ("xnafx31_redist.exe", .xnaFramework31),
            ("xnafx40_redist.msi", .xnaFramework40),
            ("xnafx40_redist.exe", .xnaFramework40)
        ] {
            if let entry = entries.first(where: {
                $0.isRegularFile && $0.lowercaseName == name
            }) {
                observe(kind, evidence(.xnaFrameworkRedistributable, entry))
            }
        }

        for (name, kind) in [
            ("dotnetfx40_full_x86_x64.exe", GamePackagedRedistributableKind.dotNetFramework40),
            ("dotnetfx40_full_setup.exe", .dotNetFramework40),
            ("dotnetfx45_full_setup.exe", .dotNetFramework45),
            ("ndp48-x86-x64-allos-enu.exe", .dotNetFramework48),
            ("dotnetfx.exe", .dotNetFrameworkUnknown)
        ] {
            if let entry = entries.first(where: {
                $0.isRegularFile && $0.lowercaseName == name
            }) {
                observe(kind, evidence(.dotNetFrameworkRedistributable, entry))
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
                let junePayload = entries.first { entry in
                    entry.isRegularFile
                        && entry.parentComponents == setup.parentComponents
                        && entry.lowercaseName.hasPrefix("jun2010_")
                        && entry.lowercaseName.hasSuffix(".cab")
                }
                let kind: GamePackagedRedistributableKind = junePayload == nil
                    ? .directXRuntimeUnknown
                    : .directXJune2010
                observe(kind, evidence(.directXSetupLibrary, library))
                observe(kind, evidence(.directXSetupProgram, setup))
                if let junePayload {
                    observe(kind, evidence(.directXJune2010Payload, junePayload))
                }
                break
            }
        }
        return evidenceByKind.map { kind, evidence in
            GamePackagedRedistributable(
                kind: kind,
                evidence: evidence.sorted { lhs, rhs in
                    (lhs.marker.rawValue, lhs.relativePath) < (rhs.marker.rawValue, rhs.relativePath)
                }
            )
        }
        .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private static func runtimeComponentDetections(
        in entries: [Entry]
    ) -> [GameRuntimeComponentDetection] {
        let mediaEvidence = entries.compactMap { entry -> GameTechnologyEvidence? in
            guard entry.isRegularFile else { return nil }
            guard [".wma", ".wmv", ".asf"].contains(where: {
                entry.lowercaseName.hasSuffix($0)
            }) else {
                return nil
            }
            return evidence(.windowsMediaAsset, entry)
        }
        guard !mediaEvidence.isEmpty else { return [] }
        return [GameRuntimeComponentDetection(
            kind: .windowsMedia,
            evidence: mediaEvidence.sorted { $0.relativePath < $1.relativePath }
        )]
    }

    private static func runtimeRequirements(
        for technologies: [GameTechnologyDetection],
        runtimeComponents: [GameRuntimeComponentDetection]
    ) -> [GameRuntimeRequirement] {
        // Un assembly, EXE o MSI junto al juego únicamente acredita que ese material está presente.
        // No demuestra que el prerequisito falte en la botella ni que el ejecutable vaya a usarlo.
        // En particular, Secrets of Grindea usa XNA mediante Wine Mono/FNA y Forsaken Isle ya
        // tiene su baseline .NET validado: convertir su inventario pasivo en un bloqueo sería una
        // regresión. Los requisitos legacy solo podrán entrar aquí cuando exista una autoridad
        // compilada que pruebe la ausencia y describa una transacción sellada con rollback.
        var descriptors: [(RuntimeRequirementKind, String)] = technologies.compactMap {
            switch $0.family {
            case .unity: (.dependency, "unity-player")
            case .unrealEngine: (.dependency, "unreal-engine")
            case .gameMaker: (.dependency, "gamemaker-runner")
            case .xna: nil
            case .monoGame: (.dependency, "monogame-framework")
            }
        }
        descriptors.append(contentsOf: runtimeComponents.map {
            switch $0.kind {
            case .windowsMedia:
                (.runtimeComponent, TrustedComponentCatalog.windowsMediaComponentID)
            }
        })
        let uniqueDescriptors = Dictionary(
            descriptors.map { (("\($0.0.rawValue):\($0.1)"), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.1 < $1.1 }
        return uniqueDescriptors.map { kind, identifier in
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
                || byte == 0x20 || byte == 0x2d || byte == 0x5f
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
