import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import RegressionCore

private final class LockedTestBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?

  func store(_ value: Value) {
    lock.lock()
    stored = value
    lock.unlock()
  }

  func load() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

final class ComponentHealthTests: XCTestCase {
  func testAnchoredPrivateFileReadRequiresOwnerAndMode0600() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-anchored-private-file-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let root = try XCTUnwrap(AnchoredDirectory.open(support))
    try root.createExclusiveRegularFile(relativePath: "lease", data: Data("sealed".utf8))

    XCTAssertEqual(
      try root.readPrivateRegularFile(
        relativePath: "lease",
        maximumBytes: 32,
        ownerUID: getuid()
      ),
      Data("sealed".utf8)
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o640],
      ofItemAtPath: support.appendingPathComponent("lease").path
    )
    XCTAssertThrowsError(try root.readPrivateRegularFile(
      relativePath: "lease",
      maximumBytes: 32,
      ownerUID: getuid()
    ))
  }

  func testAnchoredDirectoryAcceptsSystemTmpAlias() throws {
    let directory = URL(
      fileURLWithPath: "/tmp/regression-anchored-system-alias-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertNotNil(AnchoredDirectory.open(directory))
  }

  func testAnchoredDirectoryRejectsHostileParentSymlink() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-anchored-parent-\(UUID().uuidString)",
      isDirectory: true
    )
    let target = container.appendingPathComponent("target/child", isDirectory: true)
    let alias = container.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: alias,
      withDestinationURL: container.appendingPathComponent("target", isDirectory: true)
    )
    defer { try? FileManager.default.removeItem(at: container) }

    XCTAssertNil(AnchoredDirectory.open(alias.appendingPathComponent("child", isDirectory: true)))
  }

  func testPendingWindowsMediaJournalOverridesReadyLinkUntilReconciled() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifest = try fixture.writePayload(["codec.dylib": "sealed"])
    try FileManager.default.createDirectory(
      at: fixture.externalLink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.externalLink,
      withDestinationURL: fixture.payload
    )
    let intent = fixture.root.appendingPathComponent("transaction.intent")
    try Data("phase=swapped\n".utf8).write(to: intent)
    let base = fixture.descriptor(manifestSHA256: manifest)
    let descriptor = TrustedComponentDescriptor(
      identity: base.identity,
      payloadRootURL: base.payloadRootURL,
      manifestRelativePath: base.manifestRelativePath,
      expectedManifestSHA256: base.expectedManifestSHA256,
      sourcePolicy: base.sourcePolicy,
      externalLinkURL: base.externalLinkURL,
      transactionIntentURL: intent
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .repairable)
    XCTAssertEqual(report.issue, .pendingTransaction)
    XCTAssertEqual(report.recovery, .reconcilePendingTransaction(intentURL: intent))
  }

  func testWindowsMediaLeaseIsExclusiveConsumedAfterFreshIdleCheckAndReleased() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-lease-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let owner = getpid()
    let lease = try WindowsMediaRepairInterlock.issueRepairLease(
      appID: "347940",
      ownerPID: owner,
      applicationSupportURL: support,
      runtimeIsIdle: true
    )

    XCTAssertThrowsError(try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: owner,
      applicationSupportURL: support
    ))
    XCTAssertThrowsError(try WindowsMediaRepairInterlock.consumeRepairLease(
      appID: "347940",
      token: lease.token,
      ownerPID: owner,
      applicationSupportURL: support,
      runtimeIsIdle: false
    ))
    try WindowsMediaRepairInterlock.consumeRepairLease(
      appID: "347940",
      token: lease.token,
      ownerPID: owner,
      applicationSupportURL: support,
      runtimeIsIdle: true
    )
    try WindowsMediaRepairInterlock.release(
      token: lease.token,
      ownerPID: owner,
      applicationSupportURL: support
    )
    XCTAssertNoThrow(try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: owner,
      applicationSupportURL: support
    ))
  }

  func testWindowsMediaRuntimeLeaseCanJoinAnExistingCanonicalRuntimeWithoutOpeningRepairRace() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-runtime-join-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }

    let firstRuntime = Process()
    firstRuntime.executableURL = URL(fileURLWithPath: "/bin/sleep")
    firstRuntime.arguments = ["30"]
    try firstRuntime.run()
    defer {
      if firstRuntime.isRunning { firstRuntime.terminate() }
      firstRuntime.waitUntilExit()
    }

    let firstLease = try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: firstRuntime.processIdentifier,
      applicationSupportURL: support
    )
    let snapshot = try WindowsMediaRepairInterlock.snapshotExistingRuntimeLease(
      applicationSupportURL: support
    )
    let joinedLease = try WindowsMediaRepairInterlock.joinExistingRuntimeLease(
      ownerPID: getpid(),
      expectedToken: snapshot.token,
      expectedRuntimeOwnerPIDs: snapshot.liveOwnerPIDs,
      applicationSupportURL: support
    )
    XCTAssertEqual(joinedLease.token, firstLease.token)
    XCTAssertEqual(joinedLease.ownerPID, getpid())

    firstRuntime.terminate()
    firstRuntime.waitUntilExit()
    XCTAssertThrowsError(try WindowsMediaRepairInterlock.issueRepairLease(
      appID: "347940",
      ownerPID: getpid(),
      applicationSupportURL: support,
      runtimeIsIdle: true
    )) { error in
      XCTAssertEqual(error as? WindowsMediaRepairInterlockError, .leaseActive)
    }
    try WindowsMediaRepairInterlock.release(
      token: joinedLease.token,
      ownerPID: getpid(),
      applicationSupportURL: support
    )
  }

  func testWindowsMediaRuntimeJoinRejectsAReplacedLeaseGenerationAndUnobservedOwner() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-runtime-generation-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let lease = try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: getpid(),
      applicationSupportURL: support
    )

    XCTAssertThrowsError(try WindowsMediaRepairInterlock.joinExistingRuntimeLease(
      ownerPID: getpid(),
      expectedToken: "11111111-1111-4111-8111-111111111111",
      expectedRuntimeOwnerPIDs: [getpid()],
      applicationSupportURL: support
    ))
    XCTAssertThrowsError(try WindowsMediaRepairInterlock.joinExistingRuntimeLease(
      ownerPID: getpid(),
      expectedToken: lease.token,
      expectedRuntimeOwnerPIDs: [Int32.max],
      applicationSupportURL: support
    ))
    try WindowsMediaRepairInterlock.release(
      token: lease.token,
      ownerPID: getpid(),
      applicationSupportURL: support
    )
  }

