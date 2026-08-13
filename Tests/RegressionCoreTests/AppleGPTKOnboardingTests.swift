import CryptoKit
import Foundation
import XCTest

@testable import RegressionCore

final class AppleGPTKOnboardingTests: XCTestCase {
  private let selectedDMG = URL(fileURLWithPath: "/tmp/AppleGPTK-4.0b2.dmg")

  func testComponentCatalogKeepsProtectedAndCurrentGenerationsDistinct() throws {
    let protected = AppleGPTKComponentCatalog.protectedProfiles
    let current = AppleGPTKComponentCatalog.current

    XCTAssertEqual(protected.version, "3.0")
    XCTAssertEqual(protected.minimumMacOSMajorVersion, 14)
    XCTAssertEqual(
      protected.d3dMetalSHA256,
      "05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8"
    )
    XCTAssertEqual(current.version, "4.0b2")
    XCTAssertEqual(current.minimumMacOSMajorVersion, 15)
    XCTAssertNotEqual(protected.d3dMetalSHA256, current.d3dMetalSHA256)
    XCTAssertNil(protected.dmgFileName)
    XCTAssertNil(protected.dmgSHA256)
    XCTAssertNotNil(current.dmgSHA256)
    XCTAssertFalse(protected.supportsDMGOnboarding)
    XCTAssertTrue(current.supportsDMGOnboarding)
    XCTAssertNil(AppleGPTKComponentCatalog.component(version: "2.1"))
  }

