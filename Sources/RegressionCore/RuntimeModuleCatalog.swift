import Foundation

enum RuntimeModuleBinaryClass: String, Codable, CaseIterable, Sendable {
    case builtinWine
    case nativePE
    case localUserProvided
}

enum RuntimeModuleExpectedLocation: Codable, Equatable, Hashable, Sendable {
    case bottleSystem32
    case wineRootWindows64
    case localUserComponent(relativePath: String)
}

struct RuntimeModuleRequiredPair: Codable, Equatable, Sendable {
    let first: RuntimeModuleExpectedLocation
    let second: RuntimeModuleExpectedLocation

    init(first: RuntimeModuleExpectedLocation, second: RuntimeModuleExpectedLocation) {
        self.first = first
        self.second = second
    }
}

enum RuntimeModuleOverridePolicy: String, Codable, CaseIterable, Sendable {
    case allowed
    case forbidden
}

enum RuntimeModuleScope: String, Codable, CaseIterable, Sendable {
    case global
    case perProcess
}

enum RuntimeModuleArchitecture: String, Codable, CaseIterable, Sendable {
    case x86_64
}

enum RuntimeModuleSnapshotNamespace: String, Codable, CaseIterable, Sendable {
    case graphics
    case runtime
}

struct RuntimeModuleProvenance: Codable, Equatable, Sendable {
    let project: String
    let sourceURL: URL
    let license: String

    init(project: String, sourceURL: URL, license: String) {
        self.project = project
        self.sourceURL = sourceURL
        self.license = license
    }
}

struct RuntimeModuleDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let fileName: String
    let binaryClass: RuntimeModuleBinaryClass
    let expectedLocations: [RuntimeModuleExpectedLocation]
    let requiredPair: RuntimeModuleRequiredPair?
    let overridePolicy: RuntimeModuleOverridePolicy
    let scope: RuntimeModuleScope
    let architecture: RuntimeModuleArchitecture
    let variant: String
    let provenance: RuntimeModuleProvenance

    init(
        id: String,
        fileName: String,
        binaryClass: RuntimeModuleBinaryClass,
        expectedLocations: [RuntimeModuleExpectedLocation],
        requiredPair: RuntimeModuleRequiredPair? = nil,
        overridePolicy: RuntimeModuleOverridePolicy,
        scope: RuntimeModuleScope,
        architecture: RuntimeModuleArchitecture,
        variant: String,
        provenance: RuntimeModuleProvenance
    ) {
        self.id = id
        self.fileName = fileName
        self.binaryClass = binaryClass
        self.expectedLocations = expectedLocations
        self.requiredPair = requiredPair
        self.overridePolicy = overridePolicy
        self.scope = scope
        self.architecture = architecture
        self.variant = variant
        self.provenance = provenance
    }
}

/// A neutral file observation used only to preserve configuration fingerprints.
///
/// An inventory item deliberately carries no binary class, provenance, override
/// policy, or repair scope: a bottle can replace the same filename with a Wine
/// builtin or a vendor PE without changing the public snapshot key.
struct RuntimeModuleInventoryItem: Codable, Equatable, Identifiable, Sendable {
    let fileName: String
    let snapshotNamespace: RuntimeModuleSnapshotNamespace

    var id: String { snapshotKey }
    var snapshotKey: String {
        "component.\(snapshotNamespace.rawValue).\(fileName)"
    }

    init(fileName: String, snapshotNamespace: RuntimeModuleSnapshotNamespace) {
        self.fileName = fileName
        self.snapshotNamespace = snapshotNamespace
    }
}

enum RuntimeModuleCatalog {
    private static let dxmt = RuntimeModuleProvenance(
        project: "DXMT",
        sourceURL: URL(string: "https://github.com/3Shain/dxmt")!,
        license: "LGPL-2.1+"
    )
    private static let dxvk = RuntimeModuleProvenance(
        project: "DXVK",
        sourceURL: URL(string: "https://github.com/doitsujin/dxvk")!,
        license: "Zlib"
    )
    private static let appleGPTK = RuntimeModuleProvenance(
        project: "Apple Game Porting Toolkit",
        sourceURL: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!,
        license: "Apple license; local user-provided component; not redistributed"
    )

