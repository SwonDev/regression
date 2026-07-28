import Foundation

public struct ExternalCatalogSource: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: URL
    public let informationURL: URL
    public let minimumRequestInterval: TimeInterval
    public let cacheLifetime: TimeInterval

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        informationURL: URL,
        minimumRequestInterval: TimeInterval,
        cacheLifetime: TimeInterval
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.informationURL = informationURL
        self.minimumRequestInterval = minimumRequestInterval
        self.cacheLifetime = cacheLifetime
    }
}

public enum ExternalCatalogPlatform: String, Codable, Sendable {
    case macOS
    case linux
}

public struct ExternalCompatibilityRating: Codable, Equatable, Sendable {
    public let platform: ExternalCatalogPlatform
    public let value: Int?
    public let testedCrossOverVersion: String?
    public let testedAt: Date?

    public init(
        platform: ExternalCatalogPlatform,
        value: Int?,
        testedCrossOverVersion: String?,
        testedAt: Date?
    ) {
        self.platform = platform
        self.value = value.flatMap { (0...5).contains($0) ? $0 : nil }
        self.testedCrossOverVersion = testedCrossOverVersion
        self.testedAt = testedAt
    }
}

public struct ExternalGameRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sourceID)-\(externalAppID)" }

    public let sourceID: String
    public let externalAppID: String
    public let canonicalURL: URL
    public let name: String
    public let company: String?
    public let category: String?
    public let steamAppID: String?
    public let macOSRating: ExternalCompatibilityRating
    public let linuxRating: ExternalCompatibilityRating
    public let fetchedAt: Date
    public let contentFingerprint: String
    public let entityTag: String?
    public let lastModified: String?

    public init(
        sourceID: String,
        externalAppID: String,
        canonicalURL: URL,
        name: String,
        company: String?,
        category: String?,
        steamAppID: String?,
        macOSRating: ExternalCompatibilityRating,
        linuxRating: ExternalCompatibilityRating,
        fetchedAt: Date,
        contentFingerprint: String,
        entityTag: String? = nil,
        lastModified: String? = nil
    ) {
        self.sourceID = sourceID
        self.externalAppID = externalAppID
        self.canonicalURL = canonicalURL
        self.name = name
        self.company = company
        self.category = category
        self.steamAppID = steamAppID
        self.macOSRating = macOSRating
        self.linuxRating = linuxRating
        self.fetchedAt = fetchedAt
        self.contentFingerprint = contentFingerprint
        self.entityTag = entityTag
        self.lastModified = lastModified
    }
}

public enum ExternalCatalogLinkStatus: String, Codable, Sendable {
    case pending
    case linked
    case noMatch
    case unavailable
    case failed
}

public enum ExternalCatalogMatchMethod: String, Codable, Sendable {
    case steamAppID
    case exactTitle
    case knownMapping
    case manual
}

public struct ExternalCompatibilityEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sourceID)-\(appID)" }

    public let sourceID: String
    public let appID: String
    public let gameName: String
    public let status: ExternalCatalogLinkStatus
    public let matchMethod: ExternalCatalogMatchMethod?
    public let confidence: Double?
    public let record: ExternalGameRecord?
    public let lastAttemptAt: Date?
    public let errorMessage: String?

    public init(
        sourceID: String,
        appID: String,
        gameName: String,
        status: ExternalCatalogLinkStatus,
        matchMethod: ExternalCatalogMatchMethod? = nil,
        confidence: Double? = nil,
        record: ExternalGameRecord? = nil,
        lastAttemptAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.sourceID = sourceID
        self.appID = appID
        self.gameName = gameName
        self.status = status
        self.matchMethod = matchMethod
        self.confidence = confidence
        self.record = record
        self.lastAttemptAt = lastAttemptAt
        self.errorMessage = errorMessage
    }
}

public struct ExternalCatalogSyncState: Codable, Equatable, Sendable {
    public let sourceID: String
    public let lastAttemptAt: Date?
    public let lastSuccessAt: Date?
    public let nextRequestAt: Date?
    public let lastError: String?

    public init(
        sourceID: String,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextRequestAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.sourceID = sourceID
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextRequestAt = nextRequestAt
        self.lastError = lastError
    }
}

public enum LocalCompatibilityState: String, Codable, Sendable {
    case verifiedPerfect
    case playableWithIssues
    case failed
    case unverified
}

public enum CompatibilityAlignment: String, Codable, Sendable {
    case agrees
    case localOutperformsPublicRating
    case publicRatingOutperformsLocal
    case insufficientEvidence
}

public struct CompatibilityComparison: Codable, Equatable, Identifiable, Sendable {
    public var id: String { appID }

    public let appID: String
    public let gameName: String
    public let localState: LocalCompatibilityState
    public let localBackend: BackendKind?
    public let publicMacRating: Int?
    public let publicTestedVersion: String?
    public let alignment: CompatibilityAlignment
    public let comparedAt: Date
}
