import CryptoKit
import Foundation

public struct RegressionRelease: Equatable, Sendable {
    public let version: String
    public let pageURL: URL
    public let installerURL: URL
    public let installerSHA256: String
    public let installerSize: Int

    public init(
        version: String,
        pageURL: URL,
        installerURL: URL,
        installerSHA256: String,
        installerSize: Int
    ) {
        self.version = version
        self.pageURL = pageURL
        self.installerURL = installerURL
        self.installerSHA256 = installerSHA256
        self.installerSize = installerSize
    }
}

public enum RegressionReleaseUpdateStatus: Equatable, Sendable {
    case checking
    case upToDate(installedVersion: String, checkedAt: Date)
    case available(installedVersion: String, release: RegressionRelease)
    case downloading(version: String)
    case installing(version: String)
    case failed(message: String)
}

public enum RegressionAutomaticUpdateDecision: Equatable, Sendable {
    case disabled
    case noUpdate
    case requiresCanonicalInstallation
    case waitForIdle
    case manualRetryRequired
    case installNow
}

/// La actualización automática solo puede sustituir la instalación pública canónica.
/// Una release válida se aplaza mientras Steam de Regression o una operación crítica
/// estén activos; el siguiente refresco en reposo vuelve a evaluarla.
public enum RegressionAutomaticUpdatePolicy {
    public static func decision(
        enabled: Bool,
        canonicalInstallation: Bool,
        regressionIsRunning: Bool,
        applicationIsBusy: Bool,
        lastAttemptedVersion: String? = nil,
        status: RegressionReleaseUpdateStatus
    ) -> RegressionAutomaticUpdateDecision {
        guard enabled else { return .disabled }
        guard case let .available(_, release) = status else { return .noUpdate }
        guard canonicalInstallation else { return .requiresCanonicalInstallation }
        guard !regressionIsRunning, !applicationIsBusy else { return .waitForIdle }
        guard lastAttemptedVersion != release.version else { return .manualRetryRequired }
        return .installNow
    }
}

public enum RegressionReleaseUpdateError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case responseTooLarge
    case invalidRelease
    case missingInstaller
    case unsupportedDownloadURL
    case missingDigest
    case invalidDigest
    case installerTooLarge
    case integrityMismatch
    case unsafeUpdateDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub devolvió una respuesta de actualización no válida."
        case .responseTooLarge: "La respuesta de actualización supera el tamaño permitido."
        case .invalidRelease: "La versión publicada no tiene un formato compatible."
        case .missingInstaller: "La release no incluye el instalador automático esperado."
        case .unsupportedDownloadURL: "La URL del instalador no pertenece al canal oficial de GitHub."
        case .missingDigest: "GitHub no publicó el SHA-256 del instalador."
        case .invalidDigest: "El SHA-256 publicado para el instalador no es válido."
        case .installerTooLarge: "El instalador supera el tamaño máximo permitido."
        case .integrityMismatch: "El instalador descargado no coincide con el SHA-256 publicado."
        case .unsafeUpdateDirectory: "El directorio local de actualización no es seguro."
        }
    }
}

public actor RegressionReleaseUpdateService {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/SwonDev/regression/releases/latest"
    )!

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let maximumResponseBytes: Int
    private let maximumInstallerBytes: Int

    public init(
        fetch: @escaping Fetch = { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.urlCache = nil
            return try await URLSession(configuration: configuration).data(for: request)
        },
        maximumResponseBytes: Int = 1_048_576,
        maximumInstallerBytes: Int = 1_048_576,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumInstallerBytes = maximumInstallerBytes
        self.now = now
    }

    public func check(installedVersion: String) async throws -> RegressionReleaseUpdateStatus {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Regression/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await fetch(request)
        try validate(response: response, dataSize: data.count, maximumSize: maximumResponseBytes)
        let release = try decodeRelease(data)
        if SemanticVersion(release.version) > SemanticVersion(installedVersion) {
            return .available(installedVersion: installedVersion, release: release)
        }
        return .upToDate(installedVersion: installedVersion, checkedAt: now())
    }

    public func downloadInstaller(
        for release: RegressionRelease,
        to directoryURL: URL
    ) async throws -> URL {
        guard Self.isAllowedInstallerAssetURL(release.installerURL) else {
            throw RegressionReleaseUpdateError.unsupportedDownloadURL
        }
        guard release.installerSize > 0, release.installerSize <= maximumInstallerBytes else {
            throw RegressionReleaseUpdateError.installerTooLarge
        }

        var request = URLRequest(url: release.installerURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Regression/\(release.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(request)
        try validate(response: response, dataSize: data.count, maximumSize: maximumInstallerBytes)
        guard let finalURL = response.url, Self.isAllowedDownloadResponseURL(finalURL) else {
            throw RegressionReleaseUpdateError.unsupportedDownloadURL
        }
        let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == release.installerSHA256 else {
            throw RegressionReleaseUpdateError.integrityMismatch
        }

        if (try? directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryValues = try directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let destination = directoryURL.appendingPathComponent("install_regression.sh")
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }

    private func decodeRelease(_ data: Data) throws -> RegressionRelease {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let version = SemanticVersion.normalized(payload.tagName),
              let pageURL = URL(string: payload.htmlURL),
              Self.isAllowedReleasePageURL(pageURL) else {
            throw RegressionReleaseUpdateError.invalidRelease
        }
        let expectedName = "install_regression.sh"
        guard let asset = payload.assets.first(where: { $0.name == expectedName }),
              let installerURL = URL(string: asset.browserDownloadURL) else {
            throw RegressionReleaseUpdateError.missingInstaller
        }
        guard Self.isAllowedInstallerAssetURL(installerURL) else {
            throw RegressionReleaseUpdateError.unsupportedDownloadURL
        }
        guard let rawDigest = asset.digest else {
            throw RegressionReleaseUpdateError.missingDigest
        }
        let digest = rawDigest.lowercased().hasPrefix("sha256:")
            ? String(rawDigest.dropFirst("sha256:".count)).lowercased()
            : rawDigest.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw RegressionReleaseUpdateError.invalidDigest
        }
        return RegressionRelease(
            version: version,
            pageURL: pageURL,
            installerURL: installerURL,
            installerSHA256: digest,
            installerSize: asset.size
        )
    }

    private func validate(response: URLResponse, dataSize: Int, maximumSize: Int) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw RegressionReleaseUpdateError.invalidResponse
        }
        guard dataSize <= maximumSize else {
            throw RegressionReleaseUpdateError.responseTooLarge
        }
    }

    private static func isAllowedReleasePageURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/SwonDev/regression/releases/tag/")
            && url.pathComponents.count == 6
    }

    private static func isAllowedInstallerAssetURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/SwonDev/regression/releases/download/")
            && url.pathComponents.count == 7
            && url.lastPathComponent == "install_regression.sh"
    }

    private static func isAllowedDownloadResponseURL(_ url: URL) -> Bool {
        if isAllowedInstallerAssetURL(url) { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "objects.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease, assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let digest: String?
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name, digest, size
        case browserDownloadURL = "browser_download_url"
    }
}

private struct SemanticVersion: Comparable {
    let components: [Int]

    init(_ value: String) {
        components = Self.normalized(value)?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []
    }

    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return parts.map(String.init).joined(separator: ".")
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
