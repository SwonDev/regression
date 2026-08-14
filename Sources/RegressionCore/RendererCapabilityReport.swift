import CryptoKit
import Foundation

public enum RendererRoute: String, Codable, CaseIterable, Sendable {
    case dxmt
    case dxvk
    case d3dmetal
}

public enum RendererModuleLocation: Codable, Equatable, Hashable, Sendable {
    case bottleSystem32
    case wineRootWindows64
    case localUserComponent(relativePath: String)
}

public struct RendererModuleObservation: Codable, Equatable, Hashable, Sendable {
    public let moduleID: String
    public let location: RendererModuleLocation

    init(moduleID: String, location: RendererModuleLocation) {
        self.moduleID = moduleID
        self.location = location
    }
}

public struct RendererModuleRequirement: Codable, Equatable, Hashable, Sendable {
    public let moduleID: String
    public let location: RendererModuleLocation

    init(moduleID: String, location: RendererModuleLocation) {
        self.moduleID = moduleID
        self.location = location
    }
}

public struct RendererCapabilityObservation: Equatable, Sendable {
    public let activeRoutes: Set<RendererRoute>
    public let modules: Set<RendererModuleObservation>
    public let profileGraphicsBackend: RendererRoute?
    let requiredAppleGPTKVersion: AppleGPTKVersion?
    let authorizedAppleGPTKVersion: AppleGPTKVersion?

    init(
        modules: Set<RendererModuleObservation>,
        profileGraphicsBackend: RendererRoute? = nil,
        requiredAppleGPTKVersion: AppleGPTKVersion? = nil,
        authorizedAppleGPTKVersion: AppleGPTKVersion? = nil
    ) {
        self.modules = modules
        self.profileGraphicsBackend = profileGraphicsBackend
        self.requiredAppleGPTKVersion = requiredAppleGPTKVersion
        self.authorizedAppleGPTKVersion = authorizedAppleGPTKVersion
        activeRoutes = Self.deriveActiveRoutes(
            modules: modules,
            profileGraphicsBackend: profileGraphicsBackend
        )
    }

    private static func deriveActiveRoutes(
        modules: Set<RendererModuleObservation>,
        profileGraphicsBackend: RendererRoute?
    ) -> Set<RendererRoute> {
        let moduleIDs = Set(modules.map(\.moduleID))
        if let profileGraphicsBackend {
            return [profileGraphicsBackend]
        }
        if moduleIDs.contains(where: { $0.hasPrefix("dxmt.") }) {
            return [.dxmt]
        }
        if moduleIDs.contains(where: { $0.hasPrefix("dxvk.") }) {
            return [.dxvk]
        }
        return []
    }
}

public enum RendererIneligibilityReason: Equatable, Sendable {
    case noEffectiveRoute
    case incompleteRoute(RendererRoute, missing: [RendererModuleRequirement])
    case conflictingRoutes([RendererRoute])
    case appleGPTKAuthorityUnavailable(
        requiredVersion: AppleGPTKVersion,
        observedVersion: AppleGPTKVersion?
    )
}

public extension RendererIneligibilityReason {
    var diagnosticCode: String {
        switch self {
        case .noEffectiveRoute:
            "renderer.no-effective-route"
        case .incompleteRoute(let route, let missing):
            "renderer.incomplete.\(route.rawValue):\(missing.map(\.moduleID).joined(separator: "+"))"
        case .conflictingRoutes(let routes):
            "renderer.conflict:\(routes.map(\.rawValue).joined(separator: "+"))"
        case .appleGPTKAuthorityUnavailable(let required, let observed):
            "renderer.gptk-authority:\(required.rawValue):\(observed?.rawValue ?? "none")"
        }
    }
}

public enum RendererCapabilityResolution: Equatable, Sendable {
    case effective(RendererRoute)
    case ineligible(reasons: [RendererIneligibilityReason])
}

public struct RendererCapabilityReport: Equatable, Sendable {
    public let resolution: RendererCapabilityResolution

    public var effectiveRoute: RendererRoute? {
        guard case .effective(let route) = resolution else { return nil }
        return route
    }

