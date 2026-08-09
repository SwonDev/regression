import Foundation
@testable import RegressionCore
import XCTest

final class RegressionCoreTests: XCTestCase {
    func testSteamGameNameUsesCanonicalFallbackWithoutDiscardingRealNames() {
        XCTAssertEqual(SteamGameName.placeholder(for: "004570720"), "Steam App 4570720")
        XCTAssertEqual(
            SteamGameName.normalized("  DragonSword : Awakening  ", appID: "4570720"),
            "DragonSword : Awakening"
        )
        XCTAssertTrue(SteamGameName.isPlaceholder("steam app 4570720", appID: "4570720"))
        XCTAssertFalse(
            SteamGameName.isPlaceholder("DragonSword : Awakening", appID: "4570720")
        )
    }

    func testVerifiedGameCatalogContainsOnlyUniquePerfectRegressionCertifications() {
        let certifications = VerifiedGameCatalog.all

        XCTAssertEqual(Set(certifications.map(\.appID)).count, certifications.count)
        XCTAssertTrue(certifications.allSatisfy { $0.backend == .regression })
        XCTAssertEqual(VerifiedGameCatalog.certification(for: "1128000")?.gameName, "Cube World")
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "1004640")?.gameName,
            "FINAL FANTASY TACTICS - The Ivalice Chronicles"
        )
        XCTAssertEqual(VerifiedGameCatalog.certification(for: "219990")?.gameName, "Grim Dawn")
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "1903340")?.gameName,
            "Clair Obscur: Expedition 33"
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "4570720")?.gameName,
            "DragonSword : Awakening"
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "1782460")?.gameName,
            "Hell Clock"
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "619820")?.gameName,
            "Heroes of Hammerwatch II"
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "269770")?.gameName,
            "Secrets of Grindea"
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "2142790")?.gameName,
            "Fields of Mistria"
        )
        let forsaken = VerifiedGameCatalog.certification(for: "347940")
        XCTAssertEqual(forsaken?.gameName, "Forsaken Isle")
        XCTAssertEqual(
            forsaken?.sourceObservationID,
            UUID(uuidString: "31104A67-1DE6-4C6D-BE5D-797A60648769")
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "1374490")?.sourceRunID,
            UUID(uuidString: "E5244599-5E9F-4F78-BB9B-00CC781E539E")
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "2617700")?.gameName,
            "Tinkerlands"
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "2350790")?.gameName,
            "Moonlighter 2: The Endless Vault"
        )
        XCTAssertEqual(VerifiedGameCatalog.revision, "2026-08-09.1")
        XCTAssertNil(VerifiedGameCatalog.certification(for: "999999999"))
    }

    func testNewerGlobalRuntimeNeverBecomesEligibleByVersionAlone() {
        let candidate = RuntimeCandidate(
            technologyID: "dxvk",
            appID: nil,
            targetVersion: "3.0.2",
            scope: .globalResearch,
            objective: "Actualizar todo el stack",
            state: .validated,
            sourceURL: URL(string: "https://github.com/doitsujin/dxvk/releases/tag/v3.0.2")!,
            sourceFingerprint: "sha256:test-source",
            sourceVerified: true,
            isIsolated: true,
            rollbackReference: "backups/global",
            baselineEngineFingerprint: "baseline",
            candidateEngineFingerprint: "candidate",
            validationMatrixPassed: true
        )
        let assessment = OptimizationAssessment(
            appID: "219990",
            backend: .regression,
            engineFingerprint: "candidate",
            candidateID: candidate.id,
            state: .bestKnown,
            averageFPS: 120
        )

        let decision = RuntimeSelectionPolicy.promotionDecision(
            for: candidate,
            assessments: [assessment],
            technology: RuntimeTechnologyCatalog.all.first { $0.id == candidate.technologyID }
        )
        XCTAssertFalse(decision.isEligible)
        XCTAssertTrue(decision.blockers.contains { $0.contains("juego concreto") })

        let unknownTechnologyDecision = RuntimeSelectionPolicy.promotionDecision(
            for: candidate,
            assessments: [assessment],
            technology: nil
        )
        XCTAssertFalse(unknownTechnologyDecision.isEligible)
        XCTAssertTrue(
            unknownTechnologyDecision.blockers.contains { $0.contains("catálogo confiable") }
        )
    }

    func testLiveDiscoveryWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["REGRESSION_LIVE_DISCOVERY"] == "1" else {
            throw XCTSkip("Diagnóstico local desactivado")
        }
        let runner = ProcessRunner()
        let discovery = InstallationDiscovery(runner: runner)
        let snapshot = await discovery.discover(
            regressionApplicationURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Regression.app")
        )
        print("CrossOver:", snapshot.crossOver?.version ?? snapshot.crossOverIssue?.message ?? "no detectado")
        print("Botella:", snapshot.crossOver?.bottleName ?? "ninguna")
        print("Regression:", snapshot.regression.healthDetail)
        XCTAssertNotNil(snapshot.crossOver)
        XCTAssertEqual(snapshot.crossOver?.health, .ready)
        XCTAssertEqual(snapshot.regression.health, .ready)
    }

    func testSteamManifestParsing() throws {
        let manifest = #"""
        "AppState"
        {
            "appid" "1128000"
            "name" "Cube World"
            "installdir" "Cube World"
            "SizeOnDisk" "220000000"
        }
        """#
        let game = try XCTUnwrap(SteamManifestParser.parse(
            contents: manifest,
            manifestURL: URL(fileURLWithPath: "/tmp/appmanifest_1128000.acf"),
            backend: .crossOver
        ))
        XCTAssertEqual(game.appID, "1128000")
        XCTAssertEqual(game.name, "Cube World")
        XCTAssertEqual(game.installedBytes, 220_000_000)
    }

    func testSteamManifestRejectsInvalidAppIDAndNegativeSize() throws {
        let invalid = #"""
        "AppState"
        {
            "appid" "٢١٩٩٩٠"
            "name" "Juego no válido"
            "installdir" "Invalid"
        }
        """#
        XCTAssertNil(SteamManifestParser.parse(
            contents: invalid,
            manifestURL: URL(fileURLWithPath: "/tmp/appmanifest_invalid.acf"),
            backend: .regression
        ))

        let negativeSize = #"""
        "AppState"
        {
            "appid" "42"
            "name" "Juego válido"
            "installdir" "Valid"
            "SizeOnDisk" "-1"
        }
        """#
        let game = try XCTUnwrap(SteamManifestParser.parse(
            contents: negativeSize,
            manifestURL: URL(fileURLWithPath: "/tmp/appmanifest_42.acf"),
            backend: .regression
        ))
        XCTAssertNil(game.installedBytes)
    }

    func testSteamManifestDoesNotTreatAnEmptyDownloadAsInstalled() {
        let downloading = #"""
        "AppState"
        {
            "appid" "1623730"
            "StateFlags" "1026"
            "BytesToDownload" "32963904576"
            "BytesDownloaded" "0"
        }
        """#
        XCTAssertEqual(
            SteamManifestParser.installReadiness(in: downloading),
            .inProgress
        )

        let installed = #"""
        "AppState"
        {
            "appid" "1623730"
            "StateFlags" "4"
            "BytesToDownload" "32963904576"
            "BytesDownloaded" "32963904576"
        }
        """#
        XCTAssertEqual(
            SteamManifestParser.installReadiness(in: installed),
            .installed
        )
        XCTAssertEqual(
            SteamManifestParser.installReadiness(in: #""AppState" { "appid" "42" }"#),
            .unknown
        )
    }

    func testManualVerificationEvidenceUsesOneCanonicalMapping() {
        XCTAssertTrue(VerificationEvidence.manualDefault(for: .perfect).isComplete)
        XCTAssertEqual(
            VerificationEvidence.manualDefault(for: .failed).rendering,
            .failed
        )
        XCTAssertEqual(
            VerificationEvidence.manualDefault(for: .playableWithIssues).inputPrecision,
            .notTested
        )
    }

    func testSteamGameProcessLogParsing() throws {
        let line = #"[2026-07-27 08:13:10] AppID 1128000 adding PID 2196 as a tracked process ""C:\Program Files (x86)\Steam\steamapps\common\Cube World\cubeworld.exe"""#
        guard case let .started(_, appID, pid, executable) = SteamGameProcessLogParser.parse(line: line) else {
            return XCTFail("No se reconoció el inicio del proceso")
        }
        XCTAssertEqual(appID, "1128000")
        XCTAssertEqual(pid, 2196)
        XCTAssertEqual(executable, #"C:\Program Files (x86)\Steam\steamapps\common\Cube World\cubeworld.exe"#)
        XCTAssertTrue(SteamGameProcessLogParser.isPrimaryExecutable(executable))

        let ended = "[2026-07-27 08:13:19] AppID 1128000 no longer tracking PID 2196, exit code 0"
        guard case let .ended(_, endAppID, endPID, code) = SteamGameProcessLogParser.parse(line: ended) else {
            return XCTFail("No se reconoció el cierre del proceso")
        }
        XCTAssertEqual(endAppID, appID)
        XCTAssertEqual(endPID, pid)
        XCTAssertEqual(code, 0)
    }

    func testPrivacySanitizerDropsUnknownArgumentsAndURLs() {
        let arguments = [
            "--bottle", "Steam", "--cx-app", #"C:\Program Files (x86)\Steam\steam.exe"#,
            "-applaunch", "219990", "--password", "secreto"
        ]
        XCTAssertEqual(
            PrivacySanitizer.safeArguments(arguments),
            ["--bottle", "Steam", "--cx-app", #"C:\Program Files (x86)\Steam\steam.exe"#, "-applaunch", "219990"]
        )
        let redacted = PrivacySanitizer.redactedLogExcerpt("falló https://example.test/?token=abc")
        XCTAssertFalse(redacted.contains("token=abc"))
    }

    func testProcessInspectorSeparatesBackends() {
        let list = """
          100 /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64-preloader C:\\Steam\\steam.exe
          200 /project/Regression.app/Contents/SharedSupport/wine-root/bin/wine64-preloader C:\\Steam\\Steam.exe
          201 /project/Regression.app/Contents/SharedSupport/wine-root/bin/wine64-preloader C:\\Steam\\steamwebhelper.exe -steampath=C:\\Steam\\steam.exe
          300 /Applications/Steam.app/Contents/MacOS/steam_osx
        """
        let state = ProcessInspector.parseProcessList(list)
        XCTAssertEqual(state.crossOverPIDs, [100])
        XCTAssertEqual(state.regressionPIDs, [200])
        XCTAssertTrue(state.hasConflict)
    }

    func testProcessInspectorFindsDetachedSteamClientWithoutCountingHelpers() {
        let list = """
          410 C:\\Program Files (x86)\\Steam\\Steam.exe
          411 C:\\Program Files (x86)\\Steam\\bin\\cef\\steamwebhelper.exe -steampath=C:\\Program Files (x86)\\Steam\\steam.exe
          412 /Applications/Steam.app/Contents/MacOS/steam_osx
        """

        XCTAssertEqual(ProcessInspector.steamClientProcessIDs(list), [410])
        XCTAssertEqual(
            ProcessInspector.backend(
                fromOpenFileList: "n/Users/test/Regression.app/Contents/SharedSupport/wine-root/lib/wine.dylib"
            ),
            .regression
        )
        XCTAssertEqual(
            ProcessInspector.backend(
                fromOpenFileList: "n/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine.dylib"
            ),
            .crossOver
        )
    }

    func testCrossOverCommandUsesOfficialBottleInterface() {
        let installation = CrossOverInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            version: "26.3",
            build: "39832",
            bottleName: "Steam",
            bottleURL: URL(fileURLWithPath: "/tmp/Bottles/Steam"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/Bottles/Steam/drive_c/Program Files (x86)/Steam/steam.exe"),
            wineCLIURL: URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"),
            bottleCLIURL: URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxbottle"),
            feedURL: nil,
            health: .ready,
            healthDetail: "ok"
        )
        let command = BackendCommandFactory.crossOver(
            installation: installation,
            steamArguments: ["-applaunch", "219990"]
        )
        XCTAssertEqual(command.executableURL, installation.wineCLIURL)
        XCTAssertEqual(
            command.arguments,
            ["--bottle", "Steam", "--cx-app", #"C:\Program Files (x86)\Steam\steam.exe"#, "-applaunch", "219990"]
        )
    }

    func testCrossOverGraphicsBackendUsesStaticBottleConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-crossover-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"""
"OTHER" = "value"
"CX_GRAPHICS_BACKEND" = "d3dmetal"
"""#.utf8).write(to: root.appendingPathComponent("cxbottle.conf"))

        XCTAssertEqual(CrossOverBottleConfiguration.graphicsBackend(at: root), "d3dmetal")
    }

    func testConfigurationDelta() {
        let delta = ConfigurationDiffer.difference(
            before: ["renderer": "d3dmetal", "retina": "n"],
            after: ["renderer": "dxvk", "msync": "1"]
        )
        XCTAssertEqual(delta.added, ["msync": "1"])
        XCTAssertEqual(delta.removed, ["retina": "n"])
        XCTAssertEqual(delta.changed["renderer"]?.before, "d3dmetal")
        XCTAssertEqual(delta.changed["renderer"]?.after, "dxvk")
    }

    func testCompiledProfileIsCapturedOnlyForItsRegressionGame() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-profile-capture-\(UUID().uuidString)")
        let game = SteamGame(
            appID: "619820",
            name: "Heroes of Hammerwatch II",
            installDirectory: "Heroes of Hammerwatch II",
            manifestURL: root.appendingPathComponent("appmanifest_619820.acf"),
            sourceBackend: .regression
        )
        let baseline = ["backend": "regression", "provider.version": "1.7.3"]
        let regression = ConfigurationCollector.snapshot(
            bottleURL: root,
            backend: .regression,
            providerVersion: "1.7.3",
            game: game
        )
        let crossOver = ConfigurationCollector.snapshot(
            bottleURL: root,
            backend: .crossOver,
            providerVersion: "26.3",
            game: game
        )

        XCTAssertEqual(
            regression["profile.id"],
            "heroes-hammerwatch-2.opengl-forward-compatible"
        )
        XCTAssertEqual(regression["profile.opengl.forward-compatible"], "1")
        XCTAssertNil(crossOver["profile.id"])
        XCTAssertNotEqual(
            ConfigurationCollector.engineFingerprint(for: baseline),
            ConfigurationCollector.engineFingerprint(for: regression)
        )
        XCTAssertEqual(
            ConfigurationCollector.engineValues(from: regression)["profile.scope"],
            "exact-process"
        )
        XCTAssertNil(
            GameRuntimeProfileCatalog.profile(for: "999999", backend: .regression)
        )
    }

    func testTitanQuest2CompiledProfileIsExactAndRegressionOnly() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "1154030", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "titan-quest-2.apple-gptk-4.0b2-steam-shipping")
        XCTAssertEqual(profile.revision, 9)
        XCTAssertEqual(profile.executable, "tq2-win64-shipping.exe")
        XCTAssertTrue(profile.requiresActiveSteamClient)
        XCTAssertEqual(profile.configurationValues["profile.scope"], "exact-app-process")
        XCTAssertEqual(profile.configurationValues["profile.graphics.backend"], "d3dmetal")
        XCTAssertEqual(profile.configurationValues["profile.graphics.route"], "complete")
        XCTAssertEqual(
            profile.configurationValues["profile.router.contract"],
            "compiled-wineserver-startup-image-and-external-d3dmetal-v7"
        )
        XCTAssertEqual(profile.configurationValues["profile.launcher"], "steam-bootstrap")
        XCTAssertEqual(profile.configurationValues["profile.launcher.entrypoints"], "regression,steam")
        XCTAssertEqual(profile.configurationValues["profile.bootstrap.executable"], "tq2.exe")
        XCTAssertEqual(profile.configurationValues["profile.bootstrap.action"], "redirect-to-shipping")
        XCTAssertEqual(profile.configurationValues["profile.component.id"], "apple-gptk")
        XCTAssertEqual(profile.configurationValues["profile.component.version"], "4.0b2")
        XCTAssertEqual(profile.configurationValues["profile.component.repair"], "manifest-verified")
        XCTAssertNil(
            GameRuntimeProfileCatalog.profile(for: "1154030", backend: .crossOver)
        )

        let unrelated = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "619820", backend: .regression)
        )
        XCTAssertFalse(unrelated.requiresActiveSteamClient)
        XCTAssertNil(unrelated.configurationValues["profile.launcher"])
        XCTAssertNil(unrelated.configurationValues["profile.router.contract"])
    }

    func testForsakenIsleWindowsMediaProfileIsExactAndRegressionOnly() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "347940", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "windows-media-gstreamer-autodetect")
        XCTAssertEqual(profile.revision, 1)
        XCTAssertEqual(profile.executable, "forsakenisle.exe")
        XCTAssertFalse(profile.requiresActiveSteamClient)
        XCTAssertEqual(profile.configurationValues["profile.scope"], "steam-game-content-tree")
        XCTAssertEqual(profile.configurationValues["profile.media.extensions"], "asf,wma,wmv")
        XCTAssertEqual(profile.configurationValues["profile.media.backend"], "gstreamer-1.24.4")
        XCTAssertEqual(profile.configurationValues["profile.media.decoder"], "ffmpeg-6.1.6-lgpl")
        XCTAssertEqual(
            profile.configurationValues["profile.router.contract"],
            "compiled-bounded-content-scan-v1"
        )
        XCTAssertEqual(profile.configurationValues["profile.launcher.entrypoints"], "regression,steam")
        XCTAssertEqual(profile.configurationValues["profile.component.id"], "windows-media-gstreamer")
        XCTAssertEqual(profile.configurationValues["profile.component.version"], "1")
        XCTAssertEqual(profile.configurationValues["profile.component.repair"], "signed-manifest-link")
        XCTAssertNil(GameRuntimeProfileCatalog.profile(for: "347940", backend: .crossOver))

        let unrelated = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "619820", backend: .regression)
        )
        XCTAssertNil(unrelated.configurationValues["profile.media.decoder"])
        XCTAssertNil(unrelated.configurationValues["profile.component.id"])
    }

    func testGameConfigurationCollectorCapturesGraphicsWithoutPrivateValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-game-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("drive_c/Steam", isDirectory: true)
        let gameRoot = steamRoot.appendingPathComponent("steamapps/common/Test Game", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let settings = """
        resolution = 1920x1080
        fullscreen = true
        textureQuality = high
        password = secreto
        profilePath = C:\\Users\\persona
        """
        try Data(settings.utf8).write(to: gameRoot.appendingPathComponent("graphics-options.ini"))
        let game = SteamGame(
            appID: "42",
            name: "Test Game",
            installDirectory: "Test Game",
            manifestURL: steamRoot.appendingPathComponent("steamapps/appmanifest_42.acf"),
            sourceBackend: .crossOver
        )

        let values = GameConfigurationCollector.snapshot(
            bottleURL: root,
            steamRootURL: steamRoot,
            game: game
        )
        XCTAssertTrue(values.values.contains("1920x1080"))
        XCTAssertTrue(values.values.contains("high"))
        XCTAssertFalse(values.values.contains("secreto"))
        XCTAssertFalse(values.values.contains { $0.contains("persona") })
    }

    func testPrivateStorageUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-private-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateStorage.ensureDirectory(at: root)
        let file = root.appendingPathComponent("technical.log")
        try PrivateStorage.createFile(at: file)

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        ).intValue
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testCompatibilityRepositoryStoresProfilesAndExportsTechnicalDetail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-repository-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let configuration = ["backend": "crossOver", "bottle.WINEMSYNC": "1"]
        let context = RunContext(
            appID: "1128000",
            gameName: "Cube World",
            backend: .crossOver,
            bottleName: "Steam",
            providerVersion: "26.3",
            command: "$HOME/CrossOver/wine",
            arguments: ["-applaunch", "1128000"],
            system: SystemSnapshot(
                macOSVersion: "26.0",
                architecture: "arm64",
                deviceModel: "MacTest",
                displayWidth: 3024,
                displayHeight: 1964,
                displayScale: 2
            ),
            configuration: configuration,
            configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
        )
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 42,
            executable: #"C:\Games\cubeworld.exe"#,
            launchMilliseconds: 750
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: Date(),
            exitCode: 0,
            result: .succeeded,
            afterConfiguration: configuration,
            delta: ConfigurationDiffer.difference(before: configuration, after: configuration)
        )
        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "Render e interacción verificados"
        ))
        let regressionConfiguration = ["backend": "regression", "renderer": "dxvk"]
        try await repository.recordObservation(CompatibilityObservation(
            appID: "1128000",
            gameName: "Cube World",
            backend: .regression,
            providerVersion: "1.1",
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            configurationFingerprint: ConfigurationCollector.fingerprint(regressionConfiguration),
            configuration: regressionConfiguration,
            source: .imported,
            notes: "Confirmación histórica"
        ))

        let details = try await repository.runDetails()
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details.first?.arguments, ["-applaunch", "1128000"])
        XCTAssertEqual(details.first?.configuration["bottle.WINEMSYNC"], "1")
        XCTAssertEqual(details.first?.verification?.verdict, .perfect)
        let profiles = try await repository.compatibilityProfiles()
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.allSatisfy { $0.successfulRuns == 1 })
        XCTAssertTrue(profiles.allSatisfy { $0.perfectRuns == 1 })
        XCTAssertTrue(profiles.allSatisfy { $0.unverifiedRuns == 0 })
        let observations = try await repository.observations()
        XCTAssertEqual(observations.first?.backend, .regression)

        let exportURL = directory.appendingPathComponent("export.json")
        try await repository.exportJSON(to: exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exported.contains("configurationFingerprint"))
        XCTAssertTrue(exported.contains("1128000"))
        XCTAssertTrue(exported.contains("visualInspection"))
        XCTAssertTrue(exported.contains("Confirmación histórica"))
        let databaseMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("compatibility.sqlite").path
            )[.posixPermissions] as? NSNumber
        ).intValue
        let exportMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: exportURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(databaseMode & 0o777, 0o600)
        XCTAssertEqual(exportMode & 0o777, 0o600)
    }
}
