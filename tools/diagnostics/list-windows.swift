import CoreGraphics
import Foundation

// Lista las ventanas visibles para poder capturarlas por ID durante una validación.
//
// Filtrar por `layer == 0` fue un error que costó caro: una ventana de Wine a pantalla completa
// vive en la **capa 21**, no en la 0, así que juegos que estaban renderizando perfectamente se
// diagnosticaban como «no abre ventana». El listado ya no filtra por capa; la imprime, que es lo
// que hace falta para entender qué se está mirando.
//
//   list-windows.swift [texto]      ventanas en pantalla, cualquier capa
//   list-windows.swift --all        incluye también las que no están en pantalla
//   list-windows.swift --raw        sin descartar chrome del sistema

let arguments = Array(CommandLine.arguments.dropFirst())
let includeOffscreen = arguments.contains("--all")
let includeSystemChrome = arguments.contains("--raw")
let query = arguments
    .filter { $0 != "--all" && $0 != "--raw" }
    .joined(separator: " ")
    .lowercased()

let options: CGWindowListOption = includeOffscreen
    ? [.optionAll, .excludeDesktopElements]
    : [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

// El chrome del sistema (barra de menús, Dock, extras) ocupa capas altas y superficies mínimas.
// Se descarta por tamaño y capa, no por una lista de nombres que quedaría desfasada.
let minimumInterestingSide = 100
let systemChromeLayer = 100

for window in windows {
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let name = window[kCGWindowName as String] as? String ?? ""
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false

    let x = bounds["X"] as? Int ?? 0
    let y = bounds["Y"] as? Int ?? 0
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0

    if !includeSystemChrome, !includeOffscreen {
        guard layer < systemChromeLayer else { continue }
        guard width >= minimumInterestingSide, height >= minimumInterestingSide else { continue }
    }

    let searchableText = "\(owner) \(name)".lowercased()
    guard query.isEmpty || searchableText.contains(query) else { continue }

    let visibility = onScreen ? "" : "\toculta"
    print("\(number)\tL\(layer)\t\(owner)\t\(name)\t\(x),\(y) \(width)x\(height)\(visibility)")
}