#if DEBUG
  func testWindowsMediaStaleLeaseReclaimCannotDeleteAuthorityIssuedByAnotherEmitter() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-stale-lease-cas-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let crashedEmitter = Process()
    crashedEmitter.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try crashedEmitter.run()
    crashedEmitter.waitUntilExit()
    let staleOwnerPID = crashedEmitter.processIdentifier
    XCTAssertFalse(Darwin.kill(staleOwnerPID, 0) == 0 || errno == EPERM)
    let staleLeaseData = Data([
      "schema=1",
      "kind=runtime",
      "state=issued",
      "app_id=none",
      "owner_pid=\(staleOwnerPID)",
      "token=11111111-1111-4111-8111-111111111111",
    ].joined(separator: "\n").appending("\n").utf8)
    let root = try XCTUnwrap(AnchoredDirectory.open(support))
    try root.ensurePrivateDirectory(relativePath: "Locks/WindowsMedia")
    try root.createExclusiveRegularFile(
      relativePath: "Locks/WindowsMedia/runtime-or-repair.lease",
      data: staleLeaseData
    )
    defer { try? FileManager.default.removeItem(at: support) }

    let firstSawStaleLease = DispatchSemaphore(value: 0)
    let allowFirstEmitterToReclaim = DispatchSemaphore(value: 0)
    let secondEmitterEntered = DispatchSemaphore(value: 0)
    let completion = DispatchGroup()
    let firstResult = LockedTestBox<Result<WindowsMediaRepairLease, Error>>()
    let secondResult = LockedTestBox<Result<WindowsMediaRepairLease, Error>>()

    completion.enter()
    DispatchQueue.global().async {
      defer { completion.leave() }
      let result = Result {
        try WindowsMediaRepairInterlock.withTestingStaleLeaseObservedHook({
          firstSawStaleLease.signal()
          XCTAssertEqual(allowFirstEmitterToReclaim.wait(timeout: .now() + 5), .success)
        }) {
          try WindowsMediaRepairInterlock.issueRuntimeLease(
            ownerPID: getpid(),
            applicationSupportURL: support
          )
        }
      }
      firstResult.store(result)
    }

    XCTAssertEqual(firstSawStaleLease.wait(timeout: .now() + 5), .success)
    completion.enter()
    DispatchQueue.global().async {
      defer { completion.leave() }
      secondEmitterEntered.signal()
      let result = Result {
        try WindowsMediaRepairInterlock.issueRuntimeLease(
          ownerPID: getpid(),
          applicationSupportURL: support
        )
      }
      secondResult.store(result)
    }
    XCTAssertEqual(secondEmitterEntered.wait(timeout: .now() + 5), .success)
    allowFirstEmitterToReclaim.signal()
    XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)

    let capturedFirst = firstResult.load()
    let capturedSecond = secondResult.load()
    guard case .success(let firstLease)? = capturedFirst else {
      return XCTFail("El primer emisor no obtuvo la única autoridad esperada")
    }
    guard case .failure(let secondError)? = capturedSecond else {
      return XCTFail("El segundo emisor no debía obtener autoridad tras la recuperación")
    }
    XCTAssertEqual(secondError as? WindowsMediaRepairInterlockError, .leaseActive)

    XCTAssertThrowsError(try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: getpid(),
      applicationSupportURL: support
    )) { error in
      XCTAssertEqual(error as? WindowsMediaRepairInterlockError, .leaseActive)
    }
    try WindowsMediaRepairInterlock.release(
      token: firstLease.token,
      ownerPID: getpid(),
      applicationSupportURL: support
    )
  }