    public var ineligibilityReasons: [RendererIneligibilityReason] {
        guard case .ineligible(let reasons) = resolution else { return [] }
        return reasons
    }

    static func evaluate(
        _ observation: RendererCapabilityObservation
    ) -> RendererCapabilityReport {
        let effectiveRoute = observation.profileGraphicsBackend ?? .dxmt
        let requiredRoutes: [RendererRoute] = effectiveRoute == .dxmt
            ? [.dxmt]
            : [.dxmt, effectiveRoute]
        var reasons = requiredRoutes.compactMap { route -> RendererIneligibilityReason? in
            let missing = missingRequirements(
                for: route,
                requiredAppleGPTKVersion: observation.requiredAppleGPTKVersion,
                from: observation.modules
            )
            return missing.isEmpty ? nil : .incompleteRoute(route, missing: missing)
        }
        if effectiveRoute == .d3dmetal {
            guard let requiredVersion = observation.requiredAppleGPTKVersion else {
                reasons.append(.noEffectiveRoute)
                return RendererCapabilityReport(resolution: .ineligible(reasons: reasons))
            }
            if observation.authorizedAppleGPTKVersion != requiredVersion {
                reasons.append(
                    .appleGPTKAuthorityUnavailable(
                        requiredVersion: requiredVersion,
                        observedVersion: observation.authorizedAppleGPTKVersion
                    )
                )
            }
        }
        guard reasons.isEmpty else {
            return RendererCapabilityReport(resolution: .ineligible(reasons: reasons))
        }
        return RendererCapabilityReport(resolution: .effective(effectiveRoute))
    }

    private static func missingRequirements(
        for route: RendererRoute,
        requiredAppleGPTKVersion: AppleGPTKVersion?,
        from observations: Set<RendererModuleObservation>
    ) -> [RendererModuleRequirement] {
        let descriptors: [RuntimeModuleDescriptor]
        if route == .d3dmetal, let requiredAppleGPTKVersion {
            descriptors = RuntimeModuleCatalog.appleGPTKModules(version: requiredAppleGPTKVersion)
        } else {
            descriptors = RuntimeModuleCatalog.protectedModules
        }
        return descriptors
            .filter { descriptor in
                switch route {
                case .dxmt:
                    descriptor.id.hasPrefix("dxmt.")
                case .dxvk:
                    descriptor.id == "dxvk.d3d9"
                case .d3dmetal:
                    descriptor.id.hasPrefix("apple-gptk.")
                }
            }
            .flatMap { descriptor in
                descriptor.expectedLocations.compactMap { expectedLocation in
                    let location = RendererModuleLocation(expectedLocation)
                    let observation = RendererModuleObservation(
                        moduleID: descriptor.id,
                        location: location
                    )
                    guard !observations.contains(observation) else { return nil }
                    return RendererModuleRequirement(
                        moduleID: descriptor.id,
                        location: location
                    )
                }
            }
    }
}

private extension RendererModuleLocation {
    init(_ expectedLocation: RuntimeModuleExpectedLocation) {
        switch expectedLocation {
        case .bottleSystem32:
            self = .bottleSystem32
        case .wineRootWindows64:
            self = .wineRootWindows64
        case .localUserComponent(let relativePath):
            self = .localUserComponent(relativePath: relativePath)
        }
    }
}

struct RendererCapabilityInspector: Sendable {
    let applicationSupportURL: URL
    private let componentHealth: @Sendable (AppleGPTKVersion, AnchoredDirectory) -> Bool
    private let moduleHealth: @Sendable (
        RuntimeModuleDescriptor,
        RuntimeModuleExpectedLocation,
        AnchoredDirectory
    ) -> Bool
    private let afterSnapshotRootOpened: @Sendable (URL) -> Void
    private let afterGPTKTopologyCaptured: @Sendable () -> Void

    private struct RegularFileSnapshot {
        let root: AnchoredDirectory
        let relativePath: String
        let digest: AnchoredFileDigest

