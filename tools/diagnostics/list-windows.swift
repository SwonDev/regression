import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let includeOffscreen = arguments.contains("--all")
let query = arguments.filter { $0 != "--all" }.joined(separator: " ").lowercased()
let options: CGWindowListOption = includeOffscreen ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    guard includeOffscreen || layer == 0 else { continue }

    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let name = window[kCGWindowName as String] as? String ?? ""
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let searchableText = "\(owner) \(name)".lowercased()
    guard query.isEmpty || searchableText.contains(query) else { continue }

    let x = bounds["X"] as? Int ?? 0
    let y = bounds["Y"] as? Int ?? 0
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    print("\(number)\tL\(layer)\t\(owner)\t\(name)\t\(x),\(y) \(width)x\(height)")
}
