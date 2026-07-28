import Foundation

public struct CrossOverUpdateStatus: Equatable, Sendable {
    public let installedVersion: String
    public let availableVersion: String?
    public let updateAvailable: Bool
    public let automaticChecksEnabled: Bool
    public let automaticInstallationEnabled: Bool
    public let checkedAt: Date

    public init(
        installedVersion: String,
        availableVersion: String?,
        updateAvailable: Bool,
        automaticChecksEnabled: Bool,
        automaticInstallationEnabled: Bool,
        checkedAt: Date = Date()
    ) {
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.updateAvailable = updateAvailable
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticInstallationEnabled = automaticInstallationEnabled
        self.checkedAt = checkedAt
    }
}

public actor CrossOverUpdateChecker {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias PreferenceValue = @Sendable (String) -> Bool?

    private let fetch: Fetch
    private let preferenceValue: PreferenceValue
    private let now: @Sendable () -> Date
    private let maximumResponseBytes: Int

    public init(
        fetch: @escaping Fetch = { request in
            try await URLSession.shared.data(for: request)
        },
        preferenceValue: @escaping PreferenceValue = { key in
            UserDefaults(suiteName: "com.codeweavers.CrossOver")?
                .object(forKey: key) as? Bool
        },
        maximumResponseBytes: Int = 1_048_576,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.preferenceValue = preferenceValue
        self.maximumResponseBytes = maximumResponseBytes
        self.now = now
    }

    public func check(_ installation: CrossOverInstallation) async -> CrossOverUpdateStatus {
        let automaticChecks = preferenceValue("SUEnableAutomaticChecks") ?? false
        let automaticInstall = preferenceValue("SUAutomaticallyUpdate") ?? false
        let checkedAt = now()

        guard let feedURL = installation.feedURL else {
            return CrossOverUpdateStatus(
                installedVersion: installation.version,
                availableVersion: nil,
                updateAvailable: false,
                automaticChecksEnabled: automaticChecks,
                automaticInstallationEnabled: automaticInstall,
                checkedAt: checkedAt
            )
        }

        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw UpdateCheckFailure.invalidResponse
            }
            guard data.count <= maximumResponseBytes else {
                throw UpdateCheckFailure.responseTooLarge
            }
            let latest = try CrossOverAppcast.latestVersion(in: data)
            let updateAvailable = CrossOverAppcast.isNewer(
                latest,
                than: installation.version
            )
            return CrossOverUpdateStatus(
                installedVersion: installation.version,
                availableVersion: latest,
                updateAvailable: updateAvailable,
                automaticChecksEnabled: automaticChecks,
                automaticInstallationEnabled: automaticInstall,
                checkedAt: checkedAt
            )
        } catch {
            return CrossOverUpdateStatus(
                installedVersion: installation.version,
                availableVersion: nil,
                updateAvailable: false,
                automaticChecksEnabled: automaticChecks,
                automaticInstallationEnabled: automaticInstall,
                checkedAt: checkedAt
            )
        }
    }
}

enum CrossOverAppcast {
    static func latestVersion(in data: Data) throws -> String {
        let delegate = AppcastVersionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else {
            throw UpdateCheckFailure.invalidAppcast
        }
        guard let latest = delegate.versions.max(by: {
            $0.compare($1, options: .numeric) == .orderedAscending
        }) else {
            throw UpdateCheckFailure.missingVersion
        }
        return latest
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        installed.compare(candidate, options: .numeric) == .orderedAscending
    }
}

enum UpdateCheckFailure: Error {
    case invalidResponse
    case responseTooLarge
    case invalidAppcast
    case missingVersion
}

private final class AppcastVersionParser: NSObject, XMLParserDelegate {
    var versions: [String] = []
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        if let version = attributeDict["sparkle:shortVersionString"] ?? attributeDict["shortVersionString"] {
            versions.append(version)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        if name.hasSuffix("shortVersionString") {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { versions.append(value) }
        }
        buffer = ""
    }
}