        var isStillValid: Bool {
            guard let current = try? root.hashRegularFile(
                relativePath: relativePath,
                maximumBytes: 64 * 1_024 * 1_024
            ) else { return false }
            return current.sha256 == digest.sha256
                && current.byteCount == digest.byteCount
                && current.identity == digest.identity
        }
    }

    init(
        applicationSupportURL: URL,
        componentHealth: @escaping @Sendable (
            AppleGPTKVersion,
            AnchoredDirectory
        ) -> Bool = Self.componentIsHealthy,
        moduleHealth: @escaping @Sendable (
            RuntimeModuleDescriptor,
            RuntimeModuleExpectedLocation,
            AnchoredDirectory
        ) -> Bool = Self.moduleIsHealthy,
        afterSnapshotRootOpened: @escaping @Sendable (URL) -> Void = { _ in },
        afterGPTKTopologyCaptured: @escaping @Sendable () -> Void = {}
    ) {
        self.applicationSupportURL = applicationSupportURL.standardizedFileURL
        self.componentHealth = componentHealth
        self.moduleHealth = moduleHealth
        self.afterSnapshotRootOpened = afterSnapshotRootOpened
        self.afterGPTKTopologyCaptured = afterGPTKTopologyCaptured
    }

    func inspect(
        installation: RegressionInstallation,
        appID: String?
    ) -> RendererCapabilityReport {
        let requiredVersion = appID.flatMap {
            GameRuntimeProfileCatalog.requiredAppleGPTKVersion(for: $0, backend: .regression)
        }
        let declaredBackend = appID.flatMap {
            GameRuntimeProfileCatalog.configurationValues(
                for: $0,
                backend: .regression
            )["profile.graphics.backend"]
        }.flatMap(RendererRoute.init(rawValue:))
        let profileBackend = requiredVersion == nil ? declaredBackend : .d3dmetal
        let bottleSystem32URL = installation.bottleURL.appendingPathComponent(
            "drive_c/windows/system32",
            isDirectory: true
        )
        let wineWindows64URL = installation.applicationURL.appendingPathComponent(
            "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows",
            isDirectory: true
        )
        let bottleSystem32 = AnchoredDirectory.open(bottleSystem32URL)
        let wineWindows64 = AnchoredDirectory.open(wineWindows64URL)
        if bottleSystem32 != nil { afterSnapshotRootOpened(bottleSystem32URL) }
        if wineWindows64 != nil { afterSnapshotRootOpened(wineWindows64URL) }

        var modules: Set<RendererModuleObservation> = []
        var moduleSnapshots: [RegularFileSnapshot] = []
        for descriptor in RuntimeModuleCatalog.protectedModules
            where descriptor.id.hasPrefix("dxmt.") || descriptor.id.hasPrefix("dxvk.") {
            for expectedLocation in descriptor.expectedLocations {
                let root: AnchoredDirectory?
                switch expectedLocation {
                case .bottleSystem32:
                    root = bottleSystem32
                case .wineRootWindows64:
                    root = wineWindows64
                case .localUserComponent:
                    continue
                }
                guard let root,
                      moduleHealth(descriptor, expectedLocation, root) else { continue }
                guard let digest = try? root.hashRegularFile(
                    relativePath: descriptor.fileName,
                    maximumBytes: 64 * 1_024 * 1_024
                ) else { continue }
                moduleSnapshots.append(RegularFileSnapshot(
                    root: root,
                    relativePath: descriptor.fileName,
                    digest: digest
                ))
                modules.insert(RendererModuleObservation(
                    moduleID: descriptor.id,
                    location: RendererModuleLocation(expectedLocation)
                ))
            }
        }

        var authorizedVersion: AppleGPTKVersion?
        if let requiredVersion {
            authorizedVersion = inspectD3DMetal(
                installation: installation,
                requiredVersion: requiredVersion,
                modules: &modules
            )
        }

        if bottleSystem32?.isStillNamedBy(bottleSystem32URL) != true {
            modules = modules.filter { $0.location != .bottleSystem32 }
        }
        if wineWindows64?.isStillNamedBy(wineWindows64URL) != true {
            modules = modules.filter { $0.location != .wineRootWindows64 }
        }
        if !moduleSnapshots.allSatisfy(\.isStillValid) {
            modules = modules.filter {
                $0.location != .bottleSystem32 && $0.location != .wineRootWindows64
            }
        }
        return RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: modules,
                profileGraphicsBackend: profileBackend,
                requiredAppleGPTKVersion: requiredVersion,
                authorizedAppleGPTKVersion: authorizedVersion
            )
        )
    }

    private func inspectD3DMetal(
        installation: RegressionInstallation,
        requiredVersion: AppleGPTKVersion,
        modules: inout Set<RendererModuleObservation>
    ) -> AppleGPTKVersion? {
        let componentURL = applicationSupportURL.appendingPathComponent(
            "Components/AppleGPTK/\(requiredVersion.rawValue)",
            isDirectory: true
        )
        let receiptRootURL = applicationSupportURL.appendingPathComponent(
            "Receipts/AppleGPTK",
            isDirectory: true
        )
        let receiptRelativePath = "\(requiredVersion.rawValue)-license-receipt"
        guard let componentRoot = AnchoredDirectory.open(componentURL),
              let receiptRoot = AnchoredDirectory.open(receiptRootURL) else { return nil }
        afterSnapshotRootOpened(componentURL)
        afterSnapshotRootOpened(receiptRootURL)
        guard let windowsRoot = try? componentRoot.openSubdirectory(
                relativePath: "wine/x86_64-windows"
              ),
              let unixRoot = try? componentRoot.openSubdirectory(
                relativePath: "wine/x86_64-unix"
              ) else { return nil }
        var fileSnapshots: [RegularFileSnapshot] = []
        let descriptors = RuntimeModuleCatalog.appleGPTKModules(version: requiredVersion)
        for descriptor in descriptors {
            guard let expectedLocation = descriptor.expectedLocations.first else { continue }
            let relativePath = Self.gptkRelativePath(descriptor)
            let hashRoot = relativePath.hasPrefix("wine/x86_64-windows/")
                ? windowsRoot
                : componentRoot
            let hashPath = hashRoot === windowsRoot ? descriptor.fileName : relativePath
            guard let digest = try? hashRoot.hashRegularFile(
                relativePath: hashPath,
                maximumBytes: 64 * 1_024 * 1_024
            ) else { continue }
            fileSnapshots.append(RegularFileSnapshot(
                root: hashRoot,
                relativePath: hashPath,
                digest: digest
            ))
            modules.insert(RendererModuleObservation(
                moduleID: descriptor.id,
                location: RendererModuleLocation(expectedLocation)
            ))
        }
        let licenseRelativePath = Self.gptkLicenseRelativePath(for: requiredVersion)
        guard let licenseDigest = try? componentRoot.hashRegularFile(
                relativePath: licenseRelativePath,
                maximumBytes: 4 * 1_024 * 1_024
              ),
              let receiptDigest = try? receiptRoot.hashRegularFile(
                relativePath: receiptRelativePath,
                maximumBytes: 16 * 1_024
              ),
              receiptDigest.identity.ownerUID == getuid(),
              receiptDigest.identity.mode & 0o7777 == 0o600 else { return nil }
        fileSnapshots.append(RegularFileSnapshot(
            root: componentRoot,
            relativePath: licenseRelativePath,
            digest: licenseDigest
        ))
        fileSnapshots.append(RegularFileSnapshot(
            root: receiptRoot,
            relativePath: receiptRelativePath,
            digest: receiptDigest
        ))
        let healthyComponent = componentHealth(requiredVersion, componentRoot)
        let topologySnapshot = Self.gptkUnixTopologySnapshot(
            version: requiredVersion,
            unixRoot: unixRoot
        )
        afterGPTKTopologyCaptured()
        let authorized = healthyComponent
            && topologySnapshot != nil
            && receiptIsValid(
                version: requiredVersion,
                componentRoot: componentRoot,
                receiptRoot: receiptRoot,
                receiptRelativePath: receiptRelativePath,
                licenseRelativePath: licenseRelativePath
            )
            && componentRoot.stillNamesSubdirectory(
                relativePath: "wine/x86_64-windows",
                as: windowsRoot
            )
            && componentRoot.stillNamesSubdirectory(
                relativePath: "wine/x86_64-unix",
                as: unixRoot
            )
            && fileSnapshots.allSatisfy(\.isStillValid)
            && topologySnapshot?.isStillValid == true
            && componentRoot.isStillNamedBy(componentURL)
            && receiptRoot.isStillNamedBy(receiptRootURL)
        if !componentRoot.isStillNamedBy(componentURL) {
            modules = modules.filter {
                if case .localUserComponent = $0.location { return false }
                return true
            }
        }
        return authorized ? requiredVersion : nil
    }

    private func receiptIsValid(
        version: AppleGPTKVersion,
        componentRoot: AnchoredDirectory,
        receiptRoot: AnchoredDirectory,
        receiptRelativePath: String,
        licenseRelativePath: String
    ) -> Bool {
        guard let receiptData = try? receiptRoot.readPrivateRegularFile(
                relativePath: receiptRelativePath,
                maximumBytes: 16 * 1_024,
                ownerUID: getuid()
              ),
              let contents = String(data: receiptData, encoding: .utf8) else {
            return false
        }
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)
        let expectedCounts: Set<Int> = version == .version3 ? [6, 8] : [6]
        guard expectedCounts.contains(lines.count) else { return false }
        var values: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { return false }
            let key = String(line[..<separator])
            guard !key.isEmpty, values[key] == nil else { return false }
            values[key] = String(line[line.index(after: separator)...])
        }
        guard let licenseData = try? componentRoot.readRegularFile(
            relativePath: licenseRelativePath,
            maximumBytes: 4 * 1_024 * 1_024
        ) else {
            return false
        }
        let licenseHash = SHA256.hash(data: licenseData).map { String(format: "%02x", $0) }.joined()
        guard values["schema"] == "1",
              values["version"] == version.rawValue,
              values["license_sha256"] == licenseHash,
              values["confirmation"] == "ACEPTO LA LICENCIA DE APPLE GPTK \(version.rawValue)",
              values["confirmed_at"]?.range(
                of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#,
                options: .regularExpression
              ) != nil else { return false }
        switch version {
        case .version3:
            let isExistingConsent = values["source_kind"] == "existing-protected-component"
                && values["catalog_id"] == AppleGPTKComponentCatalog.protectedProfilesComponentID
                && values["payload_fingerprint"]
                    == AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint
                && values["dmg_sha256"] == nil
            let isDMGConsent = values["dmg_sha256"]?.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil
                && values["source_kind"] == nil
                && values["catalog_id"] == nil
                && values["payload_fingerprint"] == nil
            return isExistingConsent || isDMGConsent
        case .version4Beta2:
            return values["dmg_sha256"] == AppleGPTKComponentCatalog.current.dmgSHA256
        }
    }

    private static func componentIsHealthy(
        version: AppleGPTKVersion,
        root: AnchoredDirectory
    ) -> Bool {
        let files: [TrustedComponentFile]
        switch version {
        case .version3:
            files = AppleGPTKComponentCatalog.protectedProfilesDescriptor(
                rootURL: URL(fileURLWithPath: "/private/unused")
            ).files
        case .version4Beta2:
            files = [
                    TrustedComponentFile(
                        relativePath: "external/D3DMetal.framework/Versions/A/D3DMetal",
                        expectedSHA256: AppleGPTKComponentCatalog.current.d3dMetalSHA256
                    ),
                    TrustedComponentFile(
                        relativePath: "external/libd3dshared.dylib",
                        expectedSHA256: AppleGPTKComponentCatalog.current.d3dSharedSHA256
                    ),
                    TrustedComponentFile(
                        relativePath: "wine/x86_64-windows/d3d10.dll",
                        expectedSHA256: "14c84a364a1260497f0a5117ef8efd6e228764ab139a67af1127e8bd013c48c7"
                    ),
                    TrustedComponentFile(
                        relativePath: "wine/x86_64-windows/d3d11.dll",
                        expectedSHA256: "303b2bb41efa30c890e2e93d39c3d3c565c8557e069eee832f2cb8a37bd4ec26"
                    ),
                    TrustedComponentFile(
                        relativePath: "wine/x86_64-windows/d3d12.dll",
                        expectedSHA256: "1b7a02cb37ec6b484e2aaa76b5ec9cbb47e63aeec29dbe087d5d1589a3347cfb"
                    ),
                    TrustedComponentFile(
                        relativePath: "wine/x86_64-windows/dxgi.dll",
                        expectedSHA256: "522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af"
                    ),
                    TrustedComponentFile(
                        relativePath: "wine/x86_64-windows/nvapi64.dll",
                        expectedSHA256: "05eedf19e75c6b4c0dce918577aa6ca3fe5da79d04e42145cf66f498fad3556a"
                    ),
                    TrustedComponentFile(
                        relativePath: "wine/x86_64-windows/nvngx.dll",
                        expectedSHA256: "f6bc9d77fd1e898fec8c6339d367bd8e0f338992c9c0c66d59b30c6e9e0743e4"
                    ),
                ]
        }
        return files.allSatisfy { file in
            guard let digest = try? root.hashRegularFile(
                relativePath: file.relativePath,
                maximumBytes: 64 * 1_024 * 1_024
            ) else { return false }
            return digest.sha256 == file.expectedSHA256
        }
    }

    private static func moduleIsHealthy(
        descriptor: RuntimeModuleDescriptor,
        location: RuntimeModuleExpectedLocation,
        root: AnchoredDirectory
    ) -> Bool {
        guard let expected = RuntimeModuleCatalog.expectedSHA256(
                moduleID: descriptor.id,
                location: location
              ) else { return false }
        guard let digest = try? root.hashRegularFile(
            relativePath: descriptor.fileName,
            maximumBytes: 64 * 1_024 * 1_024
        ) else { return false }
        return digest.sha256 == expected
    }

    private static func gptkUnixTopologySnapshot(
        version: AppleGPTKVersion,
        unixRoot: AnchoredDirectory
    ) -> AnchoredSymbolicLinkSnapshot? {
        let target = "../../external/libd3dshared.dylib"
        let names = version == .version3
            ? ["atidxx64", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx"]
            : ["d3d10", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx"]
        let expected = Dictionary(uniqueKeysWithValues:
            names.map { ("\($0).so", target) }
        )
        guard let snapshot = try? unixRoot.symbolicLinkSnapshot(
                maximumEntries: expected.count + 1
              ),
              snapshot.targets == expected else { return nil }
        return snapshot
    }

    private static func gptkRelativePath(_ descriptor: RuntimeModuleDescriptor) -> String {
        if descriptor.fileName == "D3DMetal" {
            return "external/D3DMetal.framework/Versions/A/D3DMetal"
        }
        if descriptor.fileName == "libd3dshared.dylib" {
            return "external/libd3dshared.dylib"
        }
        return "wine/x86_64-windows/\(descriptor.fileName)"
    }

    private static func gptkLicenseRelativePath(for version: AppleGPTKVersion) -> String {
        switch version {
        case .version3:
            "external/D3DMetal.framework/Versions/A/Resources/LICENSE"
        case .version4Beta2:
            "Documentation/License.rtf"
        }
    }

}

public enum RendererLaunchGate {
    public static func validate(
        installation: RegressionInstallation,
        appID: String?
    ) throws {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Regression",
            isDirectory: true
        )
        try validate(
            installation: installation,
            appID: appID,
            inspector: RendererCapabilityInspector(applicationSupportURL: support)
        )
    }

    static func validate(
        installation: RegressionInstallation,
        appID: String?,
        inspector: RendererCapabilityInspector
    ) throws {
        let report = inspector.inspect(installation: installation, appID: appID)
        guard case .effective = report.resolution else {
            throw RegressionCoreError.rendererIneligible(report.ineligibilityReasons)
        }
    }
}
