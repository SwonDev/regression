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
        let applications = crossOverApplications()
        guard !applications.isEmpty else {
            return (
                nil,
                InstallationIssue(
                    code: .crossOverNotInstalled,
                    message: "No se encontró CrossOver en las carpetas de aplicaciones.",
                    recoveryAction: "Instalar CrossOver"
                )
            )
        }
        let applicationURL = applications.first(where: hasRequiredCrossOverTools)
            ?? applications[0]

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

        let graphicsBackend = CrossOverBottleConfiguration.graphicsBackend(at: bottleURL)

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
                let isCrossOver = identifier.contains("codeweavers.crossover")
                    || url.lastPathComponent.lowercased().hasPrefix("crossover")
                if isCrossOver {
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

    private func hasRequiredCrossOverTools(_ applicationURL: URL) -> Bool {
        let toolsRoot = applicationURL.appendingPathComponent(
            "Contents/SharedSupport/CrossOver/bin",
            isDirectory: true
        )
        return fileManager.isExecutableFile(atPath: toolsRoot.appendingPathComponent("wine").path)
            && fileManager.isExecutableFile(atPath: toolsRoot.appendingPathComponent("cxbottle").path)
    }

    private static func preferSteamBottle(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftIsSteam = lhs.lastPathComponent.caseInsensitiveCompare("Steam") == .orderedSame
        let rightIsSteam = rhs.lastPathComponent.caseInsensitiveCompare("Steam") == .orderedSame
        if leftIsSteam != rightIsSteam { return leftIsSteam }
        return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
    }
}

enum CrossOverBottleConfiguration {
    static func graphicsBackend(
        at bottleURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let configurationURL = bottleURL.appendingPathComponent("cxbottle.conf")
        guard fileManager.fileExists(atPath: configurationURL.path),
              let contents = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return nil
        }
        let pattern = #"(?m)^\s*"CX_GRAPHICS_BACKEND"\s*=\s*"([^"]+)"\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = expression.firstMatch(in: contents, range: range),
              let valueRange = Range(match.range(at: 1), in: contents) else { return nil }
        let value = contents[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
