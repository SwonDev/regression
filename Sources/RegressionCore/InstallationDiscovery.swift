import Foundation

public actor InstallationDiscovery {
    private let runner: ProcessRunner
    private let fileManager: FileManager

    public init(runner: ProcessRunner, fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func discover(regressionApplicationURL: URL? = nil) async -> InstallationSnapshot {
        let crossOverResult = await discoverCrossOver()
        let regression = discoverRegression(applicationURL: regressionApplicationURL)
        return InstallationSnapshot(
            crossOver: crossOverResult.installation,
            crossOverIssue: crossOverResult.issue,
            regression: regression
        )
    }

    private func discoverCrossOver() async -> (installation: CrossOverInstallation?, issue: InstallationIssue?) {
        guard let applicationURL = crossOverApplications().first else {
            return (
                nil,
                InstallationIssue(
                    code: .crossOverNotInstalled,
                    message: "No se encontró CrossOver en las carpetas de aplicaciones.",
                    recoveryAction: "Instalar CrossOver"
                )
            )
        }

        let bottleRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        let bottleURLs = (try? fileManager.contentsOfDirectory(
            at: bottleRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let steamRelativePath = "drive_c/Program Files (x86)/Steam/steam.exe"
        let steamBottles = bottleURLs.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent(steamRelativePath).path)
        }

        guard let bottleURL = steamBottles.sorted(by: Self.preferSteamBottle).first else {
            let namedSteam = bottleURLs.first { $0.lastPathComponent.caseInsensitiveCompare("Steam") == .orderedSame }
            if namedSteam != nil {
                return (
                    nil,
                    InstallationIssue(
                        code: .steamNotInstalled,
                        message: "La botella Steam existe, pero no contiene steam.exe.",
                        recoveryAction: "Abrir CrossOver"
                    )
                )
            }
            return (
                nil,
                InstallationIssue(
                    code: .steamBottleNotFound,
                    message: "No se encontró ninguna botella de CrossOver con Steam instalado.",
                    recoveryAction: "Instalar Steam en CrossOver"
                )
            )
        }

        let wineCLI = applicationURL.appendingPathComponent(
            "Contents/SharedSupport/CrossOver/bin/wine"
        )
        let bottleCLI = applicationURL.appendingPathComponent(
            "Contents/SharedSupport/CrossOver/bin/cxbottle"
        )
        guard fileManager.isExecutableFile(atPath: wineCLI.path),
              fileManager.isExecutableFile(atPath: bottleCLI.path) else {
            return (
                nil,
                InstallationIssue(
                    code: .bottleDamaged,
                    message: "Faltan las herramientas oficiales de CrossOver.",
                    recoveryAction: "Reinstalar CrossOver"
                )
            )
        }

        let bundle = Bundle(url: applicationURL)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "desconocida"
        let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "desconocida"
        let feed = (bundle?.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))

        let statusResult = try? await runner.run(
            executableURL: bottleCLI,
            arguments: ["--bottle", bottleURL.lastPathComponent, "--status"]
        )
        let statusText = [statusResult?.standardOutput, statusResult?.standardError]
            .compactMap { $0 }
            .joined(separator: "\n")
        let normalizedStatus = statusText.lowercased()
        let health: InstallationHealth
        let healthDetail: String
        if statusResult?.exitCode != 0 {
            health = .damaged
            healthDetail = PrivacySanitizer.redactedLogExcerpt(statusText.isEmpty ? "cxbottle terminó con error" : statusText)
        } else if normalizedStatus.contains("status=uptodate") {
            health = .ready
            healthDetail = "Botella actualizada"
        } else if normalizedStatus.contains("update") {
            health = .updateRequired
            healthDetail = "CrossOver actualizará la botella antes del siguiente inicio"
        } else {
            health = .unknown
            healthDetail = "Estado de botella no concluyente"
        }

        let graphicsBackend = await probeDefaultGraphicsBackend(
            wineCLI: wineCLI,
            bottleName: bottleURL.lastPathComponent
        )

        let installation = CrossOverInstallation(
            applicationURL: applicationURL,
            version: version,
            build: build,
            bottleName: bottleURL.lastPathComponent,
            bottleURL: bottleURL,
            steamExecutableURL: bottleURL.appendingPathComponent(steamRelativePath),
            wineCLIURL: wineCLI,
            bottleCLIURL: bottleCLI,
            feedURL: feed,
            defaultGraphicsBackend: graphicsBackend,
            health: health,
            healthDetail: healthDetail
        )
        return (installation, nil)
    }

    private func probeDefaultGraphicsBackend(wineCLI: URL, bottleName: String) async -> String? {
        let logURL = fileManager.temporaryDirectory
            .appendingPathComponent("regression-crossover-probe-\(UUID().uuidString).log")
        defer { try? fileManager.removeItem(at: logURL) }

        guard let result = try? await runner.run(
            executableURL: wineCLI,
            arguments: [
                "--bottle", bottleName,
                "--no-update",
                "--no-gui",
                "--debugmsg", "+process",
                "--cx-log", logURL.path,
                "--cx-app", #"C:\windows\system32\cmd.exe"#,
                "/c", "exit"
            ]
        ), result.exitCode == 0,
        let log = try? String(contentsOf: logURL, encoding: .utf8)
        else { return nil }

        for line in log.split(whereSeparator: \.isNewline).reversed() {
            let marker = "set_graphics_backend using "
            guard let markerRange = line.range(of: marker) else { continue }
            let suffix = line[markerRange.upperBound...]
            guard let end = suffix.range(of: " as the graphics backend") else { continue }
            let value = suffix[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func discoverRegression(applicationURL: URL?) -> RegressionInstallation {
        let resolvedApplicationURL: URL
        if let applicationURL {
            resolvedApplicationURL = applicationURL
        } else {
            resolvedApplicationURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Regression.app", isDirectory: true)
        }

        let bottle = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Regression/Bottles/Steam", isDirectory: true)
        let steam = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/Steam.exe")
        let modernLauncher = resolvedApplicationURL.appendingPathComponent("Contents/MacOS/regression-engine")
        let legacyLauncher = resolvedApplicationURL.appendingPathComponent("Contents/MacOS/regression")
        let launcher = fileManager.fileExists(atPath: modernLauncher.path) ? modernLauncher : legacyLauncher

        let health: InstallationHealth
        let detail: String
        if !fileManager.fileExists(atPath: steam.path) {
            health = .missing
            detail = "Steam no está instalado en la botella propia"
        } else if !fileManager.isExecutableFile(atPath: launcher.path) {
            health = .damaged
            detail = "Falta el lanzador del motor propio"
        } else {
            health = .ready
            detail = "Motor propio disponible"
        }

        return RegressionInstallation(
            applicationURL: resolvedApplicationURL,
            bottleURL: bottle,
            steamExecutableURL: steam,
            engineLauncherURL: launcher,
            health: health,
            healthDetail: detail
        )
    }

    private func crossOverApplications() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var candidates: [URL] = []

        for root in roots {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let identifier = bundle?.bundleIdentifier?.lowercased() ?? ""
                let hasCLI = fileManager.isExecutableFile(
                    atPath: url.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").path
                )
                if hasCLI && (identifier.contains("codeweavers.crossover") || url.lastPathComponent.lowercased().hasPrefix("crossover")) {
                    candidates.append(url)
                }
            }
        }

        return candidates.sorted { lhs, rhs in
            let left = Bundle(url: lhs)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let right = Bundle(url: rhs)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            return left.compare(right, options: .numeric) == .orderedDescending
        }
    }

    private static func preferSteamBottle(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftIsSteam = lhs.lastPathComponent.caseInsensitiveCompare("Steam") == .orderedSame
        let rightIsSteam = rhs.lastPathComponent.caseInsensitiveCompare("Steam") == .orderedSame
        if leftIsSteam != rightIsSteam { return leftIsSteam }
        return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
    }
}
