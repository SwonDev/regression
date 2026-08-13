import Foundation

/// Identidad de solo lectura para filas históricas importadas antes de retirar el catálogo
/// externo. No es un proveedor, no tiene inicializador y no contiene ninguna dirección de red.
///
/// `codeWeaversSource` conserva el nombre anterior porque las migraciones del repositorio lo usan
/// para localizar el `source_id` ya persistido. Sus URL son marcadores locales no operativos.
enum CodeWeaversCompatibilityProvider {
    static let historicalSourceID = "codeweavers"

    static let codeWeaversSource = ExternalCatalogSource(
        id: historicalSourceID,
        displayName: "Referencia externa heredada (solo lectura)",
        baseURL: historicalArchiveURL,
        informationURL: historicalArchiveURL,
        minimumRequestInterval: 0,
        cacheLifetime: 0
    )

    private static let historicalArchiveURL = URL(
        fileURLWithPath: "/Library/Application Support/Regression/HistoricalSources/codeweavers",
        isDirectory: true
    )
}
