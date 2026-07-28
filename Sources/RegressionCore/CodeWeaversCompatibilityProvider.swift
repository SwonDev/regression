import CryptoKit
import Foundation

public struct ExternalCatalogValidators: Equatable, Sendable {
    public let entityTag: String?
    public let lastModified: String?

    public init(entityTag: String? = nil, lastModified: String? = nil) {
        self.entityTag = entityTag
        self.lastModified = lastModified
    }
}

public struct ExternalCatalogSearchCandidate: Equatable, Sendable {
    public let name: String
    public let detailURL: URL

    public init(name: String, detailURL: URL) {
        self.name = name
        self.detailURL = detailURL
    }
}

public enum ExternalCatalogFetchResult: Equatable, Sendable {
    case modified(ExternalGameRecord)
    case notModified(ExternalCatalogValidators)
    case notFound
}

public protocol ExternalCompatibilityProviding: Sendable {
    var source: ExternalCatalogSource { get }

    func fetchRecord(
        at detailURL: URL,
        validators: ExternalCatalogValidators?
    ) async throws -> ExternalCatalogFetchResult

    func search(named gameName: String) async throws -> [ExternalCatalogSearchCandidate]
}

public enum CodeWeaversCompatibilityError: LocalizedError, Sendable {
    case unsafeURL
    case invalidResponse
    case responseTooLarge
    case serviceUnavailable(Int)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeURL:
            "CodeWeavers devolvió una dirección no permitida"
        case .invalidResponse:
            "CodeWeavers devolvió una respuesta no válida"
        case .responseTooLarge:
            "La ficha pública superó el tamaño máximo permitido"
        case let .serviceUnavailable(status):
            "CodeWeavers no está disponible temporalmente (HTTP \(status))"
        case let .invalidDocument(detail):
            "No se pudo interpretar la ficha pública de CodeWeavers: \(detail)"
        }
    }
}

public final class CodeWeaversCompatibilityProvider: ExternalCompatibilityProviding, Sendable {
    public static let codeWeaversSource = ExternalCatalogSource(
        id: "codeweavers",
        displayName: "CodeWeavers Compatibility Database",
        baseURL: URL(string: "https://www.codeweavers.com/compatibility")!,
        informationURL: URL(
            string: "https://support.codeweavers.com/en_US/the-compatibility-database"
        )!,
        // robots.txt de CodeWeavers publica Crawl-delay: 100 para este sitio.
        minimumRequestInterval: 100,
        cacheLifetime: 7 * 24 * 60 * 60
    )

    public let source: ExternalCatalogSource

    private let session: URLSession
    private let maximumResponseBytes: Int
    private let now: @Sendable () -> Date
    private let userAgent: String

