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

public actor ProcessRunner {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
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

public actor ProcessLauncher {
    private var ownedProcesses: [Int32: Process] = [:]

    public init() {}

    public func launch(
        backend: BackendKind,
        executableURL: URL,
        arguments: [String],
        logDirectoryURL: URL
    ) throws -> BackendLaunch {
        try PrivateStorage.ensureDirectory(at: logDirectoryURL)
        try rotateLogs(in: logDirectoryURL, retaining: 20)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let logURL = logDirectoryURL.appendingPathComponent(
            "\(backend.rawValue)-\(formatter.string(from: Date())).log"
        )
        try PrivateStorage.createFile(at: logURL)
        let handle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try? handle.close()
        ownedProcesses[process.processIdentifier] = process

        return BackendLaunch(
            backend: backend,
            processID: process.processIdentifier,
            command: PrivacySanitizer.normalizedPath(executableURL.path),
            arguments: PrivacySanitizer.safeArguments(arguments),
            logURL: logURL
        )
    }

    public func reapFinishedProcesses() {
        ownedProcesses = ownedProcesses.filter { $0.value.isRunning }
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

public actor ProcessInspector {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner) {
        self.runner = runner
    }

    public func runningBackends() async -> RunningBackendState {
        guard let result = try? await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="]
        ) else {
            return RunningBackendState()
        }
        return Self.parseProcessList(result.standardOutput)
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
            guard command.contains("steam.exe") else { continue }

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
}
