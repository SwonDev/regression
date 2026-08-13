import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import RegressionCore

final class ComponentHealthTests: XCTestCase {
  func testProductionWindowsMediaDevelopmentDescriptorUsesCompiledManifestAndInjectedPaths() {
    let roots = ProductionDescriptorRoots()

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "36",
      variant: .development,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    XCTAssertEqual(descriptor.identity.componentID, "windows-media-gstreamer")
    XCTAssertEqual(descriptor.identity.componentVersion, "1")
    XCTAssertEqual(descriptor.identity.variant, .development)
    XCTAssertEqual(descriptor.identity.buildIdentifier, "36")
    XCTAssertEqual(
      descriptor.payloadRootURL,
      roots.bundle.appendingPathComponent(
        "Contents/SharedSupport/components/windows-media/1",
        isDirectory: true
      )
    )
    XCTAssertEqual(descriptor.manifestRelativePath, "manifest.sha256")
    XCTAssertEqual(
      descriptor.expectedManifestSHA256,
      "ac662661fb3384c6ad100066391cab209f9de60b2e129fb92e07365ee6fe9bb1"
    )
    XCTAssertEqual(descriptor.sourcePolicy, .bundled)
    XCTAssertEqual(
      descriptor.externalLinkURL,
      roots.applicationSupport.appendingPathComponent(
        "Components/WindowsMedia/1",
        isDirectory: false
      )
    )
  }

  func testProductionWindowsMediaPublicDescriptorUsesReleaseManifestAndExpectedExternalLink() {
    let roots = ProductionDescriptorRoots()

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "36",
      variant: .publicInstalled,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    XCTAssertEqual(descriptor.identity.variant, .publicInstalled)
    XCTAssertEqual(
      descriptor.expectedManifestSHA256,
      "da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
    )
    XCTAssertEqual(
      descriptor.externalLinkURL?.path,
      roots.applicationSupport
        .appendingPathComponent("Components/WindowsMedia/1")
        .path
    )
  }

  func testProductionWindowsMediaCatalogDoesNotInferPublicVariantFromManifest() {
    let roots = ProductionDescriptorRoots()

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "36",
      variant: .development,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    XCTAssertEqual(descriptor.identity.variant, .development)
    XCTAssertNotEqual(
      descriptor.expectedManifestSHA256,
      "da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
    )
  }

