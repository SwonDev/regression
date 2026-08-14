import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 4 else {
    fputs(
        "usage: fixture_text_probe.swift <screenshot> [--require-enabled-prominent TEXT]\n",
        stderr
    )
    exit(64)
}

let requiredEnabledProminentText: String? = if CommandLine.arguments.count == 4 {
    CommandLine.arguments[2] == "--require-enabled-prominent" ? CommandLine.arguments[3] : nil
} else {
    nil
}
if CommandLine.arguments.count == 4, requiredEnabledProminentText == nil {
    fputs("argumento de comprobación desconocido\n", stderr)
    exit(64)
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: imageURL),
      let imageData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: imageData),
      let cgImage = bitmap.cgImage else {
    fputs("no se pudo leer la captura\n", stderr)
    exit(65)
}

var observations: [VNRecognizedTextObservation] = []
let request = VNRecognizeTextRequest { request, error in
    guard error == nil else { return }
    observations = request.results as? [VNRecognizedTextObservation] ?? []
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])
let lines = observations.compactMap { $0.topCandidates(1).first?.string }
print(lines.joined(separator: "\n"))

if let requiredEnabledProminentText {
    guard let textObservation = observations.first(where: {
        $0.topCandidates(1).first?.string.contains(requiredEnabledProminentText) == true
    }) else {
        fputs("no se encontró el control prominente solicitado\n", stderr)
        exit(66)
    }

    // Vision devuelve coordenadas normalizadas desde abajo; NSBitmapImageRep usa la superficie
    // raster desde arriba. El margen izquierdo del texto cae dentro del fondo del botón y evita
    // muestrear los glifos blancos. En el fixture claro, un control activo conserva el azul de
    // acento; el mismo botón deshabilitado queda desaturado y no supera este umbral.
    let sampleX = max(0, Int(textObservation.boundingBox.minX * Double(bitmap.pixelsWide)) - 12)
    let sampleY = min(
        bitmap.pixelsHigh - 1,
        max(
            0,
            Int(
                (1 - textObservation.boundingBox.midY)
                    * Double(bitmap.pixelsHigh)
            )
        )
    )
    guard let sample = bitmap.colorAt(x: sampleX, y: sampleY)?.usingColorSpace(.sRGB) else {
        fputs("no se pudo muestrear el control prominente\n", stderr)
        exit(67)
    }
    let red = sample.redComponent * 255
    let blue = sample.blueComponent * 255
    guard blue >= 220, blue - red >= 120 else {
        fputs("el control prominente aparece deshabilitado\n", stderr)
        exit(68)
    }
}
