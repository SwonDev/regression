import Foundation

public enum SteamGameProcessEvent: Codable, Equatable, Sendable {
    case started(timestamp: Date, appID: String, processID: Int32, executable: String)
    case ended(timestamp: Date, appID: String, processID: Int32, exitCode: Int32)
}

public enum SteamLogMonitorIssueCode: String, Codable, Equatable, Sendable {
    case logUnavailable = "log_unavailable"
    case logUnreadable = "log_unreadable"
    case logTruncated = "log_truncated"
    case logReplaced = "log_replaced"
    case pendingLineLimitExceeded = "pending_line_limit_exceeded"
    case unrecognizedProcessLineVolume = "unrecognized_process_line_volume"
    case readLimitReached = "read_limit_reached"
    case monitoringRecovered = "monitoring_recovered"
    case pendingLineAbandoned = "pending_line_abandoned"
}

public struct SteamLogMonitorIssue: Codable, Equatable, Sendable {
    public let code: SteamLogMonitorIssueCode
    public let message: String

    public init(code: SteamLogMonitorIssueCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct SteamLogDiscontinuity: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let reason: SteamLogMonitorIssueCode

    public init(epoch: UInt64, reason: SteamLogMonitorIssueCode) {
        self.epoch = epoch
        self.reason = reason
    }
}

public struct SteamLogReadOutcome: Codable, Equatable, Sendable {
    public var events: [SteamGameProcessEvent]
    public var issues: [SteamLogMonitorIssue]
    public var newlyObservedIssues: [SteamLogMonitorIssueCode]
    public var resolvedIssues: [SteamLogMonitorIssueCode]
    public var epoch: UInt64
    public var discontinuity: SteamLogDiscontinuity?
    public var hasMoreData: Bool
    public var hasPendingLine: Bool

    public init(
        events: [SteamGameProcessEvent] = [],
        issues: [SteamLogMonitorIssue] = [],
        newlyObservedIssues: [SteamLogMonitorIssueCode] = [],
        resolvedIssues: [SteamLogMonitorIssueCode] = [],
        epoch: UInt64 = 0,
        discontinuity: SteamLogDiscontinuity? = nil,
        hasMoreData: Bool = false,
        hasPendingLine: Bool = false
    ) {
        self.events = events
        self.issues = issues
        self.newlyObservedIssues = newlyObservedIssues
        self.resolvedIssues = resolvedIssues
        self.epoch = epoch
        self.discontinuity = discontinuity
        self.hasMoreData = hasMoreData
        self.hasPendingLine = hasPendingLine
    }
}

public enum SteamGameProcessLogParser {
    private static let startedExpression = try? NSRegularExpression(
        pattern: #"^\[([^]]+)\] AppID ([0-9]+) adding PID ([0-9]+) as a tracked process "(.*)"$"#
    )
    private static let endedExpression = try? NSRegularExpression(
        pattern: #"^\[([^]]+)\] AppID ([0-9]+) no longer tracking PID ([0-9]+), exit code (-?[0-9]+)$"#
    )

    public static func parse(line: String) -> SteamGameProcessEvent? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = startedExpression?.firstMatch(in: line, range: fullRange),
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

        if let match = endedExpression?.firstMatch(in: line, range: fullRange),
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
    private struct LogState: Sendable {
        var offset: UInt64
        var pendingBytes: Data
        var fileNumber: UInt64?
        var anchorBytes: Data
        var epoch: UInt64
        var activeIssues: Set<SteamLogMonitorIssueCode>
        var unrecognizedCandidateLineCount: Int
        var discardUntilNewline: Bool
        var pendingLineIdlePolls: Int
        var lastAccess: UInt64
    }

    private let maximumPendingBytes: Int
    private let unrecognizedCandidateLineThreshold: Int
    private let maximumReadBytes: Int
    private let maximumMonitoredLogs: Int
    private let anchorByteCount: Int
    private let maximumPendingLineIdlePolls: Int
    private var states: [URL: LogState] = [:]
    private var accessCounter: UInt64 = 0

