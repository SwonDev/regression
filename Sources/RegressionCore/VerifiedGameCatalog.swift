import Foundation

public enum CertificationOrigin: String, Codable, Sendable {
    case embeddedCatalog
    case localVerification
}

public struct VerifiedGameCertification: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(appID)-\(backend.rawValue)" }
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let verifiedAt: String
    public let evidence: String
    public let criteriaVersion: Int
    public let origin: CertificationOrigin
    public let sourceRunID: UUID?
    public let sourceObservationID: UUID?
    public let configurationFingerprint: String?
    public let engineFingerprint: String?
    public let catalogRevision: String
    public let isActive: Bool
    public let syncedAt: Date?

    public init(
        appID: String,
        gameName: String,
        backend: BackendKind,
        verifiedAt: String,
        evidence: String,
        criteriaVersion: Int = 2,
        origin: CertificationOrigin = .embeddedCatalog,
        sourceRunID: UUID? = nil,
        sourceObservationID: UUID? = nil,
        configurationFingerprint: String? = nil,
        engineFingerprint: String? = nil,
        catalogRevision: String = "embedded",
        isActive: Bool = true,
        syncedAt: Date? = nil
    ) {
        self.appID = appID
        self.gameName = gameName
        self.backend = backend
        self.verifiedAt = verifiedAt
        self.evidence = evidence
        self.criteriaVersion = criteriaVersion
        self.origin = origin
        self.sourceRunID = sourceRunID
        self.sourceObservationID = sourceObservationID
        self.configurationFingerprint = configurationFingerprint
        self.engineFingerprint = engineFingerprint
        self.catalogRevision = catalogRevision
        self.isActive = isActive
        self.syncedAt = syncedAt
    }


    public var rendering: VerificationDimension { .passed }
    public var inputPrecision: VerificationDimension { .passed }
    public var graphicsSettings: VerificationDimension { .passed }
    public var gameplay: VerificationDimension { .passed }
}

/// Catálogo versionado de juegos confirmados visualmente como perfectos.
///
/// La base SQLite conserva cada ejecución y sus incidencias. Este catálogo no aplica ajustes al
/// motor ni sustituye la telemetría: evita perder el estado blindado al regenerar los datos
/// locales. Solo se añade una entrada después de validar render, entrada, opciones y gameplay.
public enum VerifiedGameCatalog {
    public static let revision = "2026-08-09.4"