  func testProductionWindowsMediaUnsupportedBuildIsRejectedBeforeFilesystemInspection() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "37",
      variant: .publicInstalled,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
    XCTAssertEqual(
      report.issue,
      .unsupportedVariant("Regression 1.10.1 (37)")
    )
  }

  func testProductionWindowsMediaUnsupportedApplicationVersionIsRejected() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "36",
      variant: .development,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
  }

  func testProductionWindowsMediaPreviousReleaseIsRejected() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.0",
      buildIdentifier: "35",
      variant: .publicInstalled,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(
      report.issue,
      .unsupportedVariant("Regression 1.10.0 (35)")
    )
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
  }

  func testProductionWindowsMediaExplicitUnsupportedVariantRemainsUnsupported() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "36",
      variant: .unsupported("portable-v2"),
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.issue, .unsupportedVariant("portable-v2"))
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
  }

  func testProductionWindowsMediaCatalogStandardizesInjectedRootsLexically() {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-component-catalog-\(UUID().uuidString)",
      isDirectory: true
    )
    let bundle = base.appendingPathComponent("nested/../Regression.app", isDirectory: true)
    let support = base.appendingPathComponent("support/../Regression", isDirectory: true)

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "36",
      variant: .publicInstalled,
      applicationBundleURL: bundle,
      applicationSupportURL: support
    )

    XCTAssertEqual(
      descriptor.payloadRootURL,
      bundle.standardizedFileURL.appendingPathComponent(
        "Contents/SharedSupport/components/windows-media/1",
        isDirectory: true
      )
    )
    XCTAssertEqual(
      descriptor.externalLinkURL,
      support.standardizedFileURL.appendingPathComponent(
        "Components/WindowsMedia/1",
        isDirectory: false
      )
    )
  }

  func testProductionWindowsMediaMissingPayloadOnlyRecommendsTrustedReinstall() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "36",
      variant: .development,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .missing)
    XCTAssertEqual(report.recovery, .reinstallTrustedArtifact)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.payloadRootURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: descriptor.externalLinkURL!.path)
    )
  }

  func testDevelopmentVariantIsReadyOnlyWhenTrustedDescriptorMatchesManifest() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["BUILD.txt": "component=media\n"])
    try fixture.linkExpectedPayload()

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(variant: .development, manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .ready)
    XCTAssertEqual(report.identity.variant, .development)
    XCTAssertEqual(report.recovery, .none)
  }

  func testPublicInstalledVariantHasAnIndependentTrustedManifest() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload([
      "BUILD.txt": "component=media\nvariant=public\n",
      "lib/plugin.dylib": "portable-payload",
    ])
    try fixture.linkExpectedPayload()

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(variant: .publicInstalled, manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .ready)
    XCTAssertEqual(report.identity.buildIdentifier, "36")
  }

  func testSelfConsistentManifestIsRejectedWithoutMatchingCompiledDescriptor() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    _ = try fixture.writePayload(["BUILD.txt": "attacker-controlled-but-consistent"])
    try fixture.linkExpectedPayload()

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: String(repeating: "a", count: 64))
    )

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.recovery, .reinstallTrustedArtifact)
  }

  func testChangedPayloadIsDriftedEvenWhenManifestItselfStillMatchesDescriptor() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["lib/plugin.dylib": "approved"])
    try Data("changed".utf8).write(to: fixture.payload.appendingPathComponent("lib/plugin.dylib"))

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .drifted)
  }

  func testManifestRejectsDuplicateCanonicalPaths() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    try fixture.writeFile("one", at: "payload.bin")
    let hash = ComponentHealthFixture.sha256(Data("one".utf8))
    let manifest = "\(hash)  ./payload.bin\n\(hash)  payload.bin\n"
    let manifestDigest = try fixture.writeManifest(manifest)

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .drifted)
  }

  func testManifestRejectsTraversalWithoutReadingOutsidePayload() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("outside.bin")
    try Data("outside".utf8).write(to: outside)
    let hash = ComponentHealthFixture.sha256(Data("outside".utf8))
    let manifestDigest = try fixture.writeManifest("\(hash)  ../outside.bin\n")

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
  }

  func testManifestRejectsSymlinkedPayloadEntry() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("outside.bin")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createDirectory(at: fixture.payload, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.payload.appendingPathComponent("plugin.dylib"),
      withDestinationURL: outside
    )
    let hash = ComponentHealthFixture.sha256(Data("outside".utf8))
    let manifestDigest = try fixture.writeManifest("\(hash)  ./plugin.dylib\n")

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .drifted)
  }

  func testUnlistedHiddenPayloadIsDrifted() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["BUILD.txt": "approved"])
    try fixture.writeFile("unlisted", at: ".injected")

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .unlistedPayloadEntry(".injected"))
  }

  func testManifestItselfCannotBeReachedThroughSymlinkedDirectory() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("outside-manifest", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let manifestData = Data(
      "\(ComponentHealthFixture.sha256(Data("ok".utf8)))  ./payload.bin\n".utf8)
    try manifestData.write(to: outside.appendingPathComponent("manifest.sha256"))
    try FileManager.default.createSymbolicLink(
      at: fixture.payload.appendingPathComponent("metadata"),
      withDestinationURL: outside
    )

    let descriptor = TrustedComponentDescriptor(
      identity: fixture.descriptor().identity,
      payloadRootURL: fixture.payload,
      manifestRelativePath: "metadata/manifest.sha256",
      expectedManifestSHA256: ComponentHealthFixture.sha256(manifestData),
      sourcePolicy: .bundled
    )
    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .manifestMissing)
  }

  func testPayloadRootSymbolicLinkIsRejectedWithoutReadingItsTarget() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let actualPayload = fixture.root.appendingPathComponent("actual-component", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.payload, to: actualPayload)
    try FileManager.default.createSymbolicLink(
      at: fixture.payload,
      withDestinationURL: actualPayload
    )

    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadIsNotARegularDirectory)
  }

  func testManifestFinalComponentSymbolicLinkIsRejectedWithoutReadingItsTarget() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let outsideManifest = fixture.root.appendingPathComponent("outside-manifest.sha256")
    let data = Data("\(ComponentHealthFixture.sha256(Data("approved".utf8)))  ./payload.bin\n".utf8)
    try data.write(to: outsideManifest)
    try FileManager.default.createSymbolicLink(
      at: fixture.payload.appendingPathComponent("manifest.sha256"),
      withDestinationURL: outsideManifest
    )

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: ComponentHealthFixture.sha256(data))
    )

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .manifestMissing)
    XCTAssertEqual(try Data(contentsOf: outsideManifest), data)
  }

  func testManifestListedFIFOIsRejectedWithoutBlocking() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let fifo = fixture.payload.appendingPathComponent("injected.pipe")
    XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
    let digest = ComponentHealthFixture.sha256(Data())
    let manifestDigest = try fixture.writeManifest("\(digest)  ./injected.pipe\n")

    let started = Date()
    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadEntryMissing("injected.pipe"))
  }

  func testDotPrefixedManifestPathUsesCanonicalInventoryIdentity() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["BUILD.txt": "approved"])
    try fixture.linkExpectedPayload()
    let base = fixture.descriptor(manifestSHA256: manifestDigest)
    let descriptor = TrustedComponentDescriptor(
      identity: base.identity,
      payloadRootURL: base.payloadRootURL,
      manifestRelativePath: "./manifest.sha256",
      expectedManifestSHA256: base.expectedManifestSHA256,
      sourcePolicy: base.sourcePolicy,
      externalLinkURL: base.externalLinkURL
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .ready)
    XCTAssertEqual(report.recovery, .none)
  }

  func testMissingExternalLinkIsRepairableWithoutExecutingRepair() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["BUILD.txt": "approved"])

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .repairable)
    XCTAssertEqual(
      report.recovery,
      .createExternalLink(linkURL: fixture.externalLink, targetURL: fixture.payload)
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalLink.path))
  }

  func testUnexpectedExternalLinkTargetIsBrokenAndNeverOverwritten() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["BUILD.txt": "approved"])
    let unexpected = fixture.root.appendingPathComponent("unexpected", isDirectory: true)
    try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fixture.externalLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.externalLink, withDestinationURL: unexpected)

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest)
    )

    XCTAssertEqual(report.status, .brokenLink)
    XCTAssertEqual(
      report.recovery,
      .restoreExternalLinkAfterBackup(linkURL: fixture.externalLink, targetURL: fixture.payload)
    )
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: fixture.externalLink.path),
      unexpected.path)
  }

  func testMissingBundledPayloadIsMissing() throws {
    let fixture = try ComponentHealthFixture(createPayload: false)
    defer { fixture.remove() }

    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertEqual(report.status, .missing)
    XCTAssertEqual(report.recovery, .reinstallTrustedArtifact)
  }

  func testMissingUserProvidedPayloadRequiresUserSource() throws {
    let fixture = try ComponentHealthFixture(createPayload: false)
    defer { fixture.remove() }

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(source: .userProvided)
    )

    XCTAssertEqual(report.status, .requiresUserSource)
    XCTAssertEqual(report.recovery, .provideUserSource)
  }

  func testUnsupportedVariantIsRejectedBeforeInspectingPayload() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(variant: .unsupported("future-portable-v2"))
    )

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
  }
}

