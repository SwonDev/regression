import XCTest
@testable import RegressionCore

final class GameSessionArtifactCleanerTests: XCTestCase {
    func testCandidatesRequireExactGameAndEndedWindowsProcess() {
        let processList = #"""
        100 C:\Program Files (x86)\Steam\Steam.exe -silent
        101 C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe
        200 Z:\runtime\gameoverlayui64.exe -pid 1408 -gameid 4059020
        201 Z:\runtime\gameoverlayui64.exe -pid 1409 -gameid 4059020
        202 Z:\runtime\gameoverlayui64.exe -pid 1408 -gameid 1619520
        203 Z:\runtime\steamerrorreporter64.exe -pid=1408 -gameid=4059020
        204 Z:\runtime\steamerrorreporter64.exe -pid=1408 -gameid=1619520
        """#

        XCTAssertEqual(
            GameSessionArtifactCleaner.candidates(
                in: processList,
                appID: "4059020",
                endedWindowsProcessIDs: [1408]
            ),
            [
                GameSessionArtifactCandidate(hostProcessID: 200, kind: .gameOverlay),
                GameSessionArtifactCandidate(hostProcessID: 203, kind: .steamErrorReporter)
            ]
        )
    }

    func testCleanerTerminatesOnlyRegressionArtifacts() async {
        let runner = ArtifactCleanerRunner(
            processList: #"""
            200 Z:\runtime\gameoverlayui64.exe -pid 1408 -gameid 4059020
            201 Z:\runtime\gameoverlayui64.exe -pid 1409 -gameid 4059020
            """#,
            openFiles: [
                200: "n/Applications/Regression.app/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so\n",
                201: "n/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/wine/ntdll.so\n"
            ]
        )
        let cleaner = GameSessionArtifactCleaner(runner: runner)

        let issues = await cleaner.clean(
            appID: "4059020",
            backend: .regression,
            endedWindowsProcessIDs: [1408, 1409]
        )

        XCTAssertTrue(issues.isEmpty)
        let terminatedProcessIDs = await runner.terminatedProcessIDs()
        XCTAssertEqual(terminatedProcessIDs, [200])
    }

    func testCleanerDoesNothingForComparisonBackend() async {
        let runner = ArtifactCleanerRunner(
            processList: "200 gameoverlayui64.exe -pid 1408 -gameid 4059020",
            openFiles: [200: "n/Applications/Regression.app/Contents/SharedSupport/wine-root/ntdll.so\n"]
        )
        let cleaner = GameSessionArtifactCleaner(runner: runner)

        let issues = await cleaner.clean(
            appID: "4059020",
            backend: .crossOver,
            endedWindowsProcessIDs: [1408]
        )

        XCTAssertTrue(issues.isEmpty)
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [])
    }
}

private actor ArtifactCleanerRunner: ProcessRunning {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let processList: String
    private let openFiles: [Int32: String]
    private var calls: [Invocation] = []

    init(processList: String, openFiles: [Int32: String]) {
        self.processList = processList
        self.openFiles = openFiles
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult {
        calls.append(Invocation(executable: executableURL.path, arguments: arguments))
        switch executableURL.path {
        case "/bin/ps":
            return ProcessResult(exitCode: 0, standardOutput: processList, standardError: "")
        case "/usr/sbin/lsof":
            guard let rawPID = arguments.last, let pid = Int32(rawPID) else {
                return ProcessResult(exitCode: 1, standardOutput: "", standardError: "PID inválido")
            }
            return ProcessResult(
                exitCode: openFiles[pid] == nil ? 1 : 0,
                standardOutput: openFiles[pid] ?? "",
                standardError: ""
            )
        case "/bin/kill":
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        default:
            return ProcessResult(exitCode: 127, standardOutput: "", standardError: "inesperado")
        }
    }

    func terminatedProcessIDs() -> [Int32] {
        calls.compactMap { invocation in
            guard invocation.executable == "/bin/kill",
                  invocation.arguments.count == 2 else { return nil }
            return Int32(invocation.arguments[1])
        }
    }

    func invocations() -> [Invocation] {
        calls
    }
}