  func testProtectedProfilesDescriptorSealsTheUniqueRegularPayload() {
    let root = URL(fileURLWithPath: "/tmp/apple-gptk/../apple-gptk", isDirectory: true)
    let descriptor = AppleGPTKComponentCatalog.protectedProfilesDescriptor(rootURL: root)

    XCTAssertEqual(
      descriptor.identity.componentID,
      AppleGPTKComponentCatalog.protectedProfilesComponentID
    )
    XCTAssertEqual(descriptor.identity.componentVersion, "3.0")
    XCTAssertEqual(descriptor.payloadRootURL, root.standardizedFileURL)
    XCTAssertEqual(descriptor.files.count, 8)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: descriptor.files.map {
        ($0.relativePath, $0.expectedSHA256)
      }),
      [
        "external/D3DMetal.framework/Versions/A/D3DMetal":
          "05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8",
        "external/libd3dshared.dylib":
          "5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995",
        "wine/x86_64-windows/atidxx64.dll":
          "c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7",
        "wine/x86_64-windows/d3d11.dll":
          "7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79",
        "wine/x86_64-windows/d3d12.dll":
          "bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f",
        "wine/x86_64-windows/dxgi.dll":
          "1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561",
        "wine/x86_64-windows/nvapi64.dll":
          "f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc",
        "wine/x86_64-windows/nvngx.dll":
          "d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99",
      ]
    )
  }

  func testProtectedProfilesDescriptorReportsMissingDriftAndSymlinkFailClosed() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-gptk-health-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: container) }
    let root = container.appendingPathComponent("apple_gptk", isDirectory: true)
    let descriptor = AppleGPTKComponentCatalog.protectedProfilesDescriptor(rootURL: root)

    var report = ComponentHealthService.evaluate(descriptor)
    XCTAssertEqual(report.status, .missing)
    XCTAssertEqual(report.issue, .payloadMissing)

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for file in descriptor.files {
      let url = root.appendingPathComponent(file.relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("payload no autorizado".utf8).write(to: url)
    }
    report = ComponentHealthService.evaluate(descriptor)
    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(
      report.issue,
      .payloadDigestMismatch("external/D3DMetal.framework/Versions/A/D3DMetal")
    )

    try FileManager.default.removeItem(at: root)
    let outside = container.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    report = ComponentHealthService.evaluate(descriptor)
    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadIsNotARegularDirectory)
  }

  func testProtectedProfilesHealthIsReadyOnlyWithEveryExactUnixAlias() throws {
    let fixture = try ProtectedProfilesAliasFixture()
    defer { fixture.remove() }
    try fixture.writeAliases()

    let report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: fixture.descriptor()
    )

    XCTAssertEqual(report.status, .ready)
    XCTAssertEqual(report.recovery, .none)
    XCTAssertNil(report.issue)
  }

  func testProtectedProfilesHealthRejectsMissingWrongAndAbsoluteAliasTargets() throws {
    let missing = try ProtectedProfilesAliasFixture()
    defer { missing.remove() }
    try missing.writeAliases(omitting: "dxgi")

    var report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: missing.descriptor()
    )
    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.recovery, .provideUserSource)
    XCTAssertEqual(
      report.issue,
      .payloadEntryMissing("wine/x86_64-unix/dxgi.so")
    )

    let wrong = try ProtectedProfilesAliasFixture()
    defer { wrong.remove() }
    try wrong.writeAliases(overriding: ["d3d12": "../external/libd3dshared.dylib"])
    report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: wrong.descriptor()
    )
    XCTAssertEqual(
      report.issue,
      .payloadDigestMismatch("wine/x86_64-unix/d3d12.so")
    )

    let absolute = try ProtectedProfilesAliasFixture()
    defer { absolute.remove() }
    try absolute.writeAliases(overriding: ["nvngx": "/tmp/libd3dshared.dylib"])
    report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: absolute.descriptor()
    )
    XCTAssertEqual(
      report.issue,
      .payloadDigestMismatch("wine/x86_64-unix/nvngx.so")
    )
  }

  func testProtectedProfilesHealthRejectsRootAndParentDirectorySymlinks() throws {
    let rootFixture = try ProtectedProfilesAliasFixture()
    defer { rootFixture.remove() }
    try rootFixture.writeAliases()
    let movedRoot = rootFixture.container.appendingPathComponent("actual-root", isDirectory: true)
    try FileManager.default.moveItem(at: rootFixture.root, to: movedRoot)
    try FileManager.default.createSymbolicLink(at: rootFixture.root, withDestinationURL: movedRoot)

    var report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: rootFixture.descriptor()
    )
    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadIsNotARegularDirectory)

    let parentFixture = try ProtectedProfilesAliasFixture()
    defer { parentFixture.remove() }
    try parentFixture.writeAliases()
    let wine = parentFixture.root.appendingPathComponent("wine", isDirectory: true)
    let actualWine = parentFixture.root.appendingPathComponent("actual-wine", isDirectory: true)
    try FileManager.default.moveItem(at: wine, to: actualWine)
    try FileManager.default.createSymbolicLink(at: wine, withDestinationURL: actualWine)
    report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: parentFixture.descriptor()
    )
    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(
      report.issue,
      .payloadEntryMissing("wine/x86_64-unix/atidxx64.so")
    )
  }

  func testProtectedProfilesHealthRejectsRootReplacementABAAfterAnchoredFileSet() throws {
    let fixture = try ProtectedProfilesAliasFixture()
    defer { fixture.remove() }
    try fixture.writeAliases()

    let report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: fixture.descriptor()
    ) {
      let moved = fixture.container.appendingPathComponent("moved-root", isDirectory: true)
      try! FileManager.default.moveItem(at: fixture.root, to: moved)
      try! FileManager.default.createDirectory(
        at: fixture.root,
        withIntermediateDirectories: true
      )
      try! FileManager.default.removeItem(at: fixture.root)
      try! FileManager.default.moveItem(at: moved, to: fixture.root)
    }

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadIsNotARegularDirectory)
  }

  func testProtectedProfilesHealthRejectsNestedSubtreeReplacementAfterAnchoredFileSet() throws {
    let fixture = try ProtectedProfilesAliasFixture()
    defer { fixture.remove() }
    try fixture.writeAliases()

    let report = AppleGPTKComponentCatalog.protectedProfilesHealth(
      descriptor: fixture.descriptor()
    ) {
      let sealed = fixture.root.appendingPathComponent("sealed", isDirectory: true)
      let moved = fixture.root.appendingPathComponent("sealed-old", isDirectory: true)
      try! FileManager.default.moveItem(at: sealed, to: moved)
      try! FileManager.default.createDirectory(
        at: sealed.appendingPathComponent("files", isDirectory: true),
        withIntermediateDirectories: true
      )
      try! Data("corrupto".utf8).write(
        to: sealed.appendingPathComponent("files/file-0.bin")
      )
    }

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadIsNotARegularDirectory)
  }

  func testUnsupportedPlatformTakesPriorityOverWorkflowState() {
    let onboarding = AppleGPTKOnboarding(
      inputs: .init(
        platformSupport: .unsupported(reason: "Requiere Apple Silicon y macOS 15 o posterior"),
        componentHealth: .missing,
        dmgSelection: .notDownloaded,
        licenseConfirmation: .notReviewed,
        operation: .idle
      )
    )

    XCTAssertEqual(
      onboarding.state,
      .unsupported(reason: "Requiere Apple Silicon y macOS 15 o posterior")
    )
    XCTAssertEqual(onboarding.allowedActions, [])
  }

  func testCurrentComponentIsReadyWithoutOfferingMutation() {
    let onboarding = AppleGPTKOnboarding(
      inputs: .init(
        platformSupport: .supported,
        componentHealth: .ready,
        dmgSelection: .notDownloaded,
        licenseConfirmation: .notReviewed,
        operation: .idle
      )
    )

    XCTAssertEqual(onboarding.state, .ready)
    XCTAssertEqual(onboarding.allowedActions, [])
  }

  func testMissingDownloadOnlyOffersOfficialApplePage() {
    let onboarding = AppleGPTKOnboarding(
      inputs: .init(
        platformSupport: .supported,
        componentHealth: .missing,
        dmgSelection: .notDownloaded,
        licenseConfirmation: .notReviewed,
        operation: .idle
      )
    )

    XCTAssertEqual(onboarding.state, .requiresDownload)
    XCTAssertEqual(onboarding.allowedActions, [.openOfficialDownload])
    XCTAssertEqual(
      onboarding.officialDownloadURL.absoluteString,
      "https://developer.apple.com/download/all/?q=Evaluation+environment+for+Windows+games"
    )
  }

  func testDownloadedDMGRequiresExplicitSelection() {
    let onboarding = AppleGPTKOnboarding(
      inputs: .init(
        platformSupport: .supported,
        componentHealth: .missing,
        dmgSelection: .availableForSelection,
        licenseConfirmation: .notReviewed,
        operation: .idle
      )
    )

    XCTAssertEqual(onboarding.state, .requiresSelection)
    XCTAssertEqual(
      onboarding.allowedActions,
      [.selectDMG, .openOfficialDownload]
    )
  }

  func testSelectedDMGRequiresLicenseReviewBeforeInstallIsAllowed() {
    let onboarding = AppleGPTKOnboarding(
      inputs: .init(
        platformSupport: .supported,
        componentHealth: .missing,
        dmgSelection: .selected(selectedDMG),
        licenseConfirmation: .notReviewed,
        operation: .idle
      )
    )

    XCTAssertEqual(onboarding.state, .requiresLicense)
    XCTAssertEqual(onboarding.allowedActions, [.reviewLicense])
    XCTAssertFalse(onboarding.allowedActions.contains(.install))
  }

  func testExactLicenseConfirmationAllowsExplicitInstall() {
    let onboarding = AppleGPTKOnboarding(
      inputs: .init(
        platformSupport: .supported,
        componentHealth: .missing,
        dmgSelection: .selected(selectedDMG),
        licenseConfirmation: .confirmed,
        operation: .idle
      )
    )

    XCTAssertEqual(onboarding.state, .requiresLicense)
    XCTAssertEqual(onboarding.allowedActions, [.install])
  }

  func testOperationStatesSuppressActionsAndFailureOnlyAllowsRetry() {
    let base = AppleGPTKOnboarding.Inputs(
      platformSupport: .supported,
      componentHealth: .invalid(reason: "Hash no válido"),
      dmgSelection: .selected(selectedDMG),
      licenseConfirmation: .confirmed,
      operation: .verifying
    )

    let verifying = AppleGPTKOnboarding(inputs: base)
    let installing = AppleGPTKOnboarding(
      inputs: base.replacing(operation: .installing)
    )
    let failed = AppleGPTKOnboarding(
      inputs: base.replacing(operation: .failed(message: "Firma no válida"))
    )

    XCTAssertEqual(verifying.state, .verifying)
    XCTAssertEqual(verifying.allowedActions, [])
    XCTAssertEqual(installing.state, .installing)
    XCTAssertEqual(installing.allowedActions, [])
    XCTAssertEqual(failed.state, .failed(message: "Firma no válida"))
    XCTAssertEqual(failed.allowedActions, [.retry])
  }

  func testInspectionDescriptorAndAuthorizationUseStableJSONContract() throws {
    let inspectedAt = Date(timeIntervalSince1970: 1_786_618_800)
    let currentDMGSHA = try XCTUnwrap(AppleGPTKComponentCatalog.current.dmgSHA256)
    let descriptor = AppleGPTKInspectionDescriptor(
      schema: 1,
      version: "4.0b2",
      dmgSHA256: currentDMGSHA,
      licenseSHA256: String(repeating: "b", count: 64),
      sourceDMG: "/Users/test/Downloads/GPTK 4.0b2.dmg"
    )
    let token = AppleGPTKAuthorizationToken(
      schema: 1,
      version: descriptor.version,
      dmgSHA256: descriptor.dmgSHA256,
      licenseSHA256: descriptor.licenseSHA256,
      sourceDMG: descriptor.sourceDMG,
      authorizedAt: inspectedAt,
      nonce: "0123456789abcdef0123456789abcdef",
      authorization: "user-confirmed-license",
      confirmation: "ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2"
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(token)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    let decoded = try JSONDecoder().decode(AppleGPTKAuthorizationToken.self, from: data)

    XCTAssertTrue(json.contains("\"authorizedAt\":\"2026-08-13T11:00:00Z\""))
    XCTAssertEqual(decoded, token)
    XCTAssertEqual(
      token.validation(against: descriptor, now: inspectedAt.addingTimeInterval(300)),
      .valid
    )
  }

  func testAuthorizationValidationRejectsHashExpiryReplayShapeAndSourceDrift() throws {
    let now = Date(timeIntervalSince1970: 1_786_619_400)
    let currentDMGSHA = try XCTUnwrap(AppleGPTKComponentCatalog.current.dmgSHA256)
    let descriptor = AppleGPTKInspectionDescriptor(
      schema: 1,
      version: "4.0b2",
      dmgSHA256: currentDMGSHA,
      licenseSHA256: String(repeating: "b", count: 64),
      sourceDMG: "/tmp/GPTK.dmg"
    )

    func token(
      dmgSHA256: String? = nil,
      sourceDMG: String? = nil,
      authorizedAt: Date? = nil,
      nonce: String = "0123456789abcdef0123456789abcdef"
    ) -> AppleGPTKAuthorizationToken {
      AppleGPTKAuthorizationToken(
        schema: 1,
        version: "4.0b2",
        dmgSHA256: dmgSHA256 ?? descriptor.dmgSHA256,
        licenseSHA256: descriptor.licenseSHA256,
        sourceDMG: sourceDMG ?? descriptor.sourceDMG,
        authorizedAt: authorizedAt ?? now.addingTimeInterval(-60),
        nonce: nonce,
        authorization: "user-confirmed-license",
        confirmation: "ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2"
      )
    }

    XCTAssertEqual(
      token(dmgSHA256: String(repeating: "c", count: 64)).validation(
        against: descriptor,
        now: now
      ),
      .invalid(.dmgHashMismatch)
    )
    XCTAssertEqual(
      token(sourceDMG: "/tmp/otro.dmg").validation(against: descriptor, now: now),
      .invalid(.sourceMismatch)
    )
    XCTAssertEqual(
      token(authorizedAt: now.addingTimeInterval(-601)).validation(
        against: descriptor,
        now: now
      ),
      .invalid(.expired)
    )
    XCTAssertEqual(
      token(nonce: "replay nonce con espacios").validation(against: descriptor, now: now),
      .invalid(.invalidNonce)
    )
  }

  func testInstallerStatusOnlyAcceptsTheVersionedMachineReadablePrefixes() {
    XCTAssertEqual(
      AppleGPTKInstallerStatus(output: "ready: Apple GPTK 4.0b2 verificado\n"),
      .ready
    )
    XCTAssertEqual(
      AppleGPTKInstallerStatus(
        output: "requires-download: abre la página oficial de Apple\n"
      ),
      .requiresDownload
    )
    XCTAssertEqual(
      AppleGPTKInstallerStatus(
        output: "unsupported: Apple GPTK 4.0b2 requiere macOS 15 o posterior.\n"
      ),
      .unsupported(reason: "Apple GPTK 4.0b2 requiere macOS 15 o posterior.")
    )
    XCTAssertNil(AppleGPTKInstallerStatus(output: "installed=true\n"))
    XCTAssertNil(AppleGPTKInstallerStatus(output: ""))
  }

  func testAuthorizationFactoryCopiesOnlyTheInspectedDescriptorAndExactConfirmation() throws {
    let now = Date(timeIntervalSince1970: 1_786_619_400)
    let currentDMGSHA = try XCTUnwrap(AppleGPTKComponentCatalog.current.dmgSHA256)
    let descriptor = AppleGPTKInspectionDescriptor(
      schema: 1,
      version: "4.0b2",
      dmgSHA256: currentDMGSHA,
      licenseSHA256: String(repeating: "b", count: 64),
      sourceDMG: "/tmp/GPTK.dmg"
    )

    let token = AppleGPTKAuthorizationToken(
      authorizing: descriptor,
      at: now,
      nonce: "0123456789abcdef0123456789abcdef"
    )

    XCTAssertEqual(token.schema, descriptor.schema)
    XCTAssertEqual(token.version, descriptor.version)
    XCTAssertEqual(token.dmgSHA256, descriptor.dmgSHA256)
    XCTAssertEqual(token.licenseSHA256, descriptor.licenseSHA256)
    XCTAssertEqual(token.sourceDMG, descriptor.sourceDMG)
    XCTAssertEqual(token.authorization, AppleGPTKAuthorizationToken.authorizationValue)
    XCTAssertEqual(token.confirmation, AppleGPTKAuthorizationToken.confirmationValue)
    XCTAssertEqual(token.validation(against: descriptor, now: now), .valid)

    let driftedDescriptor = AppleGPTKInspectionDescriptor(
      schema: 1,
      version: descriptor.version,
      dmgSHA256: String(repeating: "c", count: 64),
      licenseSHA256: descriptor.licenseSHA256,
      sourceDMG: descriptor.sourceDMG
    )
    let driftedToken = AppleGPTKAuthorizationToken(
      authorizing: driftedDescriptor,
      at: now,
      nonce: "0123456789abcdef0123456789abcdef"
    )
    XCTAssertEqual(driftedToken.confirmation, "")
    XCTAssertEqual(
      driftedToken.validation(against: driftedDescriptor, now: now),
      .invalid(.invalidAuthorization)
    )
  }

  func testAuthorizationFactoryUsesTheInspectedComponentLicenseAndRejectsUnknownVersions() {
    let now = Date(timeIntervalSince1970: 1_786_619_400)
    let legacyDescriptor = AppleGPTKInspectionDescriptor(
      schema: 1,
      version: AppleGPTKComponentCatalog.protectedProfiles.version,
      // Simula un descriptor ya inspeccionado; el catálogo público no autoriza a crearlo.
      dmgSHA256: String(repeating: "a", count: 64),
      licenseSHA256: String(repeating: "b", count: 64),
      sourceDMG: "/tmp/GPTK-3.0.dmg"
    )
    let legacyToken = AppleGPTKAuthorizationToken(
      authorizing: legacyDescriptor,
      at: now,
      nonce: "0123456789abcdef0123456789abcdef"
    )

    XCTAssertEqual(legacyToken.confirmation, "")
    XCTAssertEqual(
      legacyToken.validation(against: legacyDescriptor, now: now),
      .invalid(.invalidAuthorization)
    )

    let unknownDescriptor = AppleGPTKInspectionDescriptor(
      schema: 1,
      version: "2.1",
      dmgSHA256: String(repeating: "a", count: 64),
      licenseSHA256: String(repeating: "b", count: 64),
      sourceDMG: "/tmp/GPTK-unknown.dmg"
    )
    let unknownToken = AppleGPTKAuthorizationToken(
      authorizing: unknownDescriptor,
      at: now,
      nonce: "0123456789abcdef0123456789abcdef"
    )

    XCTAssertEqual(unknownToken.confirmation, "")
    XCTAssertEqual(
      unknownToken.validation(against: unknownDescriptor, now: now),
      .invalid(.invalidAuthorization)
    )
  }

  func testExistingProtectedAuthorizationHasNoDMGIdentityAndUsesExactCatalog() throws {
    let now = Date(timeIntervalSince1970: 1_786_619_400)
    let descriptor = AppleGPTKExistingComponentInspectionDescriptor(
      schema: 1,
      version: "3.0",
      sourceKind: "existing-protected-component",
      catalogID: AppleGPTKComponentCatalog.protectedProfilesComponentID,
      payloadFingerprint: AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint,
      licenseSHA256: String(repeating: "b", count: 64),
      sourceComponent: "/Users/test/Components/AppleGPTK/3.0"
    )
    let token = AppleGPTKExistingComponentAuthorizationToken(
      authorizing: descriptor,
      at: now,
      nonce: "0123456789abcdef0123456789abcdef"
    )

    XCTAssertEqual(token.validation(against: descriptor, now: now), .valid)
    XCTAssertEqual(token.confirmation, "ACEPTO LA LICENCIA DE APPLE GPTK 3.0")
    let json = try XCTUnwrap(String(data: JSONEncoder().encode(token), encoding: .utf8))
    XCTAssertFalse(json.contains("dmgSHA256"))
    XCTAssertFalse(json.contains("sourceDMG"))
  }

  func testExistingProtectedAuthorizationRejectsWrongGenerationFingerprintAndExpiry() {
    let now = Date(timeIntervalSince1970: 1_786_619_400)
    func descriptor(
      version: String = "3.0",
      fingerprint: String = AppleGPTKComponentCatalog.protectedProfilesPayloadFingerprint
    ) -> AppleGPTKExistingComponentInspectionDescriptor {
      AppleGPTKExistingComponentInspectionDescriptor(
        schema: 1,
        version: version,
        sourceKind: "existing-protected-component",
        catalogID: AppleGPTKComponentCatalog.protectedProfilesComponentID,
        payloadFingerprint: fingerprint,
        licenseSHA256: String(repeating: "b", count: 64),
        sourceComponent: "/Users/test/Components/AppleGPTK/3.0"
      )
    }

    let wrongVersion = descriptor(version: "4.0b2")
    XCTAssertEqual(
      AppleGPTKExistingComponentAuthorizationToken(
        authorizing: wrongVersion,
        at: now,
        nonce: "0123456789abcdef0123456789abcdef"
      ).validation(against: wrongVersion, now: now),
      .invalid(.versionMismatch)
    )

    let wrongFingerprint = descriptor(fingerprint: String(repeating: "c", count: 64))
    XCTAssertEqual(
      AppleGPTKExistingComponentAuthorizationToken(
        schema: 1,
        version: "3.0",
        sourceKind: "existing-protected-component",
        catalogID: AppleGPTKComponentCatalog.protectedProfilesComponentID,
        payloadFingerprint: wrongFingerprint.payloadFingerprint,
        licenseSHA256: wrongFingerprint.licenseSHA256,
        sourceComponent: wrongFingerprint.sourceComponent,
        authorizedAt: now,
        nonce: "0123456789abcdef0123456789abcdef",
        authorization: "user-confirmed-license",
        confirmation: "ACEPTO LA LICENCIA DE APPLE GPTK 3.0"
      ).validation(against: wrongFingerprint, now: now),
      .invalid(.payloadFingerprintMismatch)
    )

    let valid = descriptor()
    XCTAssertEqual(
      AppleGPTKExistingComponentAuthorizationToken(
        authorizing: valid,
        at: now.addingTimeInterval(-601),
        nonce: "0123456789abcdef0123456789abcdef"
      ).validation(against: valid, now: now),
      .invalid(.expired)
    )
  }
}