private struct ProductionDescriptorRoots {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "regression-production-descriptor-\(UUID().uuidString)",
    isDirectory: true
  )

  var bundle: URL {
    root.appendingPathComponent("Regression.app", isDirectory: true)
  }

  var applicationSupport: URL {
    root.appendingPathComponent("Application Support/Regression", isDirectory: true)
  }
}

private final class ComponentHealthFixture {
  let root: URL
  let payload: URL
  let externalLink: URL

  init(createPayload: Bool = true) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-component-health-\(UUID().uuidString)",
      isDirectory: true
    )
    payload = root.appendingPathComponent("bundle/component/1", isDirectory: true)
    externalLink = root.appendingPathComponent("support/component/1")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if createPayload {
      try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    }
  }

  func descriptor(
    variant: ComponentArtifactVariant = .development,
    source: ComponentSourcePolicy = .bundled,
    manifestSHA256: String = String(repeating: "0", count: 64)
  ) -> TrustedComponentDescriptor {
    TrustedComponentDescriptor(
      identity: ComponentIdentity(
        componentID: "windows-media-gstreamer",
        componentVersion: "1",
        variant: variant,
        buildIdentifier: "36"
      ),
      payloadRootURL: payload,
      manifestRelativePath: "manifest.sha256",
      expectedManifestSHA256: manifestSHA256,
      sourcePolicy: source,
      externalLinkURL: externalLink
    )
  }

  @discardableResult
  func writePayload(_ files: [String: String]) throws -> String {
    for (relativePath, contents) in files {
      try writeFile(contents, at: relativePath)
    }
    let manifest =
      files.keys.sorted().map { relativePath in
        let data = Data(files[relativePath]!.utf8)
        return "\(Self.sha256(data))  ./\(relativePath)"
      }.joined(separator: "\n") + "\n"
    return try writeManifest(manifest)
  }

  func writeFile(_ contents: String, at relativePath: String) throws {
    let url = payload.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  @discardableResult
  func writeManifest(_ contents: String) throws -> String {
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    let data = Data(contents.utf8)
    try data.write(to: payload.appendingPathComponent("manifest.sha256"))
    return Self.sha256(data)
  }

  func linkExpectedPayload() throws {
    try FileManager.default.createDirectory(
      at: externalLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: externalLink, withDestinationURL: payload)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