    /// Modules whose class, placement, policy, architecture, and provenance are
    /// protected facts. This is intentionally not the bottle snapshot inventory.
    static let protectedModules: [RuntimeModuleDescriptor] = [
        RuntimeModuleDescriptor(
            id: "dxvk.d3d9",
            fileName: "d3d9.dll",
            binaryClass: .nativePE,
            expectedLocations: [.bottleSystem32],
            overridePolicy: .allowed,
            scope: .global,
            architecture: .x86_64,
            variant: "1.10.3",
            provenance: dxvk
        ),
        RuntimeModuleDescriptor(
            id: "dxmt.d3d10core",
            fileName: "d3d10core.dll",
            binaryClass: .builtinWine,
            expectedLocations: [.bottleSystem32, .wineRootWindows64],
            requiredPair: RuntimeModuleRequiredPair(
                first: .bottleSystem32,
                second: .wineRootWindows64
            ),
            overridePolicy: .forbidden,
            scope: .global,
            architecture: .x86_64,
            variant: "0.72-regression-cross-process",
            provenance: dxmt
        ),
        RuntimeModuleDescriptor(
            id: "dxmt.d3d11",
            fileName: "d3d11.dll",
            binaryClass: .builtinWine,
            expectedLocations: [.bottleSystem32, .wineRootWindows64],
            requiredPair: RuntimeModuleRequiredPair(
                first: .bottleSystem32,
                second: .wineRootWindows64
            ),
            overridePolicy: .forbidden,
            scope: .global,
            architecture: .x86_64,
            variant: "0.72-regression-cross-process",
            provenance: dxmt
        ),
        RuntimeModuleDescriptor(
            id: "dxmt.dxgi",
            fileName: "dxgi.dll",
            binaryClass: .builtinWine,
            expectedLocations: [.bottleSystem32, .wineRootWindows64],
            requiredPair: RuntimeModuleRequiredPair(
                first: .bottleSystem32,
                second: .wineRootWindows64
            ),
            overridePolicy: .forbidden,
            scope: .global,
            architecture: .x86_64,
            variant: "0.72-regression-cross-process",
            provenance: dxmt
        ),
        localGPTKModule(
            id: "apple-gptk.d3dmetal",
            fileName: "D3DMetal",
            relativePath: "AppleGPTK/4.0b2/external/D3DMetal.framework/Versions/A/D3DMetal"
        ),
        localGPTKModule(
            id: "apple-gptk.libd3dshared",
            fileName: "libd3dshared.dylib",
            relativePath: "AppleGPTK/4.0b2/external/libd3dshared.dylib"
        ),
        localGPTKModule(id: "apple-gptk.d3d10", fileName: "d3d10.dll"),
        localGPTKModule(id: "apple-gptk.d3d11", fileName: "d3d11.dll"),
        localGPTKModule(id: "apple-gptk.d3d12", fileName: "d3d12.dll"),
        localGPTKModule(id: "apple-gptk.dxgi", fileName: "dxgi.dll"),
        localGPTKModule(id: "apple-gptk.nvapi64", fileName: "nvapi64.dll"),
        localGPTKModule(id: "apple-gptk.nvngx", fileName: "nvngx.dll"),
    ]

