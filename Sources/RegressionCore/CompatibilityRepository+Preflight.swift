import CryptoKit
import Foundation

extension CompatibilityRepository {
    public func recordPreflight(
        _ report: GameTestPreflightReport,
        forRunID runID: UUID
    ) throws {
        try ensurePrepared()
        guard report.protocolVersion == GameTestPreflightReport.protocolVersion else {
            throw RegressionCoreError.invalidEvidence(
                "la versión del protocolo de preparación no está soportada"
            )
        }
        guard report.hasCompleteCheckSet else {
            throw RegressionCoreError.invalidEvidence(
                "la preparación no contiene todas las comprobaciones del protocolo"
            )
        }
        guard let appID = report.appID else {
            throw RegressionCoreError.invalidEvidence(
                "una preparación vinculada a ejecución necesita un Steam App ID"
            )
        }
        let matchingRuns = try scalarInt(
            "SELECT COUNT(*) FROM runs WHERE id=? AND app_id=? AND backend=?;",
            bindings: [runID.uuidString, appID, report.backend.rawValue]
        )
        guard matchingRuns == 1 else {
            throw RegressionCoreError.invalidEvidence(
                "la preparación no coincide con la ejecución exacta"
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reportData = try encoder.encode(report)
        let fingerprint = SHA256.hash(data: reportData)
            .map { String(format: "%02x", $0) }
            .joined()

        try execute(
            """
            INSERT INTO run_preflight_reports(
                run_id, protocol_version, status, blocker_count, warning_count,
                report_json, report_fingerprint, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                runID.uuidString,
                report.protocolVersion,
                report.status.rawValue,
                report.blockerCount,
                report.warningCount,
                String(decoding: reportData, as: UTF8.self),
                fingerprint,
                dateFormatter.string(from: report.checkedAt),
            ]
        )
    }

    public func preflightSnapshots(limit: Int = 100_000) throws -> [RunPreflightSnapshot] {
        try ensurePrepared()
        let decoder = JSONDecoder()
        return try query(
            """
            SELECT p.run_id, p.report_fingerprint, p.report_json,
                   r.app_id, r.backend, p.protocol_version, p.status,
                   p.blocker_count, p.warning_count
            FROM run_preflight_reports p
            JOIN runs r ON r.id=p.run_id
            ORDER BY p.created_at DESC
            LIMIT ?;
            """,
            bindings: [max(1, limit)]
        ) { statement in
            guard
                let runID = UUID(uuidString: Self.text(statement, 0)),
                let reportData = Self.text(statement, 2).data(using: .utf8),
                let report = try? decoder.decode(GameTestPreflightReport.self, from: reportData),
                report.appID == Self.text(statement, 3),
                report.backend.rawValue == Self.text(statement, 4),
                report.protocolVersion == Self.optionalInt(statement, 5),
                report.status.rawValue == Self.text(statement, 6),
                report.blockerCount == Self.optionalInt(statement, 7),
                report.warningCount == Self.optionalInt(statement, 8),
                report.hasCompleteCheckSet
            else { return nil }

            let expectedFingerprint = SHA256.hash(data: reportData)
                .map { String(format: "%02x", $0) }
                .joined()
            let storedFingerprint = Self.text(statement, 1)
            guard expectedFingerprint == storedFingerprint else { return nil }
            return RunPreflightSnapshot(
                runID: runID,
                reportFingerprint: storedFingerprint,
                report: report
            )
        }
    }

    func validatePreflightData() throws {
        let count = try scalarInt("SELECT COUNT(*) FROM run_preflight_reports;")
        guard count > 0 else { return }
        let decodedCount = try preflightSnapshots(limit: count).count
        guard decodedCount == count else {
            throw RegressionCoreError.database(
                "Hay diagnósticos de preparación dañados o vinculados a otra ejecución"
            )
        }
    }
}