    public init() {
        maximumPendingBytes = 256 * 1_024
        unrecognizedCandidateLineThreshold = 32
        maximumReadBytes = 512 * 1_024
        maximumMonitoredLogs = 8
        anchorByteCount = 64
        maximumPendingLineIdlePolls = 12
    }

    init(
        maximumPendingBytes: Int,
        unrecognizedCandidateLineThreshold: Int,
        maximumReadBytes: Int = 512 * 1_024,
        maximumMonitoredLogs: Int = 8,
        anchorByteCount: Int = 64,
        maximumPendingLineIdlePolls: Int = 12
    ) {
        self.maximumPendingBytes = max(1, maximumPendingBytes)
        self.unrecognizedCandidateLineThreshold = max(1, unrecognizedCandidateLineThreshold)
        self.maximumReadBytes = max(1, maximumReadBytes)
        self.maximumMonitoredLogs = max(1, maximumMonitoredLogs)
        self.anchorByteCount = max(1, anchorByteCount)
        self.maximumPendingLineIdlePolls = max(1, maximumPendingLineIdlePolls)
    }

    public func beginMonitoringAtEnd(of logURL: URL) {
        let key = logURL.standardizedFileURL
        if states[key] != nil {
            touch(key)
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: key.path)
        let offset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let anchor = (try? FileHandle(forReadingFrom: key)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? Self.readAnchor(
                handle: handle,
                endingAt: offset,
                maximumCount: anchorByteCount
            )
        } ?? Data()
        accessCounter &+= 1
        store(LogState(
            offset: offset,
            pendingBytes: Data(),
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            anchorBytes: anchor,
            epoch: 0,
            activeIssues: [],
            unrecognizedCandidateLineCount: 0,
            discardUntilNewline: false,
            pendingLineIdlePolls: 0,
            lastAccess: accessCounter
        ), for: key)
    }

    public func forget(_ logURL: URL) {
        states.removeValue(forKey: logURL.standardizedFileURL)
    }

    func monitoredLogCount() -> Int {
        states.count
    }

    public func readNewEvents(from logURL: URL) -> SteamLogReadOutcome {
        let key = logURL.standardizedFileURL
        var state = state(for: key)
        guard FileManager.default.fileExists(atPath: key.path) else {
            let resolved = state.activeIssues.remove(.logUnreadable) == nil
                ? []
                : [SteamLogMonitorIssueCode.logUnreadable]
            let newlyObserved = activate(.logUnavailable, in: &state)
            store(state, for: key)
            return outcome(
                state: state,
                newlyObserved: newlyObserved ? [.logUnavailable] : [],
                resolved: resolved
            )
        }

        let handle: FileHandle
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: key.path)
            handle = try FileHandle(forReadingFrom: key)
        } catch {
            let resolved = state.activeIssues.remove(.logUnavailable) == nil
                ? []
                : [SteamLogMonitorIssueCode.logUnavailable]
            let newlyObserved = activate(.logUnreadable, in: &state)
            store(state, for: key)
            return outcome(
                state: state,
                newlyObserved: newlyObserved ? [.logUnreadable] : [],
                resolved: resolved
            )
        }
        defer { try? handle.close() }

        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let currentFileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let availabilityResolved = state.activeIssues.intersection([.logUnavailable, .logUnreadable])
        state.activeIssues.subtract(availabilityResolved)
        var transientCodes: [SteamLogMonitorIssueCode] = availabilityResolved.isEmpty
            ? []
            : [.monitoringRecovered]
        var newlyObserved: [SteamLogMonitorIssueCode] = transientCodes
        var resolved = Array(availabilityResolved).sorted { $0.rawValue < $1.rawValue }

