import CryptoKit
import Darwin
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

public enum RegressionManualRepairDecision: Equatable, Sendable {
    case repairNow
    case newerUpdateAvailable
    case rejectDowngrade

    public var permitsInstallerSpawn: Bool {
        self == .repairNow
    }
}

/// Una reparación reinstala exclusivamente la versión ya instalada. Una release posterior se
/// presenta como actualización explícita y una anterior nunca puede iniciar el instalador.
public enum RegressionManualRepairPolicy {
    public static func decision(
        installedVersion: String,
        releaseVersion: String
    ) -> RegressionManualRepairDecision {
        guard SemanticVersion.normalized(installedVersion) != nil,
              SemanticVersion.normalized(releaseVersion) != nil else {
            return .rejectDowngrade
        }
        let installed = SemanticVersion(installedVersion)
        let release = SemanticVersion(releaseVersion)
        if release < installed { return .rejectDowngrade }
        if installed < release { return .newerUpdateAvailable }
        return .repairNow
    }

    @discardableResult
    @MainActor
    public static func runIfAuthorized(
        installedVersion: String,
        releaseVersion: String,
        spawnInstaller: @MainActor () async -> Void
    ) async -> RegressionManualRepairDecision {
        let decision = decision(
            installedVersion: installedVersion,
            releaseVersion: releaseVersion
        )
        if decision.permitsInstallerSpawn {
            await spawnInstaller()
        }
        return decision
    }
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
        let release = try await latestRelease(clientVersion: installedVersion)
        if SemanticVersion(release.version) > SemanticVersion(installedVersion) {
            return .available(installedVersion: installedVersion, release: release)
        }
        return .upToDate(installedVersion: installedVersion, checkedAt: now())
    }

    /// Devuelve la release estable oficial incluso cuando coincide con la instalada. Esta ruta
    /// permite reparar un bundle dañado reutilizando exactamente el instalador firmado y su
    /// digest publicado, sin aceptar canales, repositorios ni assets alternativos.
    public func latestRelease(clientVersion: String) async throws -> RegressionRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Regression/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await fetch(request)
        try validate(response: response, dataSize: data.count, maximumSize: maximumResponseBytes)
        return try decodeRelease(data)
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

        return try Self.writeInstaller(data, to: directoryURL)
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

    private static func writeInstaller(_ data: Data, to directoryURL: URL) throws -> URL {
        let directoryFD = try openSecureDirectoryChain(directoryURL)
        defer { _ = Darwin.close(directoryFD) }

        let destinationName = "install_regression.sh"
        var existing = stat()
        if fstatat(directoryFD, destinationName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else {
                throw RegressionReleaseUpdateError.unsafeUpdateDirectory
            }
        } else if errno != ENOENT {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }

        let temporaryName = ".install-regression-\(UUID().uuidString).tmp"
        var temporaryFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }
        var shouldRemoveTemporary = true
        defer {
            if temporaryFD >= 0 { _ = Darwin.close(temporaryFD) }
            if shouldRemoveTemporary {
                _ = unlinkat(directoryFD, temporaryName, 0)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard var pointer = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(temporaryFD, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw RegressionReleaseUpdateError.unsafeUpdateDirectory
                    }
                    guard written > 0 else {
                        throw RegressionReleaseUpdateError.unsafeUpdateDirectory
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            guard fchmod(temporaryFD, mode_t(0o700)) == 0,
                  fsync(temporaryFD) == 0 else {
                throw RegressionReleaseUpdateError.unsafeUpdateDirectory
            }
            _ = Darwin.close(temporaryFD)
            temporaryFD = -1
            guard renameat(directoryFD, temporaryName, directoryFD, destinationName) == 0,
                  fsync(directoryFD) == 0 else {
                throw RegressionReleaseUpdateError.unsafeUpdateDirectory
            }
            shouldRemoveTemporary = false
        } catch {
            throw error as? RegressionReleaseUpdateError
                ?? RegressionReleaseUpdateError.unsafeUpdateDirectory
        }

        return directoryURL.appendingPathComponent(destinationName, isDirectory: false)
    }

    /// Recorre la ruta desde `/` manteniendo cada ancestro anclado por descriptor. `O_NOFOLLOW`
    /// impide que un enlace en cualquier nivel redirija el mkdir o la escritura posterior.
    private static func openSecureDirectoryChain(_ directoryURL: URL) throws -> Int32 {
        guard directoryURL.isFileURL,
              directoryURL.path.hasPrefix("/"),
              directoryURL.path != "/" else {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }
        let components = Array(directoryURL.pathComponents.dropFirst())
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }

        var currentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw RegressionReleaseUpdateError.unsafeUpdateDirectory
        }
        defer {
            if currentFD >= 0 { _ = Darwin.close(currentFD) }
        }

        for (index, component) in components.enumerated() {
            let created: Bool
            if mkdirat(currentFD, component, mode_t(0o700)) == 0 {
                created = true
            } else if errno == EEXIST {
                created = false
            } else {
                throw RegressionReleaseUpdateError.unsafeUpdateDirectory
            }
            let nextFD = openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextFD >= 0 else {
                throw RegressionReleaseUpdateError.unsafeUpdateDirectory
            }
            if (created || index == components.count - 1),
               fchmod(nextFD, mode_t(0o700)) != 0 {
                if nextFD >= 0 { _ = Darwin.close(nextFD) }
                throw RegressionReleaseUpdateError.unsafeUpdateDirectory
            }
            _ = Darwin.close(currentFD)
            currentFD = nextFD
        }

        let result = currentFD
        currentFD = -1
        return result
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