    public init(
        session: URLSession? = nil,
        source: ExternalCatalogSource = CodeWeaversCompatibilityProvider.codeWeaversSource,
        maximumResponseBytes: Int = 3_000_000,
        userAgent: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.maximumResponseBytes = maximumResponseBytes
        self.now = now
        self.userAgent = userAgent ?? Self.defaultUserAgent
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.waitsForConnectivity = false
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpAdditionalHeaders = [
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Language": "en-US,en;q=0.8"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetchRecord(
        at detailURL: URL,
        validators: ExternalCatalogValidators? = nil
    ) async throws -> ExternalCatalogFetchResult {
        guard Self.isAllowedDetailURL(detailURL) else {
            throw CodeWeaversCompatibilityError.unsafeURL
        }
        var request = URLRequest(url: detailURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let entityTag = validators?.entityTag {
            request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        let http = try validated(response: response, data: data)
        let returnedValidators = ExternalCatalogValidators(
            entityTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
        switch http.statusCode {
        case 200:
            return .modified(try CodeWeaversPageParser.parseDetail(
                data: data,
                requestedURL: detailURL,
                sourceID: source.id,
                fetchedAt: now(),
                validators: returnedValidators
            ))
        case 304:
            return .notModified(returnedValidators)
        case 404:
            return .notFound
        default:
            throw CodeWeaversCompatibilityError.serviceUnavailable(http.statusCode)
        }
    }

    public func search(named gameName: String) async throws -> [ExternalCatalogSearchCandidate] {
        guard let searchURL = Self.publicSearchURL(for: gameName) else {
            throw CodeWeaversCompatibilityError.unsafeURL
        }
        var request = URLRequest(url: searchURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = try validated(response: response, data: data)
        guard http.statusCode == 200 else {
            throw CodeWeaversCompatibilityError.serviceUnavailable(http.statusCode)
        }
        return try CodeWeaversPageParser.parseSearchResults(data: data)
    }

    public static func knownDetailURL(forSteamAppID appID: String) -> URL? {
        let paths = [
            "1128000": "cube-world",
            "1004640": "final-fantasy-tactics-the-ivalice-chronicles",
            "219990": "grim-dawn",
            "1371980": "No_Rest_for_the_Wicked"
        ]
        guard let path = paths[appID] else { return nil }
        return URL(string: "https://www.codeweavers.com/compatibility/crossover/\(path)")
    }

    public static func probableDetailURL(for gameName: String) -> URL? {
        let slug = normalizedName(gameName)
            .split(separator: " ")
            .joined(separator: "-")
        guard !slug.isEmpty else { return nil }
        return URL(string: "https://www.codeweavers.com/compatibility/crossover/\(slug)")
    }

    public static func normalizedName(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private func validated(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard data.count <= maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              Self.isAllowedCompatibilityURL(finalURL) else {
            if data.count > maximumResponseBytes {
                throw CodeWeaversCompatibilityError.responseTooLarge
            }
            throw CodeWeaversCompatibilityError.invalidResponse
        }
        return http
    }

    public static func publicSearchURL(for gameName: String) -> URL? {
        guard !gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents(string: "https://www.codeweavers.com/compatibility")
        components?.queryItems = [
            URLQueryItem(name: "browse", value: ""),
            URLQueryItem(name: "app_desc", value: ""),
            URLQueryItem(name: "company", value: ""),
            URLQueryItem(name: "rating", value: ""),
            URLQueryItem(name: "platform", value: ""),
            URLQueryItem(name: "date_start", value: ""),
            URLQueryItem(name: "date_end", value: ""),
            URLQueryItem(name: "name", value: gameName),
            URLQueryItem(name: "search", value: "app")
        ]
        return components?.url
    }

    static func isAllowedDetailURL(_ url: URL) -> Bool {
        isAllowedCompatibilityURL(url)
            && url.path.hasPrefix("/compatibility/crossover/")
            && url.path.count > "/compatibility/crossover/".count
            && url.query == nil
            && url.fragment == nil
    }

    private static func isAllowedCompatibilityURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil else { return false }
        let host = url.host?.lowercased()
        guard host == "www.codeweavers.com" || host == "codeweavers.com" else { return false }
        return url.path == "/compatibility" || url.path.hasPrefix("/compatibility/")
    }

    private static var defaultUserAgent: String {
        let rawVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let safeVersion = rawVersion.filter { $0.isASCII && ($0.isNumber || $0 == ".") }
        return "Regression/\(safeVersion.isEmpty ? "development" : safeVersion) "
            + "(local compatibility reference; macOS)"
    }
}

enum CodeWeaversPageParser {
    static func parseDetail(
        data: Data,
        requestedURL: URL,
        sourceID: String = CodeWeaversCompatibilityProvider.codeWeaversSource.id,
        fetchedAt: Date,
        validators: ExternalCatalogValidators
    ) throws -> ExternalGameRecord {
        guard let html = String(data: data, encoding: .utf8) else {
            throw CodeWeaversCompatibilityError.invalidDocument("codificación desconocida")
        }
        let jsonDocuments = matches(
            pattern: #"(?is)<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#,
            in: html,
            capture: 1
        )
        var graph: [[String: Any]] = []
        for document in jsonDocuments {
            guard let jsonData = document.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) else { continue }
            graph.append(contentsOf: graphObjects(from: object))
        }
        guard let game = graph.first(where: { type(of: $0) == "VideoGame" }),
              let name = game["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodeWeaversCompatibilityError.invalidDocument("no contiene VideoGame JSON-LD")
        }

        let canonicalURL = (game["url"] as? String).flatMap(URL.init(string:)) ?? requestedURL
        guard CodeWeaversCompatibilityProvider.isAllowedDetailURL(canonicalURL) else {
            throw CodeWeaversCompatibilityError.invalidDocument("URL canónica inesperada")
        }

        let externalAppID = firstMatch(
            pattern: #"(?is)<span[^>]+id=[\"']var_app_id[\"'][^>]*>\s*([^<\s]+)\s*</span>"#,
            in: html,
            capture: 1
        ) ?? "slug:\(canonicalURL.lastPathComponent)"
        let publisher = (game["publisher"] as? [String: Any])?["name"] as? String
        let sameAs: [String]
        if let values = game["sameAs"] as? [String] {
            sameAs = values
        } else if let value = game["sameAs"] as? String {
            sameAs = [value]
        } else {
            sameAs = []
        }
        let steamAppID = sameAs.lazy.compactMap(steamAppID(from:)).first
        let reviews = graph.filter { type(of: $0) == "Review" }
        let macReview = reviews.first { platform(of: $0) == .macOS }
        let linuxReview = reviews.first { platform(of: $0) == .linux }
        let fingerprint = SHA256.hash(data: Data(jsonDocuments.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return ExternalGameRecord(
            sourceID: sourceID,
            externalAppID: externalAppID,
            canonicalURL: canonicalURL,
            name: name,
            company: publisher,
            category: game["applicationCategory"] as? String,
            steamAppID: steamAppID,
            macOSRating: rating(from: macReview, platform: .macOS),
            linuxRating: rating(from: linuxReview, platform: .linux),
            fetchedAt: fetchedAt,
            contentFingerprint: fingerprint,
            entityTag: validators.entityTag,
            lastModified: validators.lastModified
        )
    }

    static func parseSearchResults(data: Data) throws -> [ExternalCatalogSearchCandidate] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw CodeWeaversCompatibilityError.invalidDocument("codificación desconocida")
        }
        let pattern = #"(?is)<a[^>]+href=[\"'](/compatibility/crossover/[^\"'#?]+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<URL>()
        var results: [ExternalCatalogSearchCandidate] = []
        for match in expression.matches(in: html, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html),
                  let url = URL(
                    string: String(html[pathRange]),
                    relativeTo: URL(string: "https://www.codeweavers.com")
                  )?.absoluteURL,
                  !seen.contains(url) else { continue }
            let title = plainText(String(html[bodyRange]))
            guard !title.isEmpty else { continue }
            seen.insert(url)
            results.append(ExternalCatalogSearchCandidate(name: title, detailURL: url))
        }
        return results
    }

    private static func graphObjects(from object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            if let graph = dictionary["@graph"] as? [[String: Any]] { return graph }
            return [dictionary]
        }
        return object as? [[String: Any]] ?? []
    }

    private static func type(of object: [String: Any]) -> String? {
        if let value = object["@type"] as? String { return value }
        return (object["@type"] as? [String])?.first
    }

    private static func platform(of review: [String: Any]) -> ExternalCatalogPlatform? {
        let about = review["about"] as? [String: Any]
        let operatingSystem = (about?["operatingSystem"] as? String)?.lowercased() ?? ""
        let aspect = (review["reviewAspect"] as? String)?.lowercased() ?? ""
        if operatingSystem.contains("mac") || aspect.contains("macos") { return .macOS }
        if operatingSystem.contains("linux") || aspect.contains("linux") { return .linux }
        return nil
    }

    private static func rating(
        from review: [String: Any]?,
        platform: ExternalCatalogPlatform
    ) -> ExternalCompatibilityRating {
        guard let review else {
            return ExternalCompatibilityRating(
                platform: platform,
                value: nil,
                testedCrossOverVersion: nil,
                testedAt: nil
            )
        }
        let about = review["about"] as? [String: Any]
        let reviewRating = review["reviewRating"] as? [String: Any]
        let numericValue: Int?
        if let value = reviewRating?["ratingValue"] as? NSNumber {
            numericValue = value.intValue
        } else if let value = reviewRating?["ratingValue"] as? String {
            numericValue = Int(value)
        } else {
            numericValue = nil
        }
        return ExternalCompatibilityRating(
            platform: platform,
            value: numericValue,
            testedCrossOverVersion: about?["softwareVersion"] as? String,
            testedAt: (review["datePublished"] as? String).flatMap(parseDate)
        )
    }

    private static func steamAppID(from value: String) -> String? {
        guard let match = firstMatch(
            pattern: #"(?i)store\.steampowered\.com/app/(\d+)"#,
            in: value,
            capture: 1
        ) else { return nil }
        return SteamAppID.normalized(match)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: value)
    }

    private static func matches(
        pattern: String,
        in text: String,
        capture: Int
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > capture,
                  let range = Range(match.range(at: capture), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func firstMatch(
        pattern: String,
        in text: String,
        capture: Int
    ) -> String? {
        matches(pattern: pattern, in: text, capture: capture).first
    }

    private static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let entities = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return entities.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }
}