        let fileWasReplaced = state.fileNumber != nil
            && currentFileNumber != nil
            && state.fileNumber != currentFileNumber
        let fileShrankBelowOffset = !fileWasReplaced && state.offset > currentSize
        let anchorChanged = !fileWasReplaced
            && !fileShrankBelowOffset
            && !state.anchorBytes.isEmpty
            && !Self.anchorMatches(
                state.anchorBytes,
                handle: handle,
                endingAt: state.offset
            )
        let fileWasTruncated = fileShrankBelowOffset || anchorChanged
        let discontinuityCode: SteamLogMonitorIssueCode? = fileWasReplaced
            ? .logReplaced
            : (fileWasTruncated ? .logTruncated : nil)
        state.fileNumber = currentFileNumber ?? state.fileNumber
        if let discontinuityCode {
            state.epoch &+= 1
            state.offset = currentSize
            state.pendingBytes.removeAll(keepingCapacity: true)
            state.discardUntilNewline = false
            state.pendingLineIdlePolls = 0
            resolved.append(contentsOf: state.activeIssues)
            state.activeIssues.removeAll()
            state.unrecognizedCandidateLineCount = 0
            transientCodes.append(discontinuityCode)
            newlyObserved.append(discontinuityCode)
            do {
                state.anchorBytes = try Self.readAnchor(
                    handle: handle,
                    endingAt: currentSize,
                    maximumCount: anchorByteCount
                )
                store(state, for: key)
                return outcome(
                    state: state,
                    newlyObserved: newlyObserved,
                    resolved: resolved,
                    transientCodes: transientCodes,
                    discontinuityCode: discontinuityCode
                )
            } catch {
                let isNew = activate(.logUnreadable, in: &state)
                store(state, for: key)
                return outcome(
                    state: state,
                    newlyObserved: newlyObserved + (isNew ? [.logUnreadable] : []),
                    resolved: resolved,
                    transientCodes: transientCodes,
                    discontinuityCode: discontinuityCode
                )
            }
        }

