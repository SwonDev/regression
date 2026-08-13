import Foundation

struct CrossOverUpdateStatus: Equatable, Sendable {
    let installedVersion: String
    let availableVersion: String?
    let updateAvailable: Bool
    let automaticChecksEnabled: Bool
    let automaticInstallationEnabled: Bool
    let checkedAt: Date

    init(
        installedVersion: String,
        availableVersion: String?,
        updateAvailable: Bool,
        automaticChecksEnabled: Bool,
        automaticInstallationEnabled: Bool,
        checkedAt: Date = Date()
    ) {
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.updateAvailable = updateAvailable
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticInstallationEnabled = automaticInstallationEnabled
        self.checkedAt = checkedAt
    }
}

/// Adaptador heredado, conservado para decodificar estado antiguo sin crear ninguna consulta.
/// Regression no inspecciona ni actualiza productos externos.
actor CrossOverUpdateChecker {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func check(_ installation: CrossOverInstallation) -> CrossOverUpdateStatus {
        CrossOverUpdateStatus(
            installedVersion: installation.version,
            availableVersion: nil,
            updateAvailable: false,
            automaticChecksEnabled: false,
            automaticInstallationEnabled: false,
            checkedAt: now()
        )
    }
}