#endif

  func testWindowsMediaLeaseRejectsDuplicateKeysWithoutCrashing() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-duplicate-lease-\(UUID().uuidString)",
      isDirectory: true
    )
    let leaseURL = support.appendingPathComponent(
      "Locks/WindowsMedia/runtime-or-repair.lease",
      isDirectory: false
    )
    try FileManager.default.createDirectory(
      at: leaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([
      "schema=1",
      "kind=repair",
      "state=issued",
      "app_id=347940",
      "owner_pid=\(getpid())",
      "token=11111111-1111-4111-8111-111111111111",
      "token=22222222-2222-4222-8222-222222222222",
    ].joined(separator: "\n").appending("\n").utf8).write(to: leaseURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: leaseURL.path
    )
    defer { try? FileManager.default.removeItem(at: support) }

    XCTAssertThrowsError(try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: getpid(),
      applicationSupportURL: support
    ))
  }

  func testWindowsMediaRuntimeLeaseRejectsWALCreatedAfterLaunchPrecheck() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-runtime-wal-race-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    try WindowsMediaAnchoredPrivateFileStore.write(
      Data("pending-wal-after-precheck".utf8),
      to: .intent,
      applicationSupportURL: support
    )

    XCTAssertThrowsError(try WindowsMediaRepairInterlock.issueRuntimeLease(
      ownerPID: getpid(),
      applicationSupportURL: support
    )) { error in
      XCTAssertEqual(
        error as? WindowsMediaRepairInterlockError,
        .pendingTransaction
      )
    }
  }

  func testWindowsMediaAnchoredMutatorRejectsSwappedComponentSubtree() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-mutation-\(UUID().uuidString)",
      isDirectory: true
    )
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-outside-\(UUID().uuidString)",
      isDirectory: true
    )
    let payload = support.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(
      at: support.appendingPathComponent("Components"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: support.appendingPathComponent("Components"))
    try FileManager.default.createSymbolicLink(
      at: support.appendingPathComponent("Components"),
      withDestinationURL: outside
    )
    defer {
      try? FileManager.default.removeItem(at: support)
      try? FileManager.default.removeItem(at: outside)
    }

    XCTAssertThrowsError(try WindowsMediaAnchoredLinkMutator.apply(
      .createStage(stageName: ".1-stage-123", targetURL: payload),
      applicationSupportURL: support,
      authorizedPayloadURL: payload
    ))
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
  }

  func testWindowsMediaStoragePreparationRejectsHostileManagedSubtree() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-storage-\(UUID().uuidString)",
      isDirectory: true
    )
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-storage-outside-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: support.appendingPathComponent("Components"),
      withDestinationURL: outside
    )
    defer {
      try? FileManager.default.removeItem(at: support)
      try? FileManager.default.removeItem(at: outside)
    }

    XCTAssertThrowsError(try WindowsMediaAnchoredPrivateFileStore.prepare(
      applicationSupportURL: support
    ))
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
  }

  func testAnchoredMutationCannotEscapeWhenParentIsSwappedAfterOpen() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-openat-race-\(UUID().uuidString)",
      isDirectory: true
    )
    let managed = support.appendingPathComponent("Components/WindowsMedia", isDirectory: true)
    let displaced = support.appendingPathComponent("Components/WindowsMedia-before", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-openat-outside-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: support)
      try? FileManager.default.removeItem(at: outside)
    }
    let root = try XCTUnwrap(AnchoredDirectory.open(support))

    try root.createSymbolicLink(
      relativePath: "Components/WindowsMedia/.1-stage-123",
      target: "/trusted/payload",
      onParentOpened: {
        try? FileManager.default.moveItem(at: managed, to: displaced)
        try? FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
      }
    )

    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: displaced.appendingPathComponent(".1-stage-123").path
      ),
      "/trusted/payload"
    )
  }

  func testWindowsMediaPrivateWALStoreRejectsHostileTransactionSubtree() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-wal-store-\(UUID().uuidString)",
      isDirectory: true
    )
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-wm-wal-store-outside-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: support.appendingPathComponent("Transactions"),
      withDestinationURL: outside
    )
    defer {
      try? FileManager.default.removeItem(at: support)
      try? FileManager.default.removeItem(at: outside)
    }

    XCTAssertThrowsError(try WindowsMediaAnchoredPrivateFileStore.write(
      Data("phase=prepared\n".utf8),
      to: .intent,
      applicationSupportURL: support
    ))
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
  }

  func testAnchoredSymbolicLinkReadRejectsConcurrentReplacement() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-link-swap-\(UUID().uuidString)",
      isDirectory: true
    )
    let link = rootURL.appendingPathComponent("1")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/trusted/a")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let root = try XCTUnwrap(AnchoredDirectory.open(rootURL))

    XCTAssertThrowsError(try root.stableSymbolicLink(relativePath: "1") {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: "/trusted/b"
      )
    })
  }

  func testProductionWindowsMediaDevelopmentDescriptorUsesCompiledManifestAndInjectedPaths() {
    let roots = ProductionDescriptorRoots()

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
      variant: .development,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    XCTAssertEqual(descriptor.identity.componentID, "windows-media-gstreamer")
    XCTAssertEqual(descriptor.identity.componentVersion, "1")
    XCTAssertEqual(descriptor.identity.variant, .development)
    XCTAssertEqual(descriptor.identity.buildIdentifier, "37")
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

  func testProductionWindowsMediaPublicDescriptorUsesMeasuredReleaseManifest() {
    let roots = ProductionDescriptorRoots()

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
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

  func testProductionWindowsMediaCarriesByteIdenticalAuthorityInto112() {
    let roots = ProductionDescriptorRoots()
    let legacy = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
      variant: .publicInstalled,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )
    let current = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: TrustedComponentCatalog.supportedApplicationVersion,
      buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier,
      variant: .publicInstalled,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    XCTAssertEqual(current.identity.variant, .publicInstalled)
    XCTAssertEqual(current.expectedManifestSHA256, legacy.expectedManifestSHA256)
  }

  func testProductionWindowsMediaCatalogDoesNotInferPublicVariantFromManifest() {
    let roots = ProductionDescriptorRoots()

    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
      variant: .development,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    XCTAssertEqual(descriptor.identity.variant, .development)
    XCTAssertNotEqual(
      descriptor.expectedManifestSHA256,
      String(repeating: "0", count: 64)
    )
  }

  func testProductionWindowsMediaUnsupportedBuildIsRejectedBeforeFilesystemInspection() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "36",
      variant: .publicInstalled,
      applicationBundleURL: roots.bundle,
      applicationSupportURL: roots.applicationSupport
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
    XCTAssertEqual(
      report.issue,
      .unsupportedVariant("Regression 1.11.0 (36)")
    )
  }

  func testProductionWindowsMediaUnsupportedApplicationVersionIsRejected() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "37",
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
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
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
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
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

  func testSteamRuntimePrerequisitesCatalogPinsCompleteReleaseFileSet() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wine-root/../wine-root",
      isDirectory: true
    )

    let descriptor = TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
      applicationVersion: TrustedComponentCatalog.supportedApplicationVersion,
      buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier,
      variant: .publicInstalled,
      wineRootURL: root
    )

    XCTAssertEqual(descriptor.identity.componentID, "steam-runtime-prerequisites")
    XCTAssertEqual(descriptor.identity.componentVersion, "3")
    XCTAssertEqual(descriptor.identity.variant, .publicInstalled)
    XCTAssertEqual(
      descriptor.identity.buildIdentifier,
      TrustedComponentCatalog.supportedBuildIdentifier
    )
    XCTAssertEqual(descriptor.payloadRootURL, root.standardizedFileURL)
    XCTAssertEqual(
      descriptor.identity,
      TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
        applicationVersion: TrustedComponentCatalog.supportedApplicationVersion,
        buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier,
        variant: .publicInstalled,
        wineRootURL: root
      ).identity
    )
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: descriptor.files.map { ($0.relativePath, $0.expectedSHA256) }
      ),
      [
        "bin/wine":
          "735a1ef0f5c681ea0a8a89f4be2bd1fb079e915af1b3faabfce1f555bc944a8f",
        "bin/wineserver":
          "bf709571a2c040aebe2d721da0c3b2d4cecc1d11a941812bfd9f352579fe094b",
        "lib/wine/x86_64-unix/wine":
          "56db2f4832b29507dc42286f297a7df8508e372d5f73957e661cd1f84cfbc298",
        "lib/wine/x86_64-unix/ntdll.so":
          "15d3479d4ee348c4a7cb7e77507fa5664ef919eadefc2845dbdfd2ddced68009",
        "share/wine/wine.inf":
          "0315a55b11a456590a9368f4cb8d0011d6735cc04c9093ea583570d1352e1ee1",
        "lib/wine/x86_64-windows/ntdll.dll":
          "885c0421bfe30600bae9df83961b0fcbb5b9ccd1c02e7b071ce213ff2522e34a",
        "lib/wine/i386-windows/ntdll.dll":
          "7b580e19eb4fce14b5730cd2835c5204dc2622ce0fc4f33b68b0155864477667",
        "lib/wine/x86_64-windows/vcruntime140.dll":
          "f03a7c92ed8cda87fc0bf72a5af29962d26ca981b546b3ce0550fb57ca3ee7ff",
        "lib/wine/x86_64-windows/msvcp140.dll":
          "2a53d2db7e7b760d2b1d7ecd46b05653e11850363a10b097303d3491aaa4e94a",
        "lib/wine/x86_64-windows/ucrtbase.dll":
          "019e4bebf86cc4642fff63bc371223280ddfb0306ff379b04fe3f4dc2311ad22",
        "lib/wine/x86_64-windows/vcruntime140_1.dll":
          "69e58956261ae1081a6429c3813b143689f29849ffb693eb4fee399f335e4608",
        "lib/wine/i386-windows/vcruntime140.dll":
          "02037225c495c37747ae4cde08de6ff31119b850997799fa27237ca61bed7b35",
        "lib/wine/i386-windows/msvcp140.dll":
          "2727caf41f37eec4141c891e42365e261cc909b01d0ae568b12b9bf2fdcffa85",
        "lib/wine/i386-windows/ucrtbase.dll":
          "935fbefeb5462924e628df486ebfdad49b70a91154c9a8a57d9aa221fc91c119",
      ]
    )
    XCTAssertFalse(
      descriptor.files.contains {
        $0.expectedSHA256
          == "8fb847f4f71ae120609c963fc588d3ea77b0887f173858c2d462e424a2d8fd8e"
      },
      "el ntdll.so 1.11 con rutas GPTK genéricas no puede seguir autorizado"
    )
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: descriptor.files.map { ($0.relativePath, $0.expectedPOSIXMode) }
      ),
      [
        "bin/wine": 0o755,
        "bin/wineserver": 0o755,
        "lib/wine/x86_64-unix/wine": 0o755,
        "lib/wine/x86_64-unix/ntdll.so": 0o755,
        "share/wine/wine.inf": 0o644,
        "lib/wine/x86_64-windows/ntdll.dll": 0o644,
        "lib/wine/i386-windows/ntdll.dll": 0o644,
        "lib/wine/x86_64-windows/vcruntime140.dll": 0o644,
        "lib/wine/x86_64-windows/msvcp140.dll": 0o644,
        "lib/wine/x86_64-windows/ucrtbase.dll": 0o644,
        "lib/wine/x86_64-windows/vcruntime140_1.dll": 0o644,
        "lib/wine/i386-windows/vcruntime140.dll": 0o644,
        "lib/wine/i386-windows/msvcp140.dll": 0o644,
        "lib/wine/i386-windows/ucrtbase.dll": 0o644,
      ]
    )
  }

  func testSteamRuntimePrerequisitesRejectsLegacy111Authority() {
    let descriptor = TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
      variant: .publicInstalled,
      wineRootURL: URL(fileURLWithPath: "/Applications/Regression.app/Contents/SharedSupport/wine-root")
    )

    XCTAssertEqual(descriptor.identity.variant, .unsupported("Regression 1.11.0 (37)"))
    XCTAssertTrue(descriptor.files.isEmpty)
  }

  func testSteamRuntimeDevelopmentVariantFailsClosedWithoutReproduciblePins() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "development-runtime-without-authority-\(UUID().uuidString)",
      isDirectory: true
    )
    let descriptor = TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
      applicationVersion: TrustedComponentCatalog.supportedApplicationVersion,
      buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier,
      variant: .development,
      wineRootURL: root
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
    XCTAssertEqual(
      report.issue,
      .unsupportedVariant(
        "Regression \(TrustedComponentCatalog.supportedApplicationVersion) (\(TrustedComponentCatalog.supportedBuildIdentifier)): runtime de desarrollo sin PIN reproducible"
      )
    )
  }

  func testSteamRuntimePrerequisitesCorrectFileSetIsReadyAndReadOnly() throws {
    let fixture = try SteamRuntimePrerequisitesFixture()
    defer { fixture.remove() }
    try fixture.writeApprovedFiles()
    let unrelatedFIFO = fixture.root.appendingPathComponent("unrelated-runtime.pipe")
    XCTAssertEqual(Darwin.mkfifo(unrelatedFIFO.path, 0o600), 0)
    let before = try fixture.snapshot()

    let started = Date()
    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    XCTAssertEqual(report.status, .ready)
    XCTAssertEqual(report.recovery, .none)
    XCTAssertNil(report.issue)
    XCTAssertEqual(try fixture.snapshot(), before)
  }

  func testSteamRuntimePrerequisitesMissingFileRecommendsOnlyTrustedReinstall() throws {
    let fixture = try SteamRuntimePrerequisitesFixture()
    defer { fixture.remove() }
    try fixture.writeApprovedFiles(omitting: "lib/wine/i386-windows/ucrtbase.dll")

    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertEqual(report.status, .missing)
    XCTAssertEqual(report.recovery, .reinstallTrustedArtifact)
    XCTAssertEqual(
      report.issue,
      .payloadEntryMissing("lib/wine/i386-windows/ucrtbase.dll")
    )
  }

  func testSteamRuntimePrerequisitesDriftedFileIsRejected() throws {
    let fixture = try SteamRuntimePrerequisitesFixture()
    defer { fixture.remove() }
    try fixture.writeApprovedFiles()
    try Data("changed".utf8).write(
      to: fixture.root.appendingPathComponent("lib/wine/x86_64-windows/msvcp140.dll")
    )

    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.recovery, .reinstallTrustedArtifact)
    XCTAssertEqual(
      report.issue,
      .payloadDigestMismatch("lib/wine/x86_64-windows/msvcp140.dll")
    )
  }

  func testSteamRuntimeExecutableModeDriftIsRejected() throws {
    for executablePath in [
      "bin/wine",
      "bin/wineserver",
      "lib/wine/x86_64-unix/wine",
    ] {
      let fixture = try SteamRuntimePrerequisitesFixture()
      defer { fixture.remove() }
      try fixture.writeApprovedFiles()
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fixture.root.appendingPathComponent(executablePath).path
      )

      let report = ComponentHealthService.evaluate(fixture.descriptor())

      XCTAssertEqual(report.status, .drifted, executablePath)
      XCTAssertEqual(report.issue, .payloadEntryModeMismatch(executablePath))
    }
  }

  func testSteamRuntimePrerequisitesSymlinkIsRejectedWithoutReadingTarget() throws {
    let fixture = try SteamRuntimePrerequisitesFixture()
    defer { fixture.remove() }
    try fixture.writeApprovedFiles(omitting: "lib/wine/x86_64-windows/vcruntime140.dll")
    let outside = fixture.container.appendingPathComponent("outside.dll")
    let approved = fixture.contents["lib/wine/x86_64-windows/vcruntime140.dll"]!
    try approved.write(to: outside)
    let link = fixture.root.appendingPathComponent(
      "lib/wine/x86_64-windows/vcruntime140.dll"
    )
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(
      report.issue,
      .payloadEntryIsSymbolicLink("lib/wine/x86_64-windows/vcruntime140.dll")
    )
    XCTAssertEqual(try Data(contentsOf: outside), approved)
  }

  func testSteamRuntimePrerequisitesFIFOAndOversizedFileAreRejectedWithoutBlocking() throws {
    let fifoFixture = try SteamRuntimePrerequisitesFixture()
    defer { fifoFixture.remove() }
    let fifoPath = "lib/wine/x86_64-windows/vcruntime140_1.dll"
    try fifoFixture.writeApprovedFiles(omitting: fifoPath)
    let fifo = fifoFixture.root.appendingPathComponent(fifoPath)
    XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)

    let started = Date()
    let fifoReport = ComponentHealthService.evaluate(fifoFixture.descriptor())

    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    XCTAssertEqual(fifoReport.status, .drifted)
    XCTAssertEqual(fifoReport.issue, .payloadEntryIsNotRegularFile(fifoPath))

    let largeFixture = try SteamRuntimePrerequisitesFixture()
    defer { largeFixture.remove() }
    try largeFixture.writeApprovedFiles()
    let largeReport = ComponentHealthService.evaluate(
      largeFixture.descriptor(maximumFileBytes: 2)
    )

    XCTAssertEqual(largeReport.status, .drifted)
    XCTAssertEqual(
      largeReport.issue,
      .payloadEntryExceedsLimit("bin/wine")
    )
  }

  func testSteamRuntimePrerequisitesUnsupportedBuildIsRejectedBeforeFilesystemInspection() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "absent-runtime-\(UUID().uuidString)",
      isDirectory: true
    )
    let descriptor = TrustedComponentCatalog.steamRuntimePrerequisitesDescriptor(
      applicationVersion: "1.10.1",
      buildIdentifier: "37",
      variant: .publicInstalled,
      wineRootURL: root
    )

    let report = ComponentHealthService.evaluate(descriptor)

    XCTAssertEqual(report.status, .unsupportedVariant)
    XCTAssertEqual(report.recovery, .installSupportedApplicationBuild)
    XCTAssertEqual(report.issue, .unsupportedVariant("Regression 1.10.1 (37)"))
  }

  func testSteamRuntimePrerequisitesRootSymlinkIsRejected() throws {
    let fixture = try SteamRuntimePrerequisitesFixture()
    defer { fixture.remove() }
    try fixture.writeApprovedFiles()
    let actualRoot = fixture.container.appendingPathComponent("actual-wine-root", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.root, to: actualRoot)
    try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: actualRoot)

    let report = ComponentHealthService.evaluate(fixture.descriptor())

    XCTAssertEqual(report.status, .drifted)
    XCTAssertEqual(report.issue, .payloadIsNotARegularDirectory)
  }

  func testProductionWindowsMediaMissingPayloadOnlyRecommendsTrustedReinstall() {
    let roots = ProductionDescriptorRoots()
    let descriptor = TrustedComponentCatalog.windowsMediaDescriptor(
      applicationVersion: "1.11.0",
      buildIdentifier: "37",
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

  func testExternalLinkParentReplacementCannotRemainReady() throws {
    let fixture = try ComponentHealthFixture()
    defer { fixture.remove() }
    let manifestDigest = try fixture.writePayload(["BUILD.txt": "approved"])
    try fixture.linkExpectedPayload()
    let parent = fixture.externalLink.deletingLastPathComponent()
    let displaced = parent.deletingLastPathComponent().appendingPathComponent("component-before")
    var swapped = false

    let report = ComponentHealthService.evaluate(
      fixture.descriptor(manifestSHA256: manifestDigest),
      fileManager: .default,
      onExternalLinkTargetRead: {
        swapped = true
        try? FileManager.default.moveItem(at: parent, to: displaced)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
          at: fixture.externalLink,
          withDestinationURL: fixture.payload
        )
      }
    )

    XCTAssertTrue(swapped)
    XCTAssertNotEqual(report.status, .ready)
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

private final class SteamRuntimePrerequisitesFixture {
  private static let orderedPaths = [
    "bin/wine",
    "bin/wineserver",
    "lib/wine/x86_64-unix/wine",
    "lib/wine/x86_64-windows/vcruntime140.dll",
    "lib/wine/x86_64-windows/msvcp140.dll",
    "lib/wine/x86_64-windows/ucrtbase.dll",
    "lib/wine/x86_64-windows/vcruntime140_1.dll",
    "lib/wine/i386-windows/vcruntime140.dll",
    "lib/wine/i386-windows/msvcp140.dll",
    "lib/wine/i386-windows/ucrtbase.dll",
  ]

  let container: URL
  let root: URL
  let contents: [String: Data] = [
    "bin/wine": Data("wine-wrapper".utf8),
    "bin/wineserver": Data("wineserver".utf8),
    "lib/wine/x86_64-unix/wine": Data("wine-loader".utf8),
    "lib/wine/x86_64-windows/vcruntime140.dll": Data("x64-vcruntime".utf8),
    "lib/wine/x86_64-windows/msvcp140.dll": Data("x64-msvcp".utf8),
    "lib/wine/x86_64-windows/ucrtbase.dll": Data("x64-ucrt".utf8),
    "lib/wine/x86_64-windows/vcruntime140_1.dll": Data("x64-vcruntime-1".utf8),
    "lib/wine/i386-windows/vcruntime140.dll": Data("x86-vcruntime".utf8),
    "lib/wine/i386-windows/msvcp140.dll": Data("x86-msvcp".utf8),
    "lib/wine/i386-windows/ucrtbase.dll": Data("x86-ucrt".utf8),
  ]

  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "regression-steam-runtime-\(UUID().uuidString)",
      isDirectory: true
    )
    root = container.appendingPathComponent("wine-root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func descriptor(maximumFileBytes: Int64 = 1_024) -> TrustedComponentFileSetDescriptor {
    TrustedComponentFileSetDescriptor(
      identity: ComponentIdentity(
        componentID: "steam-runtime-prerequisites-test",
        componentVersion: "1",
        variant: .development,
        buildIdentifier: "36"
      ),
      payloadRootURL: root,
      files: Self.orderedPaths.map { path in
        TrustedComponentFile(
          relativePath: path,
          expectedSHA256: Self.sha256(contents[path]!),
          expectedPOSIXMode: path == "bin/wine"
            || path == "bin/wineserver"
            || path == "lib/wine/x86_64-unix/wine" ? 0o755 : 0o644
        )
      },
      maximumFileBytes: maximumFileBytes,
      maximumPayloadBytes: 8_192
    )
  }

  func writeApprovedFiles(omitting omittedPath: String? = nil) throws {
    for (path, data) in contents where path != omittedPath {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url)
      try FileManager.default.setAttributes(
        [.posixPermissions: path == "bin/wine"
          || path == "bin/wineserver"
          || path == "lib/wine/x86_64-unix/wine" ? 0o755 : 0o644],
        ofItemAtPath: url.path
      )
    }
  }

  func snapshot() throws -> [String: Data] {
    try Dictionary(
      uniqueKeysWithValues: contents.keys.sorted().map { path in
        (path, try Data(contentsOf: root.appendingPathComponent(path)))
      }
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: container)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