    /// Stable public snapshot allowlist. Membership means only “observe this
    /// path”; it never authorizes installation, replacement, or DLL overrides.
    static let observedInventory: [RuntimeModuleInventoryItem] = [
        inventory("d3d9.dll", namespace: .graphics),
        inventory("d3d10core.dll", namespace: .graphics),
        inventory("d3d11.dll", namespace: .graphics),
        inventory("d3d12.dll", namespace: .graphics),
        inventory("d3d12core.dll", namespace: .graphics),
        inventory("dxgi.dll", namespace: .graphics),
        inventory("winevulkan.dll", namespace: .graphics),
        inventory("vulkan-1.dll", namespace: .graphics),
        inventory("ucrtbase.dll"),
        inventory("vcruntime140.dll"),
        inventory("vcruntime140_1.dll"),
        inventory("msvcp140.dll"),
        inventory("msvcp140_1.dll"),
        inventory("msvcp140_2.dll"),
        inventory("d3dcompiler_43.dll"),
        inventory("d3dcompiler_47.dll"),
        inventory("xinput1_3.dll"),
        inventory("xinput1_4.dll"),
        inventory("xaudio2_7.dll"),
        inventory("openal32.dll"),
        inventory("mf.dll"),
        inventory("mfplat.dll"),
        inventory("mscoree.dll"),
        inventory("winegstreamer.dll"),
    ]

    static func module(id: String) -> RuntimeModuleDescriptor? {
        protectedModules.first { $0.id == id }
    }

    static func expectedSHA256(
        moduleID: String,
        location: RuntimeModuleExpectedLocation
    ) -> String? {
        switch (moduleID, location) {
        case ("dxvk.d3d9", .bottleSystem32):
            "ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb"
        case ("dxmt.d3d10core", .bottleSystem32):
            "0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4"
        case ("dxmt.d3d10core", .wineRootWindows64):
            "87ed91e86f1f4620f5229b7a0d4f1f8c5436a56088e8d4692201fe0c7d5b0deb"
        case ("dxmt.d3d11", .bottleSystem32),
             ("dxmt.d3d11", .wineRootWindows64):
            "1eafefb8650dc7239471d701f099b9caf7c8a4b288f0402b724894c5451fe6ae"
        case ("dxmt.dxgi", .bottleSystem32),
             ("dxmt.dxgi", .wineRootWindows64):
            "25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941"
        default:
            nil
        }
    }

    static func appleGPTKModules(version: AppleGPTKVersion) -> [RuntimeModuleDescriptor] {
        if version == .version4Beta2 {
            return protectedModules.filter { $0.id.hasPrefix("apple-gptk.") }
        }
        return [
            localGPTKModule(id: "apple-gptk.atidxx64", fileName: "atidxx64.dll", version: version),
            localGPTKModule(id: "apple-gptk.d3d11", fileName: "d3d11.dll", version: version),
            localGPTKModule(id: "apple-gptk.d3d12", fileName: "d3d12.dll", version: version),
            localGPTKModule(id: "apple-gptk.dxgi", fileName: "dxgi.dll", version: version),
            localGPTKModule(id: "apple-gptk.nvapi64", fileName: "nvapi64.dll", version: version),
            localGPTKModule(id: "apple-gptk.nvngx", fileName: "nvngx.dll", version: version),
            localGPTKModule(
                id: "apple-gptk.d3dmetal",
                fileName: "D3DMetal",
                relativePath: "external/D3DMetal.framework/Versions/A/D3DMetal",
                version: version
            ),
            localGPTKModule(
                id: "apple-gptk.libd3dshared",
                fileName: "libd3dshared.dylib",
                relativePath: "external/libd3dshared.dylib",
                version: version
            ),
        ]
    }

    private static func localGPTKModule(
        id: String,
        fileName: String,
        relativePath: String? = nil,
        version: AppleGPTKVersion = .version4Beta2
    ) -> RuntimeModuleDescriptor {
        RuntimeModuleDescriptor(
            id: id,
            fileName: fileName,
            binaryClass: .localUserProvided,
            expectedLocations: [
                .localUserComponent(
                    relativePath: relativePath
                        ?? "AppleGPTK/\(version.rawValue)/wine/x86_64-windows/\(fileName)"
                )
            ],
            overridePolicy: .forbidden,
            scope: .perProcess,
            architecture: .x86_64,
            variant: version.rawValue,
            provenance: appleGPTK
        )
    }

    private static func inventory(
        _ fileName: String,
        namespace: RuntimeModuleSnapshotNamespace = .runtime
    ) -> RuntimeModuleInventoryItem {
        RuntimeModuleInventoryItem(
            fileName: fileName,
            snapshotNamespace: namespace
        )
    }
}
