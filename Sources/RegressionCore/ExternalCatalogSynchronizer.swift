import Foundation

enum ExternalCatalogSyncOutcome: Equatable, Sendable {
    case freshCache
    case updated(ExternalCompatibilityEntry)
    case noMatch
    case failed(String)
    case cancelled
    case retired
}

/// Límite fail-closed para callers heredados.
///
/// Regression conserva los registros externos ya presentes en SQLite para poder exportarlos y
/// migrarlos, pero el producto distribuido no consulta ni actualiza catálogos de terceros.
/// Mantener este tombstone evita que un caller antiguo vuelva a activar red por accidente.
actor ExternalCatalogSynchronizer {
    init(repository: CompatibilityRepository) {
        _ = repository
    }

    func refresh(game: SteamGame, force: Bool = false) async -> ExternalCatalogSyncOutcome {
        _ = game
        _ = force
        return .retired
    }
}