private final class ProtectedProfilesAliasFixture {
  let container: URL
  let root: URL
  private var files: [TrustedComponentFile] = []

  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-gptk-alias-\(UUID().uuidString)",
      isDirectory: true
    )
    root = container.appendingPathComponent("apple_gptk", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<8 {
      let relativePath = "sealed/files/file-\(index).bin"
      let data = Data("protected-\(index)".utf8)
      let url = root.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url)
      files.append(
        TrustedComponentFile(
          relativePath: relativePath,
          expectedSHA256: SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        )
      )
    }
  }

  func descriptor() -> TrustedComponentFileSetDescriptor {
    TrustedComponentFileSetDescriptor(
      identity: ComponentIdentity(
        componentID: AppleGPTKComponentCatalog.protectedProfilesComponentID,
        componentVersion: "3.0",
        variant: .publicInstalled,
        buildIdentifier: "test"
      ),
      payloadRootURL: root,
      files: files,
      maximumFileBytes: 1_024,
      maximumPayloadBytes: 16 * 1_024
    )
  }

  func writeAliases(
    omitting omitted: String? = nil,
    overriding targets: [String: String] = [:]
  ) throws {
    let directory = root.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for module in AppleGPTKComponentCatalog.protectedProfilesUnixModuleNames
    where module != omitted {
      try FileManager.default.createSymbolicLink(
        atPath: directory.appendingPathComponent("\(module).so").path,
        withDestinationPath: targets[module]
          ?? AppleGPTKComponentCatalog.protectedProfilesUnixAliasTarget
      )
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: container)
  }
}

private extension AppleGPTKOnboarding.Inputs {
  func replacing(operation: AppleGPTKOnboardingOperation) -> Self {
    .init(
      platformSupport: platformSupport,
      componentHealth: componentHealth,
      dmgSelection: dmgSelection,
      licenseConfirmation: licenseConfirmation,
      operation: operation
    )
  }
}
