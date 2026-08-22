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
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "1154030")?.sourceRunID,
            UUID(uuidString: "228467BB-AECE-40EF-8FE5-E739250AA859")
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "1619520")?.sourceRunID,
            UUID(uuidString: "8EB67186-3D63-4C29-9535-BFC1BAB0A52B")
        )
        XCTAssertEqual(
            VerifiedGameCatalog.certification(for: "4059020")?.sourceRunID,
            UUID(uuidString: "EE1C5A66-1AAA-4594-B30D-1E8ECFA5A27B")
        )
        let borderlands = VerifiedGameCatalog.certification(for: "1285190")
        XCTAssertEqual(borderlands?.gameName, "Borderlands® 4")
        XCTAssertEqual(
            borderlands?.sourceObservationID,
            UUID(uuidString: "1BDCD9E2-D5F1-4C30-BBDA-43B0E5B3BBCA")
        )
        XCTAssertEqual(
            borderlands?.configurationFingerprint,
            "a2ec1490e641083b69d63e39f5d013a84760ccf50ca4fb8333b2843f191feeec"
        )
        XCTAssertEqual(
            borderlands?.engineFingerprint,
            "d7172135a42000c3c4f672663500351f27df9b89bea0d76551dc79be828b95d0"
        )
        XCTAssertEqual(VerifiedGameCatalog.revision, "2026-08-19.2")
        XCTAssertNil(VerifiedGameCatalog.certification(for: "999999999"))
    }

    /// Cursemark quedó blindado por la corrección general del contexto OpenGL core
    /// forward-compatible y por los stubs GL acotados a la familia HashLink, no por un perfil
    /// propio. Un perfil por ejecutable volvería a esconder la clase de fallo detrás de un juego
    /// concreto, que es exactamente lo que la corrección eliminó.
    func testCursemarkIsCertifiedWithoutAnExecutableProfile() {
        let cursemark = VerifiedGameCatalog.certification(for: "3219180")
        XCTAssertEqual(cursemark?.gameName, "Cursemark")
        XCTAssertEqual(cursemark?.backend, .regression)
        XCTAssertEqual(cursemark?.evidence, "docs/games/cursemark.md")
        XCTAssertEqual(
            cursemark?.sourceRunID,
            UUID(uuidString: "2798D808-2007-4C66-ADC9-D5E4A3AB1A11")
        )
        XCTAssertTrue(
            GameRuntimeProfileCatalog.all.allSatisfy { $0.appID != "3219180" },
            "Cursemark no puede recibir un perfil por ejecutable: su corrección es general."
        )
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
        print("Regression:", snapshot.regression.healthDetail)
        XCTAssertNil(snapshot.crossOver)
        XCTAssertNil(snapshot.crossOverIssue)
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

    /// TMNT es FNA, no Unreal, pero embarca el mismo EOSSDK: el aislamiento se activa por el
    /// basename exacto del proceso y jamás de forma global, para que ningún otro juego con
    /// EOSSDK pierda su overlay por arrastre.
    func testTMNTCompiledProfileIsolatesTheOverlayOnlyInsideItsOwnProcess() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "1361510", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "tmnt-shredders-revenge.fna-d3d11-dual-overlay-isolation")
        XCTAssertEqual(profile.executable, "tmnt.exe")
        XCTAssertEqual(profile.configurationValues["profile.scope"], "exact-process")
        XCTAssertEqual(profile.configurationValues["profile.engine.family"], "fna")
        XCTAssertEqual(
            profile.configurationValues["profile.dll.disabled"],
            "eosovh-win64-shipping"
        )
        XCTAssertEqual(
            profile.configurationValues["profile.dll.policy"],
            "disabled-only-in-matched-process"
        )
        // La receta no puede colarse como global: nadie más comparte ese basename.
        XCTAssertEqual(
            GameRuntimeProfileCatalog.all.filter { $0.executable == "tmnt.exe" }.count,
            1
        )
    }

    func testTitanQuest2CompiledProfileIsExactAndRegressionOnly() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "1154030", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "titan-quest-2.apple-gptk-4.0b2-steam-shipping")
        XCTAssertEqual(profile.revision, 9)
        XCTAssertEqual(profile.executable, "tq2-win64-shipping.exe")
        XCTAssertEqual(profile.configurationValues["profile.revision"], "9")
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
        XCTAssertTrue(
            GameRuntimeProfileCatalog.requiresAppleGPTK(
                for: "1154030",
                backend: .regression
            )
        )
        XCTAssertFalse(
            GameRuntimeProfileCatalog.requiresAppleGPTK(
                for: "619820",
                backend: .regression
            )
        )

        let unrelated = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "619820", backend: .regression)
        )
        XCTAssertFalse(unrelated.requiresActiveSteamClient)
        XCTAssertNil(unrelated.configurationValues["profile.launcher"])
        XCTAssertNil(unrelated.configurationValues["profile.router.contract"])
    }

    func testCompiledProfileMetadataMatchesItsAuthoritativeFields() {
        for profile in GameRuntimeProfileCatalog.all {
            XCTAssertEqual(
                profile.configurationValues["profile.id"],
                profile.identifier,
                "Profile ID metadata drifted for Steam App \(profile.appID)"
            )
            XCTAssertEqual(
                profile.configurationValues["profile.revision"],
                String(profile.revision),
                "Profile revision metadata drifted for Steam App \(profile.appID)"
            )
            XCTAssertEqual(
                profile.configurationValues["profile.executable"],
                profile.executable,
                "Profile executable metadata drifted for Steam App \(profile.appID)"
            )
        }
    }

    func testCompiledProfileInitializerRejectsContradictoryIdentityMetadata() {
        let profile = CompiledGameRuntimeProfile(
            appID: "1154030",
            identifier: "authoritative-profile",
            revision: 9,
            executable: "authoritative.exe",
            configurationValues: [
                "profile.id": "hostile-profile",
                "profile.revision": "7",
                "profile.executable": "hostile.exe",
                "profile.scope": "exact-process"
            ]
        )

        XCTAssertEqual(profile.configurationValues["profile.id"], "authoritative-profile")
        XCTAssertEqual(profile.configurationValues["profile.revision"], "9")
        XCTAssertEqual(profile.configurationValues["profile.executable"], "authoritative.exe")
        XCTAssertEqual(profile.configurationValues["profile.scope"], "exact-process")
    }

    func testAppleGPTKRequirementDistinguishesProtectedLegacyGeneration() {
        for appID in ["219990", "4570720", "2054970", "1004640"] {
            XCTAssertEqual(
                GameRuntimeProfileCatalog.requiredAppleGPTKVersion(
                    for: appID,
                    backend: .regression
                ),
                .version3
            )
        }
    }

    func testAppleGPTKRequirementUsesDeclaredCurrentProfileGeneration() {
        for appID in ["1154030", "1285190"] {
            XCTAssertEqual(
                GameRuntimeProfileCatalog.requiredAppleGPTKVersion(
                    for: appID,
                    backend: .regression
                ),
                .version4Beta2
            )
        }
    }

    func testAppleGPTKBooleanRequirementDerivesFromVersionMetadata() {
        XCTAssertTrue(
            GameRuntimeProfileCatalog.requiresAppleGPTK(
                for: "219990",
                backend: .regression
            )
        )
    }

    func testAppleGPTKRequirementIsNormalizedRegressionOnlyAndFailClosed() {
        XCTAssertEqual(
            GameRuntimeProfileCatalog.requiredAppleGPTKVersion(
                for: "000219990",
                backend: .regression
            ),
            .version3
        )
        XCTAssertNil(
            GameRuntimeProfileCatalog.requiredAppleGPTKVersion(
                for: "219990",
                backend: .crossOver
            )
        )
        XCTAssertNil(
            GameRuntimeProfileCatalog.requiredAppleGPTKVersion(
                for: "999999",
                backend: .regression
            )
        )
        XCTAssertFalse(
            GameRuntimeProfileCatalog.requiresAppleGPTK(
                for: "999999",
                backend: .regression
            )
        )
    }

    func testBorderlands4CompiledProfileIsExactAndRegressionOnly() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "1285190", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "borderlands-4.apple-gptk-linux-uname")
        XCTAssertEqual(profile.revision, 1)
        XCTAssertEqual(profile.executable, "borderlands4.exe")
        XCTAssertTrue(profile.requiresActiveSteamClient)
        XCTAssertEqual(profile.configurationValues["profile.scope"], "exact-app-process")
        XCTAssertEqual(profile.configurationValues["profile.engine.family"], "unreal")
        XCTAssertEqual(profile.configurationValues["profile.graphics.api"], "d3d12")
        XCTAssertEqual(profile.configurationValues["profile.graphics.backend"], "d3dmetal")
        XCTAssertEqual(profile.configurationValues["profile.graphics.route"], "complete")
        XCTAssertEqual(
            profile.configurationValues["profile.abi.translation"],
            "linux-x86_64-uname-sigsys-v1"
        )
        XCTAssertEqual(
            profile.configurationValues["profile.abi.detector"],
            "unix-dispatcher-syscall-63-opcode-0f05"
        )
        XCTAssertEqual(
            profile.configurationValues["profile.abi.scope"],
            "exact-borderlands4-process-macos-sigsys-only"
        )
        XCTAssertEqual(profile.configurationValues["profile.component"], "apple-gptk")
        XCTAssertEqual(profile.configurationValues["profile.component.version"], "4.0b2")
        XCTAssertEqual(profile.configurationValues["profile.component.repair"], "manifest-verified")
        XCTAssertEqual(
            profile.configurationValues["profile.component.distribution"],
            "external-apple-authorized"
        )
        XCTAssertEqual(profile.configurationValues["profile.launcher.entrypoints"], "regression,steam")
        XCTAssertEqual(
            profile.configurationValues["profile.router.contract"],
            "compiled-exact-process-d3dmetal-and-linux-abi-v1"
        )
        XCTAssertNil(GameRuntimeProfileCatalog.profile(for: "1285190", backend: .crossOver))

        let unrelated = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "619820", backend: .regression)
        )
        XCTAssertNil(unrelated.configurationValues["profile.abi.translation"])
        XCTAssertNil(unrelated.configurationValues["profile.component.distribution"])
    }

    func testMacOSLinuxUnamePatchIsNarrowAndContainsNoDiagnostics() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = repositoryRoot
            .appendingPathComponent("patches/wine-26.3.0-macos-linux-uname-sigsys.patch")
        let contents = try String(contentsOf: patchURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("is_inside_syscall( RSP_sig(ucontext) )"))
        XCTAssertTrue(contents.contains("regression_linux_uname_enabled &&"))
        XCTAssertTrue(contents.contains("RAX_sig(ucontext) == 63"))
        XCTAssertTrue(contents.contains("[-2] == 0x0f"))
        XCTAssertTrue(contents.contains("[-1] == 0x05"))
        XCTAssertTrue(contents.contains("LINUX_UTSNAME_FIELD_LENGTH 65"))
        XCTAssertTrue(contents.contains("char domainname[LINUX_UTSNAME_FIELD_LENGTH]"))
        XCTAssertTrue(contents.contains("\"Linux\""))
        XCTAssertTrue(contents.contains("\"x86_64\""))
        XCTAssertTrue(contents.contains("REGRESSION_LINUX_UNAME_SYSCALL"))
        XCTAssertTrue(contents.contains("unsetenv( \"REGRESSION_LINUX_UNAME_SYSCALL\" )"))
        XCTAssertTrue(contents.contains("regression_executable_is( \"borderlands4.exe\" )"))
        XCTAssertTrue(contents.contains("borderlands-4-linux-uname@1"))
        XCTAssertFalse(contents.contains("DEBUG-BL4-SIGSYS"))
        XCTAssertFalse(contents.contains("WINEDEBUG=+seh"))
    }

    func testExternalAppleRoutesRemainExactAndComponentVerified() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let launcherURL = repositoryRoot.appendingPathComponent("Scripts/regression-engine.sh")
        let launcherContents = try String(contentsOf: launcherURL, encoding: .utf8)
        let catalogBasenames = GameRuntimeProfileCatalog.externalAppleGPTKRouteBasenames
        let normalizedCatalogBasenames = catalogBasenames.map { $0.lowercased() }.sorted()
        let expectedBasenames = [
            "grim dawn.exe",
            "dsclient-win64-shipping.exe",
            "dd2.exe",
            "fft_enhanced.exe",
            "tq2-win64-shipping.exe",
            "borderlands4.exe",
            "dragonkinthebanished-win64-shipping.exe",
        ]

        let patchURL = repositoryRoot
            .appendingPathComponent("patches/wine-26.3.0-per-process-graphics-routing.patch")
        let patchContents = try String(contentsOf: patchURL, encoding: .utf8)
        let failClosedFunction = try XCTUnwrap(
            patchContents
                .components(separatedBy: "static int regression_executable_requires_external_gptk(void)")
                .dropFirst()
                .first?
                .components(separatedBy: "+}")
                .first
        )
        let patchCallPrefix = "regression_executable_is( \""
        let patchBasenames = failClosedFunction.split(separator: "\n").compactMap { line -> String? in
            guard let prefixRange = line.range(of: patchCallPrefix) else {
                return nil
            }
            return String(line[prefixRange.upperBound...].prefix { $0 != "\"" })
        }
        let normalizedPatchBasenames = patchBasenames.map { $0.lowercased() }.sorted()

        XCTAssertFalse(catalogBasenames.isEmpty)
        XCTAssertEqual(Set(normalizedCatalogBasenames).count, catalogBasenames.count)
        XCTAssertEqual(normalizedCatalogBasenames, expectedBasenames.sorted())
        XCTAssertEqual(normalizedPatchBasenames, normalizedCatalogBasenames)
        for basename in expectedBasenames {
            XCTAssertTrue(
                launcherContents.localizedCaseInsensitiveContains(
                    "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=\(basename)"
                )
            )
        }
        XCTAssertEqual(
            launcherContents.components(separatedBy: "$component/3.0/wine").count - 1,
            4
        )
        // Tres rutas compiladas a 4.0b2 más la que emite el detector por evidencia.
        XCTAssertEqual(
            launcherContents.components(separatedBy: "$component/4.0b2/wine").count - 1,
            4
        )
        // El detector solo puede añadir juegos nuevos: nunca reasigna una ruta compilada,
        // que es lo que mantiene a DragonSword en GPTK 3.0 y a los certificados intactos.
        XCTAssertTrue(launcherContents.contains("d3d12-metal-routes"))
        XCTAssertTrue(
            launcherContents.contains("[[ \"$routed_basenames\" != *\"|$basename_candidate|\"* ]] || continue")
        )
        XCTAssertTrue(launcherContents.contains("prepare_external_apple_gptk_routes"))
        XCTAssertTrue(launcherContents.contains("REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT=\"$count\""))
        XCTAssertTrue(launcherContents.contains("--component 3.0 --verify-only"))
        XCTAssertTrue(launcherContents.contains("--component 4.0b2 --verify-only"))
        XCTAssertFalse(launcherContents.contains("[[ -f \"$tq2_shipping\" || -f \"$borderlands_shipping\" ]] || return 0"))
        XCTAssertFalse(launcherContents.contains("if [[ -f \"$tq2_shipping\" ]]"))
        XCTAssertFalse(launcherContents.contains("if [[ -f \"$borderlands_shipping\" ]]"))
        XCTAssertFalse(launcherContents.contains("WINEDLLOVERRIDES=\"d3d12"))
        XCTAssertFalse(launcherContents.contains("REGRESSION_DEBUG_BORDERLANDS4"))
    }

    func testExternalAppleRouteFailsClosedInsideWineWithoutVerifiedEnvironmentRoute() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = repositoryRoot
            .appendingPathComponent("patches/wine-26.3.0-per-process-graphics-routing.patch")
        let contents = try String(contentsOf: patchURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("regression_executable_requires_external_gptk"))
        XCTAssertTrue(contents.contains("REGRESSION_EXTERNAL_D3DMETAL_ROUTE_%u_EXECUTABLE"))
        XCTAssertTrue(contents.contains("REGRESSION_EXTERNAL_D3DMETAL_ROUTE_%u_WINE_ROOT"))
        XCTAssertFalse(contents.contains("REGRESSION_EXTERNAL_D3DMETAL_EXECUTABLE"))
        XCTAssertFalse(contents.contains("REGRESSION_EXTERNAL_D3DMETAL_WINE_ROOT"))
        XCTAssertTrue(contents.contains("external D3DMetal component is unavailable or unauthorized"))
        XCTAssertTrue(contents.contains("exit( 126 )"))
        XCTAssertFalse(contents.contains("regression_builtin_external_d3dmetal_root"))
    }

    func testHistoricalAppleGPTK3ProfilesUseExternalRoutesAndFailClosedWhenUnavailable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = repositoryRoot
            .appendingPathComponent("patches/wine-26.3.0-per-process-graphics-routing.patch")
        let contents = try String(contentsOf: patchURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("regression_executable_requires_external_gptk"))
        XCTAssertTrue(contents.contains("regression_external_d3dmetal_root"))
        XCTAssertTrue(contents.contains("external D3DMetal component is unavailable or unauthorized"))
        XCTAssertTrue(contents.contains("regression_executable_is( \"grim dawn.exe\" )"))
        XCTAssertTrue(contents.contains("regression_executable_is( \"dd2.exe\" )"))
        XCTAssertTrue(contents.contains("regression_executable_is( \"dsclient-win64-shipping.exe\" )"))
        XCTAssertTrue(contents.contains("regression_executable_is( \"fft_enhanced.exe\" )"))
        XCTAssertFalse(contents.contains("REGRESSION_INTERNAL_GPTK_3_0_VERIFIED"))
        XCTAssertFalse(contents.contains("regression_internal_gptk_3_0_profile_suffix"))
        XCTAssertTrue(contents.contains("backend = \"external-d3dmetal\""))
        XCTAssertTrue(contents.contains("exit( 126 )"))
        XCTAssertFalse(contents.contains("REGRESSION_INTERNAL_GPTK_2_1_VERIFIED"))
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
        let endedAt = Date()
        try await repository.markProcessEnded(
            id: context.id,
            processID: 42,
            endedAt: endedAt,
            exitCode: 0
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: endedAt,
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
        XCTAssertTrue(details.isEmpty, "El historial CrossOver no pertenece a la vista pública.")
        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.runCount, 1)
        let profiles = try await repository.compatibilityProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.backend, .regression)
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
        XCTAssertFalse(
            exported.contains("visualInspection"),
            "La evidencia visual histórica de CrossOver no puede salir en el export público."
        )
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
