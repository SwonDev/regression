import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    fputs("usage: fixture_text_probe.swift <screenshot>\n", stderr)
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

var lines: [String] = []
let request = VNRecognizeTextRequest { request, error in
    guard error == nil else { return }
    lines = (request.results as? [VNRecognizedTextObservation] ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])
print(lines.joined(separator: "\n"))
