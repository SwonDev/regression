import Foundation

public enum SteamGameProcessEvent: Equatable, Sendable {
    case started(timestamp: Date, appID: String, processID: Int32, executable: String)
    case ended(timestamp: Date, appID: String, processID: Int32, exitCode: Int32)
}

public enum SteamGameProcessLogParser {
    private static let startedExpression = try! NSRegularExpression(
        pattern: #"^\[([^]]+)\] AppID ([0-9]+) adding PID ([0-9]+) as a tracked process "(.*)"$"#
    )
    private static let endedExpression = try! NSRegularExpression(
        pattern: #"^\[([^]]+)\] AppID ([0-9]+) no longer tracking PID ([0-9]+), exit code (-?[0-9]+)$"#
    )

    public static func parse(line: String) -> SteamGameProcessEvent? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = startedExpression.firstMatch(in: line, range: fullRange),
           let timestamp = capture(1, match: match, in: line).flatMap(parseDate),
           let appID = capture(2, match: match, in: line),
           let pidText = capture(3, match: match, in: line),
           let pid = Int32(pidText),
           let rawCommand = capture(4, match: match, in: line) {
            return .started(
                timestamp: timestamp,
                appID: appID,
                processID: pid,
                executable: safeExecutable(from: rawCommand)
            )
        }

        if let match = endedExpression.firstMatch(in: line, range: fullRange),
           let timestamp = capture(1, match: match, in: line).flatMap(parseDate),
           let appID = capture(2, match: match, in: line),
           let pidText = capture(3, match: match, in: line),
           let codeText = capture(4, match: match, in: line),
           let pid = Int32(pidText),
           let code = Int32(codeText) {
            return .ended(timestamp: timestamp, appID: appID, processID: pid, exitCode: code)
        }
        return nil
    }

    public static func isPrimaryExecutable(_ executable: String) -> Bool {
        let lowercased = executable.lowercased()
        return !lowercased.contains("crashpad")
            && !lowercased.contains("steamerrorreporter")
            && !lowercased.hasSuffix(".dll")
    }

    private static func safeExecutable(from command: String) -> String {
        let withoutOuterQuotes = command.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let pattern = #"(?i)([A-Z]:[\\/].*?\.(?:exe|dll))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return "desconocido"
        }
        let range = NSRange(withoutOuterQuotes.startIndex..<withoutOuterQuotes.endIndex, in: withoutOuterQuotes)
        guard
            let match = expression.firstMatch(in: withoutOuterQuotes, range: range),
            let pathRange = Range(match.range(at: 1), in: withoutOuterQuotes)
        else {
            return "desconocido"
        }
        return String(withoutOuterQuotes[pathRange])
    }

    private static func capture(_ index: Int, match: NSTextCheckingResult, in text: String) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

public actor SteamLogMonitor {
    private var offsets: [URL: UInt64] = [:]

    public init() {}

    public func beginMonitoringAtEnd(of logURL: URL) {
        guard offsets[logURL] == nil else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        offsets[logURL] = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public func readNewEvents(from logURL: URL) -> [SteamGameProcessEvent] {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }

        let previousOffset = offsets[logURL] ?? 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let safeOffset = previousOffset <= currentSize ? previousOffset : 0
        do {
            try handle.seek(toOffset: safeOffset)
            let data = try handle.readToEnd() ?? Data()
            offsets[logURL] = safeOffset + UInt64(data.count)
            let text = String(decoding: data, as: UTF8.self)
            return text.split(whereSeparator: \.isNewline).compactMap {
                SteamGameProcessLogParser.parse(line: String($0))
            }
        } catch {
            return []
        }
    }
}
