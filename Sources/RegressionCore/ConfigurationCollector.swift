import CryptoKit
import Darwin
import Foundation

public enum ConfigurationCollector {
    private static let allowedBottleKeys: Set<String> = [
        "Version", "Template", "WineArch", "WindowsVersion",
        "WINEMSYNC", "WINEESYNC", "CX_GRAPHICS_BACKEND",
        "WINEDXVK", "WINED3DMETAL", "CX_DXVK", "CX_D3DMETAL",
        "DXVK_ASYNC", "DXVK_STATE_CACHE", "DXVK_LOG_LEVEL",
        "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "WINEDLLOVERRIDES"
    ]
    private static let allowedRegistryKeys: Set<String> = [
        "RetinaMode", "VideoMemorySize", "renderer", "OffscreenRenderingMode",
        "UseGLSL", "MouseWarpOverride", "GrabFullscreen", "Decorated"
    ]
    private static let graphicsComponents = [
        "d3d9.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll",
        "d3d12core.dll", "dxgi.dll", "winevulkan.dll", "vulkan-1.dll"
    ]
    private static let runtimeComponents = [
        "ucrtbase.dll", "vcruntime140.dll", "vcruntime140_1.dll",
        "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
        "d3dcompiler_43.dll", "d3dcompiler_47.dll",
        "xinput1_3.dll", "xinput1_4.dll", "xaudio2_7.dll",
        "openal32.dll", "mf.dll", "mfplat.dll", "mscoree.dll",
        "winegstreamer.dll"
    ]

    public static func snapshot(
        bottleURL: URL,
        backend: BackendKind,
        providerVersion: String,
        game: SteamGame? = nil,
        steamRootURL: URL? = nil
    ) -> [String: String] {
        var values: [String: String] = [
            "backend": backend.rawValue,
            "provider.version": providerVersion,
            "bottle.name": bottleURL.lastPathComponent
        ]
        collectBottleConfiguration(at: bottleURL, into: &values)
        collectRegistryConfiguration(at: bottleURL, into: &values)
        collectGraphicsComponents(at: bottleURL, into: &values)
        collectRuntimeComponents(at: bottleURL, into: &values)
        if let game, let steamRootURL {
            values.merge(GameConfigurationCollector.snapshot(
                bottleURL: bottleURL,
                steamRootURL: steamRootURL,
                game: game
            )) { _, gameValue in gameValue }
        }
        return values
    }

    public static func fingerprint(_ configuration: [String: String]) -> String {
        let canonical = configuration.keys.sorted().map {
            "\($0)=\(configuration[$0] ?? "")"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Extrae únicamente la identidad del motor y de la botella. Las opciones del juego se
    /// conservan en el snapshot completo, pero no deben crear falsos motores distintos.
    public static func engineValues(from configuration: [String: String]) -> [String: String] {
        let exactKeys: Set<String> = ["backend", "provider.version"]
        let prefixes = ["bottle.", "registry.", "component.", "graphics.", "runtime."]
        return configuration.filter { key, _ in
            exactKeys.contains(key) || prefixes.contains(where: key.hasPrefix)
        }
    }

    public static func engineFingerprint(for configuration: [String: String]) -> String {
        fingerprint(engineValues(from: configuration))
    }

    private static func collectBottleConfiguration(at bottleURL: URL, into values: inout [String: String]) {
        let configURL = bottleURL.appendingPathComponent("cxbottle.conf")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        let pattern = #"(?m)^\s*"([A-Za-z0-9_]+)"\s*=\s*"([^"]*)"\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        for match in expression.matches(in: contents, range: range) {
            guard
                let keyRange = Range(match.range(at: 1), in: contents),
                let valueRange = Range(match.range(at: 2), in: contents)
            else { continue }
            let key = String(contents[keyRange])
            guard allowedBottleKeys.contains(key) else { continue }
            values["bottle.\(key)"] = String(contents[valueRange])
        }
    }

    private static func collectRegistryConfiguration(at bottleURL: URL, into values: inout [String: String]) {
        for fileName in ["user.reg", "system.reg"] {
            let registryURL = bottleURL.appendingPathComponent(fileName)
            guard let contents = try? String(contentsOf: registryURL, encoding: .utf8) else { continue }

            for line in contents.split(whereSeparator: \.isNewline) {
                let text = String(line)
                guard text.hasPrefix("\"") else { continue }
                guard let closingQuote = text.dropFirst().firstIndex(of: "\"") else { continue }
                let key = String(text[text.index(after: text.startIndex)..<closingQuote])
                guard allowedRegistryKeys.contains(key), let equals = text.firstIndex(of: "=") else { continue }
                let rawValue = String(text[text.index(after: equals)...])
                values["registry.\(key)"] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
    }

    private static func collectGraphicsComponents(at bottleURL: URL, into values: inout [String: String]) {
        let system32 = bottleURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        for component in graphicsComponents {
            let url = system32.appendingPathComponent(component)
            guard let signature = componentSignature(at: url) else { continue }
            values["component.graphics.\(component)"] = signature
        }
    }

    private static func collectRuntimeComponents(at bottleURL: URL, into values: inout [String: String]) {
        let system32 = bottleURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        for component in runtimeComponents {
            let url = system32.appendingPathComponent(component)
            guard let signature = componentSignature(at: url) else { continue }
            values["component.runtime.\(component)"] = signature
        }

        let frameworkRoot = bottleURL.appendingPathComponent(
            "drive_c/windows/Microsoft.NET/Framework64",
            isDirectory: true
        )
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: frameworkRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let names = versions.compactMap { url -> String? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true ? url.lastPathComponent : nil
            }.sorted()
            if !names.isEmpty { values["component.runtime.dotnet-frameworks"] = names.joined(separator: ",") }
        }
    }

    private static func componentSignature(at url: URL) -> String? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "bytes=\(size);sha256=\(hash)"
    }
}

public enum SystemInformation {
    public static func deviceModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac desconocido"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "Mac desconocido"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "desconocida"
        #endif
    }
}

/// Ejecuta el inventario de configuración fuera del actor principal. El cálculo incluye hashes
/// de DLLs y lectura acotada de ajustes, por lo que no debe competir con la interacción del menú.
public actor ConfigurationSnapshotCollector {
    public init() {}

    public func snapshot(
        bottleURL: URL,
        backend: BackendKind,
        providerVersion: String,
        game: SteamGame? = nil,
        steamRootURL: URL? = nil
    ) -> [String: String] {
        ConfigurationCollector.snapshot(
            bottleURL: bottleURL,
            backend: backend,
            providerVersion: providerVersion,
            game: game,
            steamRootURL: steamRootURL
        )
    }
}
