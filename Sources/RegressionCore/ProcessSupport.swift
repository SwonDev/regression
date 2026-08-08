import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult
}

public protocol ProcessLaunching: Sendable {
    func launch(
        backend: BackendKind,
        executableURL: URL,
        arguments: [String],
        logDirectoryURL: URL
    ) async throws -> BackendLaunch

    func reapFinishedProcesses() async
}

public protocol ProcessInspecting: Sendable {
    func runningBackends() async -> RunningBackendState
}

public actor ProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-process-\(UUID().uuidString)", isDirectory: true)
        try PrivateStorage.ensureDirectory(at: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        try PrivateStorage.createFile(at: outputURL)
        try PrivateStorage.createFile(at: errorURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        try process.run()
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()

        let outputData = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

public actor ProcessLauncher: ProcessLaunching {
    private struct OwnedLaunch {
        let process: Process
        let backend: BackendKind
        let executablePath: String
        let arguments: [String]
        let launch: BackendLaunch
    }

    private var ownedProcesses: [Int32: OwnedLaunch] = [:]

    public init() {}

    public func launch(
        backend: BackendKind,
        executableURL: URL,
        arguments: [String],
        logDirectoryURL: URL
    ) async throws -> BackendLaunch {
        let executablePath = executableURL.standardizedFileURL.path
        if let existing = ownedProcesses.values.first(where: {
            $0.process.isRunning
                && $0.backend == backend
                && $0.executablePath == executablePath
                && $0.arguments == arguments
        }) {
            return existing.launch
        }

        try PrivateStorage.ensureDirectory(at: logDirectoryURL)
        try rotateLogs(in: logDirectoryURL, retaining: 20)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let logURL = logDirectoryURL.appendingPathComponent(
            "\(backend.rawValue)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).log"
        )
        try PrivateStorage.createFile(at: logURL)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: logURL)
            throw error
        }
        let launch = BackendLaunch(
            backend: backend,
            processID: process.processIdentifier,
            command: PrivacySanitizer.normalizedPath(executableURL.path),
            arguments: PrivacySanitizer.safeArguments(arguments),
            logURL: logURL
        )
        ownedProcesses[process.processIdentifier] = OwnedLaunch(
            process: process,
            backend: backend,
            executablePath: executablePath,
            arguments: arguments,
            launch: launch
        )
        return launch
    }

    public func reapFinishedProcesses() async {
        ownedProcesses = ownedProcesses.filter { $0.value.process.isRunning }
    }

    private func rotateLogs(in directoryURL: URL, retaining limit: Int) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension == "log"
                && ($0.lastPathComponent.hasPrefix("crossOver-")
                    || $0.lastPathComponent.hasPrefix("regression-"))
        }
        .sorted {
            let left = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let right = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }

        for staleLog in candidates.dropFirst(max(0, limit - 1)) {
            try FileManager.default.removeItem(at: staleLog)
        }
    }
}

/// Lee únicamente la cola acotada de un log fuera del actor principal y la sanea antes de
/// devolverla a la interfaz. Así un lanzamiento verboso no puede bloquear el menú ni filtrar
/// rutas o credenciales en un mensaje de error.
public actor ProcessLogReader {
    public init() {}

    public func redactedExcerpt(
        at url: URL,
        maximumReadBytes: Int = 65_536,
        maximumOutputCharacters: Int = 2_000
    ) -> String {
        guard maximumReadBytes > 0,
              maximumOutputCharacters > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(maximumReadBytes) {
            try? handle.seek(toOffset: size - UInt64(maximumReadBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.read(upToCount: maximumReadBytes) else {
            return ""
        }
        let sanitized = PrivacySanitizer.redactedLogExcerpt(
            String(decoding: data, as: UTF8.self),
            limit: .max
        )
        return String(sanitized.suffix(maximumOutputCharacters))
    }
}

public actor ProcessInspector: ProcessInspecting {
    private let runner: any ProcessRunning
    private var cachedBackendsBySteamPID: [Int32: BackendKind] = [:]

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func runningBackends() async -> RunningBackendState {
        guard let result = try? await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="],
            environment: nil
        ) else {
            return RunningBackendState()
        }

        let parsed = Self.parseProcessList(result.standardOutput)
        var crossOver = Set(parsed.crossOverPIDs)
        var regression = Set(parsed.regressionPIDs)
        let steamClientPIDs = Set(Self.steamClientProcessIDs(result.standardOutput))
        cachedBackendsBySteamPID = cachedBackendsBySteamPID.filter {
            steamClientPIDs.contains($0.key)
        }

        for pid in crossOver {
            cachedBackendsBySteamPID[pid] = .crossOver
        }
        for pid in regression {
            cachedBackendsBySteamPID[pid] = .regression
        }

        // Wine desacopla los procesos Windows del launcher y macOS termina mostrando solo
        // `C:\...\Steam.exe` en `ps`. Para esos clientes anónimos, identifica el backend
        // mediante el runtime que realmente tienen abierto, no mediante un wineserver stale.
        for pid in steamClientPIDs where !crossOver.contains(pid) && !regression.contains(pid) {
            if let cachedBackend = cachedBackendsBySteamPID[pid] {
                switch cachedBackend {
                case .crossOver:
                    crossOver.insert(pid)
                case .regression:
                    regression.insert(pid)
                }
                continue
            }

            guard let openFiles = try? await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-n", "-P", "-Fn", "-p", String(pid)],
                environment: nil
            ) else {
                continue
            }

            switch Self.backend(fromOpenFileList: openFiles.standardOutput) {
            case .crossOver:
                crossOver.insert(pid)
                cachedBackendsBySteamPID[pid] = .crossOver
            case .regression:
                regression.insert(pid)
                cachedBackendsBySteamPID[pid] = .regression
            case nil:
                continue
            }
        }

        return RunningBackendState(
            crossOverPIDs: crossOver.sorted(),
            regressionPIDs: regression.sorted()
        )
    }

    public static func parseProcessList(_ output: String) -> RunningBackendState {
        var crossOver: Set<Int32> = []
        var regression: Set<Int32> = []

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let pidText = trimmed[..<separator]
            guard let pid = Int32(pidText) else { continue }
            let command = trimmed[separator...].lowercased()
            guard isSteamClientCommand(command) else { continue }

            if command.contains("crossover.app/contents/sharedsupport/crossover") {
                crossOver.insert(pid)
            } else if command.contains("regression.app/contents/sharedsupport/wine-root")
                || command.contains("application support/regression/bottles") {
                regression.insert(pid)
            }
        }

        return RunningBackendState(
            crossOverPIDs: crossOver.sorted(),
            regressionPIDs: regression.sorted()
        )
    }

    public static func steamClientProcessIDs(_ output: String) -> [Int32] {
        var processIDs: Set<Int32> = []

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let pidText = trimmed[..<separator]
            guard let pid = Int32(pidText) else { continue }
            let command = trimmed[separator...].lowercased()
            guard isSteamClientCommand(command) else { continue }
            processIDs.insert(pid)
        }

        return processIDs.sorted()
    }

    public static func backend(fromOpenFileList output: String) -> BackendKind? {
        let paths = output.lowercased()
        if paths.contains("crossover.app/contents/sharedsupport/crossover") {
            return .crossOver
        }
        if paths.contains("regression.app/contents/sharedsupport/wine-root")
            || paths.contains("application support/regression/bottles") {
            return .regression
        }
        return nil
    }

    private static func isSteamClientCommand(_ command: String) -> Bool {
        command.contains("steam.exe") && !command.contains("steamwebhelper.exe")
    }
}
