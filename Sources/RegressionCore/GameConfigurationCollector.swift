import CryptoKit
import Foundation

public enum GameConfigurationCollector {
    private static let acceptedExtensions: Set<String> = ["cfg", "ini", "json", "txt", "xml"]
    private static let fileNameMarkers = [
        "config", "graphic", "option", "preference", "setting", "system", "video"
    ]
    private static let settingMarkers = [
        "adapter", "antialias", "api", "display", "directx", "fullscreen",
        "height", "quality", "refresh", "renderer", "resolution", "scale",
        "shadow", "texture", "ui", "vsync", "width", "window"
    ]

    public static func snapshot(
        bottleURL: URL,
        steamRootURL: URL,
        game: SteamGame
    ) -> [String: String] {
        var values: [String: String] = [:]
        var roots: [URL] = [
            steamRootURL
                .appendingPathComponent("steamapps/common", isDirectory: true)
                .appendingPathComponent(game.installDirectory, isDirectory: true)
        ]

        let fileManager = FileManager.default
        let userRoot = bottleURL.appendingPathComponent("drive_c/users", isDirectory: true)
        let userDirectories = (try? fileManager.contentsOfDirectory(
            at: userRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for user in userDirectories {
            for base in [
                "Documents/My Games", "Documents", "AppData/Local", "AppData/Roaming"
            ] {
                let directory = user.appendingPathComponent(base, isDirectory: true)
                roots.append(directory.appendingPathComponent(game.name, isDirectory: true))
                if game.installDirectory.caseInsensitiveCompare(game.name) != .orderedSame {
                    roots.append(directory.appendingPathComponent(game.installDirectory, isDirectory: true))
                }
            }
        }

        let userdata = steamRootURL.appendingPathComponent("userdata", isDirectory: true)
        let steamUsers = (try? fileManager.contentsOfDirectory(
            at: userdata,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for user in steamUsers {
            roots.append(user.appendingPathComponent(game.appID, isDirectory: true))
        }

        var visited = Set<String>()
        var candidateCount = 0
        for root in roots where candidateCount < 64 {
            guard fileManager.fileExists(atPath: root.path), visited.insert(root.standardizedFileURL.path).inserted else {
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard candidateCount < 64 else { break }
                let relativeDepth = url.pathComponents.count - root.pathComponents.count
                if relativeDepth > 6 {
                    enumerator.skipDescendants()
                    continue
                }
                guard isCandidate(url) else { continue }
                let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resource?.isRegularFile == true, (resource?.fileSize ?? 0) <= 1_048_576 else { continue }
                candidateCount += 1
                collectFile(url, into: &values)
            }
        }
        return values
    }

    private static func isCandidate(_ url: URL) -> Bool {
        guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return fileNameMarkers.contains { name.contains($0) }
    }

    private static func collectFile(_ url: URL, into values: inout [String: String]) {
        guard let data = try? Data(contentsOf: url), let contents = String(data: data, encoding: .utf8) else {
            return
        }
        let pathHash = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let prefix = "gameconfig.\(pathHash)"
        values["\(prefix).file"] = url.lastPathComponent.lowercased()
        values["\(prefix).sha256"] = contentHash

        let pairPattern = #"^\s*[\"']?([A-Za-z0-9_. -]{2,64})[\"']?\s*[:=]\s*[\"']?([^\"'\r\n,}]{1,160})"#
        let xmlPattern = #"^\s*<([A-Za-z0-9_.-]{2,64})>\s*([^<]{1,160})\s*</"#
        let pairExpression = try? NSRegularExpression(pattern: pairPattern)
        let xmlExpression = try? NSRegularExpression(pattern: xmlPattern)

        var stored = 0
        for line in contents.split(whereSeparator: \.isNewline) where stored < 48 {
            let text = String(line)
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let match = pairExpression?.firstMatch(in: text, range: fullRange)
                ?? xmlExpression?.firstMatch(in: text, range: fullRange)
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let key = normalizedKey(String(text[keyRange]))
            guard settingMarkers.contains(where: { key.contains($0) }) else { continue }
            guard let value = safeValue(String(text[valueRange])) else { continue }
            values["\(prefix).\(key)"] = value
            stored += 1
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(scalars).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func safeValue(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"',")))
        guard !value.isEmpty, value.count <= 160 else { return nil }
        let lowercased = value.lowercased()
        guard
            !lowercased.contains("http://"),
            !lowercased.contains("https://"),
            !lowercased.contains("token"),
            !lowercased.contains("password"),
            !value.contains("@"),
            !value.contains(#":\"#),
            !value.contains("/Users/")
        else { return nil }
        return value
    }
}
