import Foundation

public enum GameSessionArtifactKind: String, Equatable, Sendable {
    case gameOverlay
    case steamErrorReporter
}

public struct GameSessionArtifactCandidate: Equatable, Sendable {
    public let hostProcessID: Int32
    public let kind: GameSessionArtifactKind

    public init(hostProcessID: Int32, kind: GameSessionArtifactKind) {
        self.hostProcessID = hostProcessID
        self.kind = kind
    }
}

public protocol GameSessionArtifactCleaning: Sendable {
    func clean(
        appID: String,
        backend: BackendKind,
        endedWindowsProcessIDs: Set<Int32>
    ) async -> [String]
}

public struct NoOpGameSessionArtifactCleaner: GameSessionArtifactCleaning {
    public init() {}

    public func clean(
        appID: String,
        backend: BackendKind,
        endedWindowsProcessIDs: Set<Int32>
    ) async -> [String] {
        []
    }
}

/// Retira únicamente procesos auxiliares de Steam que siguen vivos después de consolidar una
/// sesión de Regression. Nunca busca ni termina Steam, steamwebhelper, wineserver o procesos de
/// otro juego. Cada candidato debe coincidir con el App ID y PID de Windows ya finalizados y,
/// además, tener abierto el runtime propio de Regression según `lsof`.
public actor GameSessionArtifactCleaner: GameSessionArtifactCleaning {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func clean(
        appID: String,
        backend: BackendKind,
        endedWindowsProcessIDs: Set<Int32>
    ) async -> [String] {
        guard backend == .regression, !endedWindowsProcessIDs.isEmpty else { return [] }

        let processResult: ProcessResult
        do {
            processResult = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,command="],
                environment: nil
            )
        } catch {
            return ["No se pudieron inventariar los auxiliares de la sesión (appID): \(error.localizedDescription)"]
        }
        guard processResult.exitCode == 0 else {
            return ["No se pudieron inventariar los auxiliares de la sesión (appID) (ps \(processResult.exitCode))."]
        }

        var issues: [String] = []
        for candidate in Self.candidates(
            in: processResult.standardOutput,
            appID: appID,
            endedWindowsProcessIDs: endedWindowsProcessIDs
        ) {
            do {
                let openFiles = try await runner.run(
                    executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-n", "-P", "-Fn", "-p", String(candidate.hostProcessID)],
                    environment: nil
                )
                guard openFiles.exitCode == 0,
                      ProcessInspector.backend(fromOpenFileList: openFiles.standardOutput) == .regression
                else { continue }

                let termination = try await runner.run(
                    executableURL: URL(fileURLWithPath: "/bin/kill"),
                    arguments: ["-TERM", String(candidate.hostProcessID)],
                    environment: nil
                )
                if termination.exitCode != 0 {
                    issues.append(
                        "No se pudo retirar \(candidate.kind.rawValue) de la sesión \(appID) "
                            + "(PID host \(candidate.hostProcessID))."
                    )
                }
            } catch {
                issues.append(
                    "No se pudo retirar \(candidate.kind.rawValue) de la sesión \(appID): "
                        + error.localizedDescription
                )
            }
        }
        return issues
    }

    public static func candidates(
        in processList: String,
        appID: String,
        endedWindowsProcessIDs: Set<Int32>
    ) -> [GameSessionArtifactCandidate] {
        guard let normalizedAppID = SteamAppID.normalized(appID),
              !endedWindowsProcessIDs.isEmpty else { return [] }

        return processList.split(whereSeparator: \ .isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: \ .isWhitespace),
                  let hostPID = Int32(line[..<separator]) else { return nil }
            let command = String(line[separator...]).trimmingCharacters(in: .whitespaces)
            let tokens = command.split(whereSeparator: \ .isWhitespace).map(String.init)
            let lowered = tokens.map { $0.lowercased() }

            let kind: GameSessionArtifactKind
            if lowered.contains(where: { $0.hasSuffix("gameoverlayui64.exe") }) {
                kind = .gameOverlay
            } else if lowered.contains(where: {
                $0.hasSuffix("steamerrorreporter.exe") || $0.hasSuffix("steamerrorreporter64.exe")
            }) {
                kind = .steamErrorReporter
            } else {
                return nil
            }

            guard argumentValue("-gameid", in: lowered) == normalizedAppID,
                  let rawWindowsPID = argumentValue("-pid", in: lowered),
                  let windowsPID = Int32(rawWindowsPID),
                  endedWindowsProcessIDs.contains(windowsPID)
            else { return nil }

            return GameSessionArtifactCandidate(hostProcessID: hostPID, kind: kind)
        }
        .sorted { lhs, rhs in lhs.hostProcessID < rhs.hostProcessID }
    }

    private static func argumentValue(_ name: String, in tokens: [String]) -> String? {
        for (index, token) in tokens.enumerated() {
            if token == name, tokens.indices.contains(index + 1) {
                return tokens[index + 1]
            }
            let prefix = name + "="
            if token.hasPrefix(prefix) {
                return String(token.dropFirst(prefix.count))
            }
        }
        return nil
    }
}
