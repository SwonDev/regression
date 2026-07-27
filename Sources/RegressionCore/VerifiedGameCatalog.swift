import Foundation

public struct VerifiedGameCertification: Codable, Equatable, Sendable {
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let verifiedAt: String
    public let evidence: String

    public init(
        appID: String,
        gameName: String,
        backend: BackendKind,
        verifiedAt: String,
        evidence: String
    ) {
        self.appID = appID
        self.gameName = gameName
        self.backend = backend
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }
}

/// Catálogo versionado de juegos confirmados visualmente como perfectos.
///
/// La base SQLite conserva cada ejecución y sus incidencias. Este catálogo no aplica ajustes al
/// motor ni sustituye la telemetría: evita perder el estado blindado al regenerar los datos
/// locales. Solo se añade una entrada después de validar render, entrada, opciones y gameplay.
public enum VerifiedGameCatalog {
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
        )
    ]

    public static func certification(for appID: String) -> VerifiedGameCertification? {
        all.first { $0.appID == appID }
    }
}