        do {
            try handle.seek(toOffset: state.offset)
            let data = try handle.read(upToCount: maximumReadBytes) ?? Data()
            state.offset += UInt64(data.count)
            let hasMoreData = state.offset < currentSize
            updateActiveIssue(
                .readLimitReached,
                active: hasMoreData,
                state: &state,
                newlyObserved: &newlyObserved,
                resolved: &resolved
            )

            var completeBuffer = state.pendingBytes
            completeBuffer.append(data)
            if state.discardUntilNewline {
                guard let discardBoundary = completeBuffer.firstIndex(of: 0x0A) else {
                    state.pendingBytes.removeAll(keepingCapacity: true)
                    state.anchorBytes = try Self.readAnchor(
                        handle: handle,
                        endingAt: state.offset,
                        maximumCount: anchorByteCount
                    )
                    store(state, for: key)
                    return outcome(
                        state: state,
                        newlyObserved: newlyObserved,
                        resolved: resolved,
                        transientCodes: transientCodes,
                        hasMoreData: hasMoreData
                    )
                }
                completeBuffer = Data(completeBuffer[completeBuffer.index(after: discardBoundary)...])
                state.discardUntilNewline = false
                state.pendingLineIdlePolls = 0
                if state.activeIssues.remove(.pendingLineLimitExceeded) != nil {
                    resolved.append(.pendingLineLimitExceeded)
                }
            }
            guard let finalNewline = completeBuffer.lastIndex(of: 0x0A) else {
                let exceeded = completeBuffer.count > maximumPendingBytes
                if exceeded {
                    state.pendingBytes.removeAll(keepingCapacity: true)
                    state.discardUntilNewline = true
                    state.pendingLineIdlePolls = 0
                } else {
                    state.pendingBytes = completeBuffer
                    state.pendingLineIdlePolls = data.isEmpty
                        ? state.pendingLineIdlePolls + 1
                        : 0
                }
                updateActiveIssue(
                    .pendingLineLimitExceeded,
                    active: exceeded || state.activeIssues.contains(.pendingLineLimitExceeded),
                    state: &state,
                    newlyObserved: &newlyObserved,
                    resolved: &resolved
                )
                var abandoned = false
                if !exceeded,
                   !state.pendingBytes.isEmpty,
                   state.pendingLineIdlePolls >= maximumPendingLineIdlePolls {
                    state.pendingBytes.removeAll(keepingCapacity: true)
                    state.pendingLineIdlePolls = 0
                    transientCodes.append(.pendingLineAbandoned)
                    newlyObserved.append(.pendingLineAbandoned)
                    abandoned = true
                }
                state.anchorBytes = try Self.readAnchor(
                    handle: handle,
                    endingAt: state.offset,
                    maximumCount: anchorByteCount
                )
                store(state, for: key)
                return outcome(
                    state: state,
                    newlyObserved: newlyObserved,
                    resolved: resolved,
                    transientCodes: transientCodes,
                    discontinuityCode: discontinuityCode,
                    hasMoreData: hasMoreData,
                    hasPendingLine: !abandoned && !state.pendingBytes.isEmpty
                )
            }

            let completeData = completeBuffer[...finalNewline]
            state.pendingBytes = Data(completeBuffer[completeBuffer.index(after: finalNewline)...])
            state.pendingLineIdlePolls = 0
            let pendingExceeded = state.pendingBytes.count > maximumPendingBytes
            if pendingExceeded {
                state.pendingBytes.removeAll(keepingCapacity: true)
                state.discardUntilNewline = true
            }
            updateActiveIssue(
                .pendingLineLimitExceeded,
                active: pendingExceeded,
                state: &state,
                newlyObserved: &newlyObserved,
                resolved: &resolved
            )

            var events: [SteamGameProcessEvent] = []
            var unrecognizedCandidates = 0
            let text = String(decoding: completeData, as: UTF8.self)
            let completeLines = text.split(whereSeparator: \.isNewline)
            for lineSlice in completeLines {
                let line = String(lineSlice)
                if let event = SteamGameProcessLogParser.parse(line: line) {
                    events.append(event)
                } else if Self.looksLikeProcessEvent(line) {
                    unrecognizedCandidates += 1
                }
            }
            if events.isEmpty, unrecognizedCandidates > 0 {
                state.unrecognizedCandidateLineCount = min(
                    unrecognizedCandidateLineThreshold,
                    state.unrecognizedCandidateLineCount + unrecognizedCandidates
                )
            } else if events.isEmpty, !completeLines.isEmpty {
                state.unrecognizedCandidateLineCount = 0
            } else {
                state.unrecognizedCandidateLineCount = min(
                    unrecognizedCandidateLineThreshold,
                    unrecognizedCandidates
                )
            }
            updateActiveIssue(
                .unrecognizedProcessLineVolume,
                active: state.unrecognizedCandidateLineCount >= unrecognizedCandidateLineThreshold,
                state: &state,
                newlyObserved: &newlyObserved,
                resolved: &resolved
            )
            state.anchorBytes = try Self.readAnchor(
                handle: handle,
                endingAt: state.offset,
                maximumCount: anchorByteCount
            )
            store(state, for: key)
            return outcome(
                events: events,
                state: state,
                newlyObserved: newlyObserved,
                resolved: resolved,
                transientCodes: transientCodes,
                discontinuityCode: discontinuityCode,
                hasMoreData: hasMoreData,
                hasPendingLine: !state.pendingBytes.isEmpty
            )
        } catch {
            let isNew = activate(.logUnreadable, in: &state)
            store(state, for: key)
            return outcome(
                state: state,
                newlyObserved: newlyObserved + (isNew ? [.logUnreadable] : []),
                resolved: resolved,
                transientCodes: transientCodes,
                discontinuityCode: discontinuityCode
            )
        }
    }

    private func state(for key: URL) -> LogState {
        if var existing = states[key] {
            accessCounter &+= 1
            existing.lastAccess = accessCounter
            return existing
        }
        accessCounter &+= 1
        return LogState(
            offset: 0,
            pendingBytes: Data(),
            fileNumber: nil,
            anchorBytes: Data(),
            epoch: 0,
            activeIssues: [],
            unrecognizedCandidateLineCount: 0,
            discardUntilNewline: false,
            pendingLineIdlePolls: 0,
            lastAccess: accessCounter
        )
    }

    private func store(_ state: LogState, for key: URL) {
        states[key] = state
        while states.count > maximumMonitoredLogs,
              let oldest = states.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            states.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: URL) {
        guard var state = states[key] else { return }
        accessCounter &+= 1
        state.lastAccess = accessCounter
        states[key] = state
    }

    private func activate(
        _ code: SteamLogMonitorIssueCode,
        in state: inout LogState
    ) -> Bool {
        state.activeIssues.insert(code).inserted
    }

    private func deactivate(_ code: SteamLogMonitorIssueCode, in state: inout LogState) {
        state.activeIssues.remove(code)
    }

    private func updateActiveIssue(
        _ code: SteamLogMonitorIssueCode,
        active: Bool,
        state: inout LogState,
        newlyObserved: inout [SteamLogMonitorIssueCode],
        resolved: inout [SteamLogMonitorIssueCode]
    ) {
        if active {
            if activate(code, in: &state) {
                newlyObserved.append(code)
            }
        } else if state.activeIssues.remove(code) != nil {
            resolved.append(code)
        }
    }

    private func outcome(
        events: [SteamGameProcessEvent] = [],
        state: LogState,
        newlyObserved: [SteamLogMonitorIssueCode] = [],
        resolved: [SteamLogMonitorIssueCode] = [],
        transientCodes: [SteamLogMonitorIssueCode] = [],
        discontinuityCode: SteamLogMonitorIssueCode? = nil,
        hasMoreData: Bool = false,
        hasPendingLine: Bool = false
    ) -> SteamLogReadOutcome {
        let codes = Array(state.activeIssues).sorted { $0.rawValue < $1.rawValue } + transientCodes
        return SteamLogReadOutcome(
            events: events,
            issues: codes.map { SteamLogMonitorIssue(code: $0, message: Self.message(for: $0)) },
            newlyObservedIssues: newlyObserved,
            resolvedIssues: Array(Set(resolved)).sorted { $0.rawValue < $1.rawValue },
            epoch: state.epoch,
            discontinuity: discontinuityCode.map {
                SteamLogDiscontinuity(epoch: state.epoch, reason: $0)
            },
            hasMoreData: hasMoreData,
            hasPendingLine: hasPendingLine
        )
    }

    private static func readAnchor(
        handle: FileHandle,
        endingAt offset: UInt64,
        maximumCount: Int
    ) throws -> Data {
        let count = min(UInt64(maximumCount), offset)
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: offset - count)
        return try handle.read(upToCount: Int(count)) ?? Data()
    }

    private static func anchorMatches(
        _ expected: Data,
        handle: FileHandle,
        endingAt offset: UInt64
    ) -> Bool {
        guard offset >= UInt64(expected.count) else { return false }
        do {
            try handle.seek(toOffset: offset - UInt64(expected.count))
            return try handle.read(upToCount: expected.count) == expected
        } catch {
            return false
        }
    }

    private static func message(for code: SteamLogMonitorIssueCode) -> String {
        switch code {
        case .logUnavailable:
            "El log de procesos de Steam no está disponible; la telemetría no puede observar lanzamientos ni cierres."
        case .logUnreadable:
            "El log de procesos de Steam existe, pero no se puede leer; la telemetría queda incompleta."
        case .logTruncated:
            "Steam reescribió o truncó el log de procesos; la lectura continuó en una época nueva."
        case .logReplaced:
            "Steam reemplazó el log de procesos; la lectura continuó en una época nueva."
        case .pendingLineLimitExceeded:
            "Una línea incompleta del log superó el límite seguro y se acotó; parte de esa línea no podrá interpretarse."
        case .unrecognizedProcessLineVolume:
            "Varias líneas con apariencia de eventos de procesos no coinciden con el formato esperado; Steam puede haber cambiado su telemetría."
        case .readLimitReached:
            "El log contiene más datos que el límite seguro de una lectura; el resto se procesará en sondeos posteriores."
        case .monitoringRecovered:
            "La lectura del log de procesos de Steam se ha recuperado."
        case .pendingLineAbandoned:
            "Una línea del log permaneció incompleta durante demasiados sondeos y se descartó para no bloquear la telemetría."
        }
    }

    private static func looksLikeProcessEvent(_ line: String) -> Bool {
        line.contains("AppID ")
            && (line.contains("adding PID ") || line.contains("no longer tracking PID "))
    }
}