    public static let all: [VerifiedGameCertification] = [
        VerifiedGameCertification(
            appID: "1128000",
            gameName: "Cube World",
            backend: .regression,
            verifiedAt: "2026-07-26",
            evidence: "README.md y capturas locales del perfil blindado de Cube World"
        ),
        VerifiedGameCertification(
            appID: "1004640",
            gameName: "FINAL FANTASY TACTICS - The Ivalice Chronicles",
            backend: .regression,
            verifiedAt: "2026-07-26",
            evidence: "backups/regression-steam-user-fft-perfect-20260726.reg"
        ),
        VerifiedGameCertification(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            verifiedAt: "2026-07-27",
            evidence: "docs/games/grim-dawn.md"
        ),
        VerifiedGameCertification(
            appID: "1903340",
            gameName: "Clair Obscur: Expedition 33",
            backend: .regression,
            verifiedAt: "2026-07-29",
            evidence: "docs/games/clair-obscur-expedition-33.md"
        ),
        VerifiedGameCertification(
            appID: "4570720",
            gameName: "DragonSword : Awakening",
            backend: .regression,
            verifiedAt: "2026-07-29",
            evidence: "docs/games/dragonsword-awakening.md"
        ),
        VerifiedGameCertification(
            appID: "1782460",
            gameName: "Hell Clock",
            backend: .regression,
            verifiedAt: "2026-07-29",
            evidence: "docs/games/hell-clock.md",
            sourceRunID: UUID(uuidString: "2F2DE49D-DE01-4A7F-B2D2-39195EA5D68B"),
            configurationFingerprint:
                "aa2c5e6b85a6c077dfeb18bf0e626519000ee144eabf25ecccf0aa317a41f199",
            engineFingerprint:
                "033fd4ebad662f34b73e309cc721cfae8cd32fdcd1b2b06b0d235e93e95a1dbb"
        ),
        VerifiedGameCertification(
            appID: "619820",
            gameName: "Heroes of Hammerwatch II",
            backend: .regression,
            verifiedAt: "2026-07-29",
            evidence: "docs/games/heroes-of-hammerwatch-2.md",
            sourceRunID: UUID(uuidString: "F8E4EA27-2E6B-439C-AC93-BD927035B5B5"),
            configurationFingerprint:
                "af59b82a9e8102995ccbf5a9c93e1e9e6c62afe3213bea8a0bbe2ff7726236f1",
            engineFingerprint:
                "af59b82a9e8102995ccbf5a9c93e1e9e6c62afe3213bea8a0bbe2ff7726236f1"
        ),
        VerifiedGameCertification(
            appID: "269770",
            gameName: "Secrets of Grindea",
            backend: .regression,
            verifiedAt: "2026-08-02",
            evidence: "docs/games/secrets-of-grindea.md",
            sourceRunID: UUID(uuidString: "953B6822-AC77-4977-B862-B206D3CE16AE"),
            configurationFingerprint:
                "8bf2d0909a1d0ed0500a900183492136eb54a4396f72ad15a28940a0dfd3c61f",
            engineFingerprint:
                "2dca5d61f65d10ac63fa3876c4af0c62f078b7f6f884c208d9590db8f746b820"
        ),
        VerifiedGameCertification(
            appID: "2142790",
            gameName: "Fields of Mistria",
            backend: .regression,
            verifiedAt: "2026-08-07",
            evidence: "docs/games/fields-of-mistria.md",
            sourceRunID: UUID(uuidString: "BAAC2B06-3CAD-467A-B1F1-834B76B794AD"),
            configurationFingerprint:
                "9d3e77a78a6501f33b32705937555a833f7fa3966011e02616d3811f592146b9",
            engineFingerprint:
                "9d3e77a78a6501f33b32705937555a833f7fa3966011e02616d3811f592146b9"
        ),
        VerifiedGameCertification(
            appID: "347940",
            gameName: "Forsaken Isle",
            backend: .regression,
            verifiedAt: "2026-08-08",
            evidence: "docs/games/forsaken-isle.md",
            sourceObservationID: UUID(uuidString: "31104A67-1DE6-4C6D-BE5D-797A60648769"),
            configurationFingerprint:
                "f6c2734165d679081d1f3e9126126561a19e375ef681bd8dfc84ef6f0788be69",
            engineFingerprint:
                "f6c2734165d679081d1f3e9126126561a19e375ef681bd8dfc84ef6f0788be69"
        ),
        VerifiedGameCertification(
            appID: "1374490",
            gameName: "RuneScape: Dragonwilds",
            backend: .regression,
            verifiedAt: "2026-08-09",
            evidence: "docs/games/dragonwilds.md",
            sourceRunID: UUID(uuidString: "E5244599-5E9F-4F78-BB9B-00CC781E539E"),
            configurationFingerprint:
                "596c6ae2057bbae251428da17ad911e46f7ef6dba73950d8c5bd00d9c9cc53a5",
            engineFingerprint:
                "17e2f294927c10198edaf33ca11751376269a8271023e5e660bdca8d36874c56"
        ),
        VerifiedGameCertification(
            appID: "2617700",
            gameName: "Tinkerlands",
            backend: .regression,
            verifiedAt: "2026-08-09",
            evidence: "docs/games/tinkerlands.md",
            sourceRunID: UUID(uuidString: "0B6589C9-374B-4570-A30A-645EEF57A497"),
            configurationFingerprint:
                "7808621e2355e2c159b3bd78836738d2fc93ef9a5d2dc6468244117f3ff6e8f9",
            engineFingerprint:
                "37e2ce6806f201c1bec1f0807e467b28b1dd988ba33635e9fb6c823a7ccfd745"
        ),
        VerifiedGameCertification(
            appID: "2350790",
            gameName: "Moonlighter 2: The Endless Vault",
            backend: .regression,
            verifiedAt: "2026-08-09",
            evidence: "docs/games/moonlighter-2.md",
            sourceRunID: UUID(uuidString: "9E384BCC-18FA-4BE6-A879-8AA1E724E4C4"),
            configurationFingerprint:
                "a6601afa279218f05f11c770759898744ff0dcc0bc9a5527cefb19a1bc2331b9",
            engineFingerprint:
                "28d3234281bc056e55cb93c13dbb06d50b53771467c154733de930ef70afa5d1"
        ),
        VerifiedGameCertification(
            appID: "1619520",
            gameName: "Cross Blitz",
            backend: .regression,
            verifiedAt: "2026-08-09",
            evidence: "docs/games/cross-blitz.md",
            sourceRunID: UUID(uuidString: "8EB67186-3D63-4C29-9535-BFC1BAB0A52B"),
            configurationFingerprint:
                "3d3b91f4c16907b92f19ba819ceb208a2f80b494b50eb9531efb37a35f120e4d",
            engineFingerprint:
                "fa3cb7e58e5fc638ad9e4d1e20161a3ecf07ba2e1acd05db280f1a3af2d4a3b0"
        ),
        VerifiedGameCertification(
            appID: "4059020",
            gameName: "Luminary Demo",
            backend: .regression,
            verifiedAt: "2026-08-09",
            evidence: "docs/games/luminary-demo.md",
            sourceRunID: UUID(uuidString: "EE1C5A66-1AAA-4594-B30D-1E8ECFA5A27B"),
            configurationFingerprint:
                "fa3cb7e58e5fc638ad9e4d1e20161a3ecf07ba2e1acd05db280f1a3af2d4a3b0",
            engineFingerprint:
                "fa3cb7e58e5fc638ad9e4d1e20161a3ecf07ba2e1acd05db280f1a3af2d4a3b0"
        ),
        VerifiedGameCertification(
            appID: "1285190",
            gameName: "Borderlands® 4",
            backend: .regression,
            verifiedAt: "2026-08-09",
            evidence: "docs/games/borderlands-4.md",
            sourceObservationID: UUID(uuidString: "1BDCD9E2-D5F1-4C30-BBDA-43B0E5B3BBCA"),
            configurationFingerprint:
                "a2ec1490e641083b69d63e39f5d013a84760ccf50ca4fb8333b2843f191feeec",
            engineFingerprint:
                "d7172135a42000c3c4f672663500351f27df9b89bea0d76551dc79be828b95d0"
        )
    ]

    public static func certification(for appID: String) -> VerifiedGameCertification? {
        all.first { $0.appID == appID }
    }
}
