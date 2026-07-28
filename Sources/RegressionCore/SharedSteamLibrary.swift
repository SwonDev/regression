import Foundation

public enum SharedLibraryStatus: Equatable, Sendable {
    case notConfigured
    case ready
    case blocked(String)
}

public struct SharedLibraryAssessment: Equatable, Sendable {
    public let status: SharedLibraryStatus
    public let regressionSteamAppsURL: URL
    public let crossOverSteamAppsURL: URL
    public let onlyInRegression: [String]
    public let onlyInCrossOver: [String]

    public init(
        status: SharedLibraryStatus,
        regressionSteamAppsURL: URL,
        crossOverSteamAppsURL: URL,
        onlyInRegression: [String],
        onlyInCrossOver: [String]
    ) {
        self.status = status
        self.regressionSteamAppsURL = regressionSteamAppsURL
        self.crossOverSteamAppsURL = crossOverSteamAppsURL
        self.onlyInRegression = onlyInRegression
        self.onlyInCrossOver = onlyInCrossOver
    }
}

public actor SharedSteamLibraryManager {
    private let fileManager: FileManager
    private let backupRootURL: URL

    public init(fileManager: FileManager = .default, backupRootURL: URL) {
        self.fileManager = fileManager
        self.backupRootURL = backupRootURL
    }

    public func assess(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation
    ) -> SharedLibraryAssessment {
        let regressionSteamApps = regression.steamRootURL.appendingPathComponent("steamapps", isDirectory: true)
        let crossOverSteamApps = crossOver.steamRootURL.appendingPathComponent("steamapps", isDirectory: true)

        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: regressionSteamApps.path) {
            let resolved: URL
            if destination.hasPrefix("/") {
                resolved = URL(fileURLWithPath: destination)
            } else {
                resolved = regressionSteamApps.deletingLastPathComponent().appendingPathComponent(destination)
            }
            let ready = resolved.standardizedFileURL.resolvingSymlinksInPath()
                == crossOverSteamApps.standardizedFileURL.resolvingSymlinksInPath()
            return SharedLibraryAssessment(
                status: ready ? .ready : .blocked("steamapps ya apunta a otra ubicación"),
                regressionSteamAppsURL: regressionSteamApps,
                crossOverSteamAppsURL: crossOverSteamApps,
                onlyInRegression: [],
                onlyInCrossOver: []
            )
        }

        guard fileManager.fileExists(atPath: crossOverSteamApps.path) else {
            return SharedLibraryAssessment(
                status: .blocked("CrossOver no contiene una carpeta steamapps"),
                regressionSteamAppsURL: regressionSteamApps,
                crossOverSteamAppsURL: crossOverSteamApps,
                onlyInRegression: [],
                onlyInCrossOver: []
            )
        }

        let regressionIDs = Set(SteamManifestParser.games(in: regression.steamRootURL, backend: .regression).map(\.appID))
        let crossOverIDs = Set(SteamManifestParser.games(in: crossOver.steamRootURL, backend: .crossOver).map(\.appID))
        return SharedLibraryAssessment(
            status: .notConfigured,
            regressionSteamAppsURL: regressionSteamApps,
            crossOverSteamAppsURL: crossOverSteamApps,
            onlyInRegression: regressionIDs.subtracting(crossOverIDs).sorted(),
            onlyInCrossOver: crossOverIDs.subtracting(regressionIDs).sorted()
        )
    }

    @discardableResult
    public func configure(
        regression: RegressionInstallation,
        crossOver: CrossOverInstallation,
        runningState: RunningBackendState
    ) throws -> URL {
        guard !runningState.crossOverIsRunning, !runningState.regressionIsRunning else {
            throw RegressionCoreError.unsafeLibraryState("Steam debe estar completamente cerrado")
        }
        let assessment = assess(regression: regression, crossOver: crossOver)
        if case .ready = assessment.status { return assessment.regressionSteamAppsURL }
        if case let .blocked(reason) = assessment.status {
            throw RegressionCoreError.unsafeLibraryState(reason)
        }
        guard assessment.onlyInRegression.isEmpty else {
            throw RegressionCoreError.unsafeLibraryState(
                "Hay juegos instalados solo en Regression: \(assessment.onlyInRegression.joined(separator: ", "))"
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = backupRootURL.appendingPathComponent(
            "steamapps-regression-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try PrivateStorage.ensureDirectory(at: backupRootURL, fileManager: fileManager)

        let sourceExists = fileManager.fileExists(atPath: assessment.regressionSteamAppsURL.path)
        if sourceExists {
            try fileManager.moveItem(at: assessment.regressionSteamAppsURL, to: backupURL)
        }

        var linkCreated = false
        do {
            try fileManager.createSymbolicLink(
                at: assessment.regressionSteamAppsURL,
                withDestinationURL: assessment.crossOverSteamAppsURL
            )
            linkCreated = true
            let receipt = SharedLibraryReceipt(
                configuredAt: Date(),
                regressionSteamApps: PrivacySanitizer.normalizedPath(assessment.regressionSteamAppsURL.path),
                crossOverSteamApps: PrivacySanitizer.normalizedPath(assessment.crossOverSteamAppsURL.path),
                backup: sourceExists ? PrivacySanitizer.normalizedPath(backupURL.path) : nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try PrivateStorage.write(
                encoder.encode(receipt),
                atomicallyTo: backupRootURL.appendingPathComponent("shared-library-receipt.json"),
                fileManager: fileManager
            )
            return assessment.regressionSteamAppsURL
        } catch {
            var rollbackFailures: [String] = []
            if linkCreated {
                do {
                    try fileManager.removeItem(at: assessment.regressionSteamAppsURL)
                } catch {
                    rollbackFailures.append("no se pudo retirar el enlace incompleto: \(error.localizedDescription)")
                }
            }

            if sourceExists {
                let destinationStillExists = fileManager.fileExists(
                    atPath: assessment.regressionSteamAppsURL.path
                ) || (try? fileManager.destinationOfSymbolicLink(
                    atPath: assessment.regressionSteamAppsURL.path
                )) != nil
                if destinationStillExists {
                    rollbackFailures.append("steamapps sigue ocupado y no puede restaurarse la copia")
                } else if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        try fileManager.moveItem(
                            at: backupURL,
                            to: assessment.regressionSteamAppsURL
                        )
                    } catch {
                        rollbackFailures.append("no se pudo restaurar steamapps: \(error.localizedDescription)")
                    }
                } else {
                    rollbackFailures.append("no se encontró la copia temporal de steamapps")
                }
            }

            if !rollbackFailures.isEmpty {
                let original = error.localizedDescription
                throw RegressionCoreError.unsafeLibraryState(
                    "Falló la unificación (\(original)) y el rollback necesita atención: "
                        + rollbackFailures.joined(separator: "; ")
                )
            }
            throw error
        }
    }
}

private struct SharedLibraryReceipt: Codable {
    let configuredAt: Date
    let regressionSteamApps: String
    let crossOverSteamApps: String
    let backup: String?
}
