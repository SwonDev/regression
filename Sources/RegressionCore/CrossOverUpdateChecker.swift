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
    public init() {}

    public func check(_ installation: CrossOverInstallation) async -> CrossOverUpdateStatus {
        let preferences = UserDefaults(suiteName: "com.codeweavers.CrossOver")
        let automaticChecks = preferences?.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? false
        let automaticInstall = preferences?.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? false

        guard let feedURL = installation.feedURL else {
            return CrossOverUpdateStatus(
                installedVersion: installation.version,
                availableVersion: nil,
                updateAvailable: false,
                automaticChecksEnabled: automaticChecks,
                automaticInstallationEnabled: automaticInstall
            )
        }

        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let delegate = AppcastVersionParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            let latest = delegate.versions.max {
                $0.compare($1, options: .numeric) == .orderedAscending
            }
            let updateAvailable = latest.map {
                installation.version.compare($0, options: .numeric) == .orderedAscending
            } ?? false
            return CrossOverUpdateStatus(
                installedVersion: installation.version,
                availableVersion: latest,
                updateAvailable: updateAvailable,
                automaticChecksEnabled: automaticChecks,
                automaticInstallationEnabled: automaticInstall
            )
        } catch {
            return CrossOverUpdateStatus(
                installedVersion: installation.version,
                availableVersion: nil,
                updateAvailable: false,
                automaticChecksEnabled: automaticChecks,
                automaticInstallationEnabled: automaticInstall
            )
        }
    }
}

private final class AppcastVersionParser: NSObject, XMLParserDelegate {
    var versions: [String] = []
    private var activeElement = ""
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        activeElement = qName ?? elementName
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
        activeElement = ""
        buffer = ""
    }
}
